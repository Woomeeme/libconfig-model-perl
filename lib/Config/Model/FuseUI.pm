#
# This file is part of Config-Model
#
# This software is Copyright (c) 2005-2022 by Dominique Dumont.
#
# This is free software, licensed under:
#
#   The GNU Lesser General Public License, Version 2.1, February 1999
#
package Config::Model::FuseUI 2.152;

# there's no Singleton with Mouse
use Mouse;

use Fuse qw(fuse_get_context);
use Fcntl ':mode';
use POSIX qw(ENOENT EISDIR EINVAL);
use Log::Log4perl qw(get_logger :levels);
use English qw( -no_match_vars );

has model      => ( is => 'rw', isa => 'Config::Model' );
has root       => ( is => 'ro', isa => 'Config::Model::Node', required => 1 );
has mountpoint => ( is => 'ro', isa => 'Str', required => 1 );

my $logger = get_logger("FuseUI");

has dir_char_mockup => ( is => 'ro', isa => 'Str', default => '<slash>' );

our $fuseui;
my $dir_char_mockup;

sub BUILD {
    my $self = shift;
    croak( __PACKAGE__, " singleton constructed twice" )
        if defined $fuseui and $fuseui ne $self;
    $fuseui          = $self;                    # store singleton object in global variable
    $dir_char_mockup = $self->dir_char_mockup;
}

# nodes, list and hashes are directories
sub getdir {
    my $name = shift;
    $logger->trace("FuseUI getdir called with $name");

    my $obj = get_object($name);
    return -EINVAL() unless ( ref $obj and $obj->can('children') );

    my @c = ( '..', '.', $obj->children );
    for (@c) { s(/)($dir_char_mockup)g };
    $logger->debug( "FuseUI getdir return @c , wantarray is " . ( wantarray ? 1 : 0 ) );
    return ( @c, 0 );
}

sub fetch_as_line {
    my $obj = shift;
    my $v = $obj->fetch( check => 'no' );
    $v = '' unless defined $v;

    # let's append a \n so that returned files always have a line ending
    $v .= "\n" unless $v =~ /\n$/;

    return $v;
}

sub get_object {
    my $name = shift;
    return _get_object( $name, 0 );
}

sub get_or_create_object {
    my $name = shift;
    return _get_object( $name, 1 );
}

sub _get_object {
    my ( $name, $autoadd ) = @_;

    my $obj = $fuseui->root->get(
        path            => $name,
        check           => 'skip',
        get_obj         => 1,
        autoadd         => $autoadd,
        dir_char_mockup => $dir_char_mockup
    );
    $logger->debug( "FuseUI _get_object on $name returns ",
        ( defined $obj ? $obj->name : '<undef>' ) );
    return $obj;

}

sub getattr {
    my $name = shift;
    $logger->trace("FuseUI getattr called with $name");
    my $obj = get_object($name);

    return -&ENOENT() unless ref $obj;

    my $type = $obj->get_type;

    # return -ENOENT() unless exists($files{$file});

    my $size;
    if ( $type eq 'leaf' or $type eq 'check_list' ) {
        $size = length( fetch_as_line($obj) );
    }
    else {
        # fuseui_obj->children does not return the right data in scalar context
        my @c = $obj->children;
        $size = @c;
    }

    my $mode;
    if ( $type eq 'leaf' or $type eq 'check_list' ) {
        $mode = S_IFREG | oct(644);
    }
    else {
        $mode = S_IFDIR | oct(755);
    }

    my ( $dev, $ino, $rdev, $blocks, $gid, $uid, $nlink, $blksize ) =
        ( 0, 0, 0, 1, $EGID, $EUID, 1, 1024 );
    my ( $atime, $ctime, $mtime );
    $atime = $ctime = $mtime = time;

# 2 possible types of return values:
#return -ENOENT(); # or any other error you care to
#print(join(",",($dev,$ino,$modes,$nlink,$uid,$gid,$rdev,$size,$atime,$mtime,$ctime,$blksize,$blocks)),"\n");
    my @r = (
        $dev,  $ino,   $mode,  $nlink, $uid,     $gid, $rdev,
        $size, $atime, $mtime, $ctime, $blksize, $blocks
    );
    $logger->trace( "FuseUI getattr returns '" . join( "','", @r ) . "'" );

    return @r;
}

