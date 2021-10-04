# NAME

NewFangle::Agent - Unofficial Perl New Relic agent

# SYNOPSIS

    # Point NEWRELIC_CONFIG_FILE to your config file
    # See NewFangle::Agent::Config for details

    use NewFangle;
    use NewFangle::Agent;  # Anywhere in your code

    ...

    # Elsewhere in your code
    my $app = NewFangle::App->new;
    local $NewFangle::Agent::TX = $app->start_web_transaction( ... );

# DESCRIPTION

NewFangle::Agent is an unofficial monitoring agent for New Relic. It is used
to make it easier to instrument the New Relic integration in your application.

When this module is first imported, it goes through every loaded module
looking for relevant functions, and installs monitoring hooks around them
so that a [NewFangle::Segment](https://metacpan.org/pod/NewFangle%3A%3ASegment) is started when the function is called, and
ended when the function returns (see below for ways in which this can be
customised).

It also modifies the module loading mechanism so that this logic gets executed
on any module loaded after this point.

## Adjusting the monitoring segments

The New Relic API supports several types of monitoring segments, which can
hold different type of metadata that is useful for monitoring.

This module ships with code to detect some well-known functions and start
the appropriate tracking segment to record that activity. Specifically,
this includes

- [HTTP::Tiny::request](https://metacpan.org/pod/HTTP%3A%3ATiny#request)

    Will start an [external segment](https://metacpan.org/pod/NewFangle%3A%3ATransaction#start_external_segment).

- [LWP::UserAgent::request](https://metacpan.org/pod/LWP%3A%3AUserAgent#request)

    Will start an [external segment](https://metacpan.org/pod/NewFangle%3A%3ATransaction#start_external_segment).

- [DBI::st::execute](https://metacpan.org/pod/DBI#execute)

    Will start a [datastore segment](https://metacpan.org/pod/NewFangle%3A%3ATransaction#start_datastore_segment).

The code that starts these segments is generated with the `generate_segment_starter`
function, described in more detail [below](#generate_segment_starter).

# FUNCTIONS

## generate\_segment\_starter

    $coderef = NewFangle::Agent::generate_segment_starter( $package, $subname );

Returns a code ref that will be called whenever the specified subroutine is
called. The code reference should _always_ return a [NewFangle::Segment](https://metacpan.org/pod/NewFangle%3A%3ASegment)
object.

If `generate_segment_starter` returns an undefined value, a default tracking
segment will be started instead.

This function can be overriden in subclasses that want to modify the default
wrapping in NewFangle::Agent, but it is recommended that you still delegate
to the version shipped to catch any remaining cases.

See ["Adjusting the monitoring segments"](#adjusting-the-monitoring-segments) above for a discussion of this
process.

## install\_wrappers

    NewFangle::Agent::install_wrappers( $package );

Installs the hooks to start tracking segments before the relevant function
calls in the specified package. This function can be called manually to load
a sub-package that would otherwise not be automatically picked up.

# CONFIGURATION

## Global configuration

NewFangle::Agent reads its configuration from [NewFangle::Agent::Configuration](https://metacpan.org/pod/NewFangle%3A%3AAgent%3A%3AConfiguration).
See the documentation for that module to see where that configuration is read
from.

Only some of the fields are relevant for this particular package:

`enabled` controls whether the agent as a whole is turned on or not. If this is
false, importing NewFangle::Agent is a no-op.

`transaction_tracer.enabled` controls whether transaction traces are being
captured. If they are not, then there is no need to wrap tracking segments
around function calls, so importing NewFangle::Agent is a no-op.

The code in NewFangle::Agent does output some logging of its own, which is
controlled by `log_level`. Set the level to at least debug to see output.

The sections under `transaction_tracer.include` and
`transaction_tracer.exclude` make it possible to tweak the heuristics used
to determine what code is relevant for monitoring. Refer to
[the relevant documentation](https://metacpan.org/pod/NewFangle%3A%3AAgent%3A%3AConfig#include-exclude)
for more details.

## Runtime configuration

The flags described above control the behaviour of NewFangle::Agent at compile
time to install the tracking wrappers.

The wrappers themselves rely on two package variables, that are expected to be
localised in your application (see [Plack::Middleware::NewFangle](https://metacpan.org/pod/Plack%3A%3AMiddleware%3A%3ANewFangle) for one
possible approach to this).

The `$TX` variable should hold the current [NewFangle::Transaction](https://metacpan.org/pod/NewFangle%3A%3ATransaction) object.
If no transaction is currently defined, the wrappers return without doing
anything.

The `$Trace` variable controls whether tracing is locally enabled or not. If
not set on import, its initial value will depend on the value read from the
global config.

# CAVEATS

## Everything happens at compile time

Since everything that NewFangle::Agent does happens at compile time, all the
data that influences that logic needs itself to be available at compile time.

In practice, this means that if the agent is imported when the agent is
disabled, enabling it, or modifying any of the configuration values at a later
point will have no effect on the agent code.

## Everything happens only once

A corollary of the point above is that everything NewFangle::Agent does is
done on first import. After this, importing the module again becomes a no-op.

## Functions are searched for in imported packages

If you have multiple packages in the same file, such that importing one
will make the other one available as well, only the functions in the package
that was imported will be found. If you need the functions in the other
package to be monitored as well, you'll have to load it explicitly.

Note that any packages that are loaded inside the loaded module will not
need any special attention: they will be caught as part of the regular
process.

## Function discovery relies on compile-time name resolution

The discovery of the functions to be wrapped uses
[namespace::clean](https://metacpan.org/pod/namespace%3A%3Aclean#Late-binding-caveat), and is therefore
subject to the same limitations described in that module's documentation.

## This module does evil things

As the astute reader might have guessed by now, this module does nasty things
with both the globally available `require` function and _the symbol table
in all the code that is ever loaded_. As such, it can get into some dicey
situations.

For best results, try to limit the amount of code covered to the smallest
amount that is valuable, and make sure things work well for your use case
before letting this touch any production environment.

## Performance costs

Although the code in this module will have to touch every relevant function
in the symbol table, that will only affect startup times.

The wrapping code that executes before and after each function does of course
have a performance cost, which adds a couple of milliseconds
_per function call_. This means that code paths with deeper call stacks, or
with many long-running loops, will be most affected.

More testing needs to be done by this module's author to determine exactly
what that impact is. Until then, testing on your local environment is the
best way to decide whether that cost is too much.

# SEE ALSO

- [NewFangle](https://metacpan.org/pod/NewFangle)
- [NewFangle::Agent::Config](https://metacpan.org/pod/NewFangle%3A%3AAgent%3A%3AConfig)
- [Plack::Middleware::NewFangle](https://metacpan.org/pod/Plack%3A%3AMiddleware%3A%3ANewFangle)

# COPYRIGHT AND LICENSE

Copyright 2021 CV-Library Ltd.

This library is free software; you can redistribute it and/or modify it under
the Artistic License 2.0.
