package NewFangle::Agent::SegmentStarter::LWP::UserAgent;

use strict;
use warnings;
use experimental 'signatures';

use namespace::clean;

our $VERSION = '0.007';

sub build ( $class, $method ) {
    return sub {
        $NewFangle::Agent::TX->start_external_segment([
            $_[1]->url =~ s/\?.*//r, # URL minus query parameters
            uc $_[1]->method,
            'LWP::UserAgent',
        ]);
    } if $method eq 'request';

    return;
}

1;
