# Security policy

## Reporting a vulnerability

Please report security vulnerabilities through GitHub's private
vulnerability reporting: open the **Security** tab on this repository
and choose **"Report a vulnerability"**. That channel is end-to-end
private between the reporter and the maintainers and creates a tracked
advisory once a fix lands.

Do not file vulnerabilities as public issues.

Include:

- a description of the vulnerability,
- the affected version (commit SHA or release tag),
- a proof-of-concept or reproducer, if you have one, and
- whether you intend to publish your own write-up, and on what
  timeline.

We will acknowledge receipt within five business days, and aim to
publish a fix and a coordinated disclosure within ninety days of the
report. If the issue is in a third-party Go module that the pairing
service depends on, we will route the report upstream and link your
write-up to the upstream advisory.

## Scope

In scope:

- the pairing-service HTTP handlers (`deposit`, `retrieve` packages)
- the installer-script templates served by the `retrieve` handlers
  (`retrieve/templates/`)
- the configuration loader
- the systemd unit shipped with the service

Out of scope:

- vulnerabilities in third-party Go modules that are not specific to
  how the pairing service uses them (report those upstream; we will
  track and patch promptly)
- weaknesses that require pre-existing administrator access to the
  host running the service
- self-hosted deployments operated by third parties — Proximile LLC is
  not responsible for those

The installer-template surface is particularly sensitive because the
templates are executed on the agent host as root after download. We
treat any issue that lets an unauthenticated party inject arbitrary
shell into a rendered installer as critical.

## What we are not interested in

- automated scanner output without a working PoC
- TLS or operational findings against any third-party host happening
  to run this service — only the source in this repository is in scope

## Coordinated disclosure

We follow standard coordinated disclosure: the reporter holds public
disclosure until either the fix has shipped, or 90 days have passed,
whichever comes first. If you need a faster timeline because the bug
is being actively exploited, say so in the initial report.

We will credit you in the advisory unless you ask us not to.
