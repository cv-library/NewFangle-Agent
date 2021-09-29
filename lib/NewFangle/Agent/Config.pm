package NewFangle::Agent::Config;

use strict;
use warnings;

use experimental 'signatures';

use YAML::XS 'LoadFile';
use Hash::Merge 'merge';
use Scalar::Util 'dualvar';
use NewFangle;
use Storable 'dclone';
use Carp 'croak';

use namespace::clean;

my ( $config );

my $defaults = {
    enabled      => 0,
    log_filename => 'stderr',
    log_level    => 'error',
    distributed_tracing => {
        enabled => 0,
    },
    transaction_tracer => {
        enabled               => 1,
        threshold             => 'is_apdex_failing',
        stack_trace_threshold => 0.5,
        duration              => 0,
        datastore_reporting   => {
            record_sql => 'obfuscated',
            enabled    => 1,
            threshold  => 0.5,
        },
        include => {
            subpackages => {
                DBI => [qw(
                    DBI::st
                )],
            },
            subroutines => {
                'HTTP::Tiny' => [qw(
                    request
                )],
                'LWP::UserAgent' => [qw(
                    request
                )],
                'DBI::st' => [qw(
                    execute
                )],
            },
        },
    },
};

my %environment = (
    NEWRELIC_APP_NAME    => 'app_name',
    NEWRELIC_LICENSE_KEY => 'license_key',
    NEWRELIC_LOG_FILE    => 'log_filename',
    NEWRELIC_LOG_LEVEL   => 'log_level',
    NEWRELIC_ENABLED     => 'enabled',
);

my $set_log = sub {
    for ( $_[0]->{log_level} ) {
        my $name = lc;

           if ( $name eq 'error'   ) { $_ = dualvar( 1 => $name ) }
        elsif ( $name eq 'warning' ) { $_ = dualvar( 2 => $name ) }
        elsif ( $name eq 'info'    ) { $_ = dualvar( 3 => $name ) }
        elsif ( $name eq 'debug'   ) { $_ = dualvar( 4 => $name ) }
        else {
            warn "Unrecognised log level in config: $_";
            delete $_[0]->{log_level};
        }
    }

    $_[0]->{log_level} //= dualvar( 1 => 'error' );

    $_[0];
};

sub import {
    return if $config;
    shift;
    goto &initialize;
}

sub initialize {
    shift if $_[0] && $_[0] eq __PACKAGE__;
    my %args = @_;

    $args{config_file} //= $ENV{NEWRELIC_CONFIG_FILE};
    $args{environment} //= $ENV{NEWRELIC_ENVIRONMENT};

    # Initialise with defaults
    $config = $defaults;

    # Merge with config file
    $config = merge( LoadFile( $args{config_file} ), $config )
        if $args{config_file};

    # Merge with current environment
    $config = merge(
        $config->{environments}{ $args{environment} } // {},
        $config,
    ) if $args{environment};

    # Merge with environment variables
    while ( my ( $k, $v ) = each %environment ) {
        $config->{$v} = $ENV{$k} if $ENV{$k};
    }

    delete $config->{environments};

    $config->$set_log;

    1;
}

sub global_settings {
    croak 'New Relic agent config has not been initialized' unless $config;

    dclone($config)->$set_log;
}

sub local_settings {
    croak 'New Relic agent config has not been initialized' unless $config;

    my $local = dclone $config;

    # Merge with environment variables
    while ( my ( $k, $v ) = each %environment ) {
        $local->{$v} = $ENV{$k} if $ENV{$k};
    }

    $local->$set_log;
}

sub struct {
    shift if $_[0] && $_[0] eq __PACKAGE__;
    my %args = @_;

    my $agent = $args{global} ? global_settings() : local_settings();
    my $tx    = $agent->{transaction_tracer};

    if ( my $seconds = delete $tx->{duration} ) {
        $tx->{duration_us} = $seconds * 1_000_000;
    }

    if ( my $seconds = delete $tx->{stack_trace_threshold} ) {
        $tx->{stack_trace_threshold_us} = $seconds * 1_000_000;
    }

    if ( my $seconds = delete $tx->{datastore_reporting}{threshold} ) {
        $tx->{datastore_reporting}{threshold_us} = $seconds * 1_000_000;
    }

    delete $agent->{enabled};

    delete $tx->{include};
    delete $tx->{exclude};

    # Silence warnings in FFI::CStructDef about falsy empty strings
    $agent->{datastore_tracer}{database_name_reporting}        ||= 0;
    $agent->{datastore_tracer}{instance_reporting}             ||= 0;
    $agent->{distributed_tracing}{enabled}                     ||= 0;
    $agent->{transaction_tracer}{datastore_reporting}{enabled} ||= 0;
    $agent->{transaction_tracer}{enabled}                      ||= 0;

    NewFangle::Config->new( %$agent );
}

1;
