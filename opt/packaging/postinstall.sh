#!/bin/sh
# Post-install hook for the proxiport-pairing deb and rpm packages.
# Reloads systemd and seeds the config from the example if no real
# config exists yet. POSIX shell.

set -e

install -d -o root -g root -m 0755 /etc/proxiport

if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload >/dev/null 2>&1 || true
fi

example="/etc/proxiport/proxiport-pairing.conf.example"
real="/etc/proxiport/proxiport-pairing.conf"
if [ -f "$example" ] && [ ! -f "$real" ]; then
    cp "$example" "$real"
    chmod 0640 "$real"
    chown root:proxiport "$real"
fi

cat <<'EOF'
ProxiPort pairing service installed.

Next steps:
  1. Edit /etc/proxiport/proxiport-pairing.conf (especially [server].url
     and the static-deposit section if you want a deterministic test
     code).
  2. Put a TLS-terminating reverse proxy in front (the daemon binds
     to 127.0.0.1:9090 by default).
  3. systemctl enable --now proxiport-pairing

See https://github.com/proximile/proxiport-pairing for details.
EOF

exit 0
