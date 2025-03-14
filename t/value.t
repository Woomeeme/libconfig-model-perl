# -*- cperl -*-


use ExtUtils::testlib;
use Test::More;
use Test::Exception;
use Test::Differences;
use Test::Memory::Cycle;
use Config::Model;
use Config::Model::Tester::Setup qw/init_test/;
use Config::Model::Value;
use Test::Log::Log4perl;

use strict;
use warnings;

use 5.010;

Test::Log::Log4perl->ignore_priority("info");

binmode STDOUT, ':encoding(UTF-8)';

my ($model, $trace) = init_test();

# minimal set up to get things working
$model->create_config_class(
    name    => "BadClass",
    element => [
        crooked => {
            type  => 'leaf',
            class => 'Config::Model::Value',
        },
        crooked_enum => {
            type       => 'leaf',
            class      => 'Config::Model::Value',
            value_type => 'enum',
            default    => 'foo',
            choice     => [qw/A B C/]
        },
    ] );

$model->create_config_class(
    name    => "Master",
    element => [
        scalar => {
            type       => 'leaf',
            class      => 'Config::Model::Value',
            value_type => 'integer',
            min        => 1,
            max        => 4,
        },
        string => {
            type       => 'leaf',
            class      => 'Config::Model::Value',
            value_type => 'string',
        },
        string_with_help => {
            type       => 'leaf',
            class      => 'Config::Model::Value',
            value_type => 'string',
            help => {
                'foob[ao]b' => 'help for foobob* or foobab*  things',
                'foo' => 'help for foo things',
                '.' => 'help for non foo things'
            }
        },
        bounded_number => {
            type       => 'leaf',
            class      => 'Config::Model::Value',
            value_type => 'number',
            min        => 1,
            max        => 4,
        },
        mandatory_string => {
            type       => 'leaf',
            class      => 'Config::Model::Value',
            value_type => 'string',
            mandatory  => 1,
        },
        mandatory_boolean => {
            type       => 'leaf',
            class      => 'Config::Model::Value',
            value_type => 'boolean',
            mandatory  => 1,
        },
        mandatory_with_default_value => {
            type       => 'leaf',
            class      => 'Config::Model::Value',
            value_type => 'string',
            mandatory  => 1,
            default    => 'booya',
        },
        boolean_plain => {
            type       => 'leaf',
            value_type => 'boolean',
        },
        boolean_with_write_as => {
            type       => 'leaf',
            value_type => 'boolean',
            write_as   => [qw/false true/],
        },
        boolean_with_write_as_and_default => {
            type       => 'leaf',
            value_type => 'boolean',
            write_as   => [qw/false true/],
            default    => 'true',
        },
        bare_enum => {
            type       => 'leaf',
            class      => 'Config::Model::Value',
            value_type => 'enum',
            choice     => [qw/A B C/]
        },
        enum => {
            type       => 'leaf',
            class      => 'Config::Model::Value',
            value_type => 'enum',
            default    => 'A',
            choice     => [qw/A B C/]
        },
        enum_with_help => {
            type       => 'leaf',
            class      => 'Config::Model::Value',
            value_type => 'enum',
            choice     => [qw/a b c/],
            help       => { a => 'a help' }
        },
        uc_convert => {
            type       => 'leaf',
            class      => 'Config::Model::Value',
            value_type => 'string',
            convert    => 'uc',
        },
        lc_convert => {
            type       => 'leaf',
            class      => 'Config::Model::Value',
            value_type => 'string',
            convert    => 'lc',
        },
        upstream_default => {
            type             => 'leaf',
            value_type       => 'string',
            upstream_default => 'up_def',
        },
        a_uniline => {
            type             => 'leaf',
            value_type       => 'uniline',
            upstream_default => 'a_uniline_def',
        },
        with_replace => {
            type       => 'leaf',
            value_type => 'enum',
            choice     => [qw/a b c/],
            replace    => {
                a1       => 'a',
                c1       => 'c',
                'foo/.*' => 'b',
            },
        },
        replacement_hash => {
            type       => 'hash',
            index_type => 'string',
            cargo      => {
                type       => 'leaf',
                value_type => 'uniline',
            },
        },
        with_replace_follow => {
            type           => 'leaf',
            value_type     => 'string',
            replace_follow => '- replacement_hash',
        },
        match => {
            type       => 'leaf',
            value_type => 'string',
            match      => '^foo\d{2}/$',
        },
        prd_test_action => {
            type       => 'leaf',
            value_type => 'string',
        },
        prd_match => {
            type       => 'leaf',
            value_type => 'string',
            grammar    => q^check: <rulevar: local $failed = 0>
check: token (oper token)(s?) <reject:$failed>
oper: 'and' | 'or'
token: 'Apache' | 'CC-BY' | 'Perl' {
my $v = $arg[0]->grab("! prd_test_action")->fetch || '';
$failed++ unless $v =~ /$item[1]/ ; 
}
^,
        },
        warn_if_match => {
            type          => 'leaf',
            value_type    => 'string',
            warn_if_match => { 'foo' => { fix => '$_ = uc;' } },
        },
        warn_if_match_slashed => {
            type          => 'leaf',
            value_type    => 'string',
            warn_if_match => { 'oo/b' => { fix => 's!oo/b!!;' } },
        },
        warn_unless_match => {
            type              => 'leaf',
            value_type        => 'string',
            warn_unless_match => { foo => { msg => '', fix => '$_ = "foo".$_;' } },
        },
        assert => {
            type       => 'leaf',
            value_type => 'string',
            assert     => {
                assert_test => {
                    code => 'defined $_ and /\w/',
                    msg  => 'must not be empty',
                    fix  => '$_ = "foobar";'
                }
            },
        },
        warn_if_number => {
            type        => 'leaf',
            value_type  => 'string',
            warn_if => {
                warn_test => {
                    code => 'defined $_ && /\d/;',
                    msg  => 'should not have numbers',
                    fix  => 's/\d//g;'
                }
            },
        },
        integer_with_warn_if => {
            type        => 'leaf',
            value_type  => 'integer',
            warn_if => {
                warn_test => {
                    code => 'defined $_ && $_ < 9;',
                    msg  => 'should be greater than 9',
                    fix  => '$_ = 10;'
                }
            },
        },
        warn_unless => {
            type        => 'leaf',
            value_type  => 'string',
            warn_unless => {
                warn_test => {
                    code => 'defined $_ and /\w/',
                    msg  => 'should not be empty',
                    fix  => '$_ = "foobar";'
                }
            },
        },
        warn_unless_file => {
            type        => 'leaf',
            value_type  => 'string',
            warn_unless => {
                warn_test => {
                    code => 'file($_)->exists',
                    msg  => 'file $_ should exist',
                    fix  => '$_ = "value.t";'
                }
            },
        },
        always_warn => {
            type       => 'leaf',
            value_type => 'string',
            warn       => 'Always warn whenever used',
        },
        'Standards-Version' => {
            'value_type'        => 'uniline',
            'warn_unless_match' => {
                '3\\.9\\.2' => {
                    'msg' => 'Current standard version is 3.9.2',
                    'fix' => '$_ = undef; #restore default'
                }
            },
            'match'   => '\\d+\\.\\d+\\.\\d+(\\.\\d+)?',
            'default' => '3.9.2',
            'type'    => 'leaf',
        },
        t_file => {
            type => 'leaf',
            value_type => 'file'
        },
        t_dir => {
            type => 'leaf',
            value_type => 'dir'
        }
    ],                          # dummy class
);

