#!/usr/bin/env perl

use Test2::V0;
use lib 't/lib';
use File::Share 'dist_file';

BEGIN {
    $ENV{NEWRELIC_CONFIG_FILE} = dist_file 'NewFangle-Agent', 'test.yml';
}

use Local::Use; # Loaded before the agent

use NewFangle::Agent;

require Local::Require; # Loaded after the agent

my @segments;
package Fake::Segment {
    sub new     { bless { name => $_[1], category => $_[2] } }
    sub DESTROY { push @segments => { %{ +shift } } }
}

my $tx = mock {} => add => [
    start_segment => sub { shift; Fake::Segment->new(@_) },
];

{
    local $NewFangle::Agent::TX;
    local $NewFangle::Agent::Trace;
    Local::Use::parent(     1, 2, 3 );
    Local::Require::parent( 1, 2, 3 );
}

is \@segments, [], 'No tracing when no transaction defined';

{
    local $NewFangle::Agent::TX = $tx;
    local $NewFangle::Agent::Trace;
    Local::Use::parent(     1, 2, 3 );
    Local::Require::parent( 1, 2, 3 );
}

is \@segments, [], 'Not traced when tracing is disabled';

{
    local $NewFangle::Agent::TX    = $tx;
    local $NewFangle::Agent::Trace = 1;
    Local::Use::parent(     1, 2, 3 );
    Local::Require::parent( 1, 2, 3 );
}

is \@segments, [
    { name => 'Local::Use::child',      category => '' },
    { name => 'Local::Use::parent',     category => '' },
    { name => 'Local::Require::child',  category => '' },
    { name => 'Local::Require::parent', category => '' },
], 'Traced when transaction and tracing is enabled';

done_testing;
