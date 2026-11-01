<!--
Release description format for wireguard.

Versioning: releases are tagged X.Y.Z (semantic versioning, no "v" prefix;
the git tag and the Docker image tag are the same string, and CI refuses a
tag that is not MAJOR.MINOR.PATCH with an optional -prerelease suffix such
as 1.1.0-rc1). Bump the minor version for new variables, behavior changes,
base-image or WireGuard upgrades and larger documentation work; the patch
version for a release that only carries security or bug fixes.

Usage: create the GitHub release for the tag, copy this template into the
description and fill it in. "Generate release notes" (.github/release.yml)
can be used to seed the categorized sections with the merged PR list -
rewrite the entries in user-facing wording, as in past releases. Delete any
section that has no content. The release process is documented in the wiki
(Building and CI page).

The release.yml categories use the same section titles as this template.
Two have no section of their own: "Security" items go under Package Updates
(or Fixes) and make the summary lead with the security sentence; "Breaking
changes" are described in Upgrade notes.
-->

One or two sentences: what this release is about and why to upgrade.
Security updates lead with **Security update — upgrading is recommended.**

### 📥 Pull this release

```bash
docker pull azinchen/wireguard:X.Y.Z
docker pull ghcr.io/azinchen/wireguard:X.Y.Z
```

Multi-arch: `386`, `amd64`, `arm/v6`, `arm/v7`, `arm64`, `riscv64`. `latest` follows this release.

### ⬆️ Upgrade notes

<!-- Only when action is required or behavior changes: renamed/removed
variables, changed defaults, new variables that are off unless set, new
peers-file options. Otherwise: "No action required — no variables, defaults
or behavior changed." Deep-link the wiki page for anything new. -->

### ✨ Features

<!-- One entry per feature, bold lead naming the feature and its variable,
then what it does and how it fails, ending with a wiki link, e.g.:
- **TTL / hop-limit normalization (`TTL_SET`).** What it does, defaults, failure
  behavior. See [Gateway Mode — TTL normalization](https://github.com/azinchen/wireguard/wiki/Gateway-Mode#ttl-normalization). (#PR)
-->

- ... (#PR)

### 🐛 Fixes

- ... (#PR)

### 📦 Package Updates

<!-- Alpine / s6-overlay / APK pin bumps. Security bumps link their CVEs or
advisories and say what the package does in this image (and whether it is
build-stage only). Plain bumps are one line, e.g.:
- Bump wireguard-tools 1.0.20250521-r0 → 1.0.20260223-r0 ([upstream changelog](https://git.zx2c4.com/wireguard-tools/log/)) (#PR)
- Bump Alpine Linux 3.24.2 → 3.24.3 — security release: fixes [CVE-XXXX-YYYY](https://avd.aquasec.com/nvd/cve-xxxx-yyyy) in musl ([announcement](https://alpinelinux.org/posts/...)) (#PR)
- Bump curl 8.22.0-r0 → 8.23.0-r0 — fixes [nine CVEs](https://curl.se/docs/vuln-8.22.0.html); curl runs the health-check egress probes (#PR)
- Bump s6-overlay 3.2.3.0 → 3.2.3.2 (#PR)
-->

### 📖 Documentation

- ... (#PR)

### 🔧 CI/CD Updates

<!-- GitHub Actions bumps, one line per action, collapsing the Dependabot
PRs for the same action into one entry, e.g.:
- Bump `github/codeql-action` from 4.38.2 to 4.39.0 (#PR, #PR)
-->

### 🧩 Component versions

| Component | Version |
|---|---|
| wireguard-tools (`wg`) | A.B.C |
| wireguard-go (userspace fallback) | A.B.C |
| Alpine Linux | X.Y.Z |
| s6-overlay | D.E.F.G |

### Contributors

<!-- Add @dependabot when the release includes its PRs. -->

@azinchen

**Full Changelog**: https://github.com/azinchen/wireguard/compare/PREV_TAG...X.Y.Z