my $bad_inst = $model->instance(
    root_class_name => 'BadClass',
    instance_name   => 'test_bad_class'
);
ok( $bad_inst, "created bad_class instance" );
$bad_inst->initial_load_stop;

my $bad_root = $bad_inst->config_root;

throws_ok { $bad_root->fetch_element('crooked'); }
    'Config::Model::Exception::Model',
    "test create expected failure";
print "normal error:\n", $@, "\n" if $trace;

my $inst = $model->instance(
    root_class_name => 'Master',
    # root_dir is used to test warn_unless_file
    root_dir => 't',
    instance_name   => 'test1'
);
ok( $inst, "created dummy instance" );
$inst->initial_load_stop;

sub check_store_error {
    my ( $obj, $v, $qr ) = @_;
    my $path = $obj->location;
    $obj->store( value => $v, silent => 1, check => 'skip' );
    is( $inst->errors->{$path}, '', "store error in $path is tracked" );
    like( scalar $inst->error_messages, $qr, "check $path error message" );
}

sub check_error {
    my ( $obj, $v, $qr ) = @_;
    my $old_v = $obj->fetch;
    check_store_error(@_);
    is( $obj->fetch, $old_v, "check that wrong value $v was not stored" );
}

my $root = $inst->config_root;

subtest "simple scalar" => sub {
    my $i = $root->fetch_element('scalar');
    ok( $i, "test create bounded integer" );

    is( $inst->needs_save, 0, "verify instance needs_save status after creation" );

    is( $i->needs_check, 1, "verify check status after creation" );

    is( $i->has_data, 0, "check has_data on empty scalar" );

    $i->store(1);
    ok( 1, "store test done" );
    is( $i->needs_check,   0, "store does not trigger a check (check done during store)" );
    is( $inst->needs_save, 1, "verify instance needs_save status after store" );
    is( $i->has_data, 1, "check has_data after store" );

    is( $i->fetch,         1, "fetch test" );
    is( $i->needs_check,   0, "check was done during fetch" );
    is( $inst->needs_save, 1, "verify instance needs_save status after fetch" );

    ok($i->check_value(), "call check_value without argument");
};

