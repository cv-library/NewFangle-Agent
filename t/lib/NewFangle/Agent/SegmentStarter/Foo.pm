package NewFangle::Agent::SegmentStarter::Foo;

require NewFangle::Agent;
use experimental qw/signatures/;

sub build ( $class, $method ) {
    return sub {
        $NewFangle::Agent::TX->start_segment("Foo::$method" => [qw/1 2 3/])
    } if $method eq 'foo';

    return;
}

1;
