# ABSTRACT: Unofficial Perl New Relic agent
package NewFangle::Agent;

use strict;
use warnings;
use experimental 'signatures';

use Devel::Peek;
use Class::Load 'load_optional_class';
use NewFangle::Agent::Wrapper; # As a temporary fork of Hook::LexWrap
use NewFangle::Agent::Config;
use Carp 'croak';

use constant {
    CRITICAL  => 0,
    ERROR     => 1,
    WARNING   => 2,
    INFO      => 3,
    DEBUG     => 4,
    TRACE     => 5,
    LOG_LEVEL => NewFangle::Agent::Config->global_settings->{log_level} // 0,
};

use constant {
    IS_CRITICAL => LOG_LEVEL >= CRITICAL,
    IS_ERROR    => LOG_LEVEL >= ERROR,
    IS_WARNING  => LOG_LEVEL >= WARNING,
    IS_INFO     => LOG_LEVEL >= INFO,
    IS_DEBUG    => LOG_LEVEL >= DEBUG,
    IS_TRACE    => LOG_LEVEL >= TRACE,
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
);

our $TX;    # The current NewFangle transaction
our $Trace; # Should this be traced

our $VERSION = '0.011';

my $parse_includes = sub {
    my ( $type, $config ) = @_;

    my ( $paths, $subroutines, $subpackages );

    my $input = $config->{transaction_tracer}{$type} or return;

    if ( my @list = @{ $input->{paths} // [] } ) {
        $paths = '^(:?' . join( '|', map quotemeta, @list ) . ')';
        $paths = qr/$paths/;

        if ( IS_DEBUG ) {
            warn ucfirst($type) . " paths:\n";
            warn "- $_\n" for @list;
        }
    }

    if ( my %map = %{ $input->{subroutines} // {} } ) {
        while ( my ( $k, $v ) = each %map ) {
            @{ $subroutines->{$k} }{ @$v } = 1;
        }

        if ( IS_DEBUG ) {
            warn ucfirst($type) . " subroutines:\n";
            for my $k ( sort keys %{ $subroutines } ) {
                warn "- ${k}::$_\n" for sort keys %{ $subroutines->{$k} };
            }
        }
    }

    if ( my %map = %{ $input->{subpackages} // {} } ) {
        while ( my ( $k, $v ) = each %map ) {
            @{ $subpackages->{$k} }{ @$v } = 1;
        }

        if ( IS_DEBUG ) {
            warn ucfirst($type) . " subpackages:\n";
            for my $k ( sort keys %{ $subpackages } ) {
                warn "- ${k}:\n";
                warn "  - $_\n" for sort keys %{ $subpackages->{$k} };
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
        $include_paths && $path !~ $include_paths and do {
            warn "Skipping $package because it is not in include paths\n" if IS_TRACE;
            return;
        };

        $exclude_paths && $path =~ $exclude_paths and do {
            warn "Skipping $package because it is in exclude paths\n" if IS_TRACE;
            return;
        };

        $package =~ /^New(?:Fangle|Relic)/ and do {
            warn "Skipping $package because it is ourselves\n" if IS_TRACE;
            return;
        };

        # TODO
        $package =~ /^(?:B|Exporter|Test2|Plack|XSLoader)(?:::|$)/ and do {
            warn "Skipping $package because it is not currently supported\n" if IS_TRACE;
            return;
        };

        $package =~ /^::/ and do {
            warn "Skipping $package because it is not a package\n" if IS_TRACE;
            return;
        };
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
            warn "Including $fullname explicitly" if IS_TRACE;
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
            if ( my $gv = Devel::Peek::CvGV($coderef) ) {
                if ( *$gv{PACKAGE} ne $package ) {
                    warn "$package has dirty namespace ($subname)\n" if IS_TRACE;
                    next;
                }
            }

            if ( defined prototype $coderef ) {
                warn "Not wrapping $fullname because it has a prototype\n" if IS_TRACE;
                next;
            }
        }

        $wrapped{$fullname} = 1;

        my $starter;
        {
            my $class = qq{NewFangle::Agent::SegmentStarter::$package};
            if ( load_optional_class $class ) {
                my $sub = $class->can('build')
                    or die "$class does not implement build";
                $starter = $class->$sub($subname);
            }
        }
        $starter //= sub { $TX->start_segment( $fullname, '' ) };

        my $segment;
        NewFangle::Agent::Wrapper::wrap(
            $fullname => (
                pre => sub {
                    print STDERR "Calling $fullname\n" if IS_TRACE;

                    return unless $Trace && $TX;

                    $segment = $starter->(@_);
                },
                post => sub {
                    print STDERR "Called $fullname\n" if IS_TRACE;

                    # Since the segment ends on destruction, we can
                    # undefine it unconditionally. This is always safe
                    undef $segment;
                },
            ),
        );

        warn "Wrapped $fullname\n" if IS_TRACE;
    }
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

    if ( IS_DEBUG ) {
        print STDERR "Loading New Relic agent\n";
        print STDERR "See https://github.com/cv-library/NewFangle-Agent for details\n";
    }

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

    *CORE::GLOBAL::require = sub :prototype($) {
        die "wrong number of arguments to require\n" unless @_ == 1;

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
