#!/usr/bin/env bash
#
# Exercises the RENDERED Linux installer -- the script this service hands to a
# brand-new agent -- inside a container, and asserts the account and the
# directories it ends up with.
#
# This is not the deb/rpm scriptlet test (account_test.sh); it is the
# `curl | sh` path, which creates its own account and its own directories and
# had no harness at all. The agent executes operator-supplied commands as its
# own uid, so an agent that lands in the ProxiPort SERVER's account is inside
# the server's trust boundary on any host carrying both.
#
# Two scenarios, both against the real templates:
#
#   fresh   a host with the ProxiPort server installed. The installer must
#           create its OWN account and must not be able to read the server's
#           config or databases.
#   legacy  a host where an earlier installer already put the agent in the
#           `proxiport` account. The installer must LEAVE IT THERE -- moving a
#           running agent out of its own directories is worse than the
#           exposure -- and must say so out loud.
#
# Needs root and a throwaway filesystem, so it runs itself inside a container
# unless it is already root. It never skips: no root and no docker is exit 1,
# not a pass.

set -euo pipefail

IMAGE="${PAIRING_INSTALLER_TEST_IMAGE:-debian:bookworm}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCENARIO="${PAIRING_INSTALLER_TEST_SCENARIO:-}"

failures=0
fail() { printf '  FAIL  %s\n' "$*"; failures=$((failures + 1)); }
pass() { printf '  ok    %s\n' "$*"; }

if [ "$(id -u)" -ne 0 ]; then
    if ! command -v docker >/dev/null 2>&1; then
        echo "linux_installer_test: needs root or docker; refusing to skip." >&2
        exit 1
    fi
    rc=0
    for scenario in fresh legacy uninstall; do
        echo "linux_installer_test: scenario '$scenario' in $IMAGE"
        docker run --rm -v "$REPO_ROOT":/src:ro -w /src \
            -e "PAIRING_INSTALLER_TEST_SCENARIO=$scenario" "$IMAGE" \
            bash /src/opt/packaging/linux_installer_test.sh || rc=1
        printf '\n'
    done
    exit "$rc"
fi

if [ -z "$SCENARIO" ]; then
    echo "linux_installer_test: PAIRING_INSTALLER_TEST_SCENARIO is not set." >&2
    exit 1
fi

SRC="$REPO_ROOT"
WORK=/tmp/installer-test
rm -rf "$WORK"; mkdir -p "$WORK"

# ---------------------------------------------------------------------------
# Prerequisites. The installer needs curl to download and to probe the server;
# busybox gives us an HTTP server and pgrep without dragging in python.
# ---------------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
if ! apt-get update -qq >/dev/null 2>&1 \
   || ! apt-get install -y -qq --no-install-recommends curl busybox >/dev/null 2>&1; then
    echo "linux_installer_test: could not install curl/busybox; refusing to skip." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Render the installer exactly as the service does.
#
# The file list is read out of installerHandler.go's default branch rather than
# copied here, so adding a template to the renderer cannot silently leave this
# harness testing an older script.
# ---------------------------------------------------------------------------
# render <handler.go> <must-contain> <output>
render() {
    _handler="$SRC/retrieve/$1"; _must="$2"; _out="$3"
    _templates=$(awk '/default:/{inside=1} inside && /^\t}/{exit} inside' "$_handler" \
                 | grep -o 'templates/[A-Za-z0-9_./-]*' || true)
    if [ -z "$_templates" ]; then
        echo "linux_installer_test: could not read the template list out of" >&2
        echo "linux_installer_test: $1 -- refusing to guess." >&2
        exit 1
    fi
    if ! printf '%s\n' "$_templates" | grep -q "$_must"; then
        echo "linux_installer_test: $1's template list does not contain $_must:" >&2
        printf '%s\n' "$_templates" >&2
        exit 1
    fi
    : > "$_out"
    for _t in $_templates; do
        cat "$SRC/retrieve/$_t" >> "$_out"
        printf '\n' >> "$_out"
    done
    # The four deposit fields Go interpolates. Fixtures, not secrets.
    sed -i \
        -e 's|{{ .Fingerprint}}|aa:bb:cc:dd:ee:ff:00:11:22:33:44:55:66:77:88:99|' \
        -e "s|{{ .ConnectUrl}}|http://127.0.0.1:8099|" \
        -e 's|{{ .ClientId}}|11111111-1111-4111-8111-111111111111|' \
        -e 's|{{ .Password}}|fixture-password|' \
        "$_out"
    if grep -q '{{' "$_out"; then
        echo "linux_installer_test: unsubstituted template fields remain in $_out:" >&2
        grep -n '{{' "$_out" >&2
        exit 1
    fi
}

