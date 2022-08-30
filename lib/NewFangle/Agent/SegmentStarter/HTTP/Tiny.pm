package NewFangle::Agent::SegmentStarter::HTTP::Tiny;

use strict;
use warnings;
use experimental 'signatures';

use namespace::clean;

our $VERSION = '0.011';

sub build ( $class, $method ) {
    return sub {
        $NewFangle::Agent::TX->start_external_segment([
            $_[2] =~ s/\?.*//r, # URL minus query parameters
            uc $_[1],
            'HTTP::Tiny',
        ]);
    } if $method eq 'request';

    return;
}

1;
