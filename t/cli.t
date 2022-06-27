#!/usr/bin/env perl

use Test2::V0;
use lib 't/lib';

use File::Share 'dist_file';
use File::Temp 'tempfile';

use Capture::Tiny qw( capture capture_stdout );

subtest help => sub {
    my @commands = map s/^\s+|\s+$//gr, grep /^\s+/, split /\n/, capture_stdout {
        system qw( bin/newrelic-admin help );
    };

    ok @commands, 'Help lists available commands';

    subtest plain => sub {
        like test('help'), qr/^Usage: newrelic-admin COMMAND/, 'Has usage line';
    };

    subtest command => sub {
        for my $command (@commands) {
            subtest $command => sub {
                like test( 'help', $command ),
                    qr/^Usage: newrelic-admin (?:$command|COMMAND)/,
            };
        }
    };

    subtest option => sub {
        for my $command (@commands) {
            subtest $command => sub {
                like test( $command, '--help' ),
                    qr/^Usage: newrelic-admin (?:$command|COMMAND)/,
            };
        }
    };
};

subtest 'license-key' => sub {
    my $config = dist_file 'NewFangle-Agent', 'test.yml';

    subtest 'From config' => sub {
        is test('license-key', $config),
            "license_key = DEADBEEF\n", 'Prints default license key';
    };

    subtest 'From env' => sub {
        local $ENV{NEWRELIC_LICENSE_KEY} = 'foo';

        is test('license-key', $config),
            "license_key = foo\n", 'Prints license key from env';
    };
};

subtest 'local-config' => sub {
    my $config = dist_file 'NewFangle-Agent', 'test.yml';

    subtest 'Default' => sub {
        like test('local-config', '-'),
            qr/  threshold: is_apdex_failing/, 'Prints default config as YAML';
    };

    subtest 'From file' => sub {
        like test('local-config', $config),
            qr/^license_key: DEADBEEF/m, 'Prints config as YAML';

        local $ENV{NEWRELIC_LICENSE_KEY} = 'foo';

        like test('local-config', $config),
            qr/^license_key: foo/m, 'Prints local config as YAML';
    };
};

subtest 'generate-config' => sub {
    subtest 'Print to output' => sub {
        my $out = test('generate-config', 'foo');

        like $out, qr/^# This file configures the unofficial New Relic Perl Agent/m,
            'Generates a config file';
        like $out, qr/^license_key: 'foo'/m, 'Prints config with new license key';
    };

    subtest 'Print to path' => sub {
        my $path = tempfile();

        is test('generate-config', 'foo', $path), '', 'Nothing to STDOUT';

        my $out = do {
            open my $fh, '<', $path or die;
            local $/, <$fh>;
        };

        like $out, qr/^# This file configures the unofficial New Relic Perl Agent/m,
            'Generates a config file';
        like $out, qr/^license_key: 'foo'/m, 'Prints config with new license key';
    };
};

subtest 'run-perl' => sub {
    require NewFangle::Agent;
    is test(qw( run-perl -Ilib -E ), 'say ">> $NewFangle::Agent::VERSION <<"'),
        ">> $NewFangle::Agent::VERSION <<\n",
        'Loaded NewFangle::Agent when running Perl';
};

subtest 'version' => sub {
    subtest 'Command' => sub {
        like test('version'), qr/newrelic-admin v/, 'Print version';
    };

    subtest 'Option' => sub {
        like test('--version'), qr/newrelic-admin v/, 'Print version';
    };
};

done_testing;

sub test {
    my @args = @_;
    my ( $out, $err, $ret ) = capture { system 'bin/newrelic-admin', @args };

    is $err, '', 'Nothing on STDERR';
    is $ret, 0,  'Exits without error';

    return $out
}
