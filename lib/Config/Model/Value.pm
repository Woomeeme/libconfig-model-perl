#
# This file is part of Config-Model
#
# This software is Copyright (c) 2005-2022 by Dominique Dumont.
#
# This is free software, licensed under:
#
#   The GNU Lesser General Public License, Version 2.1, February 1999
#
package Config::Model::Value 2.152;

use v5.20;

use strict;
use warnings;
use feature "switch";

use Mouse;
use Mouse::Util::TypeConstraints;
use MouseX::StrictConstructor;

use Parse::RecDescent 1.90.0;

use Data::Dumper ();
use Config::Model::Exception;
use Config::Model::ValueComputer;
use Config::Model::IdElementReference;
use Config::Model::Warper;
use Log::Log4perl qw(get_logger :levels);
use Scalar::Util qw/weaken/;
use Carp;
use Storable qw/dclone/;
use Path::Tiny;
use List::MoreUtils qw(any) ;

extends qw/Config::Model::AnyThing/;

with "Config::Model::Role::WarpMaster";
with "Config::Model::Role::Grab";
with "Config::Model::Role::HelpAsText";
with "Config::Model::Role::ComputeFunction";

use feature qw/postderef signatures/;
no warnings qw/experimental::postderef experimental::smartmatch experimental::signatures/;

my $logger        = get_logger("Tree::Element::Value");
my $user_logger   = get_logger("User");
my $change_logger = get_logger("Anything::Change");
my $fix_logger    = get_logger("Anything::Fix");

our $nowarning = 0;    # global variable to silence warnings. Only used for tests

enum ValueType => qw/boolean enum uniline string integer number reference file dir/;

has fixes => ( is => 'rw', isa => 'ArrayRef', default => sub { [] } );

has [qw/warp compute computed_refer_to backup migrate_from/] =>
    ( is => 'rw', isa => 'Maybe[HashRef]' );

has compute_obj => (
    is      => 'ro',
    isa     => 'Maybe[Config::Model::ValueComputer]',
    builder => '_build_compute_obj',
    lazy    => 1
);

has [qw/write_as/] => ( is => 'rw', isa => 'Maybe[ArrayRef]' );

has [qw/refer_to _data replace_follow/] => ( is => 'rw', isa => 'Maybe[Str]' );

has value_type => ( is => 'rw', isa => 'ValueType' );

my @common_int_params = qw/min max mandatory /;
has \@common_int_params => ( is => 'ro', isa => 'Maybe[Int]' );

my @common_hash_params = qw/replace assert warn_if_match warn_unless_match warn_if warn_unless help/;
has \@common_hash_params => ( is => 'ro', isa => 'Maybe[HashRef]' );

my @common_list_params = qw/choice/;
has \@common_list_params => ( is => 'ro', isa => 'Maybe[ArrayRef]' );

my @common_str_params = qw/default upstream_default convert match grammar warn/;
has \@common_str_params => ( is => 'ro', isa => 'Maybe[Str]' );

my @warp_accessible_params =
    ( @common_int_params, @common_str_params, @common_list_params, @common_hash_params );

my @allowed_warp_params = ( @warp_accessible_params, qw/level help/ );
my @backup_list         = ( @allowed_warp_params,    qw/migrate_from/ );

has compute_is_upstream_default =>
    ( is => 'ro', isa => 'Bool', lazy => 1, builder => '_compute_is_upstream_default' );

sub _compute_is_upstream_default {
    my $self = shift;
    return 0 unless defined $self->compute;
    return $self->compute_obj->use_as_upstream_default;
}

has compute_is_default =>
    ( is => 'ro', isa => 'Bool', lazy => 1, builder => '_compute_is_default' );

sub _compute_is_default {
    my $self = shift;
    return 0 unless defined $self->compute;
    return !$self->compute_obj->use_as_upstream_default;
}

has error_list => (
    is      => 'ro',
    isa     => 'ArrayRef',
    default => sub { [] },
    traits  => ['Array'],
    handles => {
        add_error    => 'push',
        clear_errors => 'clear',
        has_error    => 'count',
        all_errors   => 'elements',
        is_ok        => 'is_empty'
    } );

sub error_msg  ($self) {
    my $msg = '';
    if ($self->has_error) {
        my @add;
        push @add, $self->compute_obj->compute_info if $self->compute_obj;
        push @add, $self->{_migrate_from}->compute_info if $self->{_migrate_from};
        $msg = join("\n", $self->all_errors, @add);
    }
    return $msg;
}

has warning_list => (
    is      => 'ro',
    isa     => 'ArrayRef',
    default => sub { [] },
    traits  => ['Array'],
    handles => {
        add_warning    => 'push',
        clear_warnings => 'clear',
        warning_msg    => [ join => "\n\t" ],
        has_warning    => 'count',
        has_warnings    => 'count',
        all_warnings   => 'elements',
    } );

# as some information must be backed up even though they are not
# attributes, we cannot move code below in BUILD.
around BUILDARGS => sub ($orig, $class, %args) {
    my %h = map { ( $_ => $args{$_} ); } grep { defined $args{$_} } @backup_list;
    return $class->$orig( backup => dclone( \%h ), %args );
};

sub BUILD {
    my $self = shift;

    $self->set_properties();    # set will use backup data

    # used when self is a warped slave
    if ( my $warp_info = $self->warp ) {
        $self->{warper} = Config::Model::Warper->new(
            warped_object => $self,
            %$warp_info,
            allowed => \@allowed_warp_params
        );
    }

    $self->_init;

    return $self;
}

override 'needs_check' => sub ($self, @args) {
    if ($self->instance->layered) {
        # don't check value and don't store value in layered mode
        return 0;
    }
    elsif (@args) {
        return super();
    }
    else {
        # some items like idElementReference are too complex to propagate
        # a change notification back to the value using them. So an error or
        # warning must always be rechecked.
        return ($self->value_type eq 'reference' or super()) ;
    }
};

