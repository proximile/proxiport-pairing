#!/usr/bin/env bash
#
# Asserts that the pairing daemon does not share an account with the ProxiPort
# server, against the real maintainer scripts.
#
# The pairing service is internet-facing and stateless: it binds to localhost
# behind a reverse proxy, mints one-shot installer scripts, and reads one
# config file. While it ran as `proxiport` -- shared with proxiportd by its own
# preinstall's admission -- compromising it on a co-hosted box gave read of
# /etc/proxiport/proxiportd.conf (jwt_secret, key_seed) and read/write on every
# database, the vault and the ACME key cache under /var/lib/proxiport.
#
# Needs root and a throwaway filesystem, so it runs itself inside a container
# unless it is already root. It never skips.

set -euo pipefail

IMAGE="${PAIRING_ACCOUNT_TEST_IMAGE:-debian:bookworm}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

failures=0
fail() { printf '  FAIL  %s\n' "$*"; failures=$((failures + 1)); }
pass() { printf '  ok    %s\n' "$*"; }

if [ "$(id -u)" -ne 0 ]; then
    if ! command -v docker >/dev/null 2>&1; then
        echo "account_test: needs root or docker; refusing to skip." >&2
        exit 1
    fi
    echo "account_test: re-running as root inside $IMAGE"
    exec docker run --rm -v "$REPO_ROOT":/src:ro -w /src "$IMAGE" \
        bash /src/opt/packaging/account_test.sh
fi

SRC="$REPO_ROOT"

# The ProxiPort server's account and its secrets, as its own package creates
# them. This is the thing the pairing daemon must not be able to reach.
groupadd --system proxiport
useradd --system --gid proxiport --home-dir /var/lib/proxiport \
        --shell /usr/sbin/nologin --comment "ProxiPort server user" proxiport
install -d -o proxiport -g proxiport -m 0750 /var/lib/proxiport
install -d -o root -g root -m 0755 /etc/proxiport
printf 'jwt_secret = "SECRET"\nkey_seed = "SEED"\n' > /etc/proxiport/proxiportd.conf
chown root:proxiport /etc/proxiport/proxiportd.conf
chmod 0640 /etc/proxiport/proxiportd.conf
printf 'db\n' > /var/lib/proxiport/vault.db
chown proxiport:proxiport /var/lib/proxiport/vault.db
chmod 0600 /var/lib/proxiport/vault.db

# The pairing package's payload and scriptlets.
install -d /usr/bin /lib/systemd/system
cp "$SRC/proxiport-pairing.conf.example" /etc/proxiport/proxiport-pairing.conf.example
cp "$SRC/opt/systemd/proxiport-pairing.service" /lib/systemd/system/proxiport-pairing.service
sh "$SRC/opt/packaging/preinstall.sh"
sh "$SRC/opt/packaging/postinstall.sh" >/dev/null 2>&1

unit_user="$(sed -n 's/^User=//p' /lib/systemd/system/proxiport-pairing.service | head -1)"

if [ "$unit_user" = "proxiport" ]; then
    fail "the pairing daemon runs as the ProxiPort server's account"
else
    pass "the pairing daemon runs as $unit_user, not the server's proxiport"
fi

if ! getent passwd "$unit_user" >/dev/null 2>&1; then
    fail "preinstall did not create $unit_user, so the unit cannot start"
else
    pass "preinstall created $unit_user"
fi

for secret in /etc/proxiport/proxiportd.conf /var/lib/proxiport/vault.db; do
    if su -s /bin/sh "$unit_user" -c "cat '$secret' >/dev/null 2>&1"; then
        fail "$unit_user can read $secret"
    else
        pass "$unit_user cannot read $secret"
    fi
done

if su -s /bin/sh "$unit_user" -c "touch /var/lib/proxiport/.probe 2>/dev/null"; then
    fail "$unit_user can write the ProxiPort server's data directory"
    rm -f /var/lib/proxiport/.probe
else
    pass "$unit_user cannot write the ProxiPort server's data directory"
fi

# ... and it can still read the config it is there to read.
if su -s /bin/sh "$unit_user" -c "cat /etc/proxiport/proxiport-pairing.conf >/dev/null 2>&1"; then
    pass "$unit_user can read its own config"
else
    fail "$unit_user cannot read /etc/proxiport/proxiport-pairing.conf"
fi

printf '\n'
if [ "$failures" -ne 0 ]; then
    printf '%d assertion(s) failed\n' "$failures"
    exit 1
fi
printf 'pairing account: all assertions passed\n'
