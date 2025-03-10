#
# This file is part of Config-Model
#
# This software is Copyright (c) 2005-2022 by Dominique Dumont.
#
# This is free software, licensed under:
#
#   The GNU Lesser General Public License, Version 2.1, February 1999
#
package Config::Model::Loader 2.152;

use Carp;
use strict;
use warnings;
use 5.10.1;
use Mouse;

use Config::Model::Exception;
use Log::Log4perl qw(get_logger :levels);
use JSON;
use Path::Tiny;
use YAML::Tiny;

use feature qw/postderef signatures/;
no warnings qw/experimental::postderef experimental::signatures/;

my $logger = get_logger("Loader");
my $verbose_logger = get_logger("Verbose.Loader");

## load stuff, similar to grab, but used to set items in the tree
## starting from this node

has start_node => (
    is => 'ro',
    isa => 'Config::Model::Node',
    weak_ref => 1,
    required => 1,
);

has instance => (
    is => 'ro',
    isa => 'Config::Model::Instance',
    weak_ref => 1,
    lazy_build => 1,
);

sub _build_instance {
    return $_[0]->start_node->instance;
}

my %log_dispatch = (
    name => sub { my $loc = $_[0]->location; return $loc ? $_[0]->get_type." '$loc'" : "root node"},
    qs => sub { my $s = shift; unquote($s); return "'$s'"},
    qa => sub { return '"'.join('", "', @{$_[0]}).'"'},
    s => sub { return $_[0] }, # nop
    leaf => sub { return $_[0]->get_type." '". $_[0]->location."' ".$_[0]->value_type;}
);

sub _log_cmd {
    my ($self, $cmd, $message, @params) = @_;

    return unless $verbose_logger->is_info;
    return if $self->instance->initial_load;

    $cmd =~ s/\n/\\n/g;
    foreach my $p (@params) {
        $message =~ s/%(\w+)/$log_dispatch{$1}->($p)/e;
    }
    my $str = ref $cmd eq 'ARRAY' ? "@$cmd"
        : ref $cmd ? $$cmd : $cmd;
    $verbose_logger->info("command '$str': $message");
}

