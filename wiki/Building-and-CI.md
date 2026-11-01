# Building and CI

How the image is built, published and released. Useful for contributors; nothing here is needed to run the container.

## Building locally

```bash
git clone https://github.com/azinchen/wireguard.git
cd wireguard
docker build -t wireguard:local .
```

The build needs network access (it downloads the s6-overlay release tarballs and Alpine packages). Build arguments:

| ARG | Default | Purpose |
|---|---|---|
| `ALPINE_VERSION` | pinned in Dockerfile | Base image for every stage |
| `PACKAGEVERSION` | pinned in Dockerfile | s6-overlay release |
| `IMAGE_VERSION` / `BUILD_DATE` | `N/A` | Baked into the OCI labels and `backend-functions` (shown in the startup banner) by CI |

Multi-arch:

```bash
docker buildx build --platform linux/amd64,linux/arm64 -t wireguard:local .
```

The build stages are described in [Architecture and Internals](Architecture-and-Internals#multi-stage-build).

## WireGuard: Alpine packages, no wg-quick

The image installs WireGuard from Alpine packages rather than building anything from source:

- `wireguard-tools-wg` — the bare `wg` binary. The image creates interfaces with `ip` + `wg setconf` and reloads peers with `wg syncconf`; it never uses `wg-quick` (nor its bash dependency), see [Architecture and Internals](Architecture-and-Internals#why-no-wg-quick).
- `wireguard-go` — the userspace fallback for hosts without the kernel module. It is pinned to its upstream version with a floating Alpine revision (`~`), because the riscv64 package builder lags the other architectures by a revision for days at a time, which would otherwise break the multi-arch build.
- `libqrencode-tools` renders peer configs as QR codes; `nftables` and `iproute2-minimal` do the firewall and policy routing; `curl` and `bind-tools` serve the health-check probes and DNS re-resolution.

## Version pinning

Every APK package in the Dockerfile is pinned to an exact version (except the floating revision of `wireguard-go` above), so builds are reproducible and upgrades are explicit, reviewable diffs. `scripts/update-apk-versions.sh` refreshes the pins from the Alpine package repositories (main first, then community):

```bash
./scripts/update-apk-versions.sh Dockerfile
```

Alpine and s6-overlay are pinned via the `ARG` lines above and bumped by CI (below).

## CI workflows

| Workflow | Trigger | What it does |
|---|---|---|
| `ci-build-deploy` | every push / PR | Build and push. Branches: amd64 only → GHCR (branch-name tag). `main`: full platform matrix → GHCR `:dev`. Release tags: full matrix → Docker Hub + GHCR, `:<version>` and `:latest`, after verifying the tag is a semantic version; then the Docker Hub description is refreshed from the README and the built image is scanned (`security-docker`) |
| `security-docker` | daily schedule, manual, called by CI | Trivy and Grype scans of the published image (or the just-built tag), results uploaded to the Security tab |
| `security-comprehensive` | push / PR to `main`, weekly | Super-Linter plus Trivy filesystem and config scans, results uploaded to the Security tab |
| `maintenance-updates` | daily schedule, manual | Bot PRs, one per change: APK pin refresh, s6-overlay bump, Alpine base bump |
| `maintenance-cleanup` | weekly schedule, manual | Prunes old GHCR and Docker Hub tags with [container-registry-pruner](https://github.com/azinchen/container-registry-pruner); dry-run by default when run manually |
| `wiki-publish` | tag push, manual | Mirrors the repository's `wiki/` folder into the GitHub wiki, so the published wiki always matches the latest release |

Dependabot keeps the GitHub Actions versions current with weekly PRs. Platform matrix for `main` and releases: `linux/386, linux/amd64, linux/arm/v6, linux/arm/v7, linux/arm64, linux/riscv64`.

### Bot PR labels

The maintenance workflow labels its PRs `dependencies` so release notes can be generated from them; Dependabot PRs carry `dependencies`, `github-actions` and `automation`.

## Image tags

| Tag | Meaning |
|---|---|
| `latest` | Latest final release (Docker Hub + GHCR); pre-releases do not move it |
| `1.2.0` | A specific release — the git tag |
| `1.3.0-rc1` | A pre-release: published under its own tag only |
| `dev` | Current `main` branch, full platform matrix (GHCR only) |
| `<branch>` | Development branch build, amd64 only (GHCR only); `/` in the branch name becomes `-` |

## Releases

### Version scheme

Releases are tagged **`X.Y.Z`** (semantic versioning, no `v` prefix; the git tag and the Docker tag are the same string). CI refuses a tag that is not `MAJOR.MINOR.PATCH` with an optional `-prerelease` suffix (`alpha`, `beta`, `rc`, `pre`, `preview`, `snapshot` suffixes are published without touching `:latest`). The minor version is bumped for new variables or peers-file options, behavior changes, base-image or WireGuard upgrades and larger documentation work; the patch version for a release that only carries security or bug fixes.

### Cutting a release

1. Make sure `main` is green and the bot PRs you want included are merged.
2. Tag: `git tag 1.2.0 && git push origin 1.2.0` — CI validates the tag, builds the full platform matrix, pushes `:1.2.0` and `:latest` to Docker Hub and GHCR, runs the security scan, and publishes the wiki.
3. Create the GitHub release for the tag using the release description format below.

### Release description format

The format lives at [`.github/RELEASE_TEMPLATE.md`](https://github.com/azinchen/wireguard/blob/main/.github/RELEASE_TEMPLATE.md). Structure (matching the sibling images' releases):

- a one-or-two-sentence summary of why to upgrade — security updates lead with **"Security update — upgrading is recommended."**;
- **📥 Pull this release** — the two `docker pull` lines and the multi-arch line;
- **⬆️ Upgrade notes** — required actions or behavior changes, or "No action required", with deep links into this wiki;
- **✨ Features / 🐛 Fixes / 📦 Package Updates / 📖 Documentation / 🔧 CI/CD Updates** — hand-written, user-facing entries with PR references; package security bumps link their CVEs or advisories and say what the package does in this image;
- **🧩 Component versions** — wireguard-tools, wireguard-go, Alpine Linux, s6-overlay, read from the Dockerfile at the tag;
- **Contributors** and the **Full Changelog** compare link.

**Generate release notes** ([`.github/release.yml`](https://github.com/azinchen/wireguard/blob/main/.github/release.yml) categorizes merged PRs by label into the same section titles) can seed the section contents — rewrite the entries in user-facing wording rather than shipping raw PR titles.
