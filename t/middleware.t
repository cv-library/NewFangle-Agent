use Test2::V0;
use Test2::Require::Module qw/Plack::Test/;
use Test2::Require::Module qw/Plack::Builder/;
use Test2::Require::Module qw/Plack::Middleware::ForceEnv/;
use Test2::Require::Module qw/HTTP::Request::Common/;
use Plack::Test;
use Plack::Builder;
use Plack::Middleware::NewFangle;
use HTTP::Request::Common;
use experimental 'signatures';

$ENV{NEWRELIC_ENABLED}     = 1;
$ENV{NEWRELIC_DAEMON_HOST} = '127.0.0.1:8000';
$ENV{NEWRELIC_APP_NAME}    = 'unit tests';

our ( $tx_name, %opts, %attr, @mocks );

push @mocks, mock 'NewFangle::App' => override => [
    new => sub {
        mock {} => add => [
            connected             => 1,
            start_web_transaction => sub ( $, $name ) {
                $tx_name = $name;
                mock {} => add => [
                    add_attribute_string => sub ( $, $k, $v ) {
                        $attr{$k} = $v;
                    },
                    add_attribute_int => sub ( $, $k, $v ) {
                        $attr{$k} = $v;
                    },
                    set_name => sub ( $, $v ) {
                        $tx_name = $v;
                    },
                ];
            },
        ];
    },
];

push @mocks, mock 'NewFangle::Agent::Config' => override => [
    struct => sub { +{} }
];

my $app     = sub { return [ 200, [], ['Hello, World!'] ] };
my $builder = Plack::Builder->new;
$builder->add_middleware( 'ForceEnv', newrelic => \%opts );
$builder->add_middleware('NewFangle');
my $test = Plack::Test->create( $builder->wrap($app) );

{
    local %attr;
    local $tx_name;

    my $res = $test->request( GET '/foo' );
    is $res->code,    200,             'HTTP GET successful';
    is $res->content, 'Hello, World!', 'HTTP GET returns content';
    is \%attr, {
        host   => 'localhost',
        method => 'GET',
        status => 200,
    }, 'Attributes are set';
    is $tx_name, '/foo', 'REQUEST_URI used as `transaction_name`';
}

{
    local $tx_name;
    local $opts{transaction_name} = '/foo/:placeholder';

    my $res = $test->request( GET '/foo/123' );
    is $res->code,    200,             'HTTP GET successful';
    is $res->content, 'Hello, World!', 'HTTP GET returns content';
    is $tx_name, '/foo/:placeholder',
        '$env{newrelic}{transaction_name} used as `transaction_name`';
}

done_testing;