subtest "error handling on simple scalar" => sub {
    my $i = $root->fetch_element('scalar');
    check_error( $i, 5, qr/max limit/ );

    check_error( $i, 'toto', qr/not of type/ );

    check_error( $i, 1.5, qr/number but not an integer/ );

    # test that bad storage triggers an error
    throws_ok { $i->store(5); } 'Config::Model::Exception::WrongValue', "test max nb expected failure";
    print "normal error:\n", $@, "\n" if $trace;

    ok( ! $i->store(value => 5, check => 'skip'), "bad value was skipped");
    is($i->fetch,1,"check original value");

    is($i->store(value => 5, check => 'no'),1 ,"bad value was force fed");
    is($i->fetch(check => 'no'),5,"check stored bad value");

    throws_ok { $i->fetch() } 'Config::Model::Exception::WrongValue', "check that reading a bad value trigges an error";
    is($i->fetch(check => 'skip'),undef,"check bad read value can be skipped");
    is($i->fetch(check => 'no'),5,"check stored bad value has not changed");

    $i->store(1); # fix the error condition
};

subtest "summary method" => sub {
    my $i = $root->fetch_element('scalar');
    $i->store(4);
    is($i->fetch_summary, 4, "test summary on integer");

    my $s = $root->fetch_element('string');
    $s->store("Lorem ipsum dolor sit amet, consectetur adipiscing elit,");
    is($s->fetch_summary, "Lorem ipsum dol...", "test summary on string");

    $s->store("Lorem ipsum\ndolor sit amet, consectetur adipiscing elit,");
    is($s->fetch_summary, "Lorem ipsum dol...", "test summary on string with \n");
};

subtest "bounded number" => sub {
    my $nb = $root->fetch_element('bounded_number');
    ok( $nb, "created " . $nb->name );

    $nb->store( value => 1,   callback => sub { is( $nb->fetch, 1,   "assign 1" ); } );
    $nb->store( value => 1.5, callback => sub { is( $nb->fetch, 1.5, "assign 1.5" ); } );

    $nb->store(undef);
    ok( defined $nb->fetch() ? 0 : 1, "store undef" );
};

subtest "mandatory string" => sub {
    my $ms = $root->fetch_element('mandatory_string');
    ok( $ms, "created mandatory_string" );

    throws_ok { my $v = $ms->fetch; } 'Config::Model::Exception::User', "mandatory string: undef error";
    print "normal error:\n", $@, "\n" if $trace;

    $ms->store('toto');
    is( $ms->fetch, 'toto', "mandatory_string: store and read" );

    my $toto_str = "a\nbig\ntext\nabout\ntoto";
    $ms->store($toto_str);
    $toto_str =~ s/text/string/;
    $ms->store($toto_str);

    print join( "\n", $inst->list_changes("\n") ), "\n" if $trace;
    $inst->clear_changes;
};

subtest "mandatory string provided with a default value" => sub {
    my $mwdv = $root->fetch_element('mandatory_with_default_value');
    # note: calling fetch before store triggers a "notify_change" to
    # let user know that his file was changed by model
    $mwdv->store('booya'); # emulate reading a file containing default value
    is( $mwdv->has_data, 0, "check has_data after storing default value" );
    is( $mwdv->fetch,      'booya', "status quo" );
    is( $inst->needs_save, 0,       "verify instance needs_save status after storing default value" );

    $mwdv->store('boo');
    is( $mwdv->fetch,      'boo', "override default" );
    is( $inst->needs_save, 1,     "verify instance needs_save status after storing another value" );

    $mwdv->store(undef);
    is( $mwdv->fetch,      'booya', "restore default by writing undef value in mandatory string" );
    is( $inst->needs_save, 1,       "verify instance needs_save status after restoring default value" );

    $mwdv->store('');
    is( $mwdv->fetch, 'booya', "restore default by writing empty value in mandatory string" );
    is( $inst->needs_save, 2, "verify instance needs_save status after restoring default value" );

    print join( "\n", $inst->list_changes("\n") ), "\n" if $trace;
    $inst->clear_changes;
};

subtest "mandatory boolean" => sub {
    my $mb = $root->fetch_element('mandatory_boolean');
    ok( $mb, "created mandatory_boolean" );

    throws_ok { my $v = $mb->fetch; } 'Config::Model::Exception::User',
        "mandatory bounded: undef error";
    print "normal error:\n", $@, "\n" if $trace;

    check_store_error( $mb, 'toto', qr/is not boolean/ );

    check_store_error( $mb, 2, qr/is not boolean/ );
};

