#
# This file is part of Config-Model
#
# This software is Copyright (c) 2005-2022 by Dominique Dumont.
#
# This is free software, licensed under:
#
#   The GNU Lesser General Public License, Version 2.1, February 1999
#
package Config::Model::AnyId 2.152;

use 5.020;

use Mouse;
with "Config::Model::Role::NodeLoader";
with "Config::Model::Role::Utils";

use Config::Model::Exception;
use Config::Model::Warper;
use Carp qw/cluck croak carp/;
use Log::Log4perl qw(get_logger :levels);
use Storable qw/dclone/;
use Mouse::Util::TypeConstraints;
use Scalar::Util qw/weaken/;

extends qw/Config::Model::AnyThing/;

use feature qw/signatures postderef/;
no warnings qw/experimental::signatures experimental::postderef/;

subtype 'KeyArray' => as 'ArrayRef' ;
coerce 'KeyArray' => from 'Str' => via { [$_] } ;

my $logger = get_logger("Tree::Element::Id");
my $user_logger = get_logger("User");
my $deep_check_logger = get_logger('DeepCheck');
my $fix_logger = get_logger("Anything::Fix");
my $change_logger = get_logger("ChangeTracker");

enum 'DataMode' => [qw/preset layered normal/];

has data_mode => (
    is      => 'rw',
    isa     => 'HashRef[DataMode]',
    traits  => ['Hash'],
    handles => {
        get_data_mode    => 'get',
        set_data_mode    => 'set',
        delete_data_mode => 'delete',
        clear_data_mode  => 'clear',
    },
    default => sub { {}; }
);

# this is cleared and set by set_properties
has _warpable_check_content_actions => (
    is      => 'bare', # no direct accessor
    isa     => 'ArrayRef[CodeRef]',
    traits  => ['Array'],
    handles => {
        add_warpable_check_content   => 'push',
        clear_warpable_check_content => 'clear',
        get_all_warpable_content_checks => 'elements',
    },
    default => sub { []; }
);

has _check_content_actions => (
    is      => 'bare', # no direct accessor
    isa     => 'ArrayRef[CodeRef]',
    traits  => ['Array'],
    handles => {
        add_check_content   => 'push',
        get_all_content_checks => 'elements',
    },
    default => sub { []; }
);

# needs_content_check defaults to 1 to trap bad data right after loading
has needs_content_check => ( is => 'rw', isa => 'Bool', default => 1 );

has has_fixes => (
    is => 'ro',
    isa => 'Num',
    default => 0,
    traits => ['Number'],
    handles => {
        inc_fixes =>   [ add => 1 ],
        dec_fixes =>   [ sub => 1 ],
        add_fixes => 'add',
        flush_fixes => [ mul => 0 ],
    }
);

# Some idea for improvement

# suggest => 'foo' or '$bar foo'
# creates a method analog to next_id (or next_id but I need to change
# run_user_command) that suggest the next id as foo_<nb> where
# nb is incremented each time, or compute the passed formula
# and performs the same

my @common_int_params = qw/min_index max_index max_nb auto_create_ids/;
has \@common_int_params => ( is => 'ro', isa => 'Maybe[Int]' );

my @common_hash_params = qw/default_with_init/;
has \@common_hash_params => ( is => 'ro', isa => 'Maybe[HashRef]' );

my @common_list_params = qw/allow_keys default_keys auto_create_keys/;
has \@common_list_params => (
    is => 'ro',
    isa => 'KeyArray',
    coerce => 1,
    default => sub { []; }
);

my @common_str_params = qw/allow_keys_from allow_keys_matching follow_keys_from
    migrate_keys_from migrate_values_from
    duplicates warn_if_key_match warn_unless_key_match/;
has \@common_str_params => ( is => 'ro', isa => 'Maybe[Str]' );

my @common_params =
    ( @common_int_params, @common_str_params, @common_list_params, @common_hash_params );
my @allowed_warp_params = ( @common_params, qw/level convert/ );

around BUILDARGS => sub {
    my $orig  = shift;
    my $class = shift;
    my %args  = @_;
    my %h     = map { ( $_ => $args{$_} ); } grep { defined $args{$_} } @allowed_warp_params;
    return $class->$orig( backup => dclone( \%h ), @_ );
};

has [qw/backup cargo/] => ( is => 'ro', isa => 'HashRef', required => 1 );
has warp => ( is => 'ro', isa => 'Maybe[HashRef]' );
has [qw/morph/] => ( is => 'ro', isa => 'Bool', default => 0 );
has content_warning_list => ( is => 'rw', isa => 'ArrayRef', default => sub { []; } );
has [qw/cargo_class max_index index_class index_type/] =>
    ( is => 'rw', isa => 'Maybe[Str]' );

has config_model => (
    is       => 'ro',
    isa      => 'Config::Model',
    weak_ref => 1,
    lazy     => 1,
    builder  => '_config_model'
);

sub _config_model {
    my $self = shift;
    return $self->instance->config_model;
}

sub config_class_name {
    my $self = shift;
    return $self->cargo->{config_class_name};
}

sub BUILD {
    my $self = shift;

    croak "Missing cargo->type parameter for element " . $self->{element_name} || 'unknown'
        unless defined $self->cargo->{type};

    if ( $self->cargo->{type} eq 'node' and not $self->cargo->{config_class_name} ) {
        croak "Missing cargo->config_class_name parameter for element "
        . $self->element_name || 'unknown';
    }

    if ( $self->{cargo}{type} eq 'hash' or $self->{cargo}{type} eq 'list' ) {
        die "$self->{element_name}: using $self->{cargo}{type} will probably not work";
    }

    $self->set_properties();

    if ( defined $self->warp ) {
        $self->{warper} = Config::Model::Warper->new(
            warped_object => $self,
            %{ $self->warp },
            allowed => \@allowed_warp_params
        );
    }

    return $self;
}

