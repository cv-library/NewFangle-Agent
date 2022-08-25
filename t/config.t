use Test2::V0;

use File::Share 'dist_file';
use NewFangle::Agent::Config;

subtest 'Config file from environment' => sub {
    local $ENV{NEWRELIC_CONFIG_FILE} = dist_file 'NewFangle-Agent', 'test.yml';

    NewFangle::Agent::Config::initialize;

    like +NewFangle::Agent::Config->global_settings => {
        enabled     => T,
        license_key => 'DEADBEEF',
        app_name    => 'Perl Application',
        log_level   => 'error',
        transaction_tracer => {
            enabled => 1,
            include => {
                paths => [
                    't/lib',
                ],
            },
        }
    };
};

subtest 'New Relic environment override' => sub {
    local $ENV{NEWRELIC_CONFIG_FILE}  = dist_file 'NewFangle-Agent', 'test.yml';
    local $ENV{NEWRELIC_ENVIRONMENT}  = 'environment';

    NewFangle::Agent::Config->initialize; # Can call as class method

    my $global = NewFangle::Agent::Config->global_settings;

    is $global->{license_key}, 'eu01xxdeadbeefdeadbeefdeadbeefdeadbeNRAL',
        'Environment overwrites config';

    is +NewFangle::Agent::Config->local_settings, $global,
        'Unchanged local settings same as global';

    $global->{app_name} = 'Fake name';
    is +NewFangle::Agent::Config->local_settings->{app_name}, 'Perl Application',
        'Config is read-only';

    is +NewFangle::Agent::Config->struct->to_perl,
        NewFangle::Config->new(
            app_name         => 'Perl Application',
            license_key      => 'eu01xxdeadbeefdeadbeefdeadbeefdeadbeNRAL',
            log_level        => 'info',
            log_filename     => 'stderr',
            transaction_tracer => {
                duration_us => 50_000,
            },
            datastore_tracer => {
                database_name_reporting => 0,
                instance_reporting      => 0,
            },
        )->to_perl,
        'Can generate a C-based version of config';
};

subtest 'Environment variables override global config' => sub {
    {
        local $ENV{NEWRELIC_CONFIG_FILE}  = dist_file 'NewFangle-Agent', 'test.yml';
        local $ENV{NEWRELIC_ENVIRONMENT}  = 'environment';

        subtest 'Defined override' => sub {
            local $ENV{NEWRELIC_LOG_LEVEL} = 'warning';
            NewFangle::Agent::Config->initialize; # Re-read global config
            is +NewFangle::Agent::Config->global_settings->{log_level},
                warning => 'Global settings are overriden';
        };

        subtest 'Undefined value is ignored' => sub {
            local $ENV{NEWRELIC_LOG_LEVEL};
            NewFangle::Agent::Config->initialize; # Re-read global config
            is +NewFangle::Agent::Config->global_settings->{log_level},
                info => 'Undefined value is ignored';
        };

        subtest 'False value is read' => sub {
            local $ENV{NEWRELIC_LOG_LEVEL} = '';
            like warnings {
                NewFangle::Agent::Config->initialize; # Re-read global config
            } => [
                qr/^Unrecognised log level in config:/,
            ];

            is +NewFangle::Agent::Config->global_settings->{log_level},
                error => 'Unknown log level resets to default';
        };
    }

    # Re-set back to what it was
    NewFangle::Agent::Config->initialize; # Re-read global config
    is +NewFangle::Agent::Config->global_settings->{log_level}, 'error';
};

subtest 'Environment variables override local config' => sub {
    my $global  = NewFangle::Agent::Config->global_settings;
    my $enabled = $global->{enabled} ? 1 : 0;

    is +NewFangle::Agent::Config->local_settings,
        { %$global, enabled => $enabled }, 'Initial state';

    # Flip once
    local $ENV{NEWRELIC_ENABLED} = $enabled = $enabled ? 0 : 1;

    is +NewFangle::Agent::Config->local_settings,
        { %$global, enabled => $enabled }, 'State changed';

    # Flip back
    $ENV{NEWRELIC_ENABLED} = $enabled = $enabled ? 0 : 1;

    is +NewFangle::Agent::Config->local_settings,
        { %$global, enabled => $enabled }, 'State changed back';
};

done_testing;