subtest "boolean where values are translated" => sub {
    $inst->clear_changes;
    my %data = ( 0 => 0, 1 => 1, off => 0, on => 1, no => 0, yes => 1, No => 0, Yes => 1,
                 NO => 0, YES => 1, true => 1, false => 0, True => 1, False => 0, '' => 0);
    my $bp = $root->fetch_element('boolean_plain');

    while (my ($v,$expect) =  each %data) {
        $bp->store($v);
        is( $bp->fetch, $expect, "boolean_plain: '$v'->'$expect'" );
    }

    $bp->clear;
    is( $bp->fetch, undef, "boolean_plain: get 'undef' after clear()" );
};

subtest "check changes with boolean where values are translated to true/false" => sub {
    $inst->clear_changes;
    my $bwwa = $root->fetch_element('boolean_with_write_as');
    is( $bwwa->fetch, undef, "boolean_with_write_as reads undef" );
    $bwwa->store('no');
    is( $bwwa->fetch, 'false', "boolean_with_write_as returns 'false'" );
    is( $inst->needs_save, 1, "check needs_save after writing 'boolean_with_write_as'" );

    my @changes = "boolean_with_write_as has new value: 'false'";
    eq_or_diff([$inst->list_changes],\@changes,
               "check change message after writing 'boolean_with_write_as'");

    $bwwa->store('false');
    is( $inst->needs_save, 1, "check needs_save after writing twice 'boolean_with_write_as'" );

    $bwwa->store(1);
    is( $bwwa->fetch, 'true', "boolean_with_write_as returns 'true'" );

    push @changes, "boolean_with_write_as: 'false' -> 'true'";
    eq_or_diff([$inst->list_changes], \@changes,
               "check change message after writing 'boolean_with_write_as'");
    my $bwwaad = $root->fetch_element('boolean_with_write_as_and_default');
    is( $bwwa->fetch, 'true', "boolean_with_write_as_and_default reads true" );
};

subtest "boolean_with_write_as_and_default" => sub {
    my $bwwaad = $root->fetch_element('boolean_with_write_as_and_default');
    is( $bwwaad->fetch, 'true', "boolean_with_write_as_and_default reads true" );

    $bwwaad->store(0);
    $bwwaad->clear;
    is( $bwwaad->fetch, 'true', "boolean_with_write_as_and_default returns 'true'" );
};

subtest "enum with wrong declaration" => sub {
    throws_ok { $bad_root->fetch_element('crooked_enum'); }
        'Config::Model::Exception::Model',
        "test create expected failure with enum with wrong default";
    print "normal error:\n", $@, "\n" if $trace;
};

subtest "enum" => sub {
    my $de = $root->fetch_element('enum');
    ok( $de, "Created enum with correct default" );

    $inst->clear_changes;

    is( $de->fetch, 'A', "enum with default: read default value" );

    is( $inst->needs_save, 1, "check needs_save after reading a default value" );
    $inst->clear_changes;

    $de->store('A');            # emulate config file read
    is( $inst->needs_save, 0,   "check needs_save after storing a value identical to default value" );
    is( $de->fetch,        'A', "enum with default: read default value" );
    is( $inst->needs_save, 0,   "check needs_save after reading a default value" );

    print "enum with default: read custom\n" if $trace;
    is( $de->fetch_custom, undef, "enum with default: read custom value" );

    $de->store('B');
    is( $de->fetch,          'B', "enum: store and read B" );
    is( $de->fetch_custom,   'B', "enum: read custom value" );
    is( $de->fetch_standard, 'A', "enum: read standard value" );

    ## check model data
    is( $de->value_type, 'enum', "enum: check value_type" );

    eq_array( $de->choice, [qw/A B C/], "enum: check choice" );

    ok( $de->set_properties( default => 'B' ), "enum: warping default value" );
    is( $de->default(), 'B', "enum: check new default value" );

    throws_ok { $de->set_properties( default => 'F' ) }
        'Config::Model::Exception::Model',
        "enum: warped default value to wrong value";
    print "normal error:\n", $@, "\n" if $trace;

    ok( $de->set_properties( choice => [qw/A B C D/] ), "enum: warping choice" );

    ok( $de->set_properties( choice => [qw/A B C D/], default => 'D' ),
        "enum: warping default value to new choice" );

    ok(
        $de->set_properties( choice => [qw/F G H/], default => undef ),
        "enum: warping choice to completely different set"
    );

    is( $de->default(), undef, "enum: check that new default value is undef" );

    is( $de->fetch, undef, "enum: check that new current value is undef" );

    $de->store('H');
    is( $de->fetch(), 'H', "enum: set and read a new value" );
};