RENDERED="$WORK/proxiport-installer.sh"
UNINSTALLER="$WORK/proxiport-uninstaller.sh"
render installerHandler.go  templates/linux/install.sh   "$RENDERED"
render uninstallHandler.go  templates/linux/uninstall.sh "$UNINSTALLER"

# ---------------------------------------------------------------------------
# A stub release: the installer downloads a tar.gz over HTTP with -z, unpacks
# `proxiport` and `proxiport.example.conf`, runs `--version`, and then asks the
# binary to install a service unit. The stub does all of that and records the
# account it was told to use, which is the thing under test.
# ---------------------------------------------------------------------------
mkdir -p "$WORK/pkg" "$WORK/srv"
cat > "$WORK/pkg/proxiport" <<'STUB'
#!/bin/sh
# Stub ProxiPort agent. Implements only what the installer calls.
case "$1" in
  --version) echo "proxiport 0.9.0"; exit 0 ;;
esac
svc_user=""
config=""
while [ $# -gt 0 ]; do
  case "$1" in
    --service-user) svc_user="$2"; shift 2 ;;
    --config)       config="$2";   shift 2 ;;
    *)              shift ;;
  esac
done
mkdir -p /etc/systemd/system
cat > /etc/systemd/system/proxiport.service <<UNIT
[Unit]
Description=ProxiPort agent (stub)
[Service]
ExecStart=/usr/local/bin/proxiport -c ${config}
User=${svc_user}
Group=${svc_user}
[Install]
WantedBy=multi-user.target
UNIT
printf '%s\n' "$config" > /run/pp-stub-config
exit 0
STUB
chmod 0755 "$WORK/pkg/proxiport"
cat > "$WORK/pkg/proxiport.example.conf" <<'CONF'
[client]
  server = "http://127.0.0.1:8099"
  #auth = "user:password"
  #fingerprint = ""
  #id = ""
  use_system_id = true
  #name = ""
  #tags = []
  #attributes_file_path = "/var/lib/proxiport-agent/client_attributes.(yaml|json|toml)"
  #data_dir = "/var/lib/proxiport-agent"

[logging]
  #log_file = 'C:\Program Files\proxiport\proxiport.log'
  log_file = "/var/log/proxiport-agent/proxiport.log"
  log_level = "info"

[remote-commands]
  #enabled = true
  #allow = ['^/usr/bin/.*']
  #deny = []

[remote-scripts]
  #enabled = false

[monitoring]
  enabled = true
CONF
ARCH=$(uname -m)
tar -C "$WORK/pkg" -czf "$WORK/srv/proxiport_0.9.0_linux_${ARCH}.tar.gz" \
    proxiport proxiport.example.conf

# busybox httpd serves the tarball AND answers the installer's reachability
# probe, so CONNECT_URL and the package URL are the same origin.
busybox httpd -p 127.0.0.1:8099 -h "$WORK/srv"
sleep 1
curl -fsS -o /dev/null "http://127.0.0.1:8099/proxiport_0.9.0_linux_${ARCH}.tar.gz" \
  || { echo "linux_installer_test: the stub HTTP server did not come up." >&2; exit 1; }

# ---------------------------------------------------------------------------
# Stubs for the things a container does not have. systemctl records what it
# was asked to do and, on `start`, writes the clean log that check_log reads --
# otherwise the installer reports a failed install for reasons that have
# nothing to do with what is being tested.
# ---------------------------------------------------------------------------
mkdir -p /usr/local/sbin
cat > /usr/local/sbin/systemctl <<'SYSCTL'
#!/bin/sh
echo "systemctl $*" >> /run/pp-systemctl.log
if [ "$1" = "start" ]; then
  conf=$(cat /run/pp-stub-config 2>/dev/null || true)
  if [ -n "$conf" ] && [ -e "$conf" ]; then
    log=$(sed -n 's/^[[:space:]]*log_file[[:space:]]*=[[:space:]]*"\(.*\)"$/\1/p' "$conf" | head -1)
    if [ -n "$log" ]; then
      mkdir -p "$(dirname "$log")"
      echo "client started, connected" >> "$log"
    fi
  fi