around notify_change => sub ($orig, $self, %args) {
    my $check_done = $args{check_done} || 0;

    return if $self->instance->initial_load and not $args{really};

    if ($change_logger->is_trace) {
        my @a = map { ( $_ => $args{$_} // '<undef>' ); } sort keys %args;
        $change_logger->trace( "called while needs_check is ",
        $self->needs_check, " for ", $self->name, " with ", join( ' ', @a ) );
    }

    $self->needs_check(1) unless $check_done;
    {
        croak "needless change with $args{new}"
            if defined $args{old}
            and defined $args{new}
            and $args{old} eq $args{new};
    }
    $args{new} = $self->map_write_as( $args{new} );
    $args{old} = $self->map_write_as( $args{old} );
    $self->$orig( %args, value_type => $self->value_type );

    # shake all warped or computed objects that depends on me
    foreach my $s ( $self->get_depend_slave ) {
        $change_logger->debug( "calling needs_check on slave ", $s->name )
            if $change_logger->is_debug;
        $s->needs_check(1);
    }
    return;
};

# internal method
sub set_default {
    my ( $self, $arg_ref ) = @_;

    if ( exists $arg_ref->{built_in} ) {
        $arg_ref->{upstream_default} = delete $arg_ref->{built_in};
        warn $self->name, " warning: deprecated built_in parameter, ", "use upstream_default\n";
    }

    if ( defined $arg_ref->{default} and defined $arg_ref->{upstream_default} ) {
        Config::Model::Exception::Model->throw(
            object => $self,
            error  => "Cannot specify both 'upstream_default' and " . "'default' parameters",
        );
    }

    foreach my $item (qw/upstream_default default/) {
        my $def = delete $arg_ref->{$item};

        next unless defined $def;
        $self->transform_boolean( \$def ) if $self->value_type eq 'boolean';

        # will check default value
        $self->check_value( value => $def );
        Config::Model::Exception::Model->throw(
            object => $self,
            error  => "Wrong $item value\n\t" . $self->error_msg
        ) if $self->has_error;

        $logger->debug( "Set $item value for ", $self->name, "" );

        $self->{$item} = $def;
    }
    return;
}

# set up relation between objects required by the compute constructor
# parameters
sub _build_compute_obj {
    my $self = shift;

    $logger->trace("called");

    my $c_info = $self->compute;
    return unless $c_info;

    my @compute_data;
    foreach ( keys %$c_info ) {
        push @compute_data, $_, $c_info->{$_} if defined $c_info->{$_};
    }

    my $ret = Config::Model::ValueComputer->new(
        @compute_data,
        value_object => $self,
        value_type   => $self->{value_type},
    );

    # resolve any recursive variables before registration
    my $v = $ret->compute_variables;

    $self->register_in_other_value($v);
    $logger->trace("done");
    return $ret;
}

sub register_in_other_value {
    my $self = shift;
    my $var  = shift;

    # register compute or refer_to dependency. This info may be used
    # by other tools
    foreach my $path ( values %$var ) {
        if ( defined $path and not ref $path ) {

            # is ref during test case
            #print "path is '$path'\n";
            next if $path =~ /\$/;    # next if path also contain a variable
            my $master = $self->grab($path);
            next unless $master->can('register_dependency');
            $master->register_dependency($self);
        }
    }
    return;
}

# internal
sub perform_compute {
    my $self = shift;
    $logger->trace("called");

    my $result = $self->compute_obj->compute;

    # check if the computed result fits with the constraints of the
    # Value model, but don't check if it's mandatory
    my ($value, $error, $warn) = $self->_check_value(value => $result);

    if ( scalar $error->@* ) {
        my $error = join("\n", (@$error, $self->compute_info));

        Config::Model::Exception::WrongValue->throw(
            object => $self,
            error  => "computed value error:\n\t" . $error
        );
    }

    $logger->trace("done");
    return $result;
}

# internal, used to generate error messages
sub compute_info {
    my $self = shift;
    return $self->compute_obj->compute_info;
}

sub set_migrate_from {
    my ( $self, $arg_ref ) = @_;

    my $mig_ref = delete $arg_ref->{migrate_from};

    if ( ref($mig_ref) eq 'HASH' ) {
        $self->migrate_from($mig_ref);
    }
    else {
        Config::Model::Exception::Model->throw(
            object => $self,
            error  => "migrate_from value must be a hash ref not $mig_ref"
        );
    }

    my @migrate_data;
    foreach (qw/formula variables replace use_eval undef_is/) {
        push @migrate_data, $_, $mig_ref->{$_} if defined $mig_ref->{$_};
    }

    $self->{_migrate_from} = Config::Model::ValueComputer->new(
        @migrate_data,
        value_object => $self,
        value_type   => $self->{value_type} );

    # resolve any recursive variables before registration
    my $v = $self->{_migrate_from}->compute_variables;
    return;
}

# FIXME: should it be used only once ???
sub migrate_value {
    my $self = shift;

    # migrate value is always used as a scalar, even in list
    # context. Not returning undef would break a hash assignment done
    # with something like:
    # my %args =  (value => $obj->migrate_value, fix => 1).

    ## no critic(Subroutines::ProhibitExplicitReturnUndef)

    return undef if $self->{migration_done};
    return undef if $self->instance->initial_load;
    $self->{migration_done} = 1;

    # avoid warning when reading deprecated values
    my $result = $self->{_migrate_from}->compute( check => 'skip' );

    return undef unless defined $result;

    # check if the migrated result fits with the constraints of the
    # Value object
    my $ok = $self->check_value( value => $result );

    #print "check result: $ok\n";
    if ( not $ok ) {
        Config::Model::Exception::WrongValue->throw(
            object => $self,
            error  => "migrated value error:\n\t" . $self->error_msg
        );
    }

    # old value is always undef when this method is called
    $self->notify_change( note => 'migrated value', new => $result )
        if length($result); # skip empty value (i.e. '')
    $self->{data} = $result;

    return $ok ? $result : undef;
}

sub setup_enum_choice ($self, @args) {
    my @choice = ref $args[0] ? @{ $args[0] } : @args;

    $logger->debug( $self->name, " setup_enum_choice with '", join( "','", @choice ), "'" );

    $self->{choice} = \@choice;

    # store all enum values in a hash. This way, checking
    # whether a value is present in the enum set is easier
    delete $self->{choice_hash} if defined $self->{choice_hash};

    for ( @choice ) { $self->{choice_hash}{$_} = 1; }

    # delete the current value if it does not fit in the new
    # choice
    for ( qw/data preset/ ) {
        my $lv = $self->{$_};
        if ( defined $lv and not defined $self->{choice_hash}{$lv} ) {
            delete $self->{$_};
        }
    }
    return;
}

sub setup_match_regexp {
    my ( $self, $what, $ref ) = @_;

    my $str = $self->{$what} = delete $ref->{$what};
    return unless defined $str;
    my $vt = $self->{value_type};

    if ( $vt ne 'uniline' and $vt ne 'string' and $vt ne 'enum') {
        Config::Model::Exception::Model->throw(
            object => $self,
            error  => "Can't use $what regexp with $vt, expected 'enum', 'uniline' or 'string'"
        );
    }

    $logger->debug( $self->name, " setup $what regexp with '$str'" );
    $self->{ $what . '_regexp' } = eval { qr/$str/; };

    if ($@) {
        Config::Model::Exception::Model->throw(
            object => $self,
            error  => "Unvalid $what regexp for '$str': $@"
        );
    }
    return;
}

sub check_validation_regexp {
    my ( $self, $what, $ref ) = @_;

    my $regexp_info = delete $ref->{$what};
    return unless defined $regexp_info;

    $self->{$what} = $regexp_info;

    my $vt = $self->{value_type};

    if ( $vt ne 'uniline' and $vt ne 'string' and $vt ne 'enum') {
        Config::Model::Exception::Model->throw(
            object => $self,
            error  => "Can't use $what regexp with $vt, expected 'enum', 'uniline' or 'string'"
        );
    }

    if ( not ref $regexp_info and $what ne 'warn' ) {
        warn $self->name, ": deprecated $what style. Use a hash ref\n";
    }

    my $h = ref $regexp_info ? $regexp_info : { $regexp_info => '' };

    # just check the regexp. values are checked later in &check_value
    foreach my $regexp ( keys %$h ) {
        $logger->debug( $self->name, " hash $what regexp with '$regexp'" );
        eval { qr/$regexp/; };

        if ($@) {
            Config::Model::Exception::Model->throw(
                object => $self,
                error  => "Unvalid $what regexp '$regexp': $@"
            );
        }

        my $v = $h->{$regexp};
        Config::Model::Exception::Model->throw(
            object => $self,
            error  => "value of $what regexp '$regexp' is not a hash ref but '$v'"
        ) unless ref $v eq 'HASH';

    }
    return;
}

sub setup_grammar_check {
    my ( $self, $ref ) = @_;

    my $str = $self->{grammar} = delete $ref->{grammar};
    return unless defined $str;
    my $vt = $self->{value_type};

    if ( $vt ne 'uniline' and $vt ne 'string' ) {
        Config::Model::Exception::Model->throw(
            object => $self,
            error  => "Can't use match regexp with $vt, " . "expected 'uniline' or 'string'"
        );
    }

    my @lines = split /\n/, $str;
    chomp @lines;
    if ( $lines[0] !~ /^check:/ ) {
        $lines[0] = 'check: ' . $lines[0] . ' /\s*\Z/ ';
    }

    my $actual_grammar = join( "\n", @lines ) . "\n";
    $logger->debug( $self->name, " setup_grammar_check with '$actual_grammar'" );
    eval { $self->{validation_parser} = Parse::RecDescent->new($actual_grammar); };

    if ($@) {
        Config::Model::Exception::Model->throw(
            object => $self,
            error  => "Unvalid grammar for '$str': $@"
        );
    }
    return;
}

# warning : call to 'set' are not cumulative. Default value are always
# restored. Lest keeping track of what was modified with 'set' is
# too confusing.
sub set_properties ($self, @args) {
    # cleanup all parameters that are handled by warp
    for ( @allowed_warp_params ) { delete $self->{$_} }

    # merge data passed to the constructor with data passed to set_properties
    my %args = ( %{ $self->backup // {} }, @args );

    # these are handled by Node or Warper
    for ( qw/level/ ) { delete $args{$_} }

    if ( $logger->is_trace ) {
        $logger->trace( "Leaf '" . $self->name . "' set_properties called with '",
            join( "','", sort keys %args ), "'" );
    }

    if (    defined $args{value_type}
        and $args{value_type} eq 'reference'
        and not defined $self->{refer_to}
        and not defined $self->{computed_refer_to} ) {
        Config::Model::Exception::Model->throw(
            object => $self,
            error  => "Missing 'refer_to' or 'computed_refer_to' "
                . "parameter with 'reference' value_type "
        );
    }

    for (qw/min max mandatory warn replace_follow assert warn_if warn_unless
            write_as/) {
        $self->{$_} = delete $args{$_} if defined $args{$_};
    }

    if ($args{replace}) {
        $self->{replace} = delete $args{replace};
        my $old = $self->_fetch_no_check;
        if (defined $old) {
            my $new = $self->apply_replace($old);
            $self->_store_value($new);
        }
    }

    $self->set_help( \%args );
    $self->set_value_type( \%args );
    $self->set_default( \%args );
    $self->set_convert( \%args ) if defined $args{convert};
    $self->setup_match_regexp( match => \%args ) if defined $args{match};
    foreach (qw/warn_if_match warn_unless_match/) {
        $self->check_validation_regexp( $_ => \%args ) if defined $args{$_};
    }
    $self->setup_grammar_check( \%args ) if defined $args{grammar};

    # cannot be warped
    $self->set_migrate_from( \%args ) if defined $args{migrate_from};

    Config::Model::Exception::Model->throw(
        object => $self,
        error  => "write_as is allowed only with boolean values"
    ) if defined $self->{write_as} and $self->{value_type} ne 'boolean';

    Config::Model::Exception::Model->throw(
        object => $self,
        error  => "Unexpected parameters: " . join( ' ', each %args ) ) if scalar keys %args;

    if ( $self->has_warped_slaves ) {
        my $value = $self->_fetch_no_check;
        $self->trigger_warp($value);
    }

    # when properties are changed, a check is required to validate new constraints
    $self->needs_check(1);

    return $self;
}

# simple but may be overridden
sub set_help {
    my ( $self, $args ) = @_;
    return unless defined $args->{help};
    $self->{help} = delete $args->{help};
    return;
}

# this code is somewhat dead as warping value_type is no longer supported
# but it may come back.
sub set_value_type {
    my ( $self, $arg_ref ) = @_;

    my $value_type = delete $arg_ref->{value_type} || $self->value_type;

    Config::Model::Exception::Model->throw(
        object => $self,
        error  => "Value set: undefined value_type"
    ) unless defined $value_type;

    $self->{value_type} = $value_type;

    if ( $value_type eq 'boolean' ) {

        # convert any value to boolean
        $self->{data}    = $self->{data}    ? 1 : 0 if defined $self->{data};
        $self->{preset}  = $self->{preset}  ? 1 : 0 if defined $self->{preset};
        $self->{layered} = $self->{layered} ? 1 : 0 if defined $self->{layered};
    }
    elsif ($value_type eq 'reference'
        or $value_type eq 'enum' ) {
        my $choice = delete $arg_ref->{choice};
        $self->setup_enum_choice($choice) if defined $choice;
    }
    elsif (any {$value_type eq $_} qw/string integer number uniline file dir/ ) {
        Config::Model::Exception::Model->throw(
            object => $self,
            error  => "'choice' parameter forbidden with type " . $value_type
        ) if defined $arg_ref->{choice};
    }
    else {
        my $msg =
              "Unexpected value type : '$value_type' "
            . "expected 'boolean', 'enum', 'uniline', 'string' or 'integer'."
            . "Value type can also be set up with a warp relation";
        Config::Model::Exception::Model->throw( object => $self, error => $msg )
            unless defined $self->{warp};
    }
    return;
}


sub submit_to_refer_to {
    my $self = shift;

    if ( defined $self->{refer_to} ) {
        $self->{ref_object} = Config::Model::IdElementReference->new(
            refer_to   => $self->{refer_to},
            config_elt => $self,
        );
    }
    elsif ( defined $self->{computed_refer_to} ) {
        $self->{ref_object} = Config::Model::IdElementReference->new(
            computed_refer_to => $self->{computed_refer_to},
            config_elt        => $self,
        );

        # refer_to registration is done for all element that are used as
        # variable for complex reference (ie '- $foo' , {foo => '- bar'} )
        $self->register_in_other_value( $self->{computed_refer_to}{variables} );
    }
    else {
        croak "value's submit_to_refer_to: undefined refer_to or computed_refer_to";
    }
    return;
}

sub setup_reference_choice ($self, @args) {
    return $self->setup_enum_choice(@args);
}

sub reference_object {
    my $self = shift;
    return $self->{ref_object};
}

sub built_in {
    carp "warning: built_in sub is deprecated, use upstream_default";
    goto &upstream_default;
}

## FIXME::what about id ??
sub name {
    my $self = shift;
    my $name = $self->{parent}->name . ' ' . $self->{element_name};
    $name .= ':' . $self->{index_value} if defined $self->{index_value};
    return $name;
}

sub get_type {
    return 'leaf';
}

sub get_cargo_type {
    return 'leaf';
}

sub can_store {
    my $self = shift;

    if ( not defined $self->compute ) {
        return 1;
    }
    if ( $self->compute_obj->allow_user_override ) {
        return 1;
    }
    return;
}

sub get_default_choice {
    my $self = shift;
    return @{ $self->{backup}{choice} || [] };
}

sub get_choice {
    my $self = shift;

    # just in case the reference_object has been changed
    if ( defined $self->{refer_to} or defined $self->{computed_refer_to} ) {
        $self->{ref_object}->get_choice_from_referred_to;
    }

    return @{ $self->{choice} || [] };
}

sub get_info {
    my $self = shift;

    my $type       = $self->value_type;
    my @choice     = $type eq 'enum' ? $self->get_choice : ();
    my $choice_str = @choice ? ' (' . join( ',', @choice ) . ')' : '';

    my @items = ( 'type: ' . $self->value_type . $choice_str, );

    my $std = $self->fetch(qw/mode standard check no/);

    if ( defined $self->upstream_default ) {
        push @items, "upstream_default value: " . $self->map_write_as( $self->upstream_default );
    }
    elsif ( defined $std ) {
        push @items, "default value: $std";
    }
    elsif ( defined $self->refer_to ) {
        push @items, "reference to: " . $self->refer_to;
    }
    elsif ( defined $self->computed_refer_to ) {
        push @items, "computed reference to: " . $self->computed_refer_to;
    }

    my $m = $self->mandatory;
    push @items, "is mandatory: " . ( $m ? 'yes' : 'no' ) if defined $m;

    foreach my $what (qw/min max warn grammar/) {
        my $v = $self->$what();
        push @items, "$what value: $v" if defined $v;
    }

    foreach my $what (qw/warn_if_match warn_unless_match/) {
        my $v = $self->$what();
        foreach my $k ( keys %$v ) {
            push @items, "$what value: $k";
        }
    }

    foreach my $what (qw/write_as/) {
        my $v = $self->$what();
        push @items, "$what: @$v" if defined $v;
    }

    return @items ;
}

sub get_help {
    my $self = shift;

    my $help = $self->{help};

    return $help unless @_;

    my $on_value = shift;
    return unless defined $on_value;

    my $fallback = $help->{'.'} || $help -> {'.*'};
    foreach my $k (sort { length($b) cmp length($a) } keys %$help) {
        next if $k eq '' or $k eq '.*';
        return $help->{$k} if $on_value =~ /^$k/;
    }
    return $fallback;
}

# construct an error message for enum types
sub enum_error {
    my ( $self, $value ) = @_;
    my @error;

    if ( not defined $self->{choice} ) {
        push @error, "$self->{value_type} type has no defined choice", $self->warp_error;
        return @error;
    }

    my @choice    = map { "'$_'" } $self->get_choice;
    my $var       = $self->{value_type};
    my $str_value = defined $value ? $value : '<undef>';
    push @error,
        "$self->{value_type} type does not know '$value'. Expected " . join( " or ", @choice );
    push @error,
        "Expected list is given by '" . join( "', '", @{ $self->{referred_to_path} } ) . "'"
        if $var eq 'reference' && defined $self->{referred_to_path};
    push @error, $self->warp_error if $self->{warp};

    return @error;
}

sub _check_value ($self, %args) {
    my $value     = $args{value};
    my $quiet     = $args{quiet} || 0;
    my $check     = $args{check} || 'yes';
    my $apply_fix = $args{fix} || 0;
    my $mode      = $args{mode} || 'backend';

    #croak "Cannot specify a value with fix = 1" if $apply_fix and exists $args{value} ;

    if ( $logger->is_debug ) {
        my $v = defined $value ? $value : '<undef>';
        my $loc = $self->location;
        my $msg =
              "called from "
            . join( ' ', caller )
            . " with value '$v' mode $mode check $check on '$loc'";
        $logger->debug($msg);
    }

    # need to keep track to update GUI
    $self->{nb_of_fixes} = 0;    # reset before check

    my @error;
    my @warn;
    my $vt = $self->value_type ;

    if ( not defined $value ) {

        # accept with no other check
    }
    elsif ( not defined $vt ) {
        push @error, "Undefined value_type";
    }
    elsif (( $vt =~ /integer/ and $value =~ /^-?\d+$/ )
        or ( $vt =~ /number/ and $value =~ /^-?\d+(\.\d+)?$/ ) ) {

        # correct number or integer. check min max
        push @error, "value $value > max limit $self->{max}"
            if defined $self->{max} and $value > $self->{max};
        push @error, "value $value < min limit $self->{min}"
            if defined $self->{min} and $value < $self->{min};
    }
    elsif ( $vt =~ /integer/ and $value =~ /^-?\d+(\.\d+)?$/ ) {
        push @error, "Type $vt: value $value is a number " . "but not an integer";
    }
    elsif ( $vt eq 'file' or $vt eq 'dir' ) {
        if (defined $value) {
            my $path = path($value);
            if ($path->exists) {
                my $check_sub = 'is_'.$vt ;
                push @warn, "$value is not a $vt" if not path($value)->$check_sub;
            }
            else {
                push @warn, "$vt $value does not exists" ;
            }
        }
    }
    elsif ( $vt eq 'reference' ) {

        # just in case the reference_object has been changed
        if ( defined $self->{refer_to} or defined $self->{computed_refer_to} ) {
            $self->{ref_object}->get_choice_from_referred_to;
        }

        if (    length($value)
            and defined $self->{choice_hash}
            and not defined $self->{choice_hash}{$value} ) {
            push @error, ( $quiet ? 'reference error' : $self->enum_error($value) );
        }
    }
    elsif ( $vt eq 'enum' ) {
        if (    length($value)
            and defined $self->{choice_hash}
            and not defined $self->{choice_hash}{$value} ) {
            push @error, ( $quiet ? 'enum error' : $self->enum_error($value) );
        }
    }
    elsif ( $vt eq 'boolean' ) {
        push @error, "error: '$value' is not boolean, i.e. not  "
            . join ( ' or ', map { "'$_'"} $self->map_write_as(qw/0 1/))
            unless $value =~ /^[01]$/;
    }
    elsif ($vt =~ /integer/
        or $vt =~ /number/ ) {
        push @error, "Value '$value' is not of type " . $vt;
    }
    elsif ( $vt eq 'uniline' ) {
        push @error, '"uniline" value must not contain embedded newlines (\n)'
            if $value =~ /\n/;
    }
    elsif ( $vt eq 'string' ) {

        # accepted, no more check
    }
    else {
        my $choice_msg = '';
        $choice_msg .= ", choice " . join( " ", $self->get_choice ) . ")"
            if defined $self->{choice};

        my $msg =
            "Cannot check value_type '$vt' (value '$value'$choice_msg)";
        Config::Model::Exception::Model->throw( object => $self, message => $msg );
    }

    if ( defined $self->{match_regexp} and defined $value ) {
        push @error, "value '$value' does not match regexp " . $self->{match}
            unless $value =~ $self->{match_regexp};
    }

    if ( $mode ne 'custom' ) {
        if ( $self->{warn_if_match} ) {
            my $test_sub = sub {
                my $v = shift // '';
                my $r = shift;
                $v =~ /$r/ ? 0 : 1;
            };
            $self->run_regexp_set_on_value( \$value, $apply_fix, \@warn, 'not ', $test_sub,
                $self->{warn_if_match} );
        }

        if ( $self->{warn_unless_match} ) {
            my $test_sub = sub {
                my $v = shift // '';
                my $r = shift;
                $v =~ /$r/ ? 1 : 0;
            };
            $self->run_regexp_set_on_value( \$value, $apply_fix, \@warn, '', $test_sub,
                $self->{warn_unless_match} );
        }

        $self->run_code_set_on_value( \$value, $apply_fix, \@error, $self->{assert} )
            if $self->{assert};
        $self->run_code_set_on_value( \$value, $apply_fix, \@warn, $self->{warn_unless} )
            if $self->{warn_unless};
        $self->run_code_set_on_value( \$value, $apply_fix, \@warn, $self->{warn_if}, 1 )
            if $self->{warn_if};
    }

    # unconditional warn
    push @warn, $self->{warn} if defined $value and $self->{warn};

    if ( defined $self->{validation_parser} and defined $value ) {
        my $prd = $self->{validation_parser};
        my ( $err_msg, $warn_msg ) = ( '', '' );
        my $prd_check = $prd->check( $value, 1, $self, \$err_msg, \$warn_msg );
        my $prd_result = defined $prd_check ? 1 : 0;
        $logger->debug( "grammar check on $value returned ", defined $prd_check ? $prd_check : '<undef>' );
        if (not $prd_result) {
            my $msg = "value '$value' does not match grammar from model";
            $msg .= ": $err_msg" if $err_msg;
            push @error, $msg;
        }
        push @warn, $warn_msg if $warn_msg;
    }

    $logger->debug(
        "check_value returns ",
        scalar @error,
        " errors and ", scalar @warn, " warnings"
    );

    # return $value because it may be modified by apply_fixes
    return ($value, \@error, \@warn);
}

sub _check_mandatory_value ($self, %args) {
    my $value     = $args{value};
    my $check     = $args{check} || 'yes';
    my $mode      = $args{mode} || 'backend';
    my $error     = $args{error} // carp "Missing error parameter";

    # a value may be mandatory and have a default value with layers
    if ( $self->{mandatory}
         and $check eq 'yes'
         and ( $mode =~ /backend|user/ )
         and ( not defined $value or not length($value) )
         and ( not defined $self->{layered} or not length($self->{layered}))
        ) {
        # check only "empty" mode.
        my $msg = "Undefined mandatory value.";
        $msg .= $self->warp_error
            if defined $self->{warped_attribute}{default};
        push $error->@*, $msg;
    }

    return;
}

sub check_value ($self, @args) {
    my ($value, $error, $warn) = $self->_check_value(@args);
    $self->_check_mandatory_value(@args, value => $value, error => $error);
    $self->clear_errors;
    $self->clear_warnings;
    $self->add_error(@$error)  if @$error;
    $self->add_warning(@$warn) if @$warn;

    $logger->trace("done");

    my $ok = not $error->@*;
    # return $value because it may be updated by apply_fix
    return wantarray ? ($ok, $value) : $ok;
}

sub run_code_on_value {
    my ( $self, $value_r, $apply_fix, $array, $label, $sub, $msg, $fix ) = @_;

    $logger->info( $self->location . ": run_code_on_value called (apply_fix $apply_fix)" );

    my $ret = $sub->($$value_r);
    if ( $logger->is_debug ) {
        my $str = defined $ret ? $ret : '<undef>';
        $logger->debug("run_code_on_value sub returned '$str'");
    }

    unless ($ret) {
        $logger->debug("run_code_on_value sub returned false");
        $msg =~ s/\$_/$$value_r/g if defined $$value_r;
        if ($msg =~ /\$std_value/) {
            my $std = $self->_fetch_std_no_check ;
            $msg =~ s/\$std_value/$std/g if defined $std;
        }
        $msg .= " (this cannot be fixed with 'cme fix' command)" unless $fix;
        push @$array, $msg unless $apply_fix;
        $self->{nb_of_fixes}++ if ( defined $fix and not $apply_fix );
        $self->apply_fix( $fix, $value_r, $msg ) if ( defined $fix and $apply_fix );
    }
    return;
}

# function that may be used in eval'ed code to use file in there (in
# run_code_set_on_value and apply_fix). Using this function is
# mandatory for tests that are done in pseudo root
# directory. Necessary for relative path (although chdir in and out of
# root_dir could work) and for absolute path (where chdir in and out
# of root_dir would not work without using chroot)

{
    # val is a value object. Use this trick so eval'ed code can
    # use file() function instead of $file->() sub ref
    my $val ;
    sub set_val {
        return $val = shift;
    }
    sub file {
        return $val->root_path->child(shift);
    }
}

sub run_code_set_on_value {
    my ( $self, $value_r, $apply_fix, $array, $w_info, $invert ) = @_;

    $self->set_val;

    foreach my $label ( sort keys %$w_info ) {
        my $code = $w_info->{$label}{code};
        my $msg = $w_info->{$label}{msg} || $label;
        $logger->trace("eval'ed code is: '$code'");
        my $fix = $w_info->{$label}{fix};

        my $sub = sub {
            local $_ = shift;
            ## no critic (TestingAndDebugging::ProhibitNoWarning)
            no warnings "uninitialized";
            my $ret = eval($code); ## no critic (ProhibitStringyEval)
            if ($@) {
                Config::Model::Exception::Model->throw(
                    object  => $self,
                    message => "Eval of assert or warning code failed : $@"
                );
            }
            return ($invert xor $ret) ;
        };

        $self->run_code_on_value( $value_r, $apply_fix, $array, $label, $sub, $msg, $fix );
    }
    return;
}

sub run_regexp_set_on_value {
    my ( $self, $value_r, $apply_fix, $array, $may_be, $test_sub, $w_info ) = @_;

    # no need to check default or computed values
    return unless defined $$value_r;

    foreach my $rxp ( sort keys %$w_info ) {
        # $_[0] is set to $$value_r when $sub is called
        my $sub = sub { $test_sub->( $_[0], $rxp ) };
        my $msg = $w_info->{$rxp}{msg} || "value should ${may_be}match regexp '$rxp'";
        my $fix = $w_info->{$rxp}{fix};
        $self->run_code_on_value( $value_r, $apply_fix, $array, 'regexp', $sub, $msg, $fix );
    }
    return
}

sub has_fixes {
    my $self = shift;
    return $self->{nb_of_fixes};
}

sub apply_fixes {
    my $self = shift;

    if ( $logger->is_trace ) {
        $fix_logger->trace( "called for " . $self->location );
    }

    my ( $old, $new );
    my $i = 0;
    do {
        $old = $self->{nb_of_fixes} // 0;
        $self->check_value( value => $self->_fetch_no_check, fix => 1 );

        $new = $self->{nb_of_fixes};
        $self->check_value( value => $self->_fetch_no_check );
        # if fix fails, try and check_fix call each other until this limit is found
        if ( $i++ > 20 ) {
            Config::Model::Exception::Model->throw(
                object => $self,
                error  => "Too many fix loops: check code used to fix value or the check"
            );
        }
    } while ( $self->{nb_of_fixes} and $old > $new );

    $self->show_warnings($self->_fetch_no_check);
    return;
}

# internal: called by check when a fix is required
sub apply_fix {
    my ( $self, $fix, $value_r, $msg ) = @_;

    local $_ = $$value_r;    # used inside $fix sub ref

    if ( $fix_logger->is_info ) {
        my $str = $fix;
        $str =~ s/\n/ /g;
        $fix_logger->info( $self->location . ": Applying fix '$str'" );
    }

    $self->set_val;

    eval($fix); ## no critic (ProhibitStringyEval)
    if ($@) {
        Config::Model::Exception::Model->throw(
            object  => $self,
            message => "Eval of fix $fix failed : $@"
        );
    }

    ## no critic (TestingAndDebugging::ProhibitNoWarning)
    no warnings "uninitialized";
    if ( $_ ne $$value_r ) {
        $fix_logger->info( $self->location . ": fix changed value from '$$value_r' to '$_'" );
        $self->_store_fix( $$value_r, $_, $msg );
        $$value_r = $_; # so chain of fixes work
    }
    else {
        $fix_logger->info( $self->location . ": fix did not change value '$$value_r'" );
    }
    return;
}

sub _store_fix {
    my ( $self, $old, $new, $msg ) = @_;

    $self->{data} = $new;

    if ( $fix_logger->is_trace ) {
        $fix_logger->trace(
            "fix change: '" . ( $old // '<undef>' ) . "' -> '" . ( $new // '<undef>' ) . "'"
        );
    }

    my $new_v = $new // $self->_fetch_std ;
    my $old_v = $old // $self->_fetch_std;

    if ( $fix_logger->is_trace ) {
        $fix_logger->trace(
            "fix change (with std value)): '" . ( $old // '<undef>' ) . "' -> '" . ( $new // '<undef>' ) . "'"
        );
    }

    ## no critic (TestingAndDebugging::ProhibitNoWarning)
    no warnings "uninitialized";
    # in case $old is the default value and $new is undef
    if ($old_v ne $new_v) {
        $self->notify_change(
            old => $old_v,
            new => $new_v,
            note => 'applied fix'. ( $msg ? ' for :'. $msg : '')
        );
        $self->trigger_warp($new_v) if defined $new_v and $self->has_warped_slaves;
    }
    return;
}

# read checks should be blocking

sub check {
    goto &check_fetched_value;
}

sub check_fetched_value ($self, @args) {
    if ( $logger->is_debug ) {
        ## no critic (TestingAndDebugging::ProhibitNoWarning)
        no warnings 'uninitialized';
        $logger->debug( "called for " . $self->location . " from " . join( ' ', caller ),
            " with @args" );
    }

    my %args =
          @args == 0 ? ( value => $self->{data} )
        : @args == 1 ? ( value => $args[0] )
        :              @args;

    my $value = exists $args{value} ? $args{value} : $self->{data};
    my $silent = $args{silent} || 0;
    my $check  = $args{check}  || 'yes';

    if ( $self->needs_check ) {
        $self->check_value(%args);

        my $err_count  = $self->has_error;
        my $warn_count = $self->has_warning;
        $logger->debug("done with $err_count errors and $warn_count warnings");

        $self->needs_check(0) unless $err_count or $warn_count;
    }
    else {
        $logger->debug("is not needed");
    }

    $self->show_warnings($value, $silent);

    return wantarray ? $self->all_errors : $self->is_ok;
}

sub show_warnings ($self, $value, $silent = 0) {
    # old_warn is used to avoid warning the user several times for the
    # same reason (i.e. when storing and fetching value). We take care
    # to clean up this hash each time store is run
    my $old_warn = $self->{old_warning_hash} || {};
    my %warn_h;

    if ( $self->has_warning and not $nowarning and not $silent ) {
        my $str = $value // '<undef>';
        chomp $str;
        my $w_str = $str =~ /\n/ ? "\n+++++\n$str\n+++++" : "'$str'";
        foreach my $w ( $self->all_warnings ) {
            $warn_h{$w} = 1;
            my $w_msg = "Warning in '" . $self->location_short . "': $w\nOffending value: $w_str";
            if ($old_warn->{$w}) {
                # user has already seen the warning, let's use debug level (required by tests)
                $user_logger->debug($w_msg);
            }
            else {
                $user_logger->warn($w_msg);
            }
        }
    }
    $self->{old_warning_hash} = \%warn_h;
    return;
}

sub store ($self, @args) {
    my %args =
          @args == 1 ? ( value => $args[0] )
        : @args == 3 ? ( 'value', @args )
        :              @args;
    my $check = $self->_check_check( $args{check} );
    my $silent = $args{silent} || 0;

    my $str = $args{value} // '<undef>';
    $logger->debug( "called with '$str' on ", $self->composite_name ) if $logger->is_debug;

    # store with check skip makes sense when force loading data: bad value
    # is discarded, partially consistent values are stored so the user may
    # salvage them before next save check discard them

    # $self->{data} represents what written in the file
    my $old_value = $self->{data};

    my $incoming_value = $args{value};
    $self->transform_boolean( \$incoming_value ) if $self->value_type eq 'boolean';

    my $value = $self->transform_value( value => $incoming_value, check => $check );

    ## no critic (TestingAndDebugging::ProhibitNoWarning)
    no warnings qw/uninitialized/;
    if ($self->instance->initial_load) {
        # may send more than one notification
        if ( $incoming_value ne $value ) {
            # data was transformed by model
            $self->notify_change(really => 1, old => $incoming_value , new => $value, note =>"initial value changed by model");
        }
        if (defined $old_value and $old_value ne $value) {
            $self->notify_change(really => 1, old => $old_value , new => $value, note =>"conflicting initial values");
        }
        if (defined $old_value and $old_value eq $value) {
            $self->notify_change(really => 1, note =>"removed redundant initial value");
        }
    }

    if ( defined $old_value and $value eq $old_value ) {
        $logger->info( "skip storage of ", $self->composite_name, " unchanged value: $value" )
            if $logger->is_info;
        return 1;
    }

    use warnings qw/uninitialized/;

    $self->needs_check(1);    # always when storing a value

    my ($ok, $fixed_value) = $self->check_stored_value(
        value         => $value,
        check         => $check,
        silent        => $silent,
    );

    $self->_store( %args, ok => $ok, value => $value, check => $check );

    my $user_cb = $args{callback} ;
    $user_cb->(%args) if $user_cb;

    return $ok || ($check eq 'no');
}

#
# New subroutine "_store_value" extracted - Wed Jan 16 18:46:22 2013.
#
sub _store_value {
    my $self          = shift;
    my $value         = shift;
    my $notify_change = shift // 1;

    if ( $self->instance->layered ) {
        $self->{layered} = $value;
    }
    elsif ( $self->instance->preset ) {
        $self->notify_change( check_done => 1, old => $self->{data}, new => $value )
            if $notify_change;
        $self->{preset} = $value;
    }
    else {
        ## no critic (TestingAndDebugging::ProhibitNoWarning)
        no warnings 'uninitialized';
        my $old = $self->{data} // $self->_fetch_std;
        my $new = $value        // $self->_fetch_std;
        $self->notify_change(
            check_done => 1,
            old        => $old,
            new        => $new
        ) if $notify_change and ( $old ne $new );
        $self->{data} = $value;    # may be undef
    }
    return $value;
}

# this method is overriden in layered Value
sub _store ($self, %args) {
    my ( $value, $check, $silent, $notify_change, $ok ) =
        @args{qw/value check silent notify_change ok/};

    if ( $logger->is_debug ) {
        my $i   = $self->instance;
        my $msg = "value store ". ($value // '<undef>')." ok '$ok', check is $check";
        for ( qw/layered preset/ ) { $msg .= " $_" if $i->$_() }
        $logger->debug($msg);
    }

    my $old_value = $self->_fetch_no_check;

    # let's store wrong value when check is disable (gh #15)
    if ( $ok or $check eq 'no' ) {
        $self->instance->cancel_error( $self->location );
        $self->_store_value( $value, $notify_change );
    }
    else {
        $self->instance->add_error( $self->location );
        if ($check eq 'skip') {
            if (not $silent and $self->has_error) {
                my $msg = "Warning: ".$self->location." skipping value $value because of the following errors:\n"
                    . $self->error_msg . "\n\n";
                # fuse UI exits when a warning is issued. No other need to advertise this option
                print $msg if $args{say_dont_warn};
                $user_logger->warn($msg) unless $args{say_dont_warn};
            }
        }
        else {
            Config::Model::Exception::WrongValue->throw(
                object => $self,
                error  => $self->error_msg
            );
        }
    }

    if (    $ok
        and defined $value
        and $self->has_warped_slaves
        and ( not defined $old_value or $value ne $old_value )
        and not( $self->instance->layered or $self->instance->preset ) ) {
        $self->trigger_warp($value);
    }

    $logger->trace( "_store done on ", $self->composite_name ) if $logger->is_trace;
    return;
}

#
# New subroutine "transform_boolean" extracted - Thu Sep 19 18:58:21 2013.
#
sub transform_boolean {
    my $self  = shift;
    my $v_ref = shift;

    return unless defined $$v_ref;

    if ( my $wa = $self->{write_as} ) {
        my $i = 0;
        for ( @$wa ) {
            $$v_ref = $i if ( $wa->[$i] eq $$v_ref );
            $i++
        }
    }

    # convert yes no to 1 or 0
    $$v_ref = 1 if ( $$v_ref =~ /^(y|yes|true|on)$/i );
    $$v_ref = 0 if ( $$v_ref =~ /^(n|no|false|off)$/i or length($$v_ref) == 0);
    return;
}

# internal. return ( undef, value)
# May return an undef value if actual store should be skipped
sub transform_value ($self, @args) {
    my %args = @args > 1 ? @args : ( value => $args[0] );
    my $value = $args{value};
    my $check = $args{check} || 'yes';

    my $inst = $self->instance;

    $self->warp
        if ($self->{warp}
        and defined $self->{warp_info}
        and @{ $self->{warp_info}{computed_master} } );

    if ( defined $self->compute_obj
        and not $self->compute_obj->allow_user_override ) {
        my $msg = 'assignment to a computed value is forbidden unless '
            . 'compute -> allow_override is set.';
        Config::Model::Exception::Model->throw( object => $self, message => $msg )
            if $check eq 'yes';
        return;
    }

    if ( defined $self->{refer_to} or defined $self->{computed_refer_to} ) {
        $self->{ref_object}->get_choice_from_referred_to;
    }

    $value = $self->{convert_sub}($value)
        if ( defined $self->{convert_sub} and defined $value );

    # apply replace on store *before* check is done, so a bad value
    # can be replaced with a good one
    $value = $self->apply_replace($value) if ($self->{replace} and defined $value);

    # using default or computed value is normally done on fetch. Except that an undefined
    # value cannot be stored in a mandatory value. Storing undef is used when resetting a
    # value to default. If a value is mandatory, we must store the default (or best equivalent)
    # instead
    if ( ( not defined $value or not length($value) ) and $self->mandatory ) {
        delete $self->{data};    # avoiding recycling the old stored value
        $value = $self->_fetch_no_check;
    }

    return $value;
}

sub apply_replace {
    my ($self, $value) = @_;

    if ( defined $self->{replace}{$value} ) {
        $logger->debug("store replacing value $value with $self->{replace}{$value}");
        $value = $self->{replace}{$value};
    }
    else {
        foreach my $k ( keys %{ $self->{replace} } ) {
            if ( $value =~ /^$k$/ ) {
                $logger->debug(
                    "store replacing value $value (matched /$k/) with $self->{replace}{$k}");
                $value = $self->{replace}{$k};
                last;
            }
        }
    }
    return $value;
}

sub check_stored_value ($self, %args) {
    my ($ok, $fixed_value) = $self->check_value( %args );

    my ( $value, $check, $silent ) =
        @args{qw/value check silent/};

    $self->needs_check(0) unless $self->has_error or $self->has_warning;

    # must always warn when storing a value, hence clearing the list
    # of already issued warnings
    $self->{old_warning_hash} = {};
    $self->show_warnings($value, $silent);

    return wantarray ? ($ok,$fixed_value) : $ok;
}

# print a hopefully helpful error message when value_type is not
# defined
sub _value_type_error {
    my $self = shift;

    Config::Model::Exception::Model->throw(
        object  => $self,
        message => 'value_type is undefined'
    ) unless defined $self->{warp};

    my $str = "Item " . $self->{element_name} . " is not available. " . $self->warp_error;

    Config::Model::Exception::User->throw( object => $self, message => $str );
    return;
}

sub load_data ($self, @args) {
    my %args = @args > 1 ? @args : ( data => $args[0] );
    my $data  = delete $args{data} // delete $args{value};

    my $rd = ref $data;

    if ( $rd and any { $rd eq $_ } qw/ARRAY HASH SCALAR/) {
        Config::Model::Exception::LoadData->throw(
            object     => $self,
            message    => "load_data called with non scalar arg",
            wrong_data => $data,
        );
    }
    else {
        if ( $logger->is_info ) {
            my $str = $data // '<undef>';
            $logger->info( "Value load_data (", $self->location, ") will store value $str" );
        }
        return $self->store(%args, value => $data);
    }
    return;
}

sub fetch_custom {
    my $self      = shift;
    return $self->fetch(mode => 'custom');
}

sub fetch_standard {
    my $self      = shift;
    return $self->fetch(mode => 'standard');
}

sub has_data {
    my $self = shift;
    return (defined $self->fetch(qw/mode custom check no silent 1/)) ? 1 : 0 ;
}

sub _init {
    my $self = shift;

    # trigger loop
    #$self->{warper} -> trigger if defined $self->{warper} ;
    #	   if ($self->{warp} and defined $self->{warp_info}
    #		   and @{$self->{warp_info}{computed_master}});

    if ( defined $self->{refer_to} or defined $self->{computed_refer_to} ) {
        $self->submit_to_refer_to;
        $self->{ref_object}->get_choice_from_referred_to;
    }
    return;
}

# returns something that needs to be written to config file
# unless overridden by user data
sub _fetch_std {
    my ( $self, $check ) = @_;

    if ( not defined $self->{value_type} and $check eq 'yes' ) {
        $self->_value_type_error;
    }

    # get stored value or computed value or default value
    my $std_value;

    eval {
        $std_value =
              defined $self->{preset}   ? $self->{preset}
            : $self->compute_is_default ? $self->perform_compute
            :                             $self->{default};
    };

    my $e = $@;;
    if ( ref($e) and $e->isa('Config::Model::Exception::User') ) {
        if ( $check eq 'yes' ) {
            $e->rethrow;
        }
        $std_value = undef;
    }
    elsif ( ref($e) ) {
        $e->rethrow ;
    }
    elsif ($e) {
        die $e;
    }

    return $std_value;
}

# use when std_value is needed to create error or warning message
# within a check sub. Using _fetch_std leads to deep recursions
sub _fetch_std_no_check {
    my ( $self, $check ) = @_;

    # get stored value or computed value or default value
    my $std_value;

    eval {
        $std_value =
              defined $self->{preset}   ? $self->{preset}
            : $self->compute_is_default ? $self->compute_obj->compute
            :                             $self->{default};
    };

    if ($@) {
        $logger->debug("eval got error: $@");
    }

    return $std_value;
}

my %old_mode = (
    built_in     => 'upstream_default',
    non_built_in => 'non_upstream_default',
);

{
    my %accept_mode = map { ( $_ => 1 ) } qw/custom standard preset default upstream_default
                                             layered non_upstream_default allow_undef user backend/;

    sub is_bad_mode {
        my ($self, $mode) = @_;
        if ( $mode and not defined $accept_mode{$mode} ) {
            my $good_ones = join( ' or ', sort keys %accept_mode );
            return "expected $good_ones as mode parameter, not $mode";
        }
    }
}

sub _fetch {
    my ( $self, $mode, $check ) = @_;
    $logger->trace( "called for " . $self->location ) if $logger->is_trace;

    # always call to perform submit_to_warp
    my $pref = $self->_fetch_std( $check );

    my $data = $self->{data};
    if ( defined $pref and not $self->{notified_change_for_default} and not defined $data ) {
        $self->{notified_change_for_default} = 1;
        my $info =  defined $self->{preset}  ? 'preset'
                 : $self->compute_is_default ? 'computed'
                 :                             'default';
        $self->notify_change( old => undef, new => $pref, note => "use $info value" );
    }

    my $layer_data = $self->{layered};
    my $known_upstream =
          defined $layer_data                ? $layer_data
        : $self->compute_is_upstream_default ? $self->perform_compute
        :                                      $self->{upstream_default};
    my $std = defined $pref ? $pref : $known_upstream;

    if ( defined $self->{_migrate_from} and not defined $data ) {
        $data = $self->migrate_value;
    }

    foreach my $k ( keys %old_mode ) {
        next unless $mode eq $k;
        $mode = $old_mode{$k};
        carp $self->location, " warning: deprecated mode parameter: $k, ", "expected $mode\n";
    }

    if (my $err = $self->is_bad_mode($mode)) {
        croak "fetch_no_check: $err";
    }

    if ( $mode eq 'custom' ) {
        ## no critic (TestingAndDebugging::ProhibitNoWarning)
        no warnings "uninitialized";
        my $cust;
        $cust = $data
            if $data ne $pref
            and $data ne $self->{upstream_default}
            and $data ne $layer_data;
        $logger->debug( "custom mode result '$cust' for " . $self->location )
            if $logger->is_debug;
        return $cust;
    }

    if ( $mode eq 'non_upstream_default' ) {
        ## no critic (TestingAndDebugging::ProhibitNoWarning)
        no warnings "uninitialized";
        my $nbu;
        foreach my $d ($data, $layer_data, $pref) {
            if ( defined $d and $d ne $self->{upstream_default} ) {
                $nbu = $d;
                last;
            }
        }

        $logger->debug( "done in non_upstream_default mode for " . $self->location )
            if $logger->is_debug;
        return $nbu;
    }

    my $res;
    given ($mode) {
        when ([qw/preset default upstream_default layered/]) {
            $res = $self->{$mode};
        }
        when ('standard') {
            $res = $std;
        }
        when ('backend') {
            $res = $self->_data_or_alt($data, $pref);
        }
        when ([qw/user allow_undef/]) {
            $res = $self->_data_or_alt($data, $std);
        }
        default {
            die "unexpected mode $mode ";
        }
    }

    $logger->debug( "done in '$mode' mode for " . $self->location . " -> " . ( $res // '<undef>' ) )
        if $logger->is_debug;

    return $res;
}

sub _data_or_alt ($self, $data, $alt) {
    my $res;
    given ($self->value_type) {
        when ([qw/integer boolean number/]) {
            $res = $data // $alt
        }
        default {
            # empty string is considered as undef, but empty string is
            # still returned if there's not defined alternative ($alt)
            $res = length($data) ? $data : $alt // $data
        }
    }
    return $res;
}

sub fetch_no_check {
    my $self = shift;
    carp "fetch_no_check is deprecated. Use fetch (check => 'no')";
    return $self->fetch( check => 'no' );
}

# likewise but without any warp, etc related check
sub _fetch_no_check {
    my $self = shift;
    return
          defined $self->{data}          ? $self->{data}
        : defined $self->{preset}        ? $self->{preset}
        : defined $self->{compute}       ? $self->perform_compute
        : defined $self->{_migrate_from} ? $self->migrate_value
        :                                  $self->{default};
}

sub fetch_summary ($self, @args) {
    my $value = $self->fetch(@args) // '<undef>';
    $value =~ s/\n/ /g;
    $value = substr( $value, 0, 15 ) . '...' if length($value) > 15;
    return $value;
}

sub fetch ($self, @args) {
    my %args = @args > 1 ? @args : ( mode => $args[0] );
    my $mode   = $args{mode}   || 'backend';
    my $silent = $args{silent} || 0;
    my $check  = $self->_check_check( $args{check} );

    if ( $logger->is_trace ) {
        $logger->trace( "called for "
                . $self->location
                . " check $check mode $mode"
                . " needs_check "
                . $self->needs_check );
    }

    my $inst = $self->instance;

    my $value = $self->_fetch( $mode, $check );

    if ( $logger->is_debug ) {
        $logger->debug( "_fetch returns " . ( defined $value ? $value : '<undef>' ) );
    }

    if ( my $err = $self->is_bad_mode($mode) ) {
        croak "fetch: $err";
    }

    if ( defined $self->{replace_follow} and defined $value ) {
        my $rep = $self->grab_value(
            step    => $self->{replace_follow} . qq!:"$value"!,
            mode    => 'loose',
            autoadd => 0,
        );

        # store replaced value to trigger notify_change
        if ( defined $rep and $rep ne $value ) {
            $logger->debug( "fetch replace_follow $value with $rep from ".$self->{replace_follow});
            $value = $self->_store_value($rep);
        }
    }

    # check and subsequent storage of fixes instruction must be done only
    # in user or custom mode. (because fixes are cleaned up during check and using
    # mode may not trigger the warnings. Hence confusion afterwards)
    my $ok = 1;
    $ok = $self->check( value => $value, silent => $silent, mode => $mode )
        if $mode =~ /backend|custom|user/ and $check ne 'no';

    $logger->trace( "$mode fetch (almost) done for " . $self->location )
        if $logger->is_trace;

    # check validity (all modes)
    if ( $ok or $check eq 'no' ) {
        return $self->map_write_as($value);
    }
    elsif ( $check eq 'skip' ) {
        my $msg = $self->error_msg;
        my $str = $value // '<undef>';
        $user_logger->warn("Warning: fetch [".$self->name,"] skipping value $str because of the following errors:\n$msg\n")
            if not $silent and $msg;
        # this method is supposed to return a scalar
        return undef; ## no critic(Subroutines::ProhibitExplicitReturnUndef)

    }

    Config::Model::Exception::WrongValue->throw(
        object => $self,
        error  => $self->error_msg
    );

    return;
}

sub map_write_as ($self, @args) {
    my @res;
    if ($self->{write_as} and $self->value_type eq 'boolean') {
        foreach my $v (@args) {
            push @res, ( defined $v and $v =~ /^\d+$/ ) ? $self->{write_as}[$v] : $v;
        }
    }
    else {
        @res = @args;
    }
    return wantarray ? @res : $res[0];
}

sub user_value {
    return shift->{data};
}

sub fetch_preset {
    my $self = shift;
    return $self->map_write_as( $self->{preset} );
}

sub clear {
    my $self = shift;
    $self->store(undef);
    return;
}

sub clear_preset {
    my $self = shift;
    delete $self->{preset};
    return defined $self->{layered} || defined $self->{data};
}

sub fetch_layered {
    my $self = shift;
    return $self->map_write_as( $self->{layered} );
}

sub clear_layered {
    my $self = shift;
    delete $self->{layered};
    return defined $self->{preset} || defined $self->{data};
}

sub get ($self, @args) {
    my %args = @args > 1 ? @args : ( path => $args[0] );
    my $path = delete $args{path};
    if ($path) {
        Config::Model::Exception::User->throw(
            object  => $self,
            message => "get() called with a value with non-empty path: '$path'"
        );
    }
    return $self->fetch(%args);
}

sub set ($self, $path, @data) {
    if ($path) {
        Config::Model::Exception::User->throw(
            object  => $self,
            message => "set() called with a value with non-empty path: '$path'"
        );
    }
    return $self->store(@data);
}

#These methods are important when this leaf value is used as a warp
#master, or a variable in a compute formula.

# register a dependency, This information may be used by external
# tools
sub register_dependency {
    my $self  = shift;
    my $slave = shift;

    unshift @{ $self->{depend_on_me} }, $slave;

    # weaken only applies to the passed reference, and there's no way
    # to duplicate a weak ref. Only a strong ref is created.
    weaken( $self->{depend_on_me}[0] );
    return;
}

sub get_depend_slave {
    my $self = shift;

    my @result = ();
    push @result, @{ $self->{depend_on_me} }
        if defined $self->{depend_on_me};

    push @result, $self->get_warped_slaves;

    # needs to clean up weak ref to object that were destroyed
    return grep { defined $_ } @result;
}

__PACKAGE__->meta->make_immutable;

1;

# ABSTRACT:	 Strongly typed configuration value

__END__

=pod

=encoding UTF-8

=head1 NAME

Config::Model::Value - Strongly typed configuration value

=head1 VERSION

version 2.152

=head1 SYNOPSIS

 use Config::Model;

 # define configuration tree object
 my $model = Config::Model->new;
 $model ->create_config_class (
    name => "MyClass",

    element => [

        [qw/foo bar/] => {
            type	   => 'leaf',
            value_type => 'string',
            description => 'foobar',
        }
        ,
        country => {
            type =>		  'leaf',
            value_type => 'enum',
            choice =>	   [qw/France US/],
            description => 'big countries',
        }
    ,
    ],
 ) ;

 my $inst = $model->instance(root_class_name => 'MyClass' );

 my $root = $inst->config_root ;

 # put data
 $root->load( steps => 'foo=FOO country=US' );

 print $root->report ;
 #  foo = FOO
 #		  DESCRIPTION: foobar
 #
 #  country = US
 #		  DESCRIPTION: big countries

=head1 DESCRIPTION

This class provides a way to specify configuration value with the
following properties:

=over

=item *

Strongly typed scalar: the value can either be an enumerated type, a boolean,
a number, an integer or a string

=item *

default parameter: a value can have a default value specified during
the construction. This default value is written in the target
configuration file. (C<default> parameter)

=item *

upstream default parameter: specifies a default value that is
used by the application when no information is provided in the
configuration file. This upstream_default value is not written in
the configuration files. Only the C<fetch_standard> method returns
the builtin value. This parameter was previously referred as
C<built_in> value. This may be used for audit
purpose. (C<upstream_default> parameter)

=item *

mandatory value: reading a mandatory value raises an exception if the
value is not specified (i.e is C<undef> or empty string) and has no
default value.

=item *

dynamic change of property: A slave value can be registered to another
master value so that the properties of the slave value can change
according to the value of the master value. For instance, paper size value
can be 'letter' for country 'US' and 'A4' for country 'France'.

=item *

A reference to the Id of a hash of list element. In other word, the
value is an enumerated type where the possible values (choice) is
defined by the existing keys of a has element somewhere in the tree. See
L</"Value Reference">.

=back

=head1 Default values

There are several kind of default values. They depend on where these
values are defined (or found).

From the lowest default level to the "highest":

=over

=item *

C<upstream_default>: The value is known in the application, but is not
written in the configuration file.

=item *

C<layered>: The value is known by the application through another
mean (e.g. an included configuration file), but is not written in the
configuration file.

=item *

C<default>: The value is known by the model, but not by the
application. This value must be written in the configuration file.

=item *

C<computed>: The value is computed from other configuration
elements. This value must be written in the configuration file.

=item *

C<preset>: The value is not known by the model or by the
application. But it can be found by an automatic program and stored
while the configuration L<Config::Model::Instance|instance> is in
L<preset mode|Config::Model::Instance/"preset_start ()">

=back

Then there is the value entered by the user. This overrides all
kind of "default" value.

The L<fetch_standard> function returns the "highest" level of
default value, but does not return a custom value, i.e. a value
entered by the user.

=head1 Constructor

Value object should not be created directly.

=head1 Value model declaration

A leaf element must be declared with the following parameters:

=over

=item value_type

Either C<boolean>, C<enum>, C<integer>, C<number>,
C<uniline>, C<string>, C<file>, C<dir>. Mandatory. See L</"Value types">.

=item default

Specify the default value (optional)

=item upstream_default

Specify a built in default value (optional). I.e a value known by the application
which does not need to be written in the configuration file.

=item write_as

Array ref. Reserved for boolean value. Specify how to write a boolean value.
Default is C<[0,1]> which may not be the most readable. C<write_as> can be
specified as C<['false','true']> or C<['no','yes']>.

=item compute

Computes a value according to a formula and other values. By default
a computed value cannot be set. See L<Config::Model::ValueComputer> for
computed value declaration.

=item migrate_from

This is a special parameter to cater for smooth configuration
upgrade. This parameter can be used to copy the value of a deprecated
parameter to its replacement. See L</Upgrade> for details.

=item convert => [uc | lc ]

When stored, the value is converted to uppercase (uc) or
lowercase (lc).

=item min

Specify the minimum value (optional, only for integer, number)

=item max

Specify the maximum value (optional, only for integer, number)

=item mandatory

Set to 1 if the configuration value B<must> be set by the
configuration user (default: 0)

=item choice

Array ref of the possible value of an enum. Example :

 choice => [ qw/foo bar/]

=item match

Perl regular expression. The value is matched with the regex to
assert its validity. Example C<< match => '^foo' >> means that the
parameter value must begin with "foo". Valid only for C<string> or
C<uniline> values.

=item warn_if_match

Hash ref. Keys are made of Perl regular expression. The value can
specify a warning message (leave empty or undefined for a default warning
message) and instructions to fix the value. A warning is issued
when the value matches the passed regular expression. Valid only for
C<string> or C<uniline> values. The fix instructions is evaluated
when L<apply_fixes> is called. C<$_> contains the value to fix.
C<$_> is stored as the new value once the instructions are done.
C<$self> contains the value object. Use with care.

In the example below, any value matching 'foo' is converted in uppercase:

 warn_if_match => {
   'foo' => {
        fix => 'uc;',
        msg =>  'value $_ contains foo'
   },
   'BAR' => {
        fix =>'lc;',
        msg =>  'value $_ contains BAR'
   }
 },

The tests are done in alphabetical order. In the example above, C<BAR> test is
done before C<foo> test.

C<$_> is substituted with the bad value when the message is generated. C<$std_value>
is substituted with the standard value (i.e the preset, computed or default value).

=item warn_unless_match

Hash ref like above. A warning is issued when the value does not
match the passed regular expression. Valid only for C<string> or
C<uniline> values.

=item warn

String. Issue a warning to user with the specified string any time a value is set or read.

=item warn_if

A bit like C<warn_if_match>. The hash key is not a regexp but a label to
help users. The hash ref contains some Perl code that is evaluated to
perform the test. A warning is issued if the given code returns true.

C<$_> contains the value to check. C<$self> contains the
C<Config::Model::Value> object (use with care).

The example below warns if value contains a number:

 warn_if => {
    warn_test => {
        code => 'defined $_ && /\d/;',
        msg  => 'value $_ should not have numbers',
        fix  => 's/\d//g;'
    }
 },

Hash key is used in warning message when C<msg> is not set:

 warn_if => {
   'should begin with foo' => {
        code => 'defined && /^foo/'
   }
 }

Any operation or check on file must be done with C<file> sub
(otherwise tests will break). This sub returns a L<Path::Tiny>
object that can be used to perform checks. For instance:

  warn_if => {
     warn_test => {
         code => 'not file($_)->exists',
         msg  => 'file $_ should exist'
     }

=item warn_unless

Like C<warn_if>, but issue a warning when the given C<code> returns false.

The example below warns unless the value points to an existing directory:

 warn_unless => {
     'missing dir' => {
          code => '-d',
          fix => "system(mkdir $_);" }
 }

=item assert

Like C<warn_if>. Except that returned value triggers an error when the
given code returns false:

 assert => {
    test_nb => {
        code => 'defined $_ && /\d/;',
        msg  => 'should not have numbers',
        fix  => 's/\d//g;'
    }
 },

hash key can also be used to generate error message when C<msg> parameter is not set.

=item grammar

Setup a L<Parse::RecDescent> grammar to perform validation.

If the grammar does not start with a "check" rule (i.e does not start with "check: "),
the first line of the grammar is modified to add "check" rule and this rules is set up so
the entire value must match the passed grammar.

I.e. the grammar:

 token (oper token)(s?)
 oper: 'and' | 'or'
 token: 'Apache' | 'CC-BY' | 'Perl'

is changed to

 check: token (oper token)(s?) /^\Z/ {$return = 1;}
 oper: 'and' | 'or'
 token: 'Apache' | 'CC-BY' | 'Perl'

The rule is called with Value object and a string reference. So, in the
actions you may need to define, you can call the value object as
C<$arg[0]>, store error message in C<${$arg[1]}}> and store warnings in
C<${$arg[2]}}>.

=item replace

Hash ref. Used for enum to substitute one value with another. This
parameter must be used to enable user to upgrade a configuration with
obsolete values. For instance, if the value C<foo> is obsolete and
replaced by C<foo_better>, you must declare:

 replace => { foo => 'foo_better' }

The hash key can also be a regular expression for wider range replacement.
The regexp must match the whole value:

 replace => ( 'foo.*' => 'better_foo' }

In this case, a value is replaced by C<better_foo> when the
C</^foo.*$/> regexp matches.

=item replace_follow

Path specifying a hash of value element in the configuration tree. The
hash if used in a way similar to the C<replace> parameter. In this case, the
replacement is not coded in the model but specified by the configuration.

=item refer_to

Specify a path to an id element used as a reference. See L<Value
Reference> for details.

=item computed_refer_to

Specify a path to an id element used as a computed reference. See
L<Value Reference> for details.

=item warp

See section below: L</"Warp: dynamic value configuration">.

=item help

You may provide detailed description on possible values with a hash
ref. Example:

help => { oui => "French for 'yes'", non => "French for 'no'"}

The key of help is used as a regular expression to find the help text
applicable to a value. These regexp are tried from the longest to the
shortest and are matched from the beginning of the string. The key "C<.>"
or "C<.*>" are fallback used last.

For instance:

 help => {
   'foobar' => 'help for values matching /^foobar/',
   'foo' => 'help for values matching /^foo/ but not /^foobar/ (used above)',
   '.' => 'help for all other values'
 }

=back

=head2 Value types

This modules can check several value types:

=over

=item C<boolean>

Accepts values C<1> or C<0>, C<yes> or C<no>, C<true> or C<false>, and
empty string. The value read back is always C<1> or C<0>.

=item C<enum>

Enum choices must be specified by the C<choice> parameter.

=item C<integer>

Enable positive or negative integer

=item C<number>

The value can be a decimal number

=item C<uniline>

A one line string. I.e without "\n" in it.

=item C<string>

Actually, no check is performed with this type.

=item C<reference>

Like an C<enum> where the possible values (aka choice) is defined by
another location if the configuration tree. See L</Value Reference>.

=item C<file>

A file name or path. A warning is issued if the file does not
exists (or is a directory)

=item C<dir>

A directory name or path. A warning is issued if the directory
does not exists (or is a plain file)

=back

=head1 Warp: dynamic value configuration

The Warp functionality enable a C<Value> object to change its
properties (i.e. default value or its type) dynamically according to
the value of another C<Value> object locate elsewhere in the
configuration tree. (See L<Config::Model::Warper> for an
explanation on warp mechanism).

For instance if you declare 2 C<Value> element this way:

 $model ->create_config_class (
     name => "TV_config_class",
     element => [
         country => {
             type => 'leaf',
             value_type => 'enum',
             choice => [qw/US Europe Japan/]
         } ,
         tv_standard => { # this example is getting old...
             type => 'leaf',
             value_type => 'enum',
             choice => [ qw/PAL NTSC SECAM/ ]
             warp => {
                 follow => {
                     # this points to the warp master
                     c => '- country'
                 },
                 rules => {
                     '$c eq "US"' => {
                          default => 'NTSC'
                      },
                     '$c eq "France"' => {
                          default => 'SECAM'
                      },
                     '$c eq "Japan"' => {
                          default => 'NTSC'
                      },
                     '$c eq "Europe"' => {
                          default => 'PAL'
                     },
                 }
             }
         } ,
     ]
 );

Setting C<country> element to C<US> means that C<tv_standard> has
a default value set to C<NTSC> by the warp mechanism.

Likewise, the warp mechanism enables you to dynamically change the
possible values of an enum element:

 state => {
     type => 'leaf',
     value_type => 'enum', # example is admittedly silly
     warp => {
         follow => {
             c => '- country'
         },
         rules => {
             '$c eq "US"'	 => {
                  choice => ['Kansas', 'Texas' ]
              },
             '$c eq "Europe"' => {
                  choice => ['France', 'Spain' ]
             },
             '$c eq "Japan"' => {
                  choice => ['Honshu', 'Hokkaido' ]
             }
         }
     }
 }

=head2 Cascaded warping

Warping value can be cascaded: C<A> can be warped by C<B> which can be
warped by C<C>. But this feature should be avoided since it can lead
to a model very hard to debug. Bear in mind that:

=over

=item *

Warp loops are not detected and end up in "deep recursion
subroutine" failures.

=item *

avoid "diamond" shaped warp dependencies: the results depends on the
order of the warp algorithm which can be unpredictable in this case

=item *

The keys declared in the warp rules (C<US>, C<Europe> and C<Japan> in
the example above) cannot be checked at start time against the warp
master C<Value>. So a wrong warp rule key is silently ignored
during start up and fails at run time.

=back

=head1 Value Reference

To set up an enumerated value where the possible choice depends on the
key of a L<Config::Model::AnyId> object, you must:

=over

=item *

Set C<value_type> to C<reference>.

=item *

Specify the C<refer_to> or C<computed_refer_to> parameter.
See L<refer_to parameter|Config::Model::IdElementReference/"Config class parameters">.

=back

In this case, a C<IdElementReference> object is created to handle the
relation between this value object and the referred Id. See
L<Config::Model::IdElementReference> for details.

=head1 Introspection methods

The following methods returns the current value of the parameter of
the value object (as declared in the model unless they were warped):

=over

=item min

=item max

=item mandatory

=item choice

=item convert

=item value_type

=item default

=item upstream_default

=item index_value

=item element_name

=back

=head2 name

Returns the object name.

=head2 get_type

Returns C<leaf>.

=head2 can_store

Returns true if the value object can be assigned to. Return 0 for a
read-only value (i.e. a computed value with no override allowed).

=head2 get_choice

Query legal values (only for enum types). Return an array (possibly
empty).

=head2 get_help

With a parameter, returns the help string applicable to the passed
value or undef.

Without parameter returns a hash ref that contains all the help strings.

=head2 get_info

Returns a list of information related to the value, like value type,
default value. This should be used to provide some debug information
to the user.

For instance, C<$val->get-info> may return:

 [ 'type: string', 'mandatory: yes' ]

=head2 error_msg

Returns the error messages of this object (if any)

=head2 warning_msg

Returns warning concerning this value. Returns a list in list
context and a string in scalar context.

=head2 check_value

Parameters: C<< ( value ) >>

Check the consistency of the value.

C<check_value> also accepts named parameters:

=over 4

=item value

=item quiet

When non null, check does not try to get extra
information from the tree. This is required in some cases to avoid
loops in check, get_info, get_warp_info, re-check ...

=back

In scalar context, return 0 or 1.

In array context, return an empty array when no error was found. In
case of errors, returns an array of error strings that should be shown
to the user.

=head2 has_fixes

Returns the number of fixes that can be applied to the current value.

=head2 apply_fixes

Applies the fixes to suppress the current warnings.

=head2 check

Parameters: C<< ( [ value => foo ] ) >>

Like L</check_value>.

Also displays warnings on STDOUT unless C<silent> parameter is set to 1.
In this case,user is expected to retrieve them with
L</warning_msg>.

Without C<value> argument, this method checks the value currently stored.

=head2 is_bad_mode

Accept a mode parameter. This function checks if the mode is accepted
by L</fetch> method. Returns an error message if not. For instance:

 if (my $err = $val->is_bad_mode('foo')) {
    croak "my_function: $err";
 }

This method is intented as a helper to avoid duplicating the list of
accepted modes for functions that want to wrap fetch methods (like
L<Config::Model::Dumper> or L<Config::Model::DumpAsData>)

=head1 Information management

=head2 store

Parameters: C<< ( $value ) >>
or C<< value => ...,	check => yes|no|skip ), silent => 0|1 >>

Store value in leaf element. C<check> parameter can be used to
skip validation check (default is 'yes').
C<silent> can be used to suppress warnings.

Optional C<callback> is now deprecated.

=head2 clear

Clear the stored value. Further read returns the default value (or
computed or migrated value).

=head2 load_data

Parameters: C<< ( $value ) >>

Called with the same parameters are C<store> method.

Load scalar data. Data is forwarded to L</"store"> after checking that
the passed value is not a reference.

=head2 fetch_custom

Returns the stored value if this value is different from a standard
setting or built in setting. In other words, returns undef if the
stored value is identical to the default value or the computed value
or the built in value.

=head2 fetch_standard

Returns the standard value as defined by the configuration model. The
standard value can be either a preset value, a layered value, a computed value, a
default value or a built-in default value.

=head2 has_data

Return true if the value contains information different from default
or upstream default value.

=head2 fetch

Check and fetch value from leaf element. The method can have one parameter (the fetch mode)
or several pairs:

=over 4

=item mode

Whether to fetch default, custom, etc value. See below for details

=item check

Whether to check if the value is valid or not before returning it. Default is 'yes'.
Possible value are

=over 4

=item yes

Perform check and raise an exception for bad values

=item skip

Perform check and return undef for bad values. A warning is issued when a bad value is skipped.
Set C<check> to C<no> to avoid warnings.

=item no

Do not check and return values even if bad

=back

=item silent

When set to 1, warning are not displayed on STDOUT. User is expected to read warnings
with L<warning_msg> method.

=back

According to the C<mode> parameter, this method returns either:

=over

=item empty mode parameter (default)

Value entered by user or default value if the value is different from upstream_default or
layered value. Typically this value is written in a configuration file.

=item backend

Alias for default mode.

=item custom

The value entered by the user (if different from built in, preset,
computed or default value)

=item user

The value most useful to user: the value that is used by the application.

=item preset

The value entered in preset mode

=item standard

The preset or computed or default or built in value.

=item default

The default value (defined by the configuration model)

=item layered

The value found in included files (treated in layered mode: values specified
there are handled as upstream default values). E.g. like in multistrap config.

=item upstream_default

The upstream_default value. (defined by the configuration model)

=item non_upstream_default

The custom or preset or computed or default value. Returns undef
if either of this value is identical to the upstream_default value. This
feature is useful to reduce data to write in configuration file.

=item allow_undef

With this mode, C<fetch()> behaves like in C<user> mode, but returns
C<undef> for mandatory values. Normally, trying to fetch an undefined
mandatory value leads to an exception.

=back

=head2 fetch_summary

Returns a truncated value when the value is a string or uniline that
is too long to be displayed.

=head2 user_value

Returns the value entered by the user. Does not use the default or
computed value. Returns undef unless a value was actually stored.

=head2 fetch_preset

Returns the value entered in preset mode. Does not use the default or
computed value. Returns undef unless a value was actually stored in
preset mode.

=head2 clear_preset

Delete the preset value. (Even out of preset mode). Returns true if other data
are still stored in the value (layered or user data). Returns false otherwise.

=head2 fetch_layered

Returns the value entered in layered mode. Does not use the default or
computed value. Returns undef unless a value was actually stored in
layered mode.

=head2 clear_layered

Delete the layered value. (Even out of layered mode). Returns true if other data
are still stored in the value (layered or user data). Returns false otherwise.

=head2 get( path => ..., mode => ... ,	check => ... )

Get a value from a directory like path.

=head2 set( path , value )

Set a value from a directory like path.

=head1 Examples

=head2 Number with min and max values

 bounded_number => {
    type       => 'leaf',
    value_type => 'number',
    min        => 1,
    max        => 4,
 },

=head2 Mandatory value

 mandatory_string => {
    type       => 'leaf',
    value_type => 'string',
    mandatory  => 1,
 },

 mandatory_boolean => {
    type       => 'leaf',
    value_type => 'boolean',
    mandatory  => 1,
 },

=head2 Enum with help associated with each value

Note that the help specification is optional.

 enum_with_help => {
    type       => 'leaf',
    value_type => 'enum',
    choice     => [qw/a b c/],
    help       => {
        a => 'a help'
    }
 },

=head2 Migrate old obsolete enum value

Legacy values C<a1>, C<c1> and C<foo/.*> are replaced with C<a>, C<c> and C<foo/>.

 with_replace => {
    type       => 'leaf',
    value_type => 'enum',
    choice     => [qw/a b c/],
    replace    => {
        a1       => 'a',
        c1       => 'c',
        'foo/.*' => 'foo',
    },
 },

=head2 Enforce value to match a regexp

An exception is triggered when the value does not match the C<match>
regular expression.

 match => {
    type       => 'leaf',
    value_type => 'string',
    match      => '^foo\d{2}$',
 },

=head2 Enforce value to match a L<Parse::RecDescent> grammar

 match_with_parse_recdescent => {
    type       => 'leaf',
    value_type => 'string',
    grammar    => q{
        token (oper token)(s?)
        oper: 'and' | 'or'
        token: 'Apache' | 'CC-BY' | 'Perl'
    },
 },

=head2 Issue a warning if a value matches a regexp

Issue a warning if the string contains upper case letters. Propose a fix that
translate all capital letters to lower case.

 warn_if_capital => {
    type          => 'leaf',
    value_type    => 'string',
    warn_if_match => {
        '/A-Z/' => {
            fix => '$_ = lc;'
        }
    },
 },

A specific warning can be specified:

 warn_if_capital => {
    type          => 'leaf',
    value_type    => 'string',
    warn_if_match => {
        '/A-Z/' => {
            fix  => '$_ = lc;',
            mesg => 'NO UPPER CASE PLEASE'
        }
    },
 },

=head2 Issue a warning if a value does NOT match a regexp

 warn_unless => {
    type              => 'leaf',
    value_type        => 'string',
    warn_unless_match => {
        foo => {
            msg => '',
            fix => '$_ = "foo".$_;'
        }
    },
 },

=head2 Always issue a warning

 always_warn => {
    type       => 'leaf',
    value_type => 'string',
    warn       => 'Always warn whenever used',
 },

=head2 Computed values

See L<Config::Model::ValueComputer/Examples>.

=head1 Upgrade

Upgrade is a special case when the configuration of an application has
changed. Some parameters can be removed and replaced by another
one. To avoid trouble on the application user side, Config::Model
offers a possibility to handle the migration of configuration data
through a special declaration in the configuration model.

This declaration must:

=over

=item *

Declare the deprecated parameter with a C<status> set to C<deprecated>

=item *

Declare the new parameter with the instructions to load the semantic
content from the deprecated parameter. These instructions are declared
in the C<migrate_from> parameters (which is similar to the C<compute>
parameter)

=back

Here an example where a URL parameter is changed to a set of 2
parameters (host and path):

 'old_url' => {
    type       => 'leaf',
    value_type => 'uniline',
    status     => 'deprecated',
 },
 'host' => {
    type       => 'leaf',
    value_type => 'uniline',

    # the formula must end with '$1' so the result of the capture is used
    # as the host value
    migrate_from => {
        formula   => '$old =~ m!http://([\w\.]+)!; $1 ;',
        variables => {
             old => '- old_url'
        },
        use_eval  => 1,
    },
 },
 'path' => {
    type         => 'leaf',
    value_type   => 'uniline',
    migrate_from => {
        formula   => '$old =~ m!http://[\w\.]+(/.*)!; $1 ;',
        variables => {
             old => '- old_url'
        },
        use_eval  => 1,
    },
 },

=head1 EXCEPTION HANDLING

When an error is encountered, this module may throw the following
exceptions:

Config::Model::Exception::Model
Config::Model::Exception::Formula
Config::Model::Exception::WrongValue
Config::Model::Exception::WarpError

See L<Config::Model::Exception> for more details.

=head1 AUTHOR

Dominique Dumont, (ddumont at cpan dot org)

=head1 SEE ALSO

L<Config::Model>, L<Config::Model::Node>,
L<Config::Model::AnyId>, L<Config::Model::Warper>, L<Config::Model::Exception>
L<Config::Model::ValueComputer>,

=head1 AUTHOR

Dominique Dumont

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2005-2022 by Dominique Dumont.

This is free software, licensed under:

  The GNU Lesser General Public License, Version 2.1, February 1999

=cut