subtest "uppercase conversion" => sub {
    my $uc_c = $root->fetch_element('uc_convert');
    ok( $uc_c, "testing convert => uc" );
    $uc_c->store('coucou');
    is( $uc_c->fetch(), 'COUCOU', "uc_convert: testing" );
};

subtest "lowercase conversion" => sub {
    my $lc_c = $root->fetch_element('lc_convert');
    ok( $lc_c, "testing convert => lc" );
    $lc_c->store('coUcOu');
    is( $lc_c->fetch(), 'coucou', "lc_convert: testing" );
};

subtest "integrated help on enum" => sub {
    my $value_with_help = $root->fetch_element('enum_with_help');
    my $full_help       = $value_with_help->get_help;

    is( $full_help->{a},                 'a help', "full enum help" );
    is( $value_with_help->get_help('a'), 'a help', "enum help on one choice" );
    is( $value_with_help->get_help('b'), undef,    "test undef help" );

    is( $value_with_help->fetch, undef, "test undef enum" );
};

subtest "integrated help on string" => sub {
    my $value_with_help = $root->fetch_element('string_with_help');

    my $foo_help = 'help for foo things';
    my $foob_help = 'help for foobob* or foobab*  things';
    my $other_help = 'help for non foo things';

    my %test = (
        fooboba => $foob_help,
        foobaba => $foob_help,
        foobbba => $foo_help,
        foo => $foo_help,
        foobar => $foo_help,
        f => $other_help,
        afoo => $other_help,
    );

    foreach my $k (sort keys %test) {
        is( $value_with_help->get_help($k), $test{$k} , "test string help on $k" );
    }
};

subtest "upstream default value" => sub {
    my $up_def = $root->fetch_element('upstream_default');

    is( $up_def->fetch,                         undef,    "upstream actual value" );
    is( $up_def->fetch_standard,                'up_def', "upstream standard value" );
    is( $up_def->fetch('upstream_default'),     'up_def', "upstream actual value" );
    is( $up_def->fetch('non_upstream_default'), undef,    "non_upstream value" );
    is( $up_def->has_data, 0, "does not have data");

    $up_def->store('yada');
    is( $up_def->fetch('upstream_default'),     'up_def', "after store: upstream actual value" );
    is( $up_def->fetch('non_upstream_default'), 'yada',   "after store: non_upstream value" );
    is( $up_def->fetch,                         'yada',   "after store: upstream actual value" );
    is( $up_def->fetch('standard'),             'up_def', "after store: upstream standard value" );
    is( $up_def->has_data, 1, "has data");
};

subtest "uniline type" => sub {
    my $uni = $root->fetch_element('a_uniline');
    check_error( $uni, "foo\nbar", qr/value must not contain embedded newlines/ );

    $uni->store("foo bar");
    is( $uni->fetch, "foo bar", "tested uniline value" );

    is( $inst->errors()->{'a_uniline'}, undef, "check that error was deleted by correct store" );

    $uni->store('');
    is( $uni->fetch, '', "tested empty value" );
};

subtest "replace feature" => sub {
    my $wrepl = $root->fetch_element('with_replace');
    $wrepl->store('c1');
    is( $wrepl->fetch, "c", "tested replaced value" );

    $wrepl->store('foo/bar');
    is( $wrepl->fetch, "b", "tested replaced value with regexp" );
};

subtest "preset feature" => sub {
    my $pinst = $model->instance(
        root_class_name => 'Master',
        instance_name   => 'preset_test'
    );
    ok( $pinst, "created dummy preset instance" );

    my $p_root = $pinst->config_root;

    $pinst->preset_start;
    ok( $pinst->preset, "instance in preset mode" );

    my $p_scalar = $p_root->fetch_element('scalar');
    $p_scalar->store(3);

    my $p_enum = $p_root->fetch_element('enum');
    $p_enum->store('B');

    $pinst->preset_stop;
    is( $pinst->preset, 0, "instance in normal mode" );

    is( $p_scalar->fetch, 3, "scalar: read preset value as value" );
    $p_scalar->store(4);
    is( $p_scalar->fetch,           4, "scalar: read overridden preset value as value" );
    is( $p_scalar->fetch('preset'), 3, "scalar: read preset value as preset_value" );
    is( $p_scalar->fetch_standard,  3, "scalar: read preset value as standard_value" );
    is( $p_scalar->fetch_custom,    4, "scalar: read custom_value" );

    is( $p_enum->fetch, 'B', "enum: read preset value as value" );
    $p_enum->store('C');
    is( $p_enum->fetch,           'C', "enum: read overridden preset value as value" );
    is( $p_enum->fetch('preset'), 'B', "enum: read preset value as preset_value" );
    is( $p_enum->fetch_standard,  'B', "enum: read preset value as standard_value" );
    is( $p_enum->fetch_custom,    'C', "enum: read custom_value" );
    is( $p_enum->default,         'A', "enum: read default_value" );
};

