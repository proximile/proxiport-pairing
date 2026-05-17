#!/bin/sh
# Pre-install hook for the proxiport-pairing deb and rpm packages.
# Creates the unprivileged `proxiport` system user and group used by
# the pairing daemon. POSIX shell — runs under dpkg and rpm scriptlets.
# Shared user with the main proxiport / proxiportd packages, so this
# is a no-op if either of those is already installed.

set -e

if ! getent group proxiport >/dev/null 2>&1; then
    if command -v groupadd >/dev/null 2>&1; then
        groupadd --system proxiport
    elif command -v addgroup >/dev/null 2>&1; then
        addgroup --system proxiport
    fi
fi

if ! getent passwd proxiport >/dev/null 2>&1; then
    if command -v useradd >/dev/null 2>&1; then
        useradd --system --gid proxiport \
                --home-dir /var/lib/proxiport \
                --shell /usr/sbin/nologin \
                --comment "ProxiPort daemon user" \
                proxiport
    elif command -v adduser >/dev/null 2>&1; then
        adduser --system --ingroup proxiport \
                --home /var/lib/proxiport \
                --shell /usr/sbin/nologin \
                --gecos "ProxiPort daemon user" \
                proxiport
    fi
fi

exit 0