sub open {

    # VFS sanity check; it keeps all the necessary state, not much to do here.
    my $name = shift;
    $logger->trace("FuseUI open called on $name");
    my $obj = $fuseui->root->get( path => $name, check => 'skip', get_obj => 1 );
    my $type = $obj->get_type;

    return -ENOENT() unless defined $obj;
    return -EISDIR() unless ( $type eq 'leaf' or $type eq 'check_list' );
    $logger->debug("FuseUI open on $name ok");
    return 0;
}

sub read {

    # return an error numeric, or binary/text string.  (note: 0 means EOF, "0" will
    # give a byte (ascii "0") to the reading program)
    my ( $name, $buf, $off ) = @_;

    $logger->trace("FuseUI read called on $name");
    my $obj  = get_or_create_object($name);
    my $type = $obj->get_type;

    return -ENOENT() unless defined $obj;
    return -EISDIR() unless ( $type eq 'leaf' or $type eq 'check_list' );
    my $v = fetch_as_line($obj);

    if ( not defined $v ) {
        return -EINVAL() if $off > 0;
        return '';
    }

    return -EINVAL() if $off > length($v);
    return 0 if $off == length($v);
    my $ret = substr( $v, $off, $buf );
    $logger->debug("FuseUI read returns '$ret'");
    return "$ret";
}

sub truncate {
    my ( $name, $off ) = @_;

    $logger->trace("FuseUI truncate called on $name with length $off");
    my $obj  = get_or_create_object($name);
    my $type = $obj->get_type;

    return -ENOENT() unless defined $obj;
    return -EISDIR() unless ( $type eq 'leaf' or $type eq 'check_list' );

    my $v = substr fetch_as_line($obj), 0, $off;

    $logger->trace( "FuseUI truncate stores '$v' of length ", length($v) );

    # store the value without any check. Check will be done in write()
    # the second parameter will trigger a notif_change.
    $obj->_store_value( $v, 1 );
    return 0;
}

sub write {
    my ( $name, $buf, $off ) = @_;

    if ( $logger->is_trace ) {
        my $str = $buf;
        $str =~ s/\n/\\n/g;
        $logger->trace("FuseUI write called on $name with '$str' offset $off");
    }

    my $obj  = get_or_create_object($name);
    my $type = $obj->get_type;

    return -ENOENT() unless defined $obj;
    return -EISDIR() unless ( $type eq 'leaf' or $type eq 'check_list' );

    my $v = fetch_as_line($obj);
    $logger->debug("FuseUI write starts with '$v'");

    substr $v, $off, length($buf), $buf;
    chomp $v unless ( $type eq 'leaf' and $obj->value_type eq 'string' );
    $logger->debug("FuseUI write stores '$v'");
    $obj->store( value => $v, check => 'skip', say_dont_warn => 1 );

    return length($buf);
}

sub mkdir {

    # return an error numeric, or binary/text string.  (note: 0 means EOF, "0" will
    # give a byte (ascii "0") to the reading program)
    my ( $name, $mode ) = @_;

    $logger->trace("FuseUI mkdir called on $name with mode $mode");
    my $obj = get_or_create_object($name);
    return -ENOENT() unless defined $obj;

    my $type = $obj->container_type;
    return -ENOENT() unless ( $type eq 'list' or $type eq 'hash' );

    return 0;
}

sub rmdir {

    # return an error numeric, or binary/text string.  (note: 0 means EOF, "0" will
    # give a byte (ascii "0") to the reading program)
    my ($name) = @_;

    $logger->trace("FuseUI rmdir called on $name");
    my $obj = get_object($name);
    return -ENOENT() unless defined $obj;

    my $type = $obj->get_type;
    return -ENOENT() if ( $type eq 'leaf' or $type eq 'check_list' );

    my $ct       = $obj->container_type;
    my $elt_name = $obj->element_name;
    my $parent   = $obj->parent;

    if ( $ct eq 'list' or $ct eq 'hash' ) {
        my $idx = $obj->index_value;
        $logger->debug("FuseUI rmdir actually deletes $idx");
        $parent->fetch_element($elt_name)->delete($idx);
    }

    # ignore deletion request for other "non deletable" elements

    return 0;
}

