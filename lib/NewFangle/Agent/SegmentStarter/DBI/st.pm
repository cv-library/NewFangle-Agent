package NewFangle::Agent::SegmentStarter::DBI::st;

use strict;
use warnings;
use experimental 'signatures';
use feature qw/state/;

use namespace::clean;

our $VERSION = '0.007';

sub build ( $class, $method ) {
    return sub {
        my ($sth) = @_;
        my $dbh   = $sth->{Database};
        my $name  = $dbh->{Name};

        state %meta;

        my $info = $meta{$name} //= do {
            my %meta = ( driver => $dbh->{Driver}{Name} );

            ( $meta{host}     ) = $name =~     /host=([^;]+)/;
            ( $meta{database} ) = $name =~ /database=([^;]+)/;

            \%meta;
        };

        # Driver-specific metadata
        my $collection;
        if ( $info->{driver} eq 'MySQL' ) {
            $collection = join ',', @{ $sth->{mysql_table} };
        }

        my $statement = $sth->{Statement};
        my ($operation) = $statement =~ /^\W*?(\S+)/;

        return $NewFangle::Agent::TX->start_datastore_segment([
            $info->{driver}   // '',
            $collection       // '',
            $operation        // '',
            $info->{host}     // '',
            $info->{path}     // '',
            $info->{database} // '',
            $statement        // '',
        ]);
    } if $method eq 'execute';

    return;
}

1;