fi
exit 0
SYSCTL
# The agent is "running"; the SERVER is not. Both matter: start_proxiport and
# verify_and_terminate need `pidof proxiport` / `pgrep proxiport` to succeed,
# and uninstall() refuses to do anything at all when `pgrep proxiportd` does --
# a stub that answered 0 to everything made the uninstall scenario pass
# vacuously by never running.
cat > /usr/local/sbin/pidof <<'PIDOF'
#!/bin/sh
case "$1" in
  proxiportd) exit 1 ;;
  proxiport)  exit 0 ;;
  *)          exit 1 ;;
esac
PIDOF
cp /usr/local/sbin/pidof /usr/local/sbin/pgrep
chmod 0755 /usr/local/sbin/systemctl /usr/local/sbin/pidof /usr/local/sbin/pgrep
export PATH="/usr/local/sbin:$PATH"

# ---------------------------------------------------------------------------
# Scenario fixtures.
# ---------------------------------------------------------------------------
install -d -o root -g root -m 0755 /etc/proxiport
groupadd --system proxiport
useradd --system --gid proxiport --home-dir /var/lib/proxiport \
        --shell /usr/sbin/nologin --comment "ProxiPort server user" proxiport
install -d -o proxiport -g proxiport -m 0750 /var/lib/proxiport
printf 'jwt_secret = "SECRET"\nkey_seed = "SEED"\n' > /etc/proxiport/proxiportd.conf
chown root:proxiport /etc/proxiport/proxiportd.conf
chmod 0640 /etc/proxiport/proxiportd.conf
printf 'db\n' > /var/lib/proxiport/vault.db
chown proxiport:proxiport /var/lib/proxiport/vault.db
chmod 0600 /var/lib/proxiport/vault.db

if [ "$SCENARIO" = "legacy" ] || [ "$SCENARIO" = "uninstall" ]; then
    # An agent this installer put here before the split: same account as the
    # server, its own unit, its state under the server's data dir.
    mkdir -p /etc/systemd/system
    cat > /etc/systemd/system/proxiport.service <<'OLDUNIT'
[Unit]
Description=ProxiPort agent
[Service]
ExecStart=/usr/local/bin/proxiport -c /etc/proxiport/proxiport.conf
User=proxiport
Group=proxiport
OLDUNIT
    install -d -o proxiport -g root -m 0700 /var/lib/proxiport/scripts
    printf '[client]\n  server = "http://127.0.0.1:8099"\n' > /etc/proxiport/proxiport.conf
    chown proxiport:root /etc/proxiport/proxiport.conf
fi

# ---------------------------------------------------------------------------
# Run the real installer. -p forces the tar.gz path, -z points it at the stub
# release, -x turns on command execution so the scripts directory is created.
# ---------------------------------------------------------------------------
set +e
sh "$RENDERED" -p -x -z "http://127.0.0.1:8099/proxiport_0.9.0_linux_${ARCH}.tar.gz" \
   > "$WORK/install.log" 2>&1
install_rc=$?
set -e
if [ "$install_rc" -ne 0 ]; then
    echo "linux_installer_test: the installer exited $install_rc:" >&2
    tail -40 "$WORK/install.log" >&2
    exit 1
fi

unit_user="$(sed -n 's/^User=//p' /etc/systemd/system/proxiport.service | head -1)"
[ -n "$unit_user" ] || { echo "no User= in the installed unit" >&2; exit 1; }
printf '  agent account: %s\n' "$unit_user"

# ---------------------------------------------------------------------------
# Assertions.
# ---------------------------------------------------------------------------
as_agent_can_read() { su -s /bin/sh "$1" -c "cat '$2' >/dev/null 2>&1"; }
as_agent_can_write_dir() { su -s /bin/sh "$1" -c "touch '$2/.probe' 2>/dev/null"; }

