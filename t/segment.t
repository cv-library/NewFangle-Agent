use Test2::V0;
use lib 't/lib';

require NewFangle::Agent::SegmentStarter::Foo;
require NewFangle::Agent::SegmentStarter::Bar;
require NewFangle::Agent::SegmentStarter::HTTP::Tiny;
require NewFangle::Agent::SegmentStarter::LWP::UserAgent;
require NewFangle::Agent::SegmentStarter::DBI::st;

package Foo { sub foo {} };
package Bar { sub bar {} };
package Baz { sub baz {} };

use NewFangle::Agent;

{
    my $mock = local $NewFangle::Agent::TX = mock {} => add => [
         start_segment => sub { shift->{segment} = \@_ },
    ];

    NewFangle::Agent::install_wrappers('Foo'); # uses custom starter
    Foo->foo(qw/1 2 3/);
    is $mock->{segment}, ['Foo::foo', [qw/1 2 3/]], 'Foo::foo uses custom starter';

    like dies { NewFangle::Agent::install_wrappers('Bar') },
        qr/does not implement build/, 'die when build is not implemented';

    NewFangle::Agent::install_wrappers('Baz'); # uses default starter
    Baz->baz;
    is $mock->{segment}, ['Baz::baz', ''], 'Baz::baz uses default starter';
}

{
    my $class = 'NewFangle::Agent::SegmentStarter::HTTP::Tiny';
    my $mock = local $NewFangle::Agent::TX
        = mock {} => add => [ start_external_segment => 'rw' ];
    ok my $sub = $class->build('request'), 'custom starter for HTTP::Tiny::request';
    HTTP::Tiny->$sub( 'get', 'https://example.com?foo=1' );
    like $mock->start_external_segment,
        [qw[https://example.com GET HTTP::Tiny]], 'external segment has correct params';
}

{
    my $class = 'NewFangle::Agent::SegmentStarter::LWP::UserAgent';
    my $mock = local $NewFangle::Agent::TX
        = mock {} => add => [ start_external_segment => 'rw' ];
    ok my $sub = $class->build('request'), 'custom starter for LWP::UserAgent::request';
    my $req = mock {} => add =>
        [ url => sub {'https://example.com?foo=1'}, method => 'get' ];
    LWP::UserAgent->$sub($req);
    like $mock->start_external_segment,
        [qw[https://example.com GET LWP::UserAgent]], 'external segment has correct params';
}

{
    my $class = 'NewFangle::Agent::SegmentStarter::DBI::st';
    my $mock = local $NewFangle::Agent::TX
        = mock {} => add => [ start_datastore_segment => 'rw' ];
    ok my $sub = $class->build('execute'), 'custom starter for DBI::st::execute';
    my %sth = (
        Statement => 'SELECT * FROM products',
        Database  => {
            Name   => 'dbi;MySQL;database=test;host=localhost',
            Driver => { Name => 'MySQL', },
        },
        mysql_table => [qw/foo bar baz/],
    );
    $sub->( \%sth );
    like $mock->start_datastore_segment, [
        'MySQL', 'foo,bar,baz', 'SELECT', 'localhost', '', 'test',
        'SELECT * FROM products',
    ], 'datastore segment has correct params';
}

done_testing;
