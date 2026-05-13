# Contributing to the ProxiPort pairing service

Thanks for considering a contribution. This document covers licensing,
what kinds of contributions are welcome, and the mechanics of sending a
patch.

## Licensing of contributions

The ProxiPort pairing service is **AGPL-3.0-or-later** (see
[`LICENSE`](LICENSE)). Upstream MIT-licensed code that this repository
inherits from `rport-pairing` retains its original MIT notice in
[`LICENSE-MIT`](LICENSE-MIT).

By submitting a pull request, issue, patch, or other contribution you
agree that your contribution will be licensed under AGPL-3.0-or-later
as part of the combined work. We do **not** require a separate CLA: the
inbound = outbound principle (your code is contributed under the same
licence as the project) is sufficient.

If a piece of code you contribute also carries an additional permissive
licence (MIT, Apache-2.0, BSD, etc.) you may keep that file's original
header; the combined work remains AGPL.

## What we are looking for

- **Bug reports** with reproducers — file as issues on this repository.
- **Code review and patches** for the Go service or for the installer
  templates under `retrieve/templates/`.
- **Distro packaging** for systems other than the ones the maintainer
  ships natively.
- **Hardening** of the systemd unit shipped with the service.
- **Documentation** improvements.

## Out of scope

A few things that won't get merged regardless of how good the PR is:

- Features whose only purpose is to gate functionality behind a paid
  licence. ProxiPort intentionally has no edition split.
- Restoring the upstream tacoscript install path or similar
  RealVNC/openrport-era tool integrations that were deliberately
  removed in the fork.

For everything else, open an issue first if the change is non-trivial
so we can sanity-check the direction before you spend time on a patch.

## How to send a contribution

1. Open an issue describing the change, unless it is trivial.
2. Fork, branch, push, open a PR against `main`.
3. Sign your commits (`git commit -s`) so the DCO trailer is present.
4. Run `go vet ./...` and `go test ./...` locally before pushing. CI
   runs the same checks.

For sensitive disclosures see [`SECURITY.md`](SECURITY.md).

## Contact

Open an issue on this repository. For private vulnerability reports use
the GitHub Security Advisories flow described in
[`SECURITY.md`](SECURITY.md).