sub load {
    my $self = shift;

    my %args = @_;

    my $node = $self->start_node;

    my $steps = delete $args{steps} // delete $args{step};
    croak "load error: missing 'steps' parameter" unless defined $steps;

    my $caller_is_root = delete $args{caller_is_root};

    if (delete $args{experience}) {
        carp "load: experience parameter is deprecated";
    }

    my $inst = $node->instance;

    # tune value checking
    my $check = delete $args{check} || 'yes';
    croak __PACKAGE__, "load: unexpected check $check" unless $check =~ /yes|no|skip/;

    # accept commands
    my $huge_string = ref $steps ? join( ' ', @$steps ) : $steps;

    # do a split on ' ' but take quoted string into account
    my @command = (
        $huge_string =~ m/
         (         # begin of *one* command
          (?:        # group parts of a command (e.g ...:...=... )
           [^\s"]+  # match anything but a space and a quote
           (?:        # begin quoted group
             "         # begin of a string
              (?:        # begin group
                \\"       # match an escaped quote
                |         # or
                [^"]      # anything but a quote
              )*         # lots of time
             "         # end of the string
           )          # end of quoted group
           ?          # match if I got more than one group
          )+      # can have several parts in one command
         )        # end of *one* command
        /gx    # 'g' means that all commands are fed into @command array
    );         #"asdf ;

    #print "command is ",join('+',@command),"\n" ;

    my $current_node = $node;
    my $ret;
    do {
        $ret = $self->_load( $current_node, $check, \@command, 1 );
        $logger->trace("_load returned $ret");

        # found '!' command
        if ( $ret eq 'root' ) {
            $current_node = $caller_is_root ? $node : $current_node->root;
            if ($logger->debug) {
                $logger->debug("Setting current_node to root node: ".$current_node->name);
            }
        }
    } while ( $ret eq 'root' );

    if (@command) {
        my $str = "Error: could not execute the required command, ";
        if ($command[0] =~ m!^/([\w-]+)!) {
            $str .=  "the searched item '$1' was not found" ;
        }
        else {
            $str .= "you may have specified too many '-' in your command";
        }
        Config::Model::Exception::Load->throw(
            command => $command[0],
            error  => $str,
            object => $node
        ) if $check eq 'yes';
    }

    if (%args) {
        Config::Model::Exception::Internal->throw(
            error => __PACKAGE__ . " load: unexpected parameters: " . join( ', ', keys %args ) );
    }

    return $ret;
}

# returns elt action id subaction value
sub _split_cmd {
    my $cmd = shift;
    $logger->trace("split on: ->$cmd<-");

    my $quoted_string = qr/"(?: \\" | [^"] )* "/x;    # quoted string

    # do a split on ' ' but take quoted string into account
    my @command = (
        $cmd =~ m!^
	 (\w[\w-]*)? # element name can be alone
	 (?:
            (:~|:-[=~]?|:=~|:\.\w+|:[=<>@]?|~)       # action
            (?:
                  (?: \( ( $quoted_string | [^)]+ ) \) )  # capture parameters between ( )
                | (
                    /[^/]+/      # regexp
                    | (?:
                       $quoted_string (?:,)?
                       | [^#=\.<>]+    # non action chars
                      )+
                  )
            )?
     )?
	 (?:
            (=~|\.=|=\.\w+|[=<>])          # apply regexp or assign or append
            (?:
                  (?: \( ( $quoted_string | [^)]+ ) \) )  # capture parameters between ( )
                | (
                    (?:
                      $quoted_string
                     | [^#\s]                # or non whitespace
                    )+                       # many
                  )
	        )?
     )?
	 (?:
            \#              # optional annotation
	    (
              (?:
                 $quoted_string
                | [^\s]                # or non whitespace
              )+                       # many
            )
	 )?
     (.*)    # leftover
    !gx
    );

    my $leftout = pop @command;

    if ($leftout) {
        Config::Model::Exception::Load->throw(
            command => $cmd,
            error   => "Syntax error: spurious char at command end: '$leftout'. Did you forget double quotes ?"
        );
    }
    return wantarray ? @command : \@command;
}

my %load_dispatch = (
    node        => \&_walk_node,
    warped_node => \&_walk_node,
    hash        => \&_load_hash,
    check_list  => \&_load_check_list,
    list        => \&_load_list,
    leaf        => \&_load_leaf,
);

# return 'done', 'root', 'up', 'error'
sub _load {
    my ( $self, $node, $check, $cmdref, $at_top_level ) = @_;
    $at_top_level ||= 0;
    my $node_name = "'" . $node->name . "'";
    $logger->trace("_load: called on node $node_name");

    my $inst = $node->instance;

    my $cmd;
    while ( $cmd = shift @$cmdref ) {
        if ( $logger->is_debug ) {
            my $msg = $cmd;
            $msg =~ s/\n/\\n/g;
            $logger->debug("Loader: Executing cmd '$msg' on node $node_name");
        }

        next if $cmd =~ /^\s*$/;

        if ( $cmd eq '!' ) {
            $self->_log_cmd(\$cmd,"Going from %name to root node", $node );
            $logger->debug("_load: going to root, at_top_level is $at_top_level");

            # Do not change current node as we don't want to mess up =~ commands
            return 'root';
        }

        if ( $cmd eq '-' ) {
            my $parent = $node->parent;
            if (defined $parent) {
                $self->_log_cmd($cmd,'Going up from %name to %name', $node, $node->parent);
            }
            else {
                $self->_log_cmd($cmd,'Going up from %name to exit Loader.', $node);
            }
            return 'up';
        }

        if ( $cmd =~ m!^/([\w-]+)! ) {
            my $search = $1;
            if ($node->has_element($search)) {
                $self->_log_cmd($cmd, 'Element %qs found in current node (%name).', $search, $node);
                $cmd =~ s!^/!! ;
            } else {
                $self->_log_cmd(
                    $cmd,
                    'Going up from %name to %name to search for element %qs.',
                    $node, $node->parent, $search
                );
                unshift @$cmdref, $cmd;
                return 'up';
            }
        }

        my ( $element_name, $action, $function_param, $id, $subaction, $value_function_param2, $value_param, $note ) =
            _split_cmd($cmd);

        # regexp ensure that only $value_function_param  $value_param is set
        my $value = $value_function_param2 // $value_param ;
        my @instructions = ( $element_name, $action, $function_param, $id, $subaction, $value, $note );

        if ( $logger->is_debug ) {
            my @disp = map { defined $_ ? "'$_'" : '<undef>' } @instructions;
            $logger->debug("_load instructions: @disp (from: $cmd)");
        }

        if ( not defined $element_name and not defined $note ) {
            Config::Model::Exception::Load->throw(
                command => $cmd,
                error   => 'Syntax error: cannot find element in command'
            );
        }

        unless ( defined $node ) {
            Config::Model::Exception::Load->throw(
                command => $cmd,
                error   => "Error: Got undefined node"
            );
        }

        unless ( $node->isa("Config::Model::Node")
            or $node->isa("Config::Model::WarpedNode") ) {
            Config::Model::Exception::Load->throw(
                command => $cmd,
                error   => "Error: Expected a node (even a warped node), got '" . $node->name . "'"
            );

            # below, has_element method from WarpedNode will raise
            # exception if warped_node is not available
        }

        if ( not defined $element_name and defined $note ) {
            $self->_set_note($node, \$cmd, $note);
            next;
        }

        unless ( $node->has_element($element_name) ) {
            Config::Model::Exception::UnknownElement->throw(
                object  => $node,
                element => $element_name,
            ) if $check eq 'yes';
            unshift @$cmdref, $cmd;
            return 'error';
        }

        unless ( $node->is_element_available( name => $element_name ) ) {
            Config::Model::Exception::UnavailableElement->throw(
                object  => $node,
                element => $element_name
            ) if $check eq 'yes';
            unshift @$cmdref, $cmd;
            return 'error';
        }

        unless ( $node->is_element_available( name => $element_name ) ) {
            Config::Model::Exception::RestrictedElement->throw(
                object  => $node,
                element => $element_name,
            ) if $check eq 'yes';
            unshift @$cmdref, $cmd;
            return 'error';
        }

        my $element_type = $node->element_type($element_name);

        my $method = $load_dispatch{$element_type};

        croak "_load: unexpected element type '$element_type' for $element_name"
            unless defined $method;

        $logger->debug("_load: calling $element_type loader on element $element_name");

        my $ret = $self->$method( $node, $check, \@instructions, $cmdref, $cmd );
        $logger->debug("_load: $element_type loader on element $element_name returned $ret");
        die "Internal error: method dispatched for $element_type returned an undefined value "
            unless defined $ret;

        if ( $ret eq 'error' or $ret eq 'done' ) {
            $logger->debug("_load return: $node_name got $ret");
            return $ret;
        }
        if ( $ret eq 'root' and not $at_top_level ) {
            $logger->debug("_load return: $node_name got $ret");
            return 'root';
        }

        # ret eq up or ok -> go on with the loop
    }

    return 'done';
}

sub _set_note {
    my ($self, $target, $cmd, $note) = @_;
    $self->_log_cmd($cmd, "Setting %name annotation to %qs", $target, $note);
    $target->annotation($note);
}


sub _load_note {
    my ( $self, $target_obj, $note, $instructions, $cmdref, $cmd ) = @_;

    unquote($note);

    # apply note on target object
    if ( defined $note ) {
        if ( defined $target_obj ) {
            $self->_set_note($target_obj, $cmd,$note);
        }
        else {
            Config::Model::Exception::Load->throw(
                command => $$cmdref,
                error   => "Error: cannot set annotation with '"
                    . join( "','", grep { defined $_ } @$instructions ) . "'"
            );
        }
    }
}

sub _walk_node {
    my ( $self, $node, $check, $inst, $cmdref, $cmd ) = @_;

    my $element_name = shift @$inst;
    my $note         = pop @$inst;
    my $new_node     = $node->fetch_element($element_name);
    $self->_load_note( $new_node, $note, $inst, $cmdref, $cmd );

    my @left = grep { defined $_ } @$inst;
    if (@left) {
        Config::Model::Exception::Load->throw(
            command => $inst,
            object => $node,
            error   => "Don't know what to do with '@left' "
                . "for node element $element_name"
        );
    }

    $self->_log_cmd($cmd, 'Going down from %name to %name', $node, $new_node);

    return $self->_load( $new_node, $check, $cmdref );
}

sub unquote {
    for (@_) {
        if (defined $_) {
            s/(?<!\\)\\n/\n/g;
            s/\\\\/\\/g;
            s/^"// && s/"$// && s!\\"!"!g;
        }
    }
}

sub _load_check_list {
    my ( $self, $node, $check, $inst, $cmdref, $cmd ) = @_;
    my ( $element_name, $action, $f_arg, $id, $subaction, $value, $note ) = @$inst;

    my $element = $node->fetch_element( name => $element_name, check => $check );

    if ( defined $note and not defined $action and not defined $subaction ) {
        $self->_load_note( $element, $note, $inst, $cmdref, $cmd );
        return 'ok';
    }

    if ( defined $subaction and $subaction eq '=' ) {
        $logger->debug("_load_check_list: set whole list");

        $self->_log_cmd($cmd, 'Setting %name items %qs.', $element, $value);
        # valid for check_list or list
        $element->load( $value, check => $check );
        $self->_load_note( $element, $note, $inst, $cmdref, $cmd );
        return 'ok';
    }

    if ( not defined $action and defined $subaction ) {
        Config::Model::Exception::Load->throw(
            object  => $element,
            command => join( '', grep { defined $_} @$inst ),
            error   => "Wrong assignment with '$subaction' on check_list"
        );
    }

    my $a_str = defined $action ? $action : '<undef>';

    Config::Model::Exception::Load->throw(
        object  => $element,
        command => join( '', map { $_ || '' } @$inst ),
        error   => "Wrong assignment with '$a_str' on check_list"
    );

}

{
    # sub is called with  ( $self, $element, $check, $instance, @function_args )
    # function_args are the arguments passed to the load command
    my %dispatch_action = (
        list_leaf => {
            ':.sort'          => sub { $_[1]->sort;  return 'ok';},
            ':.push'          => sub { $_[1]->push( @_[ 5 .. $#_ ] ); return 'ok'; },
            ':.unshift'       => sub { $_[1]->unshift( @_[ 5 .. $#_ ] ); return 'ok'; },
            ':.insert_at'     => sub { $_[1]->insert_at( @_[ 5 .. $#_ ] ); return 'ok'; },
            ':.insort'        => sub { $_[1]->insort( @_[ 5 .. $#_ ] ); return 'ok'; },
            ':.insert_before' => \&_insert_before,
            ':.ensure'        => \&_ensure_list_value,
        },
        'list_*' => {
            ':.copy'          => sub { $_[1]->copy( $_[5], $_[6] ); return 'ok'; },
            ':.clear'         => sub { $_[1]->clear; return 'ok'; },
        },
        hash_leaf => {
            ':.insort'        => sub { $_[1]->insort($_[5])->store($_[6]); return 'ok'; },
        },
        hash_node =>  => {
            ':.insort'        => \&_insort_hash_of_node,
        },
        'hash_*' => {
            ':.sort'          => sub { $_[1]->sort; return 'ok'; },
            ':.copy'          => sub { $_[1]->copy( $_[5], $_[6] ); return 'ok'; },
            ':.clear'         => sub { $_[1]->clear; return 'ok';},
        },
        # part of list or hash. leaf element have their own dispatch table
        # (%load_value_dispatch) because the signture of the sub ref are
        # different between the 2 dispatch tables.
        leaf => {
            ':.rm_value' => \&_remove_by_value,
            ':.rm_match' => \&_remove_matched_value,
            ':.substitute' => \&_substitute_value,
        },
        fallback => {
            ':.rm' => \&_remove_by_id,
            ':.json' => \&_load_json_vector_data,
        }
    );

    my %equiv = (
        'hash_*' => { qw/:@ :.sort/},
        list_leaf => { qw/:@ :.sort :< :.push :> :.unshift/ },
        # fix for cme gh#2
        leaf => { qw/:-= :.rm_value :-~ :.rm_match :=~ :.substitute/ },
        fallback => { qw/:- :.rm ~ :.rm/ },
    );

    while ( my ($target, $sub_equiv) = each %equiv) {
        while ( my ($new_action, $existing_action) = each %$sub_equiv) {
            $dispatch_action{$target}{$new_action} = $dispatch_action{$target}{$existing_action};
        }
    }

    sub _get_dispatch_data {
        my ($dispatch, $type, $cargo_type, $action) = @_;
        return   $dispatch->{ $type.'_'.$cargo_type }{$action}
            || $dispatch->{$type.'_*'}{$action}
            || $dispatch->{$cargo_type}{$action}
            || $dispatch->{'fallback'}{$action};
    }

    sub _get_dispatch {
        my ($self, $element, $type, $cargo_type, $action, $cmd, @f_args, ) = @_;
        return unless (defined $action and $action ne ':');

        my $dispatch = _get_dispatch_data(\%dispatch_action, $type => $cargo_type, $action);
        if ($dispatch) {
            my $real_action = _get_dispatch_data(\%equiv, $type => $cargo_type, $action) // $action;
            $self->_log_cmd($cmd, 'Running %qs on %name with %qa.', substr($real_action,2), $element, \@f_args);
        }
        return $dispatch;
    }
}

sub _insert_before {
    my ( $self, $element, $check, $inst, $cmdref, $before_str, @values ) = @_;
    my $before = ($before_str =~ s!^/!! and $before_str =~ s!/$!!) ? qr/$before_str/ : $before_str;
    $element->insert_before( $before, @values );
    return 'ok';
}

sub _ensure_list_value {
    my ( $self, $element, $check, $inst, $cmdref, @values ) = @_;
    my %content = map { $_ => 1 } $element->fetch_all_values;
    foreach my $one_value (@values) {
        next if $content{$one_value};
        $element->insort($one_value);
        $content{$one_value} = 1;
    }

    return 'ok';
}
sub _remove_by_id {
    my ( $self, $element, $check, $inst, $cmdref, $id ) = @_;
    $logger->debug("_remove_by_id: removing id '$id'");
    $element->remove($id);
    return 'ok';
}

sub __load_json_file ($file) {
    # utf8 decode is done by JSON module, so slurp_raw must be used
    return decode_json($file->slurp_raw);
}

sub _load_json_vector_data {
    my ( $self, $element, $check, $inst, $cmdref, $vector ) = @_;
    $logger->debug("_load_json_vector_data: loading '$vector'");
    my ($file, @vector) = $self->__get_file_from_vector($element,$inst,$vector);

    my $data = __load_json_file($file);

    # test for diff before clobbering ? What about deep data ???
    $element->load_data(
        data => __data_from_vector($data, @vector),
        check => $check
    );
    return 'ok';
}

sub _remove_by_value {
    my ( $self, $element, $check, $inst, $cmdref, $rm_val ) = @_;

    $logger->debug("_remove_by_value value $rm_val");
    foreach my $idx ( $element->fetch_all_indexes ) {
        my $v = $element->fetch_with_id($idx)->fetch;
        $element->delete($idx) if defined $v and $v eq $rm_val;
    }

    return 'ok';
}

sub _remove_matched_value {
    my ( $self, $element, $check, $inst, $cmdref, $rm_val ) = @_;

    $logger->debug("_remove_matched_value $rm_val");

    $rm_val =~ s!^/|/$!!g;

    foreach my $idx ( $element->fetch_all_indexes ) {
        my $v = $element->fetch_with_id($idx)->fetch;
        $element->delete($idx) if defined $v and $v =~ /$rm_val/;
    }

    return 'ok';
}

sub _substitute_value {
    my ( $self, $element, $check, $inst, $cmdref, $s_val ) = @_;

    $logger->debug("_substitute_value $s_val");

    foreach my $idx ( $element->fetch_all_indexes ) {
        my $l = $element->fetch_with_id($idx);
        $self->_load_value( $l, $check, '=~', $s_val, $inst );
    }

    return 'ok';
}

sub _insort_hash_of_node {
    my ( $self, $element, $check, $inst, $cmdref, $id ) = @_;
    my $node = $element->insort($_[5]);
    $logger->debug("_insort_hash_of_node: calling _load on node id $id");
    return $self->_load( $node, $check, $cmdref );
}

sub _load_list {
    my ( $self, $node, $check, $inst, $cmdref, $cmd ) = @_;
    my ( $element_name, $action, $f_arg, $id, $subaction, $value, $note ) = @$inst;

    my $element = $node->fetch_element( name => $element_name, check => $check );

    my @f_args = grep { defined } ( ( $f_arg // $id // '' ) =~ /([^,"]+)|"([^"]+)"/g );

    my $elt_type   = $node->element_type($element_name);
    my $cargo_type = $element->cargo_type;

    if ( defined $note and not defined $action and not defined $subaction ) {
        $self->_load_note( $element, $note, $inst, $cmdref, $cmd );
        return 'ok';
    }

    if ( defined $action and $action eq ':=' and $cargo_type eq 'leaf' ) {
        # due to ':=' action, the value is contained in $id
        $logger->debug("_load_list: set whole list with ':=' action");
        # valid for check_list or list
        $self->_log_cmd($cmd, 'Setting %name values to %qs.', $element, $id);
        $element->load( $id, check => $check );
        $self->_load_note( $element, $note, $inst, $cmdref, $cmd );
        return 'ok';
    }

    # compat mode for list=a,b,c,d commands
    if (    not defined $action
        and defined $subaction
        and $subaction eq '='
        and $cargo_type eq 'leaf' ) {
        $logger->debug("_load_list: set whole list with '=' subaction'");

        # valid for check_list or list
        $self->_log_cmd($cmd, 'Setting %name values to %qs.', $element, $value);
        $element->load( $value, check => $check );
        $self->_load_note( $element, $note, $inst, $cmdref, $cmd );
        return 'ok';
    }

    unquote( $id, $value, $note );

    if ( my $dispatch = $self->_get_dispatch($element, list => $cargo_type, $action, $cmd, @f_args)) {
        return $dispatch->( $self, $element, $check, $inst, $cmdref, @f_args );
    }

    if ( not defined $action and defined $subaction ) {
        Config::Model::Exception::Load->throw(
            object  => $element,
            command => join( '', grep { defined $_} @$inst ),
            error   => "Wrong assignment with '$subaction' on "
                . "element type: $elt_type, cargo_type: $cargo_type"
        );
    }

    if ( defined $action and $action eq ':' ) {
        unquote($id);
        my $obj = $element->fetch_with_id( index => $id, check => $check );
        $self->_load_note( $obj, $note, $inst, $cmdref, $cmd );

        if ( $cargo_type =~ /node/ ) {

            # remove possible leading or trailing quote
            $self->_log_cmd($cmd,'Going down from %name to %name', $node, $obj );
            return $self->_load( $obj, $check, $cmdref );
        }

        return 'ok' unless defined $subaction;

        if ( $cargo_type =~ /leaf/ ) {
            $logger->debug("_load_list: calling _load_value on $cargo_type id $id");
            # _log_cmd done in _load_value
            $self->_load_value( $obj, $check, $subaction, $value, $cmdref, $cmd )
                and return 'ok';
        }
    }

    my $a_str = defined $action ? $action : '<undef>';

    Config::Model::Exception::Load->throw(
        object  => $element,
        command => join( '', map { $_ || '' } @$inst ),
        error   => "Wrong assignment with '$a_str' on "
            . "element type: $elt_type, cargo_type: $cargo_type"
    );

}

sub _load_hash {
    my ( $self, $node, $check, $inst, $cmdref, $cmd ) = @_;
    my ( $element_name, $action, $f_arg, $id, $subaction, $value, $note ) = @$inst;

    unquote( $id, $value, $note );

    my $element = $node->fetch_element( name => $element_name, check => $check );
    my $cargo_type = $element->cargo_type;

    if ( defined $note and not defined $action ) {
        # _log_cmd done in _load_note
        $self->_load_note( $element, $note, $inst, $cmdref, $cmd );
        return 'ok';
    }

    if ( not defined $action ) {
        Config::Model::Exception::Load->throw(
            object  => $element,
            command => join( '', map { $_ || '' } @$inst ),
            error   => "Missing key (e.g. '$element_name:some_key') on hash element, cargo_type: $cargo_type"
        );
    }

    # loop requires $subaction so does not fit in the dispatch table
    if ( $action eq ':~' or $action eq ':.foreach_match' ) {
        my @keys = $element->fetch_all_indexes;
        my $ret  = 'ok';
        my $pattern = $id // $f_arg;
        $pattern =~ s!^/|/$!!g if $pattern;
        my @loop_on = $pattern ? grep { /$pattern/ } @keys : @keys;
        if ($logger->is_debug) {
            my $str = $pattern ? " with regex /$pattern/" : '';
            $logger->debug("_load_hash: looping$str on keys @loop_on");
        }

        my @saved_cmd = @$cmdref;
        foreach my $loop_id ( @loop_on ) {
            @$cmdref = @saved_cmd;    # restore command before loop
            my $sub_elt = $element->fetch_with_id($loop_id);
            $self->_log_cmd($cmd,'Running foreach_map loop on %name.',$sub_elt);
            if ( $cargo_type =~ /node/ ) {
                # remove possible leading or trailing quote
                $ret = $self->_load( $sub_elt, $check, $cmdref );
            }
            elsif ( $cargo_type =~ /leaf/ ) {
                $ret = $self->_load_value( $sub_elt, $check, $subaction, $value, $cmdref, $cmd );
            }
            else {
                Config::Model::Exception::Load->throw(
                    object  => $element,
                    command => join( '', @$inst ),
                    error   => "Hash assignment with '$action' on unexpected "
                        . "cargo_type: $cargo_type"
                );
            }

            $logger->debug("_load_hash: loop on id $loop_id returned $ret (left cmd: @$cmdref)");
            if ( $ret eq 'error') { return $ret; }
        }
        return $ret;
    }

    my @f_args = grep { defined } ( ( $f_arg // $id // '' ) =~ /([^,"]+)|"([^"]+)"/g );

    if ( my $dispatch = $self->_get_dispatch($element, hash => $cargo_type, $action, $cmd, @f_args)) {
        return $dispatch->( $self, $element, $check, $inst, $cmdref, @f_args );
    }

    if (not defined $id) {
        Config::Model::Exception::Load->throw(
            object  => $element,
            command => join( '', @$inst ),
            error   => qq!Unexpected hash instruction: '$action' or missing id!
        );
    }

    my $obj = $element->fetch_with_id( index => $id, check => $check );
    $self->_load_note( $obj, $note, $inst, $cmdref, $cmd );

    if ( $action eq ':' and $cargo_type =~ /node/ ) {

        # remove possible leading or trailing quote
        $self->_log_cmd($cmd,'Going down from %name to %name', $node, $obj );
        if ( defined $subaction ) {
            Config::Model::Exception::Load->throw(
                object  => $element,
                command => join( '', @$inst ),
                error   => qq!Hash assignment with '$action"$id"$subaction"$value"' on unexpected !
                    . "cargo_type: $cargo_type"
            );
        }
        return $self->_load( $obj, $check, $cmdref );
    }
    elsif ( $action eq ':' and defined $subaction and $cargo_type =~ /leaf/ ) {
        # _log_cmd is done in _load_value
        $logger->debug("_load_hash: calling _load_value on leaf $id");
        $self->_load_value( $obj, $check, $subaction, $value, $cmdref, $cmd )
            and return 'ok';
    }
    elsif ( $action eq ':' ) {
        $self->_log_cmd($cmd,'Creating empty %name.', $obj );
        $logger->debug("_load_hash: created empty element of type $cargo_type");
        return 'ok';
    }
    elsif ($action) {
        $logger->debug("_load_hash: giving up");
        Config::Model::Exception::Load->throw(
            object  => $element,
            command => join( '', grep { defined $_ } @$inst ),
            error   => "Hash load with '$action' on unexpected " . "cargo_type: $cargo_type"
        );
    }
}

sub _load_leaf {
    my ( $self, $node, $check, $inst, $cmdref, $cmd ) = @_;
    my ( $element_name, $action, $f_arg, $id, $subaction, $value, $note ) = @$inst;

    unquote( $id, $value );

    my $element = $node->fetch_element( name => $element_name, check => $check );
    $self->_load_note( $element, $note, $inst, $cmdref, $cmd );

    if ( defined $action and $element->isa('Config::Model::Value')) {
        if ($action eq '~') {
            $self->_log_cmd($cmd, "Deleting %name.", $element );
            $element->store(value => undef, check => $check);
        }
        elsif ($action eq ':') {
            Config::Model::Exception::Load->throw(
                object  => $element,
                command => $inst,
                error   => "Error: list or hash command (':') detected on a leaf."
                . "(element '" . $element->name . "')"
            );
        }
        else {
            Config::Model::Exception::Load->throw(
                object  => $element,
                command => $inst,
                error   => "Load error on leaf with "
                . "'$element_name$action$id' command "
                . "(element '" . $element->name . "')"
            );
        }
    }

    return 'ok' unless defined $subaction;

    if ( $logger->is_debug ) {
        my $msg = defined $value ? $value : '<undef>';
        $msg =~ s/\n/\\n/g;
        $logger->debug("_load_leaf: action '$subaction' value '$msg'");
    }

    my $res = $self->_load_value( $element, $check, $subaction, $value, $inst, $cmd );

    return $res if $res ;

    Config::Model::Exception::Load->throw(
        object  => $element,
        command => $inst,
        error   => "Load error on leaf with "
            . "'$element_name$subaction$value' command "
            . "(element '"
            . $element->name . "')"
    );
}

# sub is called with  ( $self, $element, $value, $check, $instructions )
# function_args are the arguments passed to the load command
my %load_value_dispatch = (
    '=' => \&_store_value ,
    '.=' => \&_append_value,
    '=~' => \&_apply_regexp_on_value,
    '=.file' => \&_store_file_in_value,
    '=.json' => \&_store_json_vector_in_value,
    '=.yaml' => \&_store_yaml_vector_in_value,
    '=.env' => sub { $_[1]->store( value => $ENV{$_[2]}, check => $_[3] ); return 'ok'; },
);

sub _store_value  {
    my ( $self, $element, $value, $check, $instructions, $cmd ) = @_;
    $self->_log_cmd($cmd, 'Setting %leaf to %qs.', $element, $value);
    $element->store( value => $value, check => $check );
    return 'ok';
}

sub _append_value {
    my ( $self, $element, $value, $check, $instructions, $cmd ) = @_;
    my $orig = $element->fetch( check => $check );
    my $next = $orig.$value;
    $self->_log_cmd(
        $cmd, 'Appending %qs to %leaf. Result is %qs.',
        $value, $element, $next
    );
    $element->store( value => $next, check => $check );
}

sub _apply_regexp_on_value {
    my ( $self, $element, $value, $check, $instructions, $cmd ) = @_;

    my $orig = $element->fetch( check => $check );
    if (defined $orig) {
        # $value may change at each run and is like s/foo/bar/ do block
        # eval is not possible
        eval("\$orig =~ $value;"); ## no critic (ProhibitStringyEval)
        my $res = $@;
        $self->_log_cmd(
            $cmd, "Applying regexp %qs to %leaf. Result is %qs.",
            $value, $element, $orig
        );
        if ($res) {
            Config::Model::Exception::Load->throw(
                object  => $element,
                command => $instructions,
                error => "Failed regexp '$value' on " . "element '"
                    . $element->name . "' : $res"
                );
        }
        $element->store( value => $orig, check => $check );
    }
    else {
        $self->_log_cmd(
            $cmd, "Not applying regexp %qs on undefined value of %leaf.",
            $value, $element, $orig
        );
    }
}

sub _store_file_in_value {
    my ( $self, $element, $value, $check, $instructions, $cmd ) = @_;

    if ($value eq '-') {
        $element->store( value => join('',<STDIN>), check => $check );
        return 'ok';
    }

    my $path = $element->root_path->child($value);
    if ($path->is_file) {
        $element->store( value => $path->slurp_utf8, check => $check );
    }
    else {
        Config::Model::Exception::Load->throw(
            object  => $element,
            command => $instructions,
            error => "cannot read file $value"
        );
    }
}

sub __data_from_vector {
    my ($data, @vector) = @_;
    for my $step (@vector) {
        $data = (ref($data) eq 'HASH') ? $data->{$step} : $data->[$step];
    }
    return $data;
}

sub __get_file_from_vector {
    my ($self, $element,$instructions,$raw_vector) =  @_;
    my @vector = split m![/]+!m, $raw_vector;
    my $cur = path('.');
    my $file;
    while (my $subpath = shift @vector) {
        my $new_path = $cur->child($subpath);
        if ($new_path->is_file) {
            $file = $new_path;
            last;
        }
        elsif ($new_path->is_dir) {
            $cur = $new_path;
        }
    }
    if (not defined $file) {
        my ( $element_name, $action, $f_arg, $id, $subaction, $value, $note )
            = @$instructions;
        Config::Model::Exception::Load->throw(
            object  => $element,
            command => "$element_name"
                . ( $action    ? "$action($f_arg)"    : '' )
                . ( $subaction ? "$subaction($value)" : '' ),
            error   => qq!Load error: Cannot find file in $value!
        );
    }
    return ($file, @vector);
}

sub _store_json_vector_in_value {
    my ( $self, $element, $value, $check, $instructions, $cmd ) = @_;
    my ($file, @vector) = $self->__get_file_from_vector($element,$instructions,$value);
    my $data = __load_json_file($file);
    $element->store(
        value => __data_from_vector($data, @vector),
        check => $check
    );
}

sub _store_yaml_vector_in_value {
    my ( $self, $element, $value, $check, $instructions, $cmd ) = @_;
    my ($file, @vector) = $self->__get_file_from_vector($element,$instructions,$value);
    my $data = YAML::Tiny->read($file->stringify);
    $element->store(
        value => __data_from_vector($data, @vector),
        check => $check
    );
}

sub _load_value {
    my ( $self, $element, $check, $subaction, $value, $instructions, $cmd ) = @_;

    if (not $element->isa('Config::Model::Value')) {
        my $class = ref($element);
        Config::Model::Exception::Load->throw(
            object  => $element,
            command => $instructions,
            error   => "Load error: _load_value called on non Value object. ($class)"
        );
    }

    $logger->debug("_load_value: action '$subaction' value '$value' check $check");
    my $dispatch = $load_value_dispatch{$subaction};
    if ($dispatch) {
        return $dispatch->( $self, $element, $value, $check, $instructions, $cmd );
    }
    else {
        Config::Model::Exception::Load->throw(
            object  => $element,
            command => $instructions,
            error => "Unexpected operator or function on value: $subaction"
            );
    }

    $logger->debug("_load_value: done returns ok");
    return 'ok';
}

1;

# ABSTRACT: Load serialized data into config tree

__END__

=pod

=encoding UTF-8

=head1 NAME

Config::Model::Loader - Load serialized data into config tree

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

 $model ->create_config_class (
    name => "MyClass",

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
        [qw/lista listb/] => {
			      type => 'list',
			      cargo =>  {type => 'leaf',
					 value_type => 'string'
					}
			      },
    ],
 ) ;

 my $inst = $model->instance(root_class_name => 'MyClass' );

 my $root = $inst->config_root ;

 # put data
 my $steps = 'foo=FOO hash_of_nodes:fr foo=bonjour -
   hash_of_nodes:en foo=hello
   ! lista=foo,bar lista:2=baz
     listb:0=foo listb:1=baz';
 $root->load( steps => $steps );

 print $root->describe,"\n" ;
 # name         value        type         comment
 # foo          FOO          string
 # bar          [undef]      string
 # hash_of_nodes <Foo>        node hash    keys: "en" "fr"
 # lista        foo,bar,baz  list
 # listb        foo,baz      list


 # delete some data
 $root->load( steps => 'lista~2' );

 print $root->describe(element => 'lista'),"\n" ;
 # name         value        type         comment
 # lista        foo,bar      list

 # append some data
 $root->load( steps => q!hash_of_nodes:en foo.=" world"! );

 print $root->grab('hash_of_nodes:en')->describe(element => 'foo'),"\n" ;
 # name         value        type         comment
 # foo          "hello world" string

=head1 DESCRIPTION

This module is used directly by L<Config::Model::Node> to load
serialized configuration data into the configuration tree.

Serialized data can be written by the user or produced by
L<Config::Model::Dumper> while dumping data from a configuration tree.

=head1 CONSTRUCTOR

=head2 new

The constructor should be used only by L<Config::Model::Node>.

Parameters:

=over

=item start_node

node ref of the root of the tree (of sub-root) to start the load from.
Stored as a weak reference.

=back

=head1 load string syntax

The string is made of the following items (also called C<actions>)
separated by spaces. These actions can be divided in 4 groups:

=over

=item *

navigation: moving up and down the configuration tree.

=item *

list and hash operation: select, add or delete hash or list item (also
known as C<id> items)

=item *

leaf operation: select, modify or delecte leaf value

=item *

annotation: modify or delete configuration annotation (aka comment)

=back

=head2 navigation

=over 8

=item -

Go up one node

=item !

Go to the root node of the configuration tree.

=item xxx

Go down using C<xxx> element. (For C<node> type element)

=item /xxx

Go up until the element C<xxx> is found. This search can be combined with one of the
command specified below, e.g C</a_string="foo bar">

=back

=head2 list and hash operation

=over

=item xxx:yy

Go down using C<xxx> element and id C<yy> (For C<hash> or C<list>
element with C<node> cargo_type). Literal C<\n> are replaced by
real C<\n> (LF in Unix).

=item xxx:.foreach_match(yy) or xxx:~yy

Go down using C<xxx> element and loop over the ids that match the regex
specified by C<yy>. (For C<hash>).

For instance, with C<OpenSsh> model, you could do

 Host:~"/.*.debian.org/" user='foo-guest'

to set "foo-user" users for all your debian accounts.

The leading and trailing '/' may be omitted. Be sure to surround the
regexp with double quote if space are embedded in the regex.

Note that the loop ends when the load command goes above the element
where the loop is executed. For instance, the instruction below
tries to execute C<DX=BV> and C<int_v=9> for all elements of C<std_id> hash:

 std_id:~/^\w+$/ DX=Bv int_v=9

In the examples below only C<DX=BV> is executed by the loop:

 std_id:~/^\w+$/ DX=Bv - int_v=9
 std_id:~/^\w+$/ DX=Bv ! int_v=9

The loop is done on all elements of the hash when no value is passed
after "C<:~>" (mnemonic: an empty regexp matches any value).

=item xxx:.rm(yy) or xxx:-yy

Delete item referenced by C<xxx> element and id C<yy>. For a list,
this is equivalent to C<splice xxx,yy,1>. This command does not go
down in the tree (since it has just deleted the element). I.e. a
'C<->' is generally not needed afterwards.

=item xxx:.rm_value(yy) or xxx:-=yy

Remove the element whose value is C<yy>. For list or hash of leaves.
Does not not complain if the value to delete is not found.

=item xxx:..rm_match(yy) or xxx:-~/yy/

Remove the element whose value matches C<yy>. For list or hash of leaves.
Does not not complain if no value were deleted.

=item xxx:.substitute(/yy/zz/) or xxx:=~s/yy/zz/

Substitute a value with another. Perl switches can be used(e.g. C<xxx:=~s/yy/zz/gi>)

=item xxx:<yy or xxx:.push(yy)

Push C<yy> value on C<xxx> list

=item xxx:>yy or xxx:.unshift(yy)

Unshift C<yy> value on C<xxx> list

=item xxx:@ or xxx:.sort

Sort the list

=item xxx:.insert_at(yy,zz)

Insert C<zz> value on C<xxx> list before B<index> C<yy>.

=item xxx:.insert_before(yy,zz)

Insert C<zz> value on C<xxx> list before B<value> C<yy>.

=item xxx:.insert_before(/yy/,zz)

Insert C<zz> value on C<xxx> list before B<value> matching C<yy>.

=item xxx:.insort(zz)

Insert C<zz> value on C<xxx> list so that existing alphanumeric order is preserved.

=item xxx:.insort(zz)

For hash element containing nodes: creates a new hash element with
C<zz> key on C<xxx> hash so that existing alphanumeric order of keys
is preserved. Note that all keys are sorted once this instruction is
called. Following instructions are applied on the created
element. I.e. putting key order aside, C<xxx:.insort(zz)> has the
same effect as C<xxx:zz> instruction.

=item xxx:.insort(zz,vv)

For hash element containing leaves: creates a new hash element with
C<zz> key and assing value C<vv> so that existing alphanumeric order of keys
is preserved. Note that all keys are sorted once this instruction is
called. Putting key order aside, C<xxx:.insort(zz,vv)> has the
same effect as C<xxx:zz=vv> instruction.

=item xxx:.ensure(zz)

Ensure that list C<xxx> contains value C<zz>. If value C<zz> is
already stored in C<xxx> list, this function does nothing. In the
other case, value C<zz> is inserted in alphabetical order.

=item xxx:=z1,z2,z3

Set list element C<xxx> to list C<z1,z2,z3>. Use C<,,> for undef
values, and C<""> for empty values.

I.e, for a list C<('a',undef,'','c')>, use C<a,,"",c>.

=item xxx:yy=zz

For C<hash> element containing C<leaf> cargo_type. Set the leaf
identified by key C<yy> to value C<zz>.

Using C<xxx:~/yy/=zz> is also possible.

=item xxx:.copy(yy,zz)

copy item C<yy> in C<zz> (hash or list).

=item xxx:.json("path/to/file.json/foo/bar")

Store C<bar> content in array or hash. This should be used to store
hash or list of values.

You may store deep data structure. In this case, make sure that the
structure of the loaded data matches the structure of the model. This
won't happen by chance.

=item xxx:.clear

Clear the hash or list.

=back

=head2 leaf operation

=over

=item xxx=zz

Set element C<xxx> to value C<yy>. load also accepts to set elements
with a quoted string. (For C<leaf> element) Literal C<\n> are replaced by
real C<\n> (LF in Unix). Literal C<\\> are replaced by C<\>.

For instance C<foo="a quoted string"> or C<foo="\"bar\" and \"baz\"">.

=item xxx=~s/foo/bar/

Apply the substitution to the value of xxx. C<s/foo/bar/> is the standard Perl C<s>
substitution pattern.

Patterns with white spaces must be surrounded by quotes:

  xxx=~"s/foo bar/bar baz/"

Perl pattern modifiers are accepted

  xxx=~s/FOO/bar/i

=item xxx~

Undef element C<xxx>

=item xxx.=zzz

Appends C<zzz> value to current value (valid for C<leaf> elements).

=item xxx=.file(yyy)

Store the content of file C<yyy> in element C<xxx>.

Store STDIn in value xxx when C<yyy> is '-'.

=item xxx=.json(path/to/data.json/foo/bar)

Open file C<data.json> and store value from JSON data extracted with
C<foo/bar> subpath.

For instance, if C<data.json> contains:

 {
    "foo": {
       "bar": 42
    }
 }

The instruction C<baz=.json(data.json/foo/bar)> stores C<42> in C<baz>
element.

=item xxx=.yaml(path/to/data.yaml/0/foo/bar)

Open file C<data.yaml> and store value from YAML data extracted with
C<0/foo/bar> subpath.

Since a YAML file can contain several documents (separated by C<--->
lines, the subpath must begin with a number to select the document
containing the required value.

For instance, if C<data.yaml> contains:

  ---
  foo:
    bar: 42

The instruction C<baz=.yaml(data.yaml/0/foo/bar)> stores C<42> in
C<baz> element.

=item xxx=.env(yyy)

Store the content of environment variable C<yyy> in element C<xxx>.

=back

=head2 annotation

=over

=item xxx#zzz or xxx:yyy#zzz

Element annotation. Can be quoted or not quoted. Note that annotations are
always placed at the end of an action item.

I.e. C<foo#comment>, C<foo:bar#comment> or C<foo:bar=baz#comment> are valid.
C<foo#comment:bar> is B<not> valid.

=back

=head2 Quotes

You can surround indexes and values with double quotes. E.g.:

  a_string="\"foo\" and \"bar\""

=head1 Examples

You can use L<cme> to modify configuration with C<cme modify> command.

For instance, if L<Config::Model::Ssh> is installed, you can run:

 cme modify ssh 'ControlMaster=auto ControlPath="~/.ssh/master-%r@%n:%p"'

To delete C<Host *> entry:

 cme modify ssh 'Host:-"*"'

To specify 2 C<Host> with a single command:

 cme modify ssh 'Host:"foo* bar*" ForwardX11=yes HostName="foo.com" - Host:baz HostName="baz.com"'

Note the 'C<->' used to go up one node before "C<Host:baz>". In this
case, "up one node" leads to the "root node", so "C<!>" could also be
used instead of "C<->":

 cme modify ssh 'Host:"foo* bar*" ForwardX11=yes HostName="foo.com" ! Host:baz HostName="baz.com"'

Let's modify now the host name of using a C<.org> domain instead of
C<.com>. The C<:~> operator uses a regexp to loop over several Host
entries:

 cme modify ssh 'Host:~/ba[rz]/ HostName=~s/.com$/.org/'

Now that ssh config is mucked up with dummy entries, let's clean up:

 cme modify ssh 'Host:-"baz" Host:-"foo* bar*"'

=head1 Methods

=head2 load

Load data into the node tree (from the node passed with C<node>)
and fill values as we go following the instructions passed with
C<steps>.  (C<steps> can also be an array ref).

Parameters are:

=over

=item steps (or step)

A string or an array ref containing the steps to load. See
L<above/"load string syntax"> for a description of the string.

=item check

Whether to check values while loading. Either C<yes> (default), C<no> or C<skip>.
Bad values are discarded when C<check> is set to C<skip>.

=item caller_is_root

Change the target of the C<!> command: when set, the C<!> command go
to caller node instead of going to root node. (default is false)

=back

=head1 AUTHOR

Dominique Dumont, (ddumont at cpan dot org)

=head1 SEE ALSO

L<Config::Model>,L<Config::Model::Node>,L<Config::Model::Dumper>

=head1 AUTHOR

Dominique Dumont

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2005-2022 by Dominique Dumont.

This is free software, licensed under:

  The GNU Lesser General Public License, Version 2.1, February 1999

=cut
