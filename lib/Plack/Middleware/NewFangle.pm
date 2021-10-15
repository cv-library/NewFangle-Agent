package Plack::Middleware::NewFangle;

use strict;
use warnings;

use experimental 'signatures';
use feature 'state';

use parent 'Plack::Middleware';
use Plack::Util::Accessor qw(
    start_transaction
      end_transaction

    start_non_web_transaction
      end_non_web_transaction
);

use NewFangle 'newrelic_init';
use NewFangle::Agent::Config;
use Scalar::Util 'weaken';

use namespace::clean;

our $VERSION = '0.003';

my %cache;

sub prepare_app ( $self ) {
    # This does not include the query parameters to avoid PII
    $self->{start_transaction} //= sub ( $app, $env ) {
        my $name = $env->{REQUEST_URI} =~ s/\?.*//r;

        my $tx = $app->start_web_transaction($name);

        $tx->add_attribute_string( host   => $env->{HTTP_HOST} );
        $tx->add_attribute_string( method => $env->{REQUEST_METHOD} );

        $tx;
    };

    $self->{end_transaction} //= sub ( $tx, $res ) {
        $tx->add_attribute_int( status => $res->[0] );
        $tx->end;
    };

    $self->{start_non_web_transaction} //= sub ( $app, $env ) {
        my $name = $env->{REQUEST_URI} =~ s/\?.*//r;
        $app->start_non_web_transaction($name);
    };

    $self->{end_non_web_transaction} //= sub ( $tx, $res ) {
        $tx->add_attribute_int( status => $res->[0] );
        $tx->end;
    };
}

sub call ( $self, $env ) {
    my $config      = NewFangle::Agent::Config->local_settings;
    my $per_request = $env->{newrelic}; # Per-request configuration

    return $self->app->($env)
        if !$config->{enabled} || $per_request->{ignore_transaction};

    local $NewFangle::Agent::TX;
    local $NewFangle::Agent::Trace = $NewFangle::Agent::Trace;

    if ( exists $per_request->{suppress_transaction_trace} ) {
        $NewFangle::Agent::Trace
            = 0 if $per_request->{suppress_transaction_trace}
    }

    my $name = $config->{app_name};
    my $app  = $cache{$name};

    unless ( $app && $app->connected ) {
        # Try to initialise a connection to the NewRelic daemon
        # only once to avoid a connection error
        state $init = do {
            die 'Missing host for New Relic daemon' unless $config->{daemon_host};
            newrelic_init $config->{daemon_host}, 100
        };

        $app = NewFangle::App->new( NewFangle::Agent::Config->struct, 100 );
    }

    if ( $app && $app->connected ) {
        # Cache existing connections
        $cache{$name} = $app;
    }
    else {
        warn 'Could not connect to NewRelic daemon';
        undef $app;
        delete $cache{$name};
    }

    # If the agent is not enabled, or we couldn't connect,
    # there's nothing else to do here
    return $self->app->($env) unless $app;

    my $web = $per_request->{set_background_task} ? 'non_web_' : '';

    my $start = $self->{"start_${web}transaction"};
    my $end   = $self->{  "end_${web}transaction"};

    my $tx = $NewFangle::Agent::TX = $app->$start($env);
    weaken $tx;

    my $res = $self->app->($env);

    return Plack::Util::response_cb(
        $res => sub ($res) {
            return unless $tx;
            $tx->$end($res);
        }
    );
}

1;
