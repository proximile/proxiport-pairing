#!/bin/sh
# Pre-install hook for the proxiport-pairing deb and rpm packages.
# Creates the unprivileged `proxiport-pairing` system user and group the
# pairing daemon runs as. POSIX shell — runs under dpkg and rpm scriptlets.
#
# This account is the pairing service's alone. It used to be `proxiport`,
# shared with the ProxiPort server and agent packages, which meant that
# compromising the internet-facing pairing service on a co-hosted box gave
# read of /etc/proxiport/proxiportd.conf (jwt_secret, key_seed) and read/write
# on every database, the vault and the ACME key cache under /var/lib/proxiport.
# The pairing daemon needs none of that: it is stateless, binds to localhost,
# and reads one config file.

set -e

if ! getent group proxiport-pairing >/dev/null 2>&1; then
    if command -v groupadd >/dev/null 2>&1; then
        groupadd --system proxiport-pairing
    elif command -v addgroup >/dev/null 2>&1; then
        addgroup --system proxiport-pairing
    fi
fi

if ! getent passwd proxiport-pairing >/dev/null 2>&1; then
    if command -v useradd >/dev/null 2>&1; then
        useradd --system --gid proxiport-pairing \
                --home-dir /nonexistent \
                --shell /usr/sbin/nologin \
                --comment "ProxiPort pairing service user" \
                proxiport-pairing
    elif command -v adduser >/dev/null 2>&1; then
        adduser --system --ingroup proxiport-pairing \
                --home /nonexistent --no-create-home \
                --shell /usr/sbin/nologin \
                --gecos "ProxiPort pairing service user" \
                proxiport-pairing
    fi
fi

exit 0