sub unlink {
    my ($name) = @_;

    $logger->debug("FuseUI unlink called on $name");
    my $obj  = get_object($name);
    my $type = $obj->get_type;

    return -ENOENT() unless defined $obj;
    return -EISDIR() unless ( $type eq 'leaf' or $type eq 'check_list' );

    my $ct       = $obj->container_type;
    my $elt_name = $obj->element_name;
    my $parent   = $obj->parent;

    if ( $ct eq 'list' or $ct eq 'hash' ) {
        my $idx = $obj->index_value;
        $logger->debug("FuseUI unlink actually deletes $idx");
        $parent->fetch_element($elt_name)->delete($name);
    }

    # ignore deletion request for other "non deletable" elements

    return 0;
}

sub statfs { return 255, 1, 1, 1, 1, 2 }

my @methods = map { ( $_ => __PACKAGE__ . "::$_" ) }
    qw/getattr getdir open read write statfs truncate unlink mkdir rmdir/;

# FIXME: flush release
# maybe also: readlink mknod symlink rename link chmod chown utime

sub run_loop {
    my ( $self, %args ) = @_;
    my $debug = $args{debug} || 0;

    Fuse::main(
        mountpoint => $self->mountpoint,
        @methods,
        debug => $debug || 0,
        threaded => 0,
    );
}

1;

# ABSTRACT: Fuse virtual file interface for Config::Model

__END__

=pod

=encoding UTF-8

=head1 NAME

Config::Model::FuseUI - Fuse virtual file interface for Config::Model

=head1 VERSION

version 2.152

=head1 SYNOPSIS

 # command line
 mkdir mydir
 cme fusefs popcon -fuse-dir mydir
 ll mydir
 fusermount -u mydir

 # programmatic
 use Config::Model ;
 use Config::Model::FuseUI ;

 my $model = Config::Model -> new; 
 my $root = $model -> instance (root_class_name => "PopCon") -> config_root ; 
 my $ui = Config::Model::FuseUI->new( root => $root, mountpoint => "mydir" ); 
 $ui -> run_loop ;  # blocking call

 # explore mydir in another terminal then umount mydir directory

=head1 DESCRIPTION

This module provides a virtual file system interface for you configuration data. Each possible 
parameter of your configuration file is mapped to a file. 

=head1 Example 

 $ cme fusefs popcon -fuse-dir fused
 Mounting config on fused in background.
 Use command 'fusermount -u fused' to unmount
 $ ll fused
 total 4
 -rw-r--r-- 1 domi domi  1 Dec  8 19:27 DAY
 -rw-r--r-- 1 domi domi  0 Dec  8 19:27 HTTP_PROXY
 -rw-r--r-- 1 domi domi  0 Dec  8 19:27 MAILFROM
 -rw-r--r-- 1 domi domi  0 Dec  8 19:27 MAILTO
 -rw-r--r-- 1 domi domi 32 Dec  8 19:27 MY_HOSTID
 -rw-r--r-- 1 domi domi  3 Dec  8 19:27 PARTICIPATE
 -rw-r--r-- 1 domi domi  0 Dec  8 19:27 SUBMITURLS
 -rw-r--r-- 1 domi domi  3 Dec  8 19:27 USEHTTP
 $ fusermount -u fuse_dir

=head1 BUGS

=over

=item *

For some configuration, mapping each parameter to a file may lead to a high number of files.

=item *

The content of a file is when writing a wrong value. I.e. the files is
empty and the old value is lost.

=back

=head1 constructor

=head1 new

parameters are:

=over

=item model

Config::Model object

=item root

Root of the configuration tree (C<Config::Model::Node> object )

=item mountpoint

=back

=head1 Methods

=head2 run_loop

Parameters: C<< ( fork_in_loop => 1|0, debug => 1|0 ) >>

Mount the file system either in the current process or fork a new process before mounting the file system.
In the former case, the call is blocking. In the latter case, the call returns after forking a process that
performs the mount. Debug parameter is passed to Fuse system to get traces from Fuse.

=head2 fuse_mount

Mount the fuse file system. This method blocks until the file system is
unmounted (with C<fusermount -u mount_point> command)

=head1 SEE ALSO

L<Fuse>, L<Config::Model>, L<cme>

=head1 AUTHOR

Dominique Dumont

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2005-2022 by Dominique Dumont.

This is free software, licensed under:

  The GNU Lesser General Public License, Version 2.1, February 1999

=cut
