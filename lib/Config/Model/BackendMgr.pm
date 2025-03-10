#
# This file is part of Config-Model
#
# This software is Copyright (c) 2005-2022 by Dominique Dumont.
#
# This is free software, licensed under:
#
#   The GNU Lesser General Public License, Version 2.1, February 1999
#
package Config::Model::BackendMgr 2.152;

use Mouse;
use strict;
use warnings;

use Carp;
use 5.10.1;

use Config::Model::Exception;
use Data::Dumper;
use Storable qw/dclone/;
use Scalar::Util qw/weaken reftype/;
use Log::Log4perl qw(get_logger :levels);
use Path::Tiny 0.070;

my $logger = get_logger('BackendMgr');
my $user_logger = get_logger('User');

# one BackendMgr per file

has 'node' => (
    is       => 'ro',
    isa      => 'Config::Model::Node',
    weak_ref => 1,
    required => 1
);
has 'file_backup' => ( is => 'rw', isa => 'ArrayRef', default => sub { [] } );

has 'rw_config' => (
    is => 'ro',
    isa => 'HashRef',
    required => 1
);

has 'backend_obj' => (
    is      => 'rw',
    isa     => 'Config::Model::Backend::Any',
    lazy    => 1 ,
    builder => '_build_backend_obj',
);

sub _build_backend_obj {
    my $self = shift;

    my $backend = $self->rw_config->{backend};
    $logger->warn("function parameter for a backend is deprecated. Please implement 'read' method in backend $backend")
        if $self->rw_config->{function};
    # try to load a specific Backend class
    my $f = $self->rw_config->{function} || 'read';
    my $c = $self->load_backend_class( $backend, $f );

    no strict 'refs'; ## no critic (ProhibitNoStrict)
    return $c->new(
        node => $self->node,
        name => $backend,
        auto_create => $self->rw_config->{auto_create},
        auto_delete => $self->rw_config->{auto_delete},
    );
}

has support_annotation => (
    is => 'ro',
    isa => 'Bool',
    default => 0,
);

with "Config::Model::Role::ComputeFunction";
with "Config::Model::Role::FileHandler";

