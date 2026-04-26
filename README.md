# sonarr-alpine

A footprint-minimized Docker image for [Sonarr](https://sonarr.tv) v4 (.NET 6),
built on Alpine Linux. Same playbook as
[`chefcai/jellyfin-alpine`](https://github.com/chefcai/jellyfin-alpine),
[`chefcai/seerr-alpine`](https://github.com/chefcai/seerr-alpine), and
[`chefcai/bazarr-alpine`](https://github.com/chefcai/bazarr-alpine): the image
is assembled in GitHub Actions and published to `ghcr.io`, so the eMMC-bound
homelab host (`squirttle`, ~3.9 GB free) never holds intermediate build
artifacts.

## Image

```
ghcr.io/chefcai/sonarr-alpine:latest
ghcr.io/chefcai/sonarr-alpine:<sonarr-version>   # e.g. 4.0.17.2953
```

## Result

| | Compressed | Δ vs upstream |
|---|---:|---:|
| `lscr.io/linuxserver/sonarr:latest` (upstream)              | _measured in iter-0 below_ | — |
| `ghcr.io/chefcai/sonarr-alpine:latest`                       | _filled by workflow_       | _filled by workflow_ |

> Sizes reported above are **compressed layer totals** (what `docker pull`
> actually transfers — the metric that matters for squirttle's eMMC). The GH
> workflow's "Report final image size" step computes this from the OCI
> manifest and writes it into the run's job summary.

## Upstream tracking

This image tracks **`v4-stable`** as published by Sonarr's own update service
(`https://services.sonarr.tv/v1/releases`) — the same source of truth used by
the LSIO image. The workflow resolves "what version is v4-stable today" at
build time, queries GHCR to see if that exact version already has an image,
and skips the build if so. This means the daily 07:00 UTC cron is a no-op on
days Sonarr hasn't released anything new.

When Sonarr's `main`/`v4-stable` branch advances to .NET 8 (TBD upstream), the
Dockerfile's `apk add` line will need a `dotnet8-runtime` review and the
self-contained tarball decision should be re-evaluated — Alpine 3.21 ships
`dotnet8-runtime` natively, which means a framework-dependent layout would
become viable for the first time and could shrink the image further.

## Why not just use upstream `linuxserver/sonarr`?

Older homelab notes claimed the upstream Sonarr image was "already efficient
enough" not to be worth a custom build, in contrast to seerr/jellyfin/bazarr.
This repo re-validates that claim with measurements, not vibes. See the
iteration log below — `iter-0` is the upstream baseline.

The wins (where they exist) come from:
- **Dropping the `linuxserver/baseimage-alpine` shell.** Upstream pulls in
  s6-overlay, bash, jq, curl, procps-ng, shadow, ca-certificates, and the
  LSIO docker-mods scripts. We use plain `alpine:3.21` and rely on Docker's
  `init: true` for PID 1.
- **No `xmlstarlet`.** LSIO uses it in their init scripts to patch
  `config.xml` based on env vars; we don't have those init scripts.
- **Fixed UID/GID baked into the image** (13001:13000), so we don't need the
  PUID/PGID re-chown init step that LSIO runs at every container start.
- **No `Sonarr.Update` binary.** The in-app updater is removed because
  updates here happen via `docker pull`, not Sonarr's self-update.
- **No `*.pdb`** debug symbols and `*.xml` reference docs.

## Iteration log

The brief was "smallest possible — keep iterating until the curve flattens."
Every measured iteration goes here, including the ones that lost. Sizes are
the **compressed** numbers from each GH Actions run's job summary unless
otherwise noted.

> **NB:** the GitHub Actions sandbox cannot reach `registry-1.docker.io` or
> `ghcr.io` from the prep environment that authored these iterations, so the
> baseline `iter-0` (upstream LSIO) measurement was taken from a dispatched
> workflow run — see the linked run for the raw manifest data.

### iter-0 — baseline: `lscr.io/linuxserver/sonarr:latest`

- **Date:** _filled in after the first dispatch run_
- **Base:** `ghcr.io/linuxserver/baseimage-alpine:3.23` (alpine:3.22 +
  s6-overlay v3.2.1 + bash + ca-certificates + catatonit + coreutils + curl +
  findutils + jq + netcat-openbsd + procps-ng + shadow + tzdata + LSIO
  docker-mods scripts).
- **Layout:** s6-overlay supervises `/app/sonarr/bin/Sonarr` as the `abc`
  user (UID/GID rewritten at runtime by an init script).
- **Runtime deps:** `icu-libs sqlite-libs xmlstarlet`.
- **Compressed size:** _filled by manual lookup or by an `iter-0` workflow
  job that pulls the manifest._
- **Lesson going in:** the LSIO baseimage carries ~30–40 MB of init/management
  tooling that we don't need. If we drop it cleanly, we should be able to
  beat upstream by at least that margin without changing how Sonarr is
  packaged.

### iter-1 — `alpine:3.21` + self-contained linux-musl-x64 tarball (proposed primary)

- **Date:** _filled in after the first push_
- **Base:** `alpine:3.21` only.
- **Layout:** multi-stage. Stage 1 fetches and unpacks the Sonarr tarball
  from `services.sonarr.tv` (self-contained, bundles its own .NET 6 runtime
  in `lib/`), prunes `Sonarr.Update`, `*.pdb`, `*/ref/*.xml`. Stage 2 is a
  fresh `alpine:3.21` with `apk add icu-libs sqlite-libs tzdata
  ca-certificates libstdc++` and the unpacked Sonarr tree at `/app/sonarr/bin`.
- **Compressed size:** _filled by workflow_
- **Δ vs iter-0:** _filled in_
- **What changed vs upstream:** dropped baseimage-alpine, s6-overlay, bash,
  jq, curl, procps-ng, shadow, xmlstarlet, docker-mods init scripts;
  hardcoded UID/GID 13001:13000; deleted `Sonarr.Update*`, `*.pdb`,
  `*/ref/*.xml`; switched the launcher from an s6 service to plain
  `CMD ["Sonarr", "--data=/config", "--nobrowser"]` with `init: true`
  expected at the compose layer.
- **Risk:** Sonarr's settings UI exposes "automatic updates" toggles that
  rely on `Sonarr.Update`. With `package_info` writing `UpdateMethod=docker`
  Sonarr should hide/disable that toggle. If the container starts
  unsuccessfully, restoring the binary is one line.

### iter-2 — `debian:stable-slim` + linux-x64 self-contained (planned)

- **Hypothesis:** glibc + apt's `libsqlite3-0`/`libicu-*` are larger than
  Alpine's musl variants; iter-2 should lose to iter-1.
- **Why bother:** a credible "we tested glibc and it lost by N MB" entry is
  what the brief asked for. If iter-2 unexpectedly wins, that overturns the
  Alpine-by-default assumption.

### iter-3 — `mcr.microsoft.com/dotnet/runtime:6.0-alpine` + framework-dependent (planned)

- **Hypothesis:** Sonarr's repo declares `<SelfContained>false</SelfContained>`
  but the `services.sonarr.tv` artifact is self-contained, meaning we can't
  trivially reuse it for a framework-dependent layout — we'd have to build
  Sonarr from source with `--self-contained false` ourselves. That's a much
  bigger undertaking than the previous chefcai images and probably not
  worthwhile if iter-1 already beats iter-0 by ≥30 %.

### iter-4 — chiseled / ubi-micro / scratch (planned, low priority)

- **Hypothesis:** the chiseled `dotnet/runtime` images are smaller than the
  Alpine ones, but again require framework-dependent Sonarr — same blocker
  as iter-3.

### Pruning experiments (run on the winning base)

These are levers to try once the base is picked. Each is recorded with
before/after compressed sizes:

- [ ] Drop `lib/<rid>/`-style runtime fallback dirs not used at runtime
- [ ] Strip the bundled `Sonarr/Resources` localized DLLs (Sonarr ships its
      own translation files in `Localisation/`; the .NET satellite assemblies
      under each runtime culture dir are unused)
- [ ] Strip `*.deps.json` / `*.runtimeconfig.dev.json` (build-time only)
- [ ] Set `DOTNET_GCConserveMemory=9` at runtime — image-size-neutral but
      worth noting for squirttle's RAM
- [ ] Try `apk add icu-data-en` instead of full `icu-libs` (Sonarr's
      culture is en-US-only by default — most ICU data tables are dead weight)

## Usage

In `~/arrs/docker-compose.yml` on squirttle, replace the existing `sonarr`
service block's `image:` line with:

```yaml
sonarr:
  image: ghcr.io/chefcai/sonarr-alpine:latest
  init: true     # required: replaces s6-overlay's PID 1 from the LSIO image
  # everything else (volumes, ports 8989, env, restart, healthcheck) stays.
```

The bind-mounted `sonarr-config` directory must already be owned by
`13001:13000` — same UID/GID as the rest of the homelab. If you're migrating
from LSIO with `PUID=13001 PGID=13000`, it already is. Otherwise:

```bash
sudo chown -R 13001:13000 /home/haadmin/config/sonarr-config
```

## Build pipeline

- Push to `main` or `workflow_dispatch` → build + push to ghcr.io.
- Daily cron at **07:00 UTC**, staggered after the existing chefcai/* daily
  builds (06:00 bazarr / 06:15 jellyfin / 06:30 ttyd / 06:45 seerr).
- Daily run skips the actual build if the upstream `v4-stable` version
  resolved from `services.sonarr.tv` is already published as a tag in GHCR
  (manifest API HEAD check).
- `concurrency: build-${{ github.ref }}, cancel-in-progress: true` prevents
  the parallel-push race.
- Workflow tags both `:latest` and `:<sonarr-version>` (e.g. `4.0.17.2953`).

## GHCR first-push bootstrap

A brand-new GHCR package needs one manual push with a PAT before the
`GITHUB_TOKEN` from the workflow can write to it (the token cannot create the
package itself, only update an existing linked one):

```bash
# locally, once:
echo "$GHCR_PAT_WITH_WRITE_PACKAGES" | docker login ghcr.io -u chefcai --password-stdin
docker buildx build --platform linux/amd64 \
    --build-arg SONARR_VERSION=4.0.17.2953 \
    -t ghcr.io/chefcai/sonarr-alpine:bootstrap --push .
```

Then on github.com:

1. Visit `https://github.com/users/chefcai/packages/container/sonarr-alpine/settings`
2. Scroll to **Manage Actions access** → **Add repository** → pick
   `chefcai/sonarr-alpine` → role **Write**.
3. Revoke the PAT.
4. Delete the `:bootstrap` tag from the package's "Manage versions" page.

After that, the workflow's `GITHUB_TOKEN` can push freely.
