# Security policy

## Reporting a vulnerability

Please do not open a public issue. Report it privately through GitHub's
**Report a vulnerability** button on the repository's Security tab
(private vulnerability reporting). Include what you found, how to
reproduce it, and the versions affected.

You will get an acknowledgement within a few days. A confirmed issue is
fixed on the latest release first, and disclosed in a GitHub security
advisory once a fix is available.

## Scope

Stoic runs inside apps, so what matters most is anything that lets input an
app does not control — a configuration file, a network response, a document
from disk — crash the app, exhaust its memory or threads, read or write
outside what it was given, or leak values marked private into events, logs
or diagnostics.

## Supported versions

Before 1.0, only the latest release receives fixes.