subtest "layered feature" => sub {
    my $layer_inst = $model->instance(
        root_class_name => 'Master',
        instance_name   => 'layered_test'
    );
    ok( $layer_inst, "created dummy layered instance" );

    my $l_root = $layer_inst->config_root;

    $layer_inst->layered_start;
    ok( $layer_inst->layered, "instance in layered mode" );

    my $l_scalar = $l_root->fetch_element('scalar');
    $l_scalar->store(3);

    my $l_enum = $l_root->fetch_element('bare_enum');
    $l_enum->store('B');

    my $msl = $l_root->fetch_element('mandatory_string');
    $msl->store('plop');

    $layer_inst->layered_stop;
    is( $layer_inst->layered, 0, "instance in normal mode" );

    is( $l_scalar->fetch, undef, "scalar: read layered value as backend value" );
    is( $l_scalar->fetch( mode => 'user' ), 3, "scalar: read layered value as user value" );
    is( $l_scalar->has_data, 0, "scalar: has no data" );
    is( $l_scalar->fetch(mode => 'non_upstream_default'), 3,
        "scalar: read non upstream default value before store" );

    # store a value identical to the layered value
    $l_scalar->store(3);
    is( $l_scalar->fetch, 3, "scalar: read value as backend value after store" );
    is( $l_scalar->has_data, 0, "scalar: has no data after store layered value" );

    $l_scalar->store(4);
    is( $l_scalar->fetch,            4, "scalar: read overridden layered value as value" );
    is( $l_scalar->fetch('layered'), 3, "scalar: read layered value as layered_value" );
    is( $l_scalar->fetch_standard,   3, "scalar: read standard_value" );
    is( $l_scalar->fetch(mode => 'non_upstream_default'), 4,
        "scalar: read non upstream default value after store" );
    is( $l_scalar->fetch_custom,     4, "scalar: read custom_value" );
    is( $l_scalar->has_data,         1, "scalar: has data" );

    is( $l_enum->fetch, undef, "enum: read layered value as backend value" );
    is( $l_enum->fetch( mode => 'user' ), 'B', "enum: read layered value as user value" );
    is( $l_enum->has_data, 0, "enum: has no data" );
    $l_enum->store('C');
    is( $l_enum->fetch,            'C', "enum: read overridden layered value as value" );
    is( $l_enum->fetch('layered'), 'B', "enum: read layered value as layered_value" );
    is( $l_enum->fetch_standard,   'B', "enum: read layered value as standard_value" );
    is( $l_enum->fetch_custom,     'C', "enum: read custom_value" );
    is( $l_enum->has_data, 1, "enum: has data" );

    is($msl->fetch('layered'), 'plop',"check mandatory value in layer");
    is($msl->fetch, undef,"check mandatory value backend mode");
    is($msl->fetch('user'), 'plop',"check mandatory value user mode with layer");
};

subtest "match regexp" => sub {
    my $match = $root->fetch_element('match');

    check_error( $match, 'bar', qr/does not match/ );

    $match->store('foo42/');
    is( $match->fetch, 'foo42/', "test stored matching value" );
};

subtest "validation done with a Parse::RecDescent grammar" => sub {
    my $prd_match = $root->fetch_element('prd_match');

    check_error( $prd_match, 'bar',  qr/does not match grammar/ );
    check_error( $prd_match, 'Perl', qr/does not match grammar/ );
    $root->fetch_element('prd_test_action')->store('Perl CC-BY Apache');

    foreach my $prd_test ( ( 'Perl', 'Perl and CC-BY', 'Perl and CC-BY or Apache' ) ) {
        $prd_match->store($prd_test);
        is( $prd_match->fetch, $prd_test, "test stored prd value $prd_test" );
    }
};

subtest "warn_if_match with a string" => sub {
    my $wim = $root->fetch_element('warn_if_match');

    {
        my $xp = Test::Log::Log4perl->expect(
            ignore_priority => "info",
            ['User', warn =>  qr/should not match/]
        );
        $wim->store('foobar');
    }

    is( $wim->has_fixes, 1, "test has_fixes" );

    {
        # check code is not run when check is 'no'.
        my $xp = Test::Log::Log4perl->expect(ignore_priority => "debug", []);
        $wim->fetch(  check => 'no');
    }

    is( $wim->fetch( check => 'no', silent => 1 ), 'foobar', "check warn_if stored value" );
    is( $wim->has_fixes, 1, "test has_fixes after fetch with check=no" );

    is( $wim->fetch( mode => 'standard' ), undef, "check warn_if standard value" );
    is( $wim->has_fixes, 1, "test has_fixes after fetch with mode = standard" );

    ### test fix included in model
    $wim->apply_fixes;
    is( $wim->fetch, 'FOOBAR', "test if fixes were applied" );
};

