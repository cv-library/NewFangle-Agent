# ABSTRACT: Unofficial Perl New Relic agent
package NewFangle::Agent;

use strict;
use warnings;
use feature 'state';
use experimental 'signatures';

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

my (
    $done,                # Have we already been imported?
    %wrapped,             # Keep track of what has already been wrapped
    $include_paths,       # Paths that we are including
    $exclude_paths,       # Paths that we are excluding
    $include_subroutines, # Included subroutines. Keys are package names
    $exclude_subroutines, # Excluded subroutines. Keys are package names
    $include_subpackages, # Included subpackages. Keys are package names
    $exclude_subpackages, # Excluded subpackages. Keys are package names
    $log_level,           # The verbosity of the code
);

our $TX;    # The current NewFangle transaction
our $Trace; # Should this be traced

our $VERSION = '0.001';

my $parse_includes = sub {
    my ( $type, $config ) = @_;

    my ( $paths, $subroutines, $subpackages );

    my $input = $config->{transaction_tracer}{$type} or return;

    if ( my @list = @{ $input->{paths} // [] } ) {
        $paths = '^(:?' . join( '|', map quotemeta, @list ) . ')';
        $paths = qr/$paths/;

        if ( $log_level >= DEBUG ) {
            warn ucfirst($type) . " paths:\n";
            warn "* $_\n" for @list;
        }
    }

    if ( my %map = %{ $input->{subroutines} // {} } ) {
        while ( my ( $k, $v ) = each %map ) {
            @{ $subroutines->{$k} }{ @$v } = 1;
        }

        if ( $log_level >= DEBUG ) {
            warn ucfirst($type) . " subroutines:\n";
            for my $k ( sort keys %{ $subroutines } ) {
                warn "* ${k}::$_\n" for sort keys %{ $subroutines->{$k} };
            }
        }
    }

    if ( my %map = %{ $input->{subpackages} // {} } ) {
        while ( my ( $k, $v ) = each %map ) {
            @{ $subpackages->{$k} }{ @$v } = 1;
        }

        if ( $log_level >= DEBUG ) {
            warn ucfirst($type) . " subpackages:\n";
            for my $k ( sort keys %{ $subpackages } ) {
                warn "* ${k}::$_\n" for sort keys %{ $subpackages->{$k} };
            }
        }
    }

    return ( $paths, $subroutines, $subpackages )
};

my $wrap = sub ($filename) {
    return
        # This is a pragma
        if lc($filename) eq $filename
        # This is a version number
        || $filename =~ /^\d/a;

    my $path = $INC{$filename} or return;

    my $package = $filename =~ s/\//::/gr;
    $package =~ s/\.p[ml]$//;

    if ( $include_subpackages->{$package} ) {
        # If this package has any subpackages that we are interested
        # in wrapping, wrap those as well
        install_wrappers($_) for keys %{ $include_subpackages->{$package} // {} };
    }

    # If we are specifically including any subroutine in this
    # package, then we cannot skip it wholesale
    unless ( $include_subroutines->{$package} ) {
        return
            # Path not in include path subset
            if ( $include_paths && $path !~ $include_paths )
            # Path in exclude path subset
            || ( $exclude_paths && $path =~ $exclude_paths )
            # Ignore ourselves
            || $package =~ /^New(?:Fangle|Relic)/
            # TODO: Ignore modules that cause infinite recursion
            || $package =~ /^(?:Test2|B)/
            # Not a module name
            || $package =~ /^::/;
    }

    install_wrappers($package);
};

sub install_wrappers ($package) {
    my $subs = namespace::clean->get_functions($package);

    while ( my ( $subname, $coderef ) = each %$subs ) {
        my $fullname = "${package}::$subname";

        # Skip functions we've already wrapped
        next if $wrapped{$fullname};

        # If we are explicitly including this subroutine
        # none of the other checks matter
        if ( $include_subroutines->{$package}{$subname} ) {
            warn "Including $fullname explicitly" if $log_level >= TRACE;
        }
        else {
            # Otherwise, perform all other additional checks
            next
                # Skip packages we only included for some subs
                if %{ $include_subroutines->{$package} // {} }
                # Skip import and unimport
                || $subname =~ /^(?:un)?import$/
                # Skip uppercase functions
                || uc($subname) eq $subname
                # Skip "private" functions
                || $subname =~ /^_/
                # Skip subroutines we are excplictly excluding
                || $exclude_subroutines->{$package}{$subname};

            # Skip imported functions.
            # See https://stackoverflow.com/a/3685262/807650
            if ( my $gv = Devel::Peek::CvGV( \&$coderef ) ) {
                my $source = *$gv{PACKAGE};
                if ( $source ne $package ) {
                    warn "$package has dirty namespace ($subname)\n"
                        if $log_level >= TRACE;

                    next;
                }
            }

            if ( defined prototype $coderef ) {
                warn "Not wrapping $fullname because it has a prototype\n"
                    if $log_level >= TRACE;

                next;
            }
        }

        $wrapped{$fullname} = 1;

        my $starter = generate_segment_starter( $package, $subname );
        $starter //= sub {
            #                      category
            #                              \
            $TX->start_segment( $fullname, '' );
        };

        my @segments;
        Hook::LexWrap::wrap(
            $fullname => (
                pre => sub {
                    print STDERR "Calling $fullname\n" if $log_level >= TRACE;

                    return unless $Trace && $TX;

                    push @segments, $starter->(@_);
                },
                post => sub {
                    print STDERR "Called $fullname\n" if $log_level >= TRACE;

                    return unless $Trace && $TX;

                    my $segment = pop @segments or return;
                    $segment->end;
                },
            ),
        );

        warn "Wrapped $fullname\n" if $log_level >= TRACE;
    }
}

sub generate_segment_starter ( $package, $subname ) {
    my $fullname = "${package}::${subname}";

    return sub {
        $TX->start_external_segment([
            "$_[1]" =~ s/\?.*//r, # URL minus query parameters
            $subname,
            $package,
        ]);
    } if $fullname eq 'HTTP::Tiny::request';

    return sub {
        $TX->start_external_segment([
            "$_[0]->url" =~ s/\?.*//r, # URL minus query parameters
            $subname,
            $package,
        ]);
    } if $fullname eq 'LWP::UserAgent::request';

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

        return $TX->start_datastore_segment([
            $info->{driver}   // '',
            $collection       // '',
            $operation        // '',
            $info->{host}     // '',
            $info->{path}     // '',
            $info->{database} // '',
            $statement        // '',
        ]);
    } if $fullname eq 'DBI::st::execute';

    return;
}

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

    $log_level = $config->{log_level} // 0;

    ( $include_paths, $include_subroutines, $include_subpackages ) = $parse_includes->( include => $config );
    ( $exclude_paths, $exclude_subroutines, $exclude_subpackages ) = $parse_includes->( exclude => $config );

    # Wrap everything that might have been loaded before we were
    $wrap->($_) for keys %INC;

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

        $wrap->($arg);

        return $ret;
    };
}

1;