# this method can be called by the warp mechanism to alter (warp) the
# feature of the Id object.
sub set_properties ($self, @args) {
    # mega cleanup
    for ( @allowed_warp_params ) { delete $self->{$_}; }

    my %args = ( %{ $self->{backup} }, @args );

    # these are handled by Node or Warper
    for ( qw/level/ ) { delete $args{$_}; }

    $logger->trace( $self->name, " set_properties called with @args" );

    for ( @common_params ) {
        $self->{$_} = delete $args{$_} if defined $args{$_};
    }

    $self->set_convert( \%args ) if defined $args{convert};

    $self-> clear_warpable_check_content;
    for ( $self-> get_all_content_checks ) {
        $self-> add_warpable_check_content($_);
    }
    for ( qw/duplicates/ ) {
        my $method = "check_$_";
        my $weak_self = $self;
        weaken($weak_self); # weaken reference loop ($self - check_content - closure - self)
        $self-> add_check_content( sub { $weak_self->$method(@_);} ) if  $self->{$_};
    }

    Config::Model::Exception::Model->throw(
        object => $self,
        error  => "Undefined index_type"
    ) unless defined $self->{index_type};

    Config::Model::Exception::Model->throw(
        object => $self,
        error  => "Unexpected index_type $self->{index_type}"
        )
        unless ( $self->{index_type} eq 'integer'
        or $self->{index_type} eq 'string' );

    my @current_idx = $self->_fetch_all_indexes();
    if (@current_idx) {
        my $first_idx = shift @current_idx;
        my $last_idx  = pop @current_idx;

        foreach my $idx ( ( $first_idx, $last_idx ) ) {
            my $ok = $self->check_idx($first_idx);
            next if $ok;

            # here a user input may trigger an exception even if fetch
            # or set value check is disabled. That's mostly because,
            # we cannot enforce more strict settings without random
            # deletion of data. For instance, if a hash contains 5
            # items and the max_nb of items is reduced to 3. Which 2
            # items should we remove ?

            # Since we cannot choose, we must raise an exception in
            # all cases.
            Config::Model::Exception::WrongValue->throw(
                error => "Error while setting id property:"
                    . join( "\n\t", @{ $self->{idx_error_list} } ),
                object => $self
            );
        }
    }

    $self->auto_create_elements;

    if (    defined $self->{duplicates}
        and defined $self->{cargo}
        and $self->{cargo}{type} ne 'leaf' ) {
        Config::Model::Exception::Model->throw(
            object => $self,
            error  => "Cannot specify 'duplicates' with cargo type '$self->{cargo}{type}'",
        );
    }

    my $ok_dup = 'forbid|suppress|warn|allow';
    if ( defined $self->{duplicates} and $self->{duplicates} !~ /^$ok_dup$/ ) {
        Config::Model::Exception::Model->throw(
            object => $self,
            error  => "Unexpected 'duplicates' $self->{duplicates} expected $ok_dup",
        );
    }

    Config::Model::Exception::Model->throw(
        object => $self,
        error  => "Unexpected parameters: " . join( ' ', keys %args )
    ) if scalar keys %args;

    return;
}

sub create_default_with_init {
    my $self = shift;
    my $idx = shift;

    return unless defined $self->{default_with_init};

    my $h = $self->{default_with_init};
    foreach my $def_key ( keys %$h ) {
        $self->create_default_content($def_key);
    }
    return;
}

sub create_default_content {
    my $self = shift;
    my $idx = shift //  die "missing index";

    return unless defined $self->{default_with_init};

    my $def = $self->{default_with_init}{$idx};
    return unless defined $def; # no default content to create for $idx

    return if $self->_defined($idx) ; # object already created

    $self->auto_vivify($idx);

    my $v_obj = $self->_fetch_with_id($idx);
    if ( $v_obj->get_type eq 'leaf' ) {
        $v_obj->store( $def );
    }
    else {
        $v_obj->load( $def );
    }
    return;
}

sub max {
    my $self = shift;
    carp $self->name, ": max param is deprecated, use max_index\n";
    return $self->max_index;
}

sub min {
    my $self = shift;
    carp $self->name, ": min param is deprecated, use min_index\n";
    return $self->min_index;
}

sub cargo_type { goto &get_cargo_type; }

sub get_cargo_type {
    my $self = shift;

    #my @ids = $self->fetch_all_indexes ;
    # the returned cargo type might be different from collected type
    # when collected type is 'warped_node'.
    #return @ids ? $self->fetch_with_id($ids[0])->get_cargo_type
    #  : $self->{cargo_type} ;
    return $self->{cargo}{type};
}

sub get_cargo_info {
    my $self = shift;
    my $what = shift;
    return $self->{cargo}{$what};
}

# internal, does a grab with improved error message
sub safe_typed_grab ($self, %args) {
    my $param = $args{param} || croak "safe_typed_grab: missing param";

    my $res = eval {
        $self->grab(
            step  => $self->{$param},
            type  => $self->get_type,
            check => $args{check} || 'yes',
        );
    };

    if ($@) {
        my $e = $@;
        my $msg = $e ? $e->full_message : '';
        Config::Model::Exception::Model->throw(
            object => $self,
            error  => "'$param' parameter: " . $msg
        );
    }

    return $res;
}

sub get_default_keys {
    my $self = shift;

    if ( $self->{follow_keys_from} ) {
        my $followed = $self->safe_typed_grab( param => 'follow_keys_from' );
        my @res = $followed->fetch_all_indexes;
        return wantarray ? @res : \@res;
    }

    my @res;

    push @res, @{ $self->{default_keys} }
        if defined $self->{default_keys};

    push @res, keys %{ $self->{default_with_init} }
        if defined $self->{default_with_init};

    return wantarray ? @res : \@res;
}