subtest "warn_if_match with a slash in regexp" => sub {
    my $wim = $root->fetch_element('warn_if_match_slashed');

    {
        my $xp = Test::Log::Log4perl->expect(
            ignore_priority => "info",
            ['User', warn =>  qr/should not match/]
        );
        $wim->store('foo/bar');
    }

    is( $wim->has_fixes, 1, "test has_fixes" );

    {
        # check code is not run when check is 'no'.
        my $xp = Test::Log::Log4perl->expect(ignore_priority => "debug", []);
        $wim->fetch(  check => 'no');
    }

    is( $wim->fetch( check => 'no', silent => 1 ), 'foo/bar', "check warn_if stored value" );
    is( $wim->has_fixes, 1, "test has_fixes after fetch with check=no" );

    ### test fix included in model
    $wim->apply_fixes;
    is( $wim->fetch, 'far', "test if fixes were applied" );
};

subtest "warn_if_number with a regexp" => sub {
    my $win = $root->fetch_element('warn_if_number');

    {
        my $xp = Test::Log::Log4perl->expect(
            ignore_priority => 'info',
            ['User', warn => qr/should not have numbers/]
        );
        $win->store('bar51');
    }

    is( $win->has_fixes, 1, "test has_fixes" );
    $win->apply_fixes;
    is( $win->fetch, 'bar', "test if fixes were applied" );
};

subtest "integer_with_warn_if" => sub {
    my $iwwi = $root->fetch_element('integer_with_warn_if');
    {
        my $xp = Test::Log::Log4perl->expect(
            ignore_priority => 'info',
            ['User', warn => qr/should be greater than 9/]
        );
        $iwwi->store('5');
    }

    is( $iwwi->has_fixes, 1, "test has_fixes" );
    $iwwi->apply_fixes;
    is( $iwwi->fetch, 10, "test if fixes were applied" );
};

my $warn_unless_test = sub {
    my $wup = $root->fetch_element('warn_unless_match');
    my $v = shift;
    {
        my $xp = Test::Log::Log4perl->expect(
            ignore_priority => 'info',
            ['User', warn => qr/should match/]
        );
        $wup->store($v);
    }

    is( $wup->has_fixes, 1, "test has_fixes" );
    $wup->apply_fixes;
    is( $wup->fetch, "foo$v", "test if fixes were applied" );
};

subtest "warn_unless_match feature with unline value" => $warn_unless_test, "bar" ;
subtest "warn_unless_match feature with multiline value" => $warn_unless_test, "bar\nbaz\bazz\n";

subtest "unconditional feature" => sub {
    my $aw = $root->fetch_element('always_warn');
    my $xp = Test::Log::Log4perl->expect(
        ignore_priority => 'info',
        ['User', warn => qr/always/]
    );
    $aw->store('whatever');
};

subtest "warning and repeated storage in same element" => sub {
    my $aw = $root->fetch_element('always_warn');
    my $xp = Test::Log::Log4perl->expect(
        ignore_priority => 'info',
        [ 'User', ( warn => qr/always/ ) x 2 ]
    );
    $aw->store('what ?'); # warns
    $aw->store('what ?');  # does not warn
    $aw->store('what never'); # warns
};

subtest "unicode" => sub {
    my $wip = $root->fetch_element('warn_if_match');
    my $smiley = "\x{263A}";    # See programming perl chapter 15
    $wip->store(':-)');         # to test list_changes just below
    $wip->store($smiley);
    is( $wip->fetch, $smiley, "check utf-8 string" );
};

print join( "\n", $inst->list_changes("\n") ), "\n" if $trace;

subtest "replace_follow" => sub {
    my $wrf = $root->fetch_element('with_replace_follow');
    $inst->clear_changes;

    $wrf->store('foo');
    is( $inst->needs_save, 1, "check needs_save after store" );
    $inst->clear_changes;

    is( $wrf->fetch,       'foo', "check replacement_hash with foo (before replacement)" );
    is( $inst->needs_save, 0,     "check needs_save after simple fetch" );

    $root->load('replacement_hash:foo=repfoo replacement_hash:bar=repbar');
    is( $inst->needs_save, 2, "check needs_save after load" );
    $inst->clear_changes;

    is( $wrf->fetch,       'repfoo', "check replacement_hash with foo (after replacement)" );
    is( $inst->needs_save, 1,        "check needs_save after fetch with replacement" );

    $wrf->store('bar');
    is( $wrf->fetch, 'repbar', "check replacement_hash with bar" );

    $wrf->store('baz');
    is( $wrf->fetch, 'baz', "check replacement_hash with baz (no replacement)" );

    ok(
        !$root->fetch_element('replacement_hash')->exists('baz'),
        "check that replacement hash was not changed by missed substitution"
    );

    $inst->clear_changes;
};

