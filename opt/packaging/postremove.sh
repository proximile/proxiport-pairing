#!/bin/sh
# Post-remove hook for the proxiport-pairing deb and rpm packages.
# Reloads systemd so the disappeared unit does not show up as masked.
# Leaves /etc/proxiport in place — the operator wipes it after a
# deliberate purge.

set -e

if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload >/dev/null 2>&1 || true
fi

exit 0