sub name {
    my $self = shift;
    return $self->{parent}->name . ' ' . $self->{element_name} . ' id';
}

# internal. Handle model declaration arguments
sub handle_args ($self, %args) {
    my $warp_info = delete $args{warp};

    for (qw/index_class index_type morph ordered/) {
        $self->{$_} = delete $args{$_} if defined $args{$_};
    }

    $self->{backup} = dclone( \%args );

    $self->set_properties(%args) if defined $self->{index_type};

    if ( defined $warp_info ) {
        $self->{warper} = Config::Model::Warper->new(
            warped_object => $self,
            %$warp_info,
            allowed => \@allowed_warp_params
        );
    }

    return $self;
}

sub apply_fixes {
    my $self = shift;
    $fix_logger->trace( $self->location . ": apply_fixes called" );

    $self->deep_check( fix => 1, logger => $fix_logger );
    return;
}

my %check_idx_dispatch =
    map { ( $_ => 'check_' . $_ ); }
    qw/follow_keys_from allow_keys allow_keys_from allow_keys_matching
    warn_if_key_match warn_unless_key_match/;

my %mode_move = (
    layered => { preset => 1, normal => 1 },
    preset  => { normal => 1 },
    normal  => {},
);

around notify_change => sub ($orig, $self, %args) {
    if ($change_logger->is_trace) {
        my @a = map { ( $_ => $args{$_} // '<undef>' ); } sort keys %args;
        $change_logger->trace( "called for ", $self->name, " from ", join( ' ', caller ),
        " with ", join( ' ', @a ) );
    }

    # $idx may be undef if $self has changed, not necessarily its content
    my $idx = $args{index};
    if ( defined $idx ) {

        # use $idx to trigger move from layered->preset->normal
        my $imode = $self->instance->get_data_mode;
        my $old_mode = $self->get_data_mode($idx) || 'normal';
        $self->set_data_mode( $idx, $imode ) if $mode_move{$old_mode}{$imode};
    }

    return if $self->instance->initial_load and not $args{really};

    $self-> needs_content_check(1);
    $self->$orig(%args);
    return;
};

# the number of checks is becoming confusing. We have
# - check_idx to check whether an index is fine. This is called when creating
#   a new index
# - check_content: a more expensive check that runs all content checker registered
#   in this object. By default, none. A plain AnyId can contains a duplicated_content
#   checker if configured
# - a deep_check (for lack of a better name): a also expensive check that involve index
#   versus other part of the config tree. By default, no check is done. This is currently
#   used only by DPkg model which check if the index value is used elsewhere

# Using plain check in this class is avoided because it's too generic, but a polymorphic
# entry point is still needed, oh well...
sub check {
    # since check is not used when creating an index, but called explicitly
    # so it can be forwarded to deep_check.
    goto &deep_check; # backward compat
}

sub deep_check ($self, @args) {
    $deep_check_logger->trace("called on ".$self->name);

    for ( $self->fetch_all_indexes() ) {
        $self->check_idx(@args, index => $_);
    }

    $self->check_content(@args, logger => $deep_check_logger);
    return;
}

# check globally the list or hash, called by apply_fix or deep_check
sub check_content ($self, %args) {
    my $silent    = $args{silent} || 0;
    my $apply_fix = $args{fix}    || 0;
    my $local_logger = $args{logger} || $logger;

    if ( $self-> needs_content_check ) {

        $local_logger->trace( "Running check_content on ",$self->location );
        # need to keep track to update GUI
        $self-> flush_fixes;    # reset before check

        my @error;
        my @warn;

        foreach my $sub ( $self-> get_all_content_checks ) {
            $sub->( \@error, \@warn, $apply_fix, $silent );
        }

        my $nb = $self->fetch_size;
        push @error, "Too many items ($nb) limit $self->{max_nb}, "
            if defined $self->{max_nb} and $nb > $self->{max_nb};

        if (not $silent) {
            for ( @warn ) {
                $user_logger->warn( "Warning in '" . $self->location_short . "': $_" )
            }
        }


        $self->{content_warning_list} = \@warn;
        $self->{content_error_list}   = \@error;
        $self-> needs_content_check(0);

        return scalar @error ? 0 : 1;
    }
    else {
        $local_logger->debug( $self->location, " has not changed, actual check skipped" )
            if $local_logger->is_debug;
        my $err = $self->{content_error_list} // [];
        return scalar @$err ? 0 : 1;
    }
}

# internal function to check the validity of the index. Called when creating a new
# index or when set_properties is called (init or during warp)
sub check_idx ($self, @args) {
    my %args = _resolve_arg_shortcut(\@args, 'index');
    my $idx       = $args{index};
    my $silent    = $args{silent} || 0;
    my $check     = $args{check} || 'yes';
    my $apply_fix = $args{fix} // ($check eq 'fix' ? 1 : 0);

    Config::Model::Exception::Internal->throw(
        object => $self,
        error  => "check_idx method: key or index is not defined"
    ) unless defined $idx;

    my @error;
    my @warn;

    foreach my $key_check_name ( keys %check_idx_dispatch ) {
        next unless $self->{$key_check_name};
        my $method = $check_idx_dispatch{$key_check_name};
        $self->$method( $idx, \@error, \@warn, $apply_fix );
    }

    my $nb     = $self->fetch_size;
    my $new_nb = $nb;
    $new_nb++ unless $self->_exists($idx);

    if ( $idx eq '' ) {
        push @error, "Index is empty";
    }
    elsif ( $self->{index_type} eq 'integer' and $idx =~ /\D/ ) {
        push @error, "Index is not integer ($idx)";
    }
    elsif ( defined $self->{max_index} and $idx > $self->{max_index} ) {
        push @error, "Index $idx > max_index limit $self->{max_index}";
    }
    elsif ( defined $self->{min_index} and $idx < $self->{min_index} ) {
        push @error, "Index $idx < min_index limit $self->{min_index}";
    }

    push @error, "Too many items ($new_nb) limit $self->{max_nb}, " . "rejected id '$idx'"
        if defined $self->{max_nb} and $new_nb > $self->{max_nb};

    if ( scalar @error ) {
        my @a = $self->_fetch_all_indexes;
        push @error, "Item ids are '" . join( ',', @a ) . "'", $self->warp_error;
    }

    $self->{idx_error_list} = \@error;
    $self->{warning_hash}{$idx} = \@warn;

    if (@warn and not $silent and $check ne 'no') {
        for (@warn) {
            $user_logger->warn( "Warning in '" . $self->location_short . "': $_" );
        }
    }

    return scalar @error ? 0 : 1;
}

#internal
sub check_follow_keys_from {
    my ( $self, $idx, $error ) = @_;

    my $followed = $self->safe_typed_grab( param => 'follow_keys_from' );
    return if $followed->exists($idx);

    push @$error,
          "key '" . $self->shorten_idx($idx) . "' does not exists in followed object '"
        . $followed->name
        . "'. Expected '"
        . join( "', '", $followed->fetch_all_indexes ) . "'";
    return;
}

#internal
sub check_allow_keys {
    my ( $self, $idx, $error ) = @_;

    my $ok = grep { $_ eq $idx } @{ $self->{allow_keys} };

    push @$error,
        "Unexpected key '" . $self->shorten_idx($idx) . "'. Expected '" . join( "', '", @{ $self->{allow_keys} } ) . "'"
        unless $ok;
    return;
}

#internal
sub check_allow_keys_matching {
    my ( $self, $idx, $error ) = @_;
    my $match = $self->{allow_keys_matching};

    push @$error, "Unexpected key '" . $self->shorten_idx($idx) . "'. Key must match $match"
        unless $idx =~ /$match/;
    return;
}

#internal
sub check_allow_keys_from {
    my ( $self, $idx, $error ) = @_;

    my $from = $self->safe_typed_grab( param => 'allow_keys_from' );
    my $ok = grep { $_ eq $idx } $from->fetch_all_indexes;

    return if $ok;

    push @$error,
          "key '" . $self->shorten_idx($idx) . "' does not exists in '"
        . $from->name
        . "'. Expected '"
        . join( "', '", $from->fetch_all_indexes ) . "'";
    return;
}

sub check_warn_if_key_match {
    my ( $self, $idx, $error, $warn ) = @_;
    my $re = $self->{warn_if_key_match};

    push @$warn, "key '" . $self->shorten_idx($idx) . "' should not match $re\n" if $idx =~ /$re/;
    return;
}

sub check_warn_unless_key_match {
    my ( $self, $idx, $error, $warn ) = @_;
    my $re = $self->{warn_unless_key_match};

    push @$warn, "key '" . $self->shorten_idx($idx) . "' should match $re\n" unless $idx =~ /$re/;
    return;
}

sub check_duplicates {
    my ( $self, $error, $warn, $apply_fix, $silent ) = @_;

    my $dup = $self->{duplicates};
    return if $dup eq 'allow';

    $logger->trace("check_duplicates called");
    my %h;
    my @issues;
    my @to_delete;
    foreach my $i ( $self->fetch_all_indexes ) {
        my $v = $self->fetch_with_id( index => $i, check => 'no' )->fetch;
        next unless $v;
        $h{$v} = 0 unless defined $h{$v};
        $h{$v}++;
        if ( $h{$v} > 1 ) {
            $logger->debug("got duplicates $i -> $v : $h{$v}");
            push @to_delete, $i;
            push @issues,    qq!$i:"$v"!;
        }
    }

    return unless @issues;

    if ($apply_fix) {
        $logger->debug("Fixing duplicates @issues, removing @to_delete");
        for (reverse @to_delete) { $self->remove($_) }
    }
    elsif ( $dup eq 'forbid' ) {
        $logger->debug("Found forbidden duplicates @issues");
        push @$error, "Forbidden duplicates value @issues";
    }
    elsif ( $dup eq 'warn' ) {
        $logger->debug("warning condition: found duplicate @issues");
        push @$warn, "Duplicated value: @issues";
        $self->add_fixes( scalar @issues);
    }
    elsif ( $dup eq 'suppress' ) {
        $logger->debug("suppressing duplicates @issues");
        for (reverse @to_delete) { $self->remove($_) }
    }
    else {
        die "Internal error: duplicates is $dup";
    }
    return;
}

sub fetch_with_id ($self, @args) {
    my %args = _resolve_arg_shortcut(\@args, 'index');
    my $check = $self->_check_check( $args{check} );
    my $idx   = $args{index};

    $logger->trace( $self->name, " called for idx $idx" ) if $logger->is_trace;

    $idx = $self->{convert_sub}($idx)
        if ( defined $self->{convert_sub} and defined $idx );

    # try migration only once
    $self->_migrate unless $self->{migration_done};

    my $ok = 1;

    # check index only if it's unknown
    $ok = $self->check_idx( index => $idx, check => $check )
        unless $self->_defined($idx)
        or $check eq 'no';

    if ( $ok or $check eq 'no' ) {
        # create another method
        $self->create_default_content($idx); # no-op if idx exists

        $self->auto_vivify($idx) unless $self->_defined($idx);
        return $self->_fetch_with_id($idx);
    }
    else {
        Config::Model::Exception::WrongValue->throw(
            error  => join( "\n\t", @{ $self->{idx_error_list} } ),
            object => $self
        );
    }

    return;
}

sub get ($self, @args) {
    my %args = _resolve_arg_shortcut(\@args, 'path');
    my $path    = delete $args{path};
    my $autoadd = 1;
    $autoadd = $args{autoadd} if defined $args{autoadd};
    my $get_obj = delete $args{get_obj} || 0;
    $path =~ s!^/!!;
    my ( $item, $new_path ) = split m!/!, $path, 2;

    my $dcm = $args{dir_char_mockup};

    # $item =~ s($dcm)(/)g if $dcm ;
    if ($dcm) {
        while (1) {
            my $i = index( $item, $dcm );
            last if $i == -1;
            substr $item, $i, length($dcm), '/';
        }
    }

    return unless ( $self->exists($item) or $autoadd );

    $logger->trace("get: path $path, item $item");

    my $obj = $self->fetch_with_id( index => $item, %args );
    return $obj if ( ( $get_obj or $obj->get_type ne 'leaf' ) and not defined $new_path );
    return $obj->get( path => $new_path, get_obj => $get_obj, %args );
}

sub set ($self, $path, @args) {
    $path =~ s!^/!!;
    my ( $item, $new_path ) = split m!/!, $path, 2;
    return $self->fetch_with_id($item)->set( $new_path, @args );
}

sub copy {
    my ( $self, $from, $to ) = @_;

    my $from_obj = $self->fetch_with_id($from);
    my $ok       = $self->check_idx($to);

    if ( $ok && $self->{cargo}{type} eq 'leaf' ) {
        $logger->trace( "AnyId: copy leaf value from " . $self->name . " $from to $to" );
        return $self->fetch_with_id($to)->store( $from_obj->fetch() );
    }
    elsif ($ok) {

        # node object
        $logger->trace( "AnyId: deep copy node from " . $self->name );
        my $target = $self->fetch_with_id($to);
        $logger->trace( "AnyId: deep copy node to " . $target->name );
        return $target->copy_from($from_obj);
    }
    else {
        Config::Model::Exception::WrongValue->throw(
            error  => join( "\n\t", @{ $self->{idx_error_list} } ),
            object => $self
        );
    }
    return;
}

sub fetch_all {
    my $self = shift;
    my @keys = $self->fetch_all_indexes;
    return map { $self->fetch_with_id($_); } @keys;
}

sub fetch ($self, @args) {
    return join(',', $self->fetch_all_values(@args) );
}

sub fetch_value ($self, @args) {
    my %args = _resolve_arg_shortcut(\@args, 'idx');
    return $self->_fetch_value(%args, sub => 'fetch');
}

sub fetch_summary ($self, @args) {
    my %args = _resolve_arg_shortcut(\@args, 'idx');
    return $self->_fetch_value(%args, sub => 'fetch_summary');
}

sub _fetch_value ($self, %args) {
    my $check = $self->_check_check( $args{check} );
    my $sub = delete $args{sub};

    if ( $self->{cargo}{type} eq 'leaf' ) {
        return  $self->fetch_with_id($args{idx})->$sub( check => $check, mode => $args{mode} );
    }
    else {
        Config::Model::Exception::WrongType->throw(
            object        => $self,
            function      => 'fetch_values',
            got_type      => $self->{cargo}{type},
            expected_type => 'leaf',
            info          => "with index $args{idx}",
        );
    }
    return;
}

sub fetch_all_values ($self, @args) {
    my %args = _resolve_arg_shortcut(\@args, 'mode');
    my $mode  = $args{mode};
    my $check = $self->_check_check( $args{check} );

    my @keys = $self->fetch_all_indexes;

    # verify content restrictions applied to List (e.g. no duplicate values)
    my $ok = $check eq 'no' ? 1 : $self->check_content();

    if ( $ok or $check eq 'no' ) {
        return grep { defined $_ }
            map { $self->fetch_value(idx => $_, check => $check, mode => $mode ); } @keys;
    }
    else {
        Config::Model::Exception::WrongValue->throw(
            error  => join( "\n\t", @{ $self->{content_error_list} } ),
            object => $self
        );
    }
    return;
}

sub fetch_all_indexes {
    my $self = shift;
    $self->create_default;    # will check itself if creation is necessary
    $self->_migrate;
    return $self->_fetch_all_indexes;
}

sub get_all_indexes {
    my $self = shift;
    carp "get_all_indexes is deprecated. use fetch_all_indexes";
    return $self->fetch_all_indexes;
}

sub children {
    my $self = shift;
    return $self->fetch_all_indexes;
}

sub has_data {
    my $self = shift;
    return $self->fetch_size ;
}

# auto vivify must create according to cargo}{type
# node -> Node or user class
# leaf -> Value or user class

# warped node cannot be used. Same effect can be achieved by warping
# cargo_args

my %element_default_class = (
    warped_node => 'WarpedNode',
    node        => 'Node',
    leaf        => 'Value',
);

my %can_override_class = (
    node => 0,
    leaf => 1,
);

#internal
sub auto_vivify {
    my ( $self, $idx ) = @_;
    my %cargo_args = %{ $self->cargo };
    my $class      = delete $cargo_args{class};    # to override class in cargo

    my $cargo_type = delete $cargo_args{type};

    Config::Model::Exception::Model->throw(
        object  => $self,
        message => "unknown '$cargo_type' cargo type:  "
            . "in cargo_args. Expected "
            . join( ' or ', keys %element_default_class )
    ) unless defined $element_default_class{$cargo_type};

    my $el_class = 'Config::Model::' . $element_default_class{$cargo_type};

    if ( defined $class ) {
        Config::Model::Exception::Model->throw(
            object  => $self,
            message => "$cargo_type class " . "cannot be overidden by '$class'"
        ) unless $can_override_class{$cargo_type};
        $el_class = $class;
    }


    my @common_args = (
        element_name => $self->{element_name},
        index_value  => $idx,
        instance     => $self->{instance},
        parent       => $self->parent,
        container    => $self,
        %cargo_args,
    );

    my $item;

    # check parameters passed by the user
    if ( $cargo_type eq 'node' ) {
        $item = $self->load_node( @common_args, config_class_name => $self->config_class_name );
    }
    else {
        Mouse::Util::load_class($el_class);
        $item = $el_class->new(@common_args);
    }

    my $imode = $self->instance->get_data_mode;
    $self->set_data_mode( $idx, $imode );

    $self->_store( $idx, $item );
    return;
}

## no critic (Subroutines::ProhibitBuiltinHomonyms)
sub defined {
    my ( $self, $idx ) = @_;

    return $self->_defined($idx);
}

## no critic (Subroutines::ProhibitBuiltinHomonyms)
sub exists {
    my ( $self, $idx ) = @_;

    return $self->_exists($idx);
}

## no critic (Subroutines::ProhibitBuiltinHomonyms)
sub delete {
    my ( $self, $idx ) = @_;

    delete $self->{warning_hash}{$idx};
    my $ret = $self->_delete($idx);
    # notification is not needed if the value was already delete or missing
    $self->notify_change( note => "deleted entry $idx" ) if defined $ret;
    return $ret;
}

sub clear {
    my ($self) = @_;

    $self->{warning_hash} = {};
    $self->_clear;
    $self->clear_data_mode;
    $self->notify_change( note => "cleared all entries" );
    return;
}

sub clear_values {
    my ($self) = @_;
    carp "clear_values deprecated";

    my $ct = $self->get_cargo_type;
    Config::Model::Exception::User->throw(
        object  => $self,
        message => "clear_values() called on non leaf cargo type: '$ct'"
    ) if $ct ne 'leaf';

    # this will trigger a notify_change
    for ( $self->fetch_all_indexes ) {
        $self->fetch_with_id($_)->store(undef);
    }
    $self->notify_change( note => "cleared all values" );
    return;
}

sub warning_msg {
    my ( $self, $idx ) = @_;
    my $list ;
    if ( defined $idx ) {
        $list = $self->{warning_hash}{$idx} ;
    }
    elsif ( @{ $self->{content_warning_list} } ) {
        $list = $self->{content_warning_list} ;
    }
    return $list ? join( "\n", @$list ) : '';
}

sub has_warning {
    my $self = shift;

    return @{ $self->{content_warning_list} };
}

sub error_msg {
    my $self = shift;
    my @list;
    for (qw/idx_error_list content_error_list/) {
        push @list, @{ $self->{$_} } if $self->{$_};
    }

    return unless @list;
    return wantarray ? @list : join( "\n\t", @list );
}

__PACKAGE__->meta->make_immutable;

1;

# ABSTRACT: Base class for hash or list element

__END__

=pod

=encoding UTF-8

=head1 NAME

Config::Model::AnyId - Base class for hash or list element

=head1 VERSION

version 2.152

=head1 SYNOPSIS

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
    name    => "MyClass",
    element => [
        plain_hash => {
            type       => 'hash',
            index_type => 'string',
            cargo      => {
                type       => 'leaf',
                value_type => 'string',
            },
        },
        bounded_hash => {
            type       => 'hash',      # hash id
            index_type => 'integer',

            # hash boundaries
            min_index => 1, max_index => 123, max_nb => 2,

            # specify cargo held by hash
            cargo => {
                type       => 'leaf',
                value_type => 'string'
            },
        },
        bounded_list => {
            type => 'list',    # list id

            max_index => 123,
            cargo     => {
                type       => 'leaf',
                value_type => 'string'
            },
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
 my $steps = 'plain_hash:foo=boo bounded_list=foo,bar,baz
   bounded_hash:3=foo bounded_hash:30=baz 
   hash_of_nodes:"foo node" foo="in foo node" -
   hash_of_nodes:"bar node" bar="in bar node" ';
 $root->load( steps => $steps );

 # dump resulting tree
 print $root->dump_tree;

=head1 DESCRIPTION

This class provides hash or list elements for a L<Config::Model::Node>.

The hash index can either be en enumerated type, a boolean, an integer
or a string.

=head1 CONSTRUCTOR

AnyId object should not be created directly.

=head1 Hash or list model declaration

A hash or list element must be declared with the following parameters:

=over

=item type

Mandatory element type. Must be C<hash> or C<list> to have a
collection element.  The actual element type must be specified by
C<< cargo => type >>.

=item index_type

Either C<integer> or C<string>. Mandatory for hash.

=item ordered

Whether to keep the order of the hash keys (default no). (a bit like
L<Tie::IxHash>).  The hash keys are ordered along their creation. The
order can be modified with L<swap|Config::Model::HashId/"swap ( key1 , key2 )">,
L<move_up|Config::Model::HashId/"move_up ( key )"> or
L<move_down|Config::Model::HashId/"move_down ( key )">.

=item duplicates

Specify the policy regarding duplicated values stored in the list or as
hash values (valid only when cargo type is C<leaf>). The policy can be
C<allow> (default), C<suppress>, C<warn> (which offers the possibility
to apply a fix), C<forbid>. Note that duplicates I<check cannot be
performed when the duplicated value is stored>: this happens outside of
this object. Duplicates can be check only after when the value is read.

=item write_empty_value

By default, hash entries without data are not saved in configuration
files. Without data means the cargo of the hash key is empty: either
its value is undef or all the values of the contained node are also empty.

Set this parameter to 1 if the key must be saved in the configuration
file even if the hash contains no value for that key.

Note that writing hash entries without value may not be supported by
all backends. Use with care. Supported only for hash elements.

=item cargo

Hash ref specifying the cargo held by the hash of list. This has must
contain:

=over 8

=item type

Can be C<node> or C<leaf> (default).

=item config_class_name

Specifies the type of configuration object held in the hash. Only
valid when C<cargo> C<type> is C<node>.

=item <other>

Constructor arguments passed to the cargo object. See
L<Config::Model::Node> when C<< cargo->type >> is C<node>. See 
L<Config::Model::Value> when C<< cargo->type >> is C<leaf>.

=back

=item min_index

Specify the minimum value (optional, only for hash and for integer index)

=item max_index

Specify the maximum value (optional, only for list or for hash with 
integer index)

=item max_nb

Specify the maximum number of indexes. (hash only, optional, may also
be used with string index type)

=item default_keys

When set, the default parameter (or set of parameters) are used as
default keys hashes and created automatically when the C<keys> or C<exists>
functions are used on an I<empty> hash.

You can use C<< default_keys => 'foo' >>, 
or C<< default_keys => ['foo', 'bar'] >>.

=item default_with_init

To perform special set-up on children nodes you can also use 

   default_with_init =>  {
      foo => 'X=Av Y=Bv',
      bar => 'Y=Av Z=Cv'
   }

When the hash contains leaves, you can also use:

   default_with_init => {
       def_1 => 'def_1 stuff',
       def_2 => 'def_2 stuff'
   }

=item migrate_keys_from

Specifies that the keys of the hash are copied from another hash in
the configuration tree only when the hash is read for the first time after
initial load (i.e. once the configuration files are completely read). 

   migrate_keys_from => '- another_hash'

=item migrate_values_from

Specifies that the values of the hash (or list) are copied from another hash (or list) in
the configuration tree only when the hash (or list) is read for the first time after
initial load (i.e. once the configuration files are completely read). 

   migrate_values_from => '- another_hash_or_list'

=item follow_keys_from

Specifies that the keys of the hash follow the keys of another hash in
the configuration tree. In other words, the created hash
always has the same keys as the other hash.

   follow_keys_from => '- another_hash'

=item allow_keys

Specifies authorized keys:

  allow_keys => ['foo','bar','baz']

=item allow_keys_from

A bit like the C<follow_keys_from> parameters. Except that the hash pointed to
by C<allow_keys_from> specified the authorized keys for this hash.

  allow_keys_from => '- another_hash'

=item allow_keys_matching

Keys must match the specified regular expression. For instance:

  allow_keys_matching => '^foo\d\d$'

=item auto_create_keys

When set, the default parameter (or set of parameters) are used as
keys hashes and created automatically. (valid only for hash elements)

Called with C<< auto_create_keys => ['foo'] >>, or 
C<< auto_create_keys => ['foo', 'bar'] >>.

=item warn_if_key_match

Issue a warning if the key matches the specified regular expression

=item warn_unless_key_match

Issue a warning unless the key matches the specified regular expression

=item auto_create_ids

Specifies the number of elements to create automatically. E.g.  C<<
auto_create_ids => 4 >> initializes the list with 4 undef elements.
(valid only for list elements)

=item convert => [uc | lc ]

The hash key are converted to uppercase (uc) or lowercase (lc).

=item warp

See L</"Warp: dynamic value configuration"> below.

=back

=head1 Warp: dynamic value configuration

The Warp functionality enables an L<HashId|Config::Model::HashId> or
L<ListId|Config::Model::ListId> object to change its default settings
(e.g. C<min_index>, C<max_index> or C<max_nb> parameters) dynamically according to
the value of another C<Value> object. (See
L<Config::Model::Warper> for explanation on warp mechanism)

For instance, with this model:

 $model ->create_config_class 
  (
   name => 'Root',
   'element'
   => [
       macro => { type => 'leaf',
                  value_type => 'enum',
                  name       => 'macro',
                  choice     => [qw/A B C/],
                },
       warped_hash => { type => 'hash',
                        index_type => 'integer',
                        max_nb     => 3,
                        warp       => {
                                       follow => '- macro',
                                       rules => { A => { max_nb => 1 },
                                                  B => { max_nb => 2 }
                                                }
                                      },
                        cargo => { type => 'node',
                                   config_class_name => 'Dummy'
                                 }
                      },
     ]
  );

Setting C<macro> to C<A> means that C<warped_hash> can only accept
one C<Dummy> class item .

Setting C<macro> to C<B> means that C<warped_hash> accepts two
C<Dummy> class items.

Like other warped class, a HashId or ListId can have multiple warp
masters (See L<Config::Model::Warper/"Warp follow argument">:

  warp => { follow => { m1 => '- macro1', 
                        m2 => '- macro2' 
                      },
            rules  => [ '$m1 eq "A" and $m2 eq "A2"' => { max_nb => 1},
                        '$m1 eq "A" and $m2 eq "B2"' => { max_nb => 2}
                      ],
          }

=head2 Warp and auto_create_ids or auto_create_keys

When a warp is applied with C<auto_create_keys> or C<auto_create_ids>
parameter, the auto_created items are created if they are not already
present. But this warp never removes items that were previously
auto created.

For instance, when a tied hash is created with
C<< auto_create => [a,b,c] >>, the hash contains C<(a,b,c)>.

Then, once a warp with C<< auto_create_keys => [c,d,e] >> is applied,
the hash then contains C<(a,b,c,d,e)>. The items created by the first
auto_create_keys are not removed.

=head2 Warp and max_nb

When a warp is applied, the items that do not fit the constraint
(e.g. min_index, max_index) are removed.

For the max_nb constraint, an exception is raised if a warp
leads to a number of items greater than the max_nb constraint.

=head1 Content check

By default, this class provides an optional content check that checks
for duplicated values (when C<duplicates> parameter is set).

Derived classes can register more global checker with the following method.

=head2 add_check_content

This method expects a sub ref with signature C<( $self, $error, $warn,
$apply_fix )>.  Where C<$error> and C<$warn> are array ref. You can
push error or warning messages there.  C<$apply_fix> is a
boolean. When set to 1, the passed method can fix the warning or the
error. Please make sure to weaken C<$self> to avoid memory cycles.

Example:

 package MyId;
 use Mouse;
 extends qw/Config::Model::HashId/;
 use Scalar::Util qw/weaken/;

 sub setup {
    my $self = shift;
    weaken($self);
    $self-> add_check_content( sub { $self->check_usused_licenses(@_);} )
}

=head1 Introspection methods

The following methods returns the current value stored in the Id
object (as declared in the model unless they were warped):

=over

=item min_index 

=item max_index 

=item max_nb 

=item index_type 

=item default_keys 

=item default_with_init 

=item follow_keys_from

=item auto_create_ids

=item auto_create_keys

=item ordered

=item morph

=item config_model

=back

=head2 get_cargo_type

Returns the object type contained by the hash or list (i.e. returns
C<< cargo -> type >>).

=head2 get_cargo_info

Parameters: C<< ( < what > ) >>

Returns more info on the cargo contained by the hash or list. C<what>
may be C<value_type> or any other cargo info stored in the model.
Returns undef if the requested info is not provided in the model.

=head2 get_default_keys

Returns a list (or a list ref) of the current default keys. These keys
can be set by the C<default_keys> or C<default_with_init> parameters
or by the other hash pointed by C<follow_keys_from> parameter.

=head2 name

Returns the object name. The name finishes with ' id'.

=head2 config_class_name

Returns the config_class_name of collected elements. Valid only
for collection of nodes.

This method returns undef if C<cargo> C<type> is not C<node>.

=head2 has_fixes

Returns the number of fixes that can be applied to the current value. 

=head1 Information management

=head2 fetch_with_id

Parameters: C<< ( index => $idx , [ check => 'no' ]) >>

Fetch the collected element held by the hash or list. Index check is 'yes' by default.
Can be called with one parameter which is used as index.

=head2 get

Get a value from a directory like path. Parameters are:

=over

=item path

Poor man's version of XPath style path. This string is in the form:

 /foo/bar/4

Each word between the '/' is either an element name or a hash key or a list index. 

=item mode

Either C<default>, C<custom>, C<user>,... 
See C<mode> parameter in <Config::Model::Value/"fetch( ... )">

=item check

Either C<skip>, C<no>

=item get_obj

If the path leads to a leaf, this parameter tell whether to return 
the stored value or the value object. 

=item autoadd

Whether to create missing keys

=item dir_char_mockup

When the hash key used contains '/', (for instance a directory value),
the key cannot be used as is with this method. Because '/' is already
used to separate configuration items (this is also important with
L<Config::Model::FuseUI>). This parameter specifies how the forbidden
'/' char is shown in the path. Default is C<< <slash> >>

=back

=head2 set

Parameters: C<( path, value )>

Set a value with a directory like path.

=head2 copy

Parameters: C<( from_index, to_index )>

Deep copy an element within the hash or list. If the element contained
by the hash or list is a node, all configuration information is
copied from one node to another.

=head2 fetch_all

Returns an array containing all elements held by the hash or list.

=head2 fetch_value

Parameters: C<< ( idx => ..., mode => ..., check => ...) >>

Returns the value held by the C<idx> element of the hash or list. This
method is only valid for hash or list containing leaves.

See L<fetch_all_values> for C<mode> argument documentation and
L<Config::Model::Value/fetch> for C<check> argument documentation.

=head2 fetch_summary

Arguments: C<< ( idx => ..., mode => ..., check => ...) >>

Like L</fetch_value>, but returns a truncated value when the value is
a string or uniline that is too long to be displayed.

=head2 fetch_all_values

Parameters: C<< ( mode => ..., check => ...) >>

Returns an array containing all defined values held by the hash or
list. (undefined values are simply discarded). This method is only
valid for hash or list containing leaves.

With C<mode> parameter, this method returns either:

=over

=item custom

The value entered by the user

=item preset

The value entered in preset mode

=item standard

The value entered in preset mode or checked by default.

=item default

The default value (defined by the configuration model)

=back

See L<Config::Model::Value/fetch> for C<check> argument documentation.

=head2 fetch

Similar to L</fetch_all_values>, with the same parameters, Returns the
result as a string with comma separated list values.

=head2 fetch_all_indexes

Returns an array containing all indexes of the hash or list. Hash keys
are sorted alphabetically, except for ordered hashed.

=head2 children

Like fetch_all_indexes. This method is
polymorphic for all non-leaf objects of the configuration tree.

=head2 defined

Parameters: C<( index )>

Returns true if the value held at C<index> is defined.

=head2 exists

Parameters: C<( index )>

Returns true if the value held at C<index> exists (i.e the key exists
but the value may be undefined). This method may not make sense for
list element.

=head2 has_data

Return true if the array or hash is not empty.

=head2 delete

Parameters: C<( index )>

Delete the C<index>ed value 

=head2 clear

Delete all values (also delete underlying value or node objects).

=head2 clear_values

Delete all values (without deleting underlying value objects).

=head2 warning_msg

Parameters: C<( [index] )>

Returns warnings concerning indexes of this hash. 
Without parameter, returns a string containing all warnings or undef. With an index, return the warnings
concerning this index or undef.

=head2 has_warning

Returns the current number of warning.

=head2 error_msg

Returns the error messages of this object (if any)

=head1 AUTHOR

Dominique Dumont, ddumont [AT] cpan [DOT] org

=head1 SEE ALSO

L<Config::Model>,
L<Config::Model::Instance>,
L<Config::Model::Node>,
L<Config::Model::WarpedNode>,
L<Config::Model::HashId>,
L<Config::Model::ListId>,
L<Config::Model::CheckList>,
L<Config::Model::Value>

=head1 AUTHOR

Dominique Dumont

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2005-2022 by Dominique Dumont.

This is free software, licensed under:

  The GNU Lesser General Public License, Version 2.1, February 1999

=cut