subtest "Standards-Version" => sub {
    my $sv = $root->fetch_element('Standards-Version');
    {
        my $xp = Test::Log::Log4perl->expect(
            ignore_priority => 'info',
            ['User', warn => qr/Current/]
        );
        # store old standard version
        $sv->store('3.9.1');
    }
    is( $inst->needs_save, 1, "check needs_save after load" );
    $sv->apply_fixes;
    is( $inst->needs_save, 2, "check needs_save after load" );
    print join( "\n", $inst->list_changes("\n") ), "\n" if $trace;

    is( $sv->fetch, '3.9.2', "check fixed standard version" );

    is( $sv->fetch( mode => 'custom' ), undef, "check custom standard version" );
};

subtest "assert"  => sub {
    my $assert_elt = $root->fetch_element('assert');
    throws_ok { $assert_elt->fetch(); } 'Config::Model::Exception::WrongValue', "check assert error";

    $assert_elt->apply_fixes;
    ok( 1, "assert_elt apply_fixes called" );
    is( $assert_elt->fetch, 'foobar', "check fixed assert pb" );
};

subtest "warn_unless" => sub {
    my $warn_unless = $root->fetch_element('warn_unless');

    my $xp = Test::Log::Log4perl->expect(
        ignore_priority => 'info',
        ['User', warn => qr/should not be empty/]
    );
    $warn_unless->fetch();

    $warn_unless->apply_fixes;
    ok( 1, "warn_unless apply_fixes called" );
    is( $warn_unless->fetch, 'foobar', "check fixed warn_unless pb" );
};

subtest "warn_unless_file" => sub {
    my $warn_unless_file = $root->fetch_element('warn_unless_file');

    my $xp = Test::Log::Log4perl->expect(
        ignore_priority => 'info',
        ['User', warn =>  qr/file not-value.t should exist/]
    );
    $warn_unless_file->store('not-value.t');

    $warn_unless_file->apply_fixes;
    ok( 1, "warn_unless_file apply_fixes called" );
    is( $warn_unless_file->fetch, 'value.t', "check fixed warn_unless_file" );
};

subtest "file and dir value types"  => sub {
    my $t_file = $root->fetch_element('t_file');
    my $t_dir  = $root->fetch_element('t_dir');

    {
        my $xp = Test::Log::Log4perl->expect(
            ignore_priority => 'info',
            [
                'User',
                warn => qr/not exist/,
                warn => qr/not a file/,
                warn => qr/not a dir/,
            ]
        );
        $t_file->store('toto');
        $t_file->store('t');
        $t_dir->store('t/value.t');
    }

    $t_file->store('t/value.t') ;
    is($t_file->has_warning, 0, "test a file");

    $t_dir->store('t/') ;
    is($t_dir->has_warning, 0, "test a dir");

};

subtest "problems during initial load" => sub {
    my $inst2 = $model->instance(
        root_class_name => 'Master',
        instance_name   => 'initial_test'
    );
    ok( $inst2, "created initial_test inst2ance" );

    # is triggered internally only when at least one node has a RW backend
    $inst2->initial_load_start;

    my $s = $inst2->config_root->fetch_element('string');
    $s->store('foo');
    $s->store('foo');


    is( $inst2->needs_save, 1, "verify instance needs_save status after redundant data" );

    eq_or_diff([$inst2->list_changes],['string: removed redundant initial value'],"check change message for redundant data");
    $inst2->clear_changes;
    is( $inst2->needs_save, 0, "needs_save after clearing changes" );

    $s->store('bar');
    eq_or_diff([$inst2->list_changes],['string: \'foo\' -> \'bar\' # conflicting initial values'],"check change message for redundant data");
    is( $inst2->needs_save, 1, "verify instance needs_save status after conflicting data" );

    $inst2->clear_changes;
    $s->parent->fetch_element('uc_convert')->store('foo');
    eq_or_diff([$inst2->list_changes],['uc_convert: \'foo\' -> \'FOO\' # initial value changed by model'],
               "check change message when model changes data coming from config file");

    $inst2->clear_changes;
    $s->parent->fetch_element('boolean_with_write_as')->store('true');
    is( $inst2->needs_save, 0, "verify instance needs_save status after writing 'boolean_with_write_as'" );

    $inst2->initial_load_stop;
};

memory_cycle_ok( $model, "check memory cycles" );

done_testing;
