# ProxiPort pairing service

[![Go Tests](https://img.shields.io/github/actions/workflow/status/proximile/proxiport-pairing/go_test.yml?branch=main&style=for-the-badge&label=Go%20Tests&logo=Go)](https://github.com/proximile/proxiport-pairing/actions/workflows/go_test.yml)
[![Lint](https://img.shields.io/github/actions/workflow/status/proximile/proxiport-pairing/lint.yml?branch=main&style=for-the-badge&label=Lint&logo=Go)](https://github.com/proximile/proxiport-pairing/actions/workflows/lint.yml)
[![License: AGPL v3](https://img.shields.io/badge/License-AGPL_v3-blue.svg?style=for-the-badge)](LICENSE)

A small HTTP service that lets a ProxiPort server hand out one-shot
installer scripts to brand-new agents. The operator deposits the
agent's credentials (connect URL, client id, password, server
fingerprint); the service returns a short pairing code; the agent host
curls `/<pairing-code>` and pipes the rendered installer into `sh` (or
PowerShell on Windows).

The deposited data lives in memory only, expires after five minutes,
and is consumed once.

This is a continuation of `openrport/rport-pairing` (in turn a fork of
the original CloudRadar `rport-pairing`). See [`NOTICE`](NOTICE) for
attribution and [`LICENSE-MIT`](LICENSE-MIT) for the inherited MIT
notice. The combined work is AGPL-3.0-or-later.

## Endpoints

| Method | Path             | Purpose                                          |
|--------|------------------|--------------------------------------------------|
| POST   | `/`              | Deposit credentials; receive a pairing code.    |
| GET    | `/<code>`        | Render the installer with those credentials.    |
| GET    | `/update`        | Render the update script (no credentials).      |
| GET    | `/uninstall`     | Render the uninstaller script (no credentials). |

Linux vs. Windows is dispatched off the `User-Agent` header — anything
matching `PowerShell` gets the `.ps1` rendering; everything else gets
the `.sh` rendering.

### Deposit

```bash
curl -X POST 'http://127.0.0.1:9090/' \
  -H 'Content-Type: application/json' \
  -d '{
        "connect_url":  "https://proxiport.example.com:8080",
        "fingerprint":  "2a:c4:79:04:80:ba:7c:60:05:e5:2c:49:6d:74:56:24",
        "client_id":    "myclient",
        "password":     "hunter2"
      }'
```

Response:

```json
{
  "pairing_code": "9L6fHH",
  "expires": "2026-05-13T11:39:04Z",
  "installers": {
    "linux":   "curl https://pairing.proxiport.net/9L6fHH > proxiport-installer.sh\nsudo sh proxiport-installer.sh",
    "windows": "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12\n$url=\"https://pairing.proxiport.net/9L6fHH\"\nInvoke-WebRequest -Uri $url -OutFile \"proxiport-installer.ps1\"\npowershell -ExecutionPolicy Bypass -File .\\proxiport-installer.ps1"
  }
}
```

### Pair (Linux)

```bash
curl https://pairing.proxiport.net/9L6fHH -o proxiport-installer.sh
sudo sh proxiport-installer.sh
```

### Pair (Windows)

```powershell
iwr https://pairing.proxiport.net/9L6fHH -OutFile proxiport-installer.ps1
.\proxiport-installer.ps1
```

### Update an existing agent

The update endpoint serves a script that fetches the latest agent
binary, replaces the on-disk binary, and restarts the service. No
prior deposit is needed — there are no credentials to embed.

```bash
curl https://pairing.proxiport.net/update -o proxiport-update.sh
sudo sh proxiport-update.sh
```

## Install and run your own

The pairing service is stateless and tiny — running your own copy is
cheap. On Debian/Ubuntu the easiest path is the `.deb` package from
the GitHub releases page (there is an `.rpm` too); it installs the
binary, the systemd unit, and the example config in one step:

```bash
VERSION=$(curl -fsS https://api.github.com/repos/proximile/proxiport-pairing/releases/latest | sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p')
curl -LO "https://github.com/proximile/proxiport-pairing/releases/download/v${VERSION}/proxiport-pairing_${VERSION}_linux_$(uname -m).deb"
sudo apt-get install ./proxiport-pairing_${VERSION}_linux_$(uname -m).deb
```

Or install by hand from the release tarball:

```bash
cd /tmp
curl -LO https://github.com/proximile/proxiport-pairing/releases/latest/download/proxiport-pairing_linux_$(uname -m).tar.gz
tar xf proxiport-pairing_linux_*.tar.gz
sudo mv proxiport-pairing /usr/local/bin/
sudo mkdir -p /etc/proxiport
sudo mv proxiport-pairing.conf.example /etc/proxiport/proxiport-pairing.conf
sudo mv proxiport-pairing.service /etc/systemd/system/
sudo useradd -r -s /usr/sbin/nologin proxiport || true
sudo systemctl daemon-reload
sudo systemctl enable --now proxiport-pairing
```

Edit `/etc/proxiport/proxiport-pairing.conf` to set the public URL
under which agents will see this service. Terminate TLS in front of
the service with a reverse proxy.

### Reverse proxy example (Caddy)

```caddyfile
pairing.example.com {
    reverse_proxy 127.0.0.1:9090
    log {
        output file /var/log/proxiport/proxiport-pairing.log
    }
}
```

## Develop locally

The build is plain `go build` — no CGO, no generated files.

```bash
go build ./cmd/proxiport-pairing
go test ./...
```

Run the service against the example config and exercise the endpoints
with the static `0000000` pairing code (defined in
`proxiport-pairing.conf.example`):

```bash
./proxiport-pairing -c proxiport-pairing.conf.example &
curl http://127.0.0.1:9090/0000000 -A "curl/8.0" -o /tmp/install.sh
shellcheck /tmp/install.sh
```

For the PowerShell installer:

```powershell
iwr "http://127.0.0.1:9090/0000000" -OutFile install.ps1
Invoke-ScriptAnalyzer -Path install.ps1
```

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md). Sensitive disclosures: see
[`SECURITY.md`](SECURITY.md).

## License

AGPL-3.0-or-later. See [`LICENSE`](LICENSE). The portions inherited
from `rport-pairing` retain their original MIT notice in
[`LICENSE-MIT`](LICENSE-MIT).