# check if dir is present. May create it in auto_create write mode
sub get_cfg_dir_path {
    my $self = shift;
    my %args = @_;

    my $w = $args{write} || 0;
    my $dir = $self->get_tuned_config_dir(%args);

    if ( not $dir->is_dir and $w and $args{auto_create} ) {
        $logger->info("creating directory $dir");
        $dir->mkpath;
    }

    unless ( $dir->is_dir ) {
        my $mode = $w ? 'write' : 'read';
        $logger->info( "$args{backend}: missing directory $dir ($mode mode)" );
        return ( 0, $dir );
    }

    $logger->trace( "dir: " . $dir // '<undef>' );

    return ( 1, $dir );
}

# return (1, config file path) constructed from arguments or return
# (0). May create directory in auto_create write mode.
sub get_cfg_file_path {
    my $self = shift;
    my %args = @_;

    my $w = $args{write} || 0;

    # config file override
    my $cfo = $args{config_file};

    if ( defined $cfo) {
        my $override
            = $args{root}   ? $args{root}->child($cfo)
            : $cfo =~ m!^/! ? path($cfo)
            :                 path('.')->child($cfo);

        my $mode = $w ? 'write' : 'read';
        $logger->trace("$args{backend} override target file is $override ($mode mode)");
        return ( 1, $override );
    }

    my ( $dir_ok, $dir ) = $self->get_cfg_dir_path(%args);

    if ( defined $args{file} ) {
        my $file = $args{skip_compute} ? $args{file} : $self->node->compute_string($args{file});
        my $res = $dir->child($file);
        $logger->trace("get_cfg_file_path: returns $res");
        return ( $dir_ok, $res );
    }

    return 0;
}

sub open_read_file {
    my ($self, $file_path) = @_;

    if ( $file_path->is_file ) {
        $logger->debug("open_read_file: open $file_path for read");
        # store a backup in memory in case there's a problem
        $self->file_backup( [ $file_path->lines_utf8 ] );
        return $file_path->filehandle("<", ":utf8");
    }
    else {
        return;
    }
}

# called at configuration node creation
#
# New subroutine "load_backend_class" extracted - Thu Aug 12 18:32:37 2010.
#
sub load_backend_class {
    my $self = shift;
    my $backend  = shift;
    my $function = shift;

    $logger->trace("load_backend_class: called with backend $backend, function $function");
    my %c;

    my $k = "Config::Model::Backend::" . ucfirst($backend);
    my $f = $k . '.pm';
    $f =~ s!::!/!g;
    $c{$k} = $f;

    # try another class
    $k =~ s/_(\w)/uc($1)/ge;
    $f =~ s/_(\w)/uc($1)/ge;
    $c{$k} = $f;

    foreach my $c ( sort keys %c ) {
        if ( $c->can($function) ) {

            # no need to load class
            $logger->debug("load_backend_class: $c is already loaded (can $function)");
            return $c;
        }
    }

    # look for file to load
    my $class_to_load;
    foreach my $c ( sort keys %c ) {
        $logger->trace("load_backend_class: looking to load class $c");
        foreach my $prefix (@INC) {
            my $realfilename = "$prefix/$c{$c}";
            $class_to_load = $c if -f $realfilename;
        }
    }

    if (not defined  $class_to_load) {
        Config::Model::Exception::Model->throw(
            object => $self->node,
            error => "backend error: cannot find Perl class for backend: '$backend'",
        );
    };
    my $file_to_load = $c{$class_to_load};

    $logger->trace("load_backend_class: loading class $class_to_load, $file_to_load");
    eval { require $file_to_load; };

    if ($@) {
        die "Error with backend $backend: could not parse $file_to_load: $@\n";
    }
    return $class_to_load;
}

sub read_config_data {
    my ( $self, %args ) = @_;

    $logger->trace( "called for node ", $self->node->location );

    my $check                = delete $args{check};
    my $config_file_override = delete $args{config_file};
    my $auto_create_override = delete $args{auto_create};

    croak "unexpected args " . join( ' ', keys %args ) . "\n" if %args;

    my $rw_config = dclone $self->rw_config ;

    my $instance = $self->node->instance();

    # root override is passed by the instance
    my $root_dir = $instance->root_dir ;

    my $auto_create  = $rw_config->{auto_create};
    my $backend = $rw_config->{backend};

    if ( $rw_config->{default_layer} ) {
        $self->read_config_sub_layer( $rw_config, $root_dir, $config_file_override, $check,
                                      $backend );
    }

    my ( $res, $file ) =
        $self->try_read_backend( $rw_config, $root_dir, $config_file_override, $check, $backend );

    Config::Model::Exception::ConfigFile::Missing->throw (
        file   => $file || "<unknown>",
        object => $self->node,
    ) unless $res or $auto_create_override or $auto_create;

}

sub read_config_sub_layer {
    my ( $self, $rw_config, $root_dir, $config_file_override, $check, $backend ) = @_;

    my $layered_config = delete $rw_config->{default_layer};
    my $layered_read   = dclone $rw_config ;

    foreach my $item ( qw/file config_dir os_config_dir/ ) {
        my $lc = delete $layered_config->{$item};
        $layered_read->{$item} = $lc if $lc;
    }

    Config::Model::Exception::Model->throw(
        error => "backend error: unexpected default_layer parameters: "
            . join( ' ', sort keys %$layered_config ),
        object => $self->node,
    ) if %$layered_config;

    my $i                  = $self->node->instance;
    my $already_in_layered = $i->layered;

    # layered stuff here
    if ( not $already_in_layered ) {
        $i->layered_clear;
        $i->layered_start;
    }

    $self->try_read_backend( $layered_read, $root_dir, $config_file_override, $check, $backend );

    if ( not $already_in_layered ) {
        $i->layered_stop;
    }
}

# called at configuration node creation, NOT when writing
#
# New subroutine "try_read_backend" extracted - Sun Jul 14 11:52:58 2013.
#
sub try_read_backend {
    my $self                 = shift;
    my $rw_config            = shift;
    my $root_dir             = shift;
    my $config_file_override = shift;
    my $check                = shift;
    my $backend              = shift;

    my $read_dir = $self->get_tuned_config_dir(%$rw_config);

    my @read_args = (
        %$rw_config,
        root        => $root_dir,
        config_dir  => $read_dir,
        backend     => $backend,
        check       => $check,
        config_file => $config_file_override
    );

    my $backend_obj = $self->backend_obj();

    if ($backend_obj->can('suffix')) {
        $logger->warn("suffix method is deprecated. you can remove it from backend $backend");
    }

    my ( $file_ok, $file_path ) = $self->get_cfg_file_path(
        @read_args,
        skip_compute => $backend_obj->skip_open,
    );

    my $fh;
    if (not $backend_obj->skip_open and $file_ok) {
        $fh = $self->open_read_file($file_path) ;
    }

    my $f = $self->rw_config->{function} || 'read';
    if ($logger->is_info) {
        my $fp = defined $file_path ? " on $file_path":'' ;
        $logger->info( "Read with $backend " . reftype($backend_obj) . "::$f".$fp);
    }

    my $res;

    eval {
        $res = $backend_obj->$f(
            @read_args,
            file_path => $file_path,
            object    => $self->node,
        );
    };
    my $error = $@;

    # catch eval error
    if ( ref($error) and $error->isa('Config::Model::Exception::Syntax') ) {

        $error->parsed_file( $file_path) unless $error->parsed_file;
        $error->rethrow;
    }
    elsif ( ref $error and $error->isa('Config::Model::Exception') ) {
        $error->rethrow ;
    }
    elsif ( ref $error ) {
        die $error ;
    }
    elsif ( $error ) {
        die "Backend $backend failed to read $file_path: $error";
    }

    # only backend based on C::M::Backend::Any can support annotations
    if ($backend_obj->can('annotation')) {
        $self->{support_annotation} = $backend_obj->annotation ;
    }

    return ( $res, $file_path );
}

sub auto_write_init {
    my ( $self, %args ) = @_;

    croak "auto_write_init: unexpected args " . join( ' ', sort keys %args ) . "\n"
        if %args;

    my $rw_config = dclone $self->rw_config ;

    my $instance = $self->node->instance();

    # root override is passed by the instance
    my $root_dir = $instance->root_dir;

    my $backend = $rw_config->{backend};

    my $write_dir = $self->get_tuned_config_dir(%$rw_config);

    $logger->trace( "auto_write_init creating write cb ($backend) for ", $self->node->name );

    my @wr_args = (
        %$rw_config,            # model data
        config_dir  => $write_dir,    # override from instance
        write       => 1,             # for get_cfg_file_path
        root        => $root_dir,     # override from instance
    );

    # used bby C::M::Dumper and C::M::DumpAsData
    # TODO: is this needed once multi backend are removed
    $self->{auto_write}{$backend} = 1;

    my $wb;
    my $f = $rw_config->{function} || 'write';
    my $backend_class = $self->load_backend_class( $backend, $f );
    my $location = $self->node->name;
    my $node = $self->node;     # closure

    # provide a proper write back function
    $wb = sub {
        my %cb_args = @_;

        my $force_delete = delete $cb_args{force_delete} ;
        $logger->debug( "write cb ($backend) called for $location ", $force_delete ? '' : ' (deleted)' );
        my $backend_obj = $self->backend_obj();

        my ($fh, $file_ok, $file_path );

        if (not $backend_class->skip_open) {
            ( $file_ok, $file_path ) = $self->get_cfg_file_path( @wr_args, %cb_args);
        }

        if ($file_ok) {
            $fh = $self->open_file_to_write( $backend, $file_path, delete $cb_args{backup} );
        }

        # override needed for "save as" button
        my %backend_args = (
            @wr_args,
            file_path => $file_path,
            object    => $node,
            %cb_args            # override from user
        );

        my $res;
        if ($force_delete) {
            $backend_obj->delete(%backend_args);
        }
        else {
            $res = eval { $backend_obj->$f( %backend_args ); };
            my $error = $@;
            $logger->error( "write backend $backend $backend_class" . '::' . "$f failed: $error" )
                if $error;
            $self->close_file_to_write( $error, $file_path, $rw_config->{file_mode} );

            $self->auto_delete($file_path, \%backend_args)
                if $rw_config->{auto_delete} and not $backend_class->skip_open ;
        }

        return defined $res ? $res : $@ ? 0 : 1;
    };

    $logger->trace( "registering write $backend in node " . $self->node->name );

    $instance->register_write_back(  $self->node->location, $backend, $wb  );
}

sub auto_delete {
    my ($self, $file_path, $args) = @_;

    return unless $file_path;

    my $perl_data;
    $perl_data = $self->node->dump_as_data( full_dump => $args->{full_dump} // 0)
        if defined $self->node;

    my $size = ref($perl_data) eq 'HASH'  ? scalar keys %$perl_data
             : ref($perl_data) eq 'ARRAY' ? scalar @$perl_data
             :                              $perl_data ;
    if (not $size) {
        $logger->info( "Removing $file_path (no data to store)" );
        unlink($file_path);
    }
}


sub open_file_to_write {
    my ( $self, $backend, $file_path, $backup ) = @_;

    my $do_backup = defined $backup;
    $backup ||= 'old';    # use old only if defined
    $backup = '.' . $backup unless $backup =~ /^\./;

    # make sure that parent dir exists before creating file
    $file_path->parent->mkpath;

    if ( $do_backup and $file_path->is_file ) {
        $file_path->copy( $file_path.$backup ) or die "Backup copy failed: $!";
    }

    $logger->debug("$backend backend opened file $file_path to write");
    return $file_path->filehandle(">",":utf8");
}

sub close_file_to_write {
    my ( $self, $error, $file_path, $file_mode ) = @_;

    return unless defined $file_path;

    if ($error) {
        # restore backup and display error
        $logger->warn("Error during write, restoring backup data in $file_path" );
        $file_path->append_utf8({ truncate => 1 }, $self->file_backup );
        $error->rethrow if ref($error) and $error->can('rethrow');
        die $error;
    }

    # TODO: move chmod in a backend role
    $file_path->chmod($file_mode) if $file_mode;

    # TODO: move in a backend role
    # check file size and remove empty files
    $file_path->remove if -z $file_path and not -l $file_path;
}

sub is_auto_write_for_type {
    my $self = shift;
    my $type = shift;
    return $self->{auto_write}{$type} || 0;
}

__PACKAGE__->meta->make_immutable;

1;

# ABSTRACT: Load configuration node on demand

__END__

=pod

=encoding UTF-8

=head1 NAME

Config::Model::BackendMgr - Load configuration node on demand

=head1 VERSION

version 2.152

=head1 SYNOPSIS

 # Use BackendMgr to write data in Yaml file
 # This example requires Config::Model::Backend::Yaml which is now
 # shipped outside of Config::Model. Please get it on CPAN
 use Config::Model;

 # define configuration tree object
 my $model = Config::Model->new;
 $model->create_config_class(
    name    => "Foo",
    element => [
        [qw/foo bar/] => {
            type       => 'leaf',
            value_type => 'string'
        },
    ]
 );

 $model->create_config_class(
    name => "MyClass",

    # rw_config spec is used by Config::Model::BackendMgr
    rw_config => {
        backend     => 'yaml',
        config_dir  => '/tmp/',
        file        => 'my_class.yml',
        auto_create => 1,
    },

    element => [
        [qw/foo bar/] => {
            type       => 'leaf',
            value_type => 'string'
        },
        hash_of_nodes => {
            type       => 'hash',     # hash id
            index_type => 'string',
            cargo      => {
                type              => 'node',
                config_class_name => 'Foo'
            },
        },
    ],
 );

 my $inst = $model->instance( root_class_name => 'MyClass' );

 my $root = $inst->config_root;

 # put data
 my $steps = 'foo=FOO hash_of_nodes:fr foo=bonjour -
   hash_of_nodes:en foo=hello ';
 $root->load( steps => $steps );

 $inst->write_back;

 # now look at file /tmp/my_class.yml

=head1 DESCRIPTION

This class provides a way to specify how to load or store
configuration data within the model.

With these specifications, all configuration information is read
during creation of a node (which triggers the creation of a backend
manager object) and written back when L<write_back|Config::Model::Instance/write_back>
method is called either on the instance.

=begin comment

This feature is also useful if you want to read configuration class
declarations at run time. (For instance in a C</etc> directory like
C</etc/some_config.d>). In this case, each configuration class must
specify how to read and write configuration information.

Idea: sub-files name could be <instance>%<location>.cds

=end comment

This load/store can be done with different backends:

=over

=item *

Any of the C<Config::Model::Backend::*> classes available on your system.
For instance C<Config::Model::Backend::Yaml>.

=item *

C<cds_file>: Config dump string (cds) in a file. I.e. a string that describes the
content of a configuration tree is loaded from or saved in a text
file. This format is defined by this project. See
L<Config::Model::Loader/"load string syntax">.

=item *

C<perl_file>: Perl data structure (perl) in a file. See L<Config::Model::DumpAsData>
for details on the data structure. Now handled by L<Config::Model::Backend::PerlFile>

=back

When needed, C<write_back> method can be called on the instance (See
L<Config::Model::Instance>) to store back all configuration information.

=head1 Backend specification

The backend specification is provided as an attribute of a
L<Config::Model::Node> specification. These attributes are optional:
A node without C<rw_config> attribute must rely on another node to
read or save its data.

When needed (usually for the root node), the configuration class is
declared with a C<rw_config> parameter which specifies the read/write
backend configuration.

=head2 Parameters available for all backends

The following parameters are accepted by all backends:

=over 4

=item config_dir

Specify configuration directory. This parameter is optional as the
directory can be hardcoded in the backend class. C<config_dir> beginning
with 'C<~>' is munged so C<~> is replaced by C<< File::HomeDir->my_data >>.
See L<File::HomeDir> for details.

=item file

Specify configuration file name (without the path). This parameter is
optional as the file name can be hardcoded in the backend class.

The configuration file name can be specified with C<&index> keyword
when a backend is associated to a node contained in a hash. For instance,
with C<file> set to C<&index.conf>:

 service    # hash element
   foo      # hash index
     nodeA  # values of nodeA are stored in foo.conf
   bar      # hash index
     nodeB  # values of nodeB are  stored in bar.conf

Likewise, the keyword C<&element> can be used to specify the file
name. For instance, with C<file> set to C<&element-&index.conf>:

 service    # hash element
   foo      # hash index
     nodeA  # values of nodeA are stored in service.foo.conf
   bar      # hash index
     nodeB  # values of nodeB are  stored in service.bar.conf

=item file_mode

C<file_mode> parameter can be used to set the mode of the written
file(s). C<file_mode> value can be in any form supported by
L<Path::Tiny/chmod>. Example:

  file_mode => 0664,
  file_mode => '0664',
  file_mode => 'g+w'

=item os_config_dir

Specify alternate location of a configuration directory depending on the OS
(as returned by C<$^O>, see L<perlport/PLATFORMS>).
For instance:

 config_dir => '/etc/ssh',
 os_config_dir => { darwin => '/etc' }

=item default_layer

Optional. Specifies where to find a global configuration file that
specifies default values. For instance, this is used by OpenSSH to
specify a global configuration file (C</etc/ssh/ssh_config>) that is
overridden by user's file:

 default_layer => {
    os_config_dir => { 'darwin' => '/etc' },
    config_dir    => '/etc/ssh',
    file          => 'ssh_config'
 }

Only the 3 above parameters can be specified in C<default_layer>.

=item auto_create

By default, an exception is thrown if no read was
successful. This behavior can be overridden by specifying
C<< auto_create => 1 >> in one of the backend specification. For instance:

 rw_config  => {
     backend => 'IniFile',
     config_dir => '/tmp',
     file  => 'foo.conf',
     auto_create => 1
 },

Setting C<auto_create> to 1 is necessary to create a configuration
from scratch

=item auto_delete

Delete configuration files that contains no data. (default is to leave an empty file)

=back

=head2 Config::Model::Backend::* backends

Specify the backend name and the parameters of the backend defined
in their documentation.

For instance:

 rw_config => {
     backend     => 'yaml',
     config_dir  => '/tmp/',
     file        => 'my_class.yml',
 },

See L<Config::Model::Backend::Yaml> for more details for this backend.

=head2 Your own backend

You can also write a dedicated backend. See
L<How to write your own backend|Config::Model::Backend::Any/"How to write your own backend">
for details.

=head1 Test setup

By default, configurations files are read from the directory specified
by C<config_dir> parameter specified in the model. You may override the
C<root> directory for test.

=head1 Methods

=head2 support_annotation

Returns 1 if at least the backend supports read and write annotations
(aka comments) in the configuration file.

=head1 AUTHOR

Dominique Dumont, (ddumont at cpan dot org)

=head1 SEE ALSO

L<Config::Model>, L<Config::Model::Instance>,
L<Config::Model::Node>, L<Config::Model::Dumper>

=head1 AUTHOR

Dominique Dumont

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2005-2022 by Dominique Dumont.

This is free software, licensed under:

  The GNU Lesser General Public License, Version 2.1, February 1999

=cut
