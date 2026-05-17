#!/bin/sh
# Pre-remove hook for the proxiport-pairing deb and rpm packages.
# Stops and disables the systemd unit if present.

set -e

if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-enabled proxiport-pairing.service >/dev/null 2>&1; then
        systemctl disable --now proxiport-pairing.service >/dev/null 2>&1 || true
    fi
fi

exit 0
