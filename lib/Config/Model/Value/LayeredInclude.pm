#
# This file is part of Config-Model
#
# This software is Copyright (c) 2005-2022 by Dominique Dumont.
#
# This is free software, licensed under:
#
#   The GNU Lesser General Public License, Version 2.1, February 1999
#
package Config::Model::Value::LayeredInclude 2.152;

use v5.20;
use Mouse;
use strict;
use warnings;
use Log::Log4perl qw(get_logger :levels);

use base qw/Config::Model::Value/;

use feature qw/postderef signatures/;
no warnings qw/experimental::postderef experimental::signatures/;

my $logger = get_logger("Tree::Element::Value::LayeredInclude");

# should we clear all layered value when include value is changed ?
# If yes, beware of recursive includes. Clear should only be done once.

around _store => sub ($orig, $self, %args) {
    my ( $value, $check, $silent, $notify_change, $ok, $callback ) =
        @args{qw/value check silent notify_change ok callback/};

    my $old_value = $self->_fetch_no_check;

    $orig->($self, %args);
    {
        ## no critic (TestingAndDebugging::ProhibitNoWarnings)
        no warnings 'uninitialized';
        return $value if $value eq $old_value;
    }

    my $i                  = $self->instance;
    my $already_in_layered = $i->layered;

    # layered stuff here
    if ( not $already_in_layered ) {
        $i->layered_clear;
        $i->layered_start;
    }

    {
        ## no critic (TestingAndDebugging::ProhibitNoWarnings)
        no warnings 'uninitialized';
        $logger->debug("Loading layered config from $value (old_data is $old_value)");
    }

    # load included file in layered mode
    $self->root->read_config_data(
        # check => 'no',
        config_file => $value,
        auto_create => 0,        # included file must exist
    );

    if ( not $already_in_layered ) {
        $i->layered_stop;
    }

    # test if already in layered mode -> if no, clear layered,
    $logger->debug("Done loading layered config from $value");

    return $value;
};

1;

# ABSTRACT: Include a sub layer configuration

__END__

=pod

=encoding UTF-8

=head1 NAME

Config::Model::Value::LayeredInclude - Include a sub layer configuration

=head1 VERSION

version 2.152

=head1 SYNOPSIS

    # in a model declaration:
    'element' => [
      'include' => {
        'class' => 'Config::Model::Value::LayeredInclude',

        # usual Config::Model::Value parameters
        'type' => 'leaf',
        'value_type' => 'uniline',
        'convert' => 'lc',
        'summary' => 'Include file for cascaded configuration',
        'description' => 'To support multiple variants of ...'
      },
    ]

=head1 DESCRIPTION

This class inherits from L<Config::Model::Value>. It overrides
L<_store> to trigger a refresh of layered value when a value is
changed. I.e. changing this value trigger a reload of the referred configuration
file which values are used as default value. This class was designed to
cope with L<multistrap|http://wiki.debian.org/Multistrap> configuration.

=head2 CAUTION

A configuration file can support 2 kinds of include:

=over

=item *

Layered include which sets default values like multistrap or ssh. These includes are
read-only.

=item *

Real includes like C<apache>. In this cases modified configuration items can be written to
included files.

=back

This class works only with the first type

=head1 AUTHOR

Dominique Dumont

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2005-2022 by Dominique Dumont.

This is free software, licensed under:

  The GNU Lesser General Public License, Version 2.1, February 1999

=cut