if [ "$SCENARIO" = "fresh" ]; then
    if [ "$unit_user" = "proxiport" ]; then
        fail "the agent was installed into the ProxiPort server's account"
    else
        pass "the agent runs as $unit_user, not the server's proxiport"
    fi

    getent passwd "$unit_user" >/dev/null \
        && pass "the installer created $unit_user" \
        || fail "$unit_user does not exist, so the unit cannot start"

    for secret in /etc/proxiport/proxiportd.conf /var/lib/proxiport/vault.db; do
        if as_agent_can_read "$unit_user" "$secret"; then
            fail "$unit_user can read $secret"
        else
            pass "$unit_user cannot read $secret"
        fi
    done

    if as_agent_can_write_dir "$unit_user" /var/lib/proxiport; then
        fail "$unit_user can write the server's data directory"
        rm -f /var/lib/proxiport/.probe
    else
        pass "$unit_user cannot write the server's data directory"
    fi

    for d in "/var/lib/$unit_user" "/var/log/$unit_user"; do
        if [ -d "$d" ]; then
            pass "$d exists"
        else
            fail "$d was not created, so the agent has nowhere to write"
        fi
    done

    if as_agent_can_read "$unit_user" /etc/proxiport/proxiport.conf; then
        pass "$unit_user can read its own config"
    else
        fail "$unit_user cannot read /etc/proxiport/proxiport.conf"
    fi

    if grep -qE "^${unit_user}[[:space:]]" /etc/sudoers.d/* 2>/dev/null; then
        pass "the sudoers rules name $unit_user"
    elif ls /etc/sudoers.d/proxiport* >/dev/null 2>&1; then
        fail "sudoers rules exist but do not name $unit_user"
    else
        pass "no sudoers rules were written (sudo is absent in this image)"
    fi
elif [ "$SCENARIO" = "uninstall" ]; then
    # The destructive path. `curl .../uninstall | sudo sh` used to rm -rf
    # /etc/proxiport -- which holds proxiportd.conf -- and delete the
    # `proxiport` account and /var/lib/proxiport, which hold every database,
    # the vault and the ACME key cache. Removing the AGENT must not touch any
    # of the server's anything.
    set +e
    sh "$UNINSTALLER" > "$WORK/uninstall.log" 2>&1
    uninstall_rc=$?
    set -e
    if [ "$uninstall_rc" -ne 0 ]; then
        echo "linux_installer_test: the uninstaller exited $uninstall_rc:" >&2
        tail -30 "$WORK/uninstall.log" >&2
        exit 1
    fi

    for survivor in /etc/proxiport/proxiportd.conf /var/lib/proxiport/vault.db; do
        if [ -e "$survivor" ]; then
            pass "$survivor survived the agent uninstall"
        else
            fail "the agent uninstall deleted $survivor"
        fi
    done
    if getent passwd proxiport >/dev/null; then
        pass "the server's proxiport account survived"
    else
        fail "the agent uninstall deleted the server's proxiport account"
    fi
    if [ -e /etc/proxiport/proxiport.conf ]; then
        fail "the agent's own config was left behind"
    else
        pass "the agent's own config was removed"
    fi
    if [ -e /usr/local/bin/proxiport ]; then
        fail "the agent binary was left behind"
    else
        pass "the agent binary was removed"
    fi
else
    if [ "$unit_user" = "proxiport" ]; then
        pass "an existing agent install keeps its account ($unit_user)"
    else
        fail "the installer moved an existing agent from proxiport to $unit_user"
    fi
    if [ -d /var/lib/proxiport/scripts ]; then
        pass "the existing agent kept its scripts directory"
    else
        fail "the existing agent's scripts directory is gone"
    fi
    if grep -qi "proxiport.*server" "$WORK/install.log" \
       || grep -qi "shares the ProxiPort server" "$WORK/install.log"; then
        pass "the installer warned that the account is shared with the server"
    else
        fail "the installer kept the shared account without saying so"
    fi
fi

printf '\n'
if [ "$failures" -ne 0 ]; then
    printf '%d assertion(s) failed in scenario %s\n' "$failures" "$SCENARIO"
    exit 1
fi
printf 'linux installer (%s): all assertions passed\n' "$SCENARIO"
