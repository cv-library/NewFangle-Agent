# ABSTRACT: Unofficial Perl New Relic agent
package NewFangle::Agent;

use strict;
use warnings;

use Devel::Peek;
use Hook::LexWrap;
use NewFangle::Agent::Config;
use Carp 'croak';

use constant {
    CRITICAL => 0,
    ERROR    => 1,
    WARNING  => 2,
    INFO     => 3,
    DEBUG    => 4,
    TRACE    => 5,
};

use namespace::clean;

my ( $done, %wrapped, $include, $exclude );

our $TX;    # The current NewFangle transaction
our $Trace; # Should this be traced

our $VERSION = '0.001';

# a log file location has been provided. Possible values, in
# increasing order of detail, are: "critical", "error", "warning",
# "info" and "debug". When reporting any agent issues to New

my $wrap = sub {
    my ( $arg, $log_level ) = @_;

    return
        # This is a pragma
        if lc($arg) eq $arg
        # This is a version number
        || $arg =~ /^\d/a;

    my $path = $INC{$arg} or return;

    my $package = $arg =~ s/\//::/gr;
    $package =~ s/\.p[ml]$//;

    return
        # Path not in include subset
        if ( $include && $path !~ $include )
        # Path in exclude subset
        || ( $exclude && $path =~ $exclude )
        # Ignore ourselves
        || $package =~ /^New(?:Fangle|Relic)/
        # TODO: Ignore modules that cause infinite recursion
        || $package =~ /^(?:Test2|B)/
        # Not a module name
        || $package =~ /^::/;

    my $subs = namespace::clean->get_functions($package);

    while ( my ( $subname, $coderef ) = each %$subs ) {
        my $fullname = "${package}::$subname";

        next
            # Skip import and unimport
            if $subname =~ /import$/
            # Skip uppercase functions
            || uc($subname) eq $subname
            # Skip "private" functions
            || $subname =~ /^_/
            # Skip functions we've already wrapped
            || $wrapped{$fullname};

        $wrapped{$fullname} = 1;

        # Skip imported functions.
        # See https://stackoverflow.com/a/3685262/807650
        if ( my $gv = Devel::Peek::CvGV( \&$coderef ) ) {
            my $source = *$gv{PACKAGE};
            if ( $source ne $package ) {
                warn "$package has dirty namespace ($subname)\n"
                    if $log_level >= DEBUG;

                next;
            }
        }

        if ( defined prototype $coderef ) {
            warn "Not wrapping $fullname because it has a prototype\n"
                if $log_level >= DEBUG;

            next;
        }

        my @segments;
        Hook::LexWrap::wrap(
            $fullname => (
                pre => sub {
                    warn "Calling $fullname" if $log_level >= TRACE;

                    return unless $Trace && $TX;

                    #                                      category
                    #                                              \
                    push @segments, $TX->start_segment( $fullname, '' );
                },
                post => sub {
                    warn "Called $fullname" if $log_level >= TRACE;

                    return unless $Trace && $TX;

                    my $segment = pop @segments or return;
                    $segment->end;
                },
            ),
        );

        warn "Wrapped $fullname\n" if $log_level >= TRACE;
    }
};

sub import {
    croak 'NewFangle::Agent takes no import options' if @_ > 1;

    return if $done;

    $done = 1;
    my $config = NewFangle::Agent::Config->global_settings;

    $Trace //= $config->{transaction_tracer}{enabled};

    # If the agent is disabled, or transaction tracing is not enabled,
    # there is no need to wrap functions on require, and we can return.
    return unless $config->{enabled}
        && $config->{transaction_tracer}{enabled};

    my $log_level = $config->{log_level} // 0;

    if ( my @list = map quotemeta, @{ $config->{transaction_tracer}{exclude} // [] } ) {
        $exclude = '^(:?' . join( '|', @list ) . ')';
        warn "Exclude: $exclude\n" if $log_level >= DEBUG;
        $exclude = qr/$exclude/;
    }

    if ( my @list = map quotemeta, @{ $config->{transaction_tracer}{include} // [] } ) {
        $include = '^(:?' . join( '|', @list ) . ')';
        warn "Include: $include\n" if $log_level >= DEBUG;
        $include = qr/$include/;
    }

    # Wrap everything that might have been loaded before we were
    $wrap->( $_, $log_level ) for keys %INC;

    # Much of the dark arts that follow comes from
    # https://metacpan.org/pod/Lexical::SealRequireHints
    my $next_require = defined &CORE::GLOBAL::require
        ? \&CORE::GLOBAL::require
        : sub {
            my ($arg) = @_;
            # The shenanigans with $CORE::GLOBAL::{require} are required
            # because if there's a &CORE::GLOBAL::require when the eval is
            # executed (compiling the CORE::require it contains) then the
            # CORE::require in there is interpreted as plain require on
            # some Perl versions, leading to recursion.
            my $grequire = $CORE::GLOBAL::{require};
            delete $CORE::GLOBAL::{require};

            my $requirer = eval qq{
                package @{[scalar(caller(0))]};
                sub { scalar(CORE::require(\$_[0])) };
            };

            $CORE::GLOBAL::{require} = $grequire;
            return scalar( $requirer->($arg) );
        };

    *CORE::GLOBAL::require = sub ($) {
        die "wrong number of arguments to require\n"
            unless @_ == 1;

        my ($arg) = @_;

        # Some reference to $next_require is required at this level of
        # subroutine so that it will be closed over and hence made
        # available to the string eval.
        my $nr = $next_require;
        my $requirer = eval qq{
            package @{[scalar(caller(0))]};
            sub { scalar(\$next_require->(\$_[0])) };
        };

        my $ret = scalar $requirer->($arg);

        $wrap->( $arg, $log_level );

        return $ret;
    };
}

1;
