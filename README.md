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
ghcr.io/chefcai/sonarr-alpine:<sonarr-version>   # e.g. 4.0.17.2952
```

## Result

| | Compressed pull (linux/amd64) | On-disk (uncompressed) | Δ vs upstream |
|---|---:|---:|---:|
| `lscr.io/linuxserver/sonarr:latest` (upstream) | **85.0 MB** | **206 MB** | — |
| `ghcr.io/chefcai/sonarr-alpine:latest`         | **71.86 MB** | **170 MB** | **−15.5 % (compressed)** / **−17.5 % (on-disk)** |

> Compressed size is what `docker pull` actually transfers — the metric that
> matters for squirttle's eMMC bandwidth/space. The GH workflow's "Report
> final image size" step computes this from the OCI manifest after each
> push and writes it into the run's job summary.

**The 30 % reduction target in the brief was not achievable.** Sonarr v4's
self-contained tarball from `services.sonarr.tv` (~70 MB compressed) is the
floor that all viable iterations share. The savings vs upstream come almost
entirely from dropping the `linuxserver/baseimage-alpine` layer (s6-overlay,
bash, jq, curl, procps-ng, shadow, ca-certificates, docker-mods scripts)
plus a few Sonarr.Update / *.pdb / UI/*.map prunes inside the application
layer. The ffprobe binary in the tarball is 16 MB and would yield another
~9 MB compressed if removed, but that breaks Sonarr's "Analyse video files"
feature and is not enabled by default in `:latest`.

## Upstream tracking

Tracks **`v4-stable`** as published by Sonarr's own update service
(`https://services.sonarr.tv/v1/releases`) — the same source of truth used by
the LSIO image. The workflow resolves "what version is v4-stable today" at
build time, queries GHCR to see if that exact version already has an image,
and skips the build if so. The daily 07:00 UTC cron is therefore a no-op on
days Sonarr hasn't released anything new.

When Sonarr's `main` branch advances to .NET 8 (TBD upstream — `develop`
already targets net10.0 with SDK 10.0.203), the Dockerfile's runtime deps
will need a review and a framework-dependent layout becomes viable for the
first time (Alpine 3.21 ships `dotnet8-runtime` natively, `dotnet6-runtime`
is not packaged anywhere in apk).

## Why not just use upstream `linuxserver/sonarr`?

Older homelab notes claimed the upstream Sonarr image was "already efficient
enough" not to be worth a custom build, in contrast to seerr/jellyfin/bazarr
where chefcai/* saved hundreds of MB. This repo re-validated that claim with
measurements. The notes were *almost* right — there was a real win, but a
small one (15.5 %), not the 50–60 % wins those other projects delivered.

The wins come from:
- **Dropping the `linuxserver/baseimage-alpine` shell.** Upstream pulls in
  s6-overlay, bash, jq, curl, procps-ng, shadow, ca-certificates, and the
  LSIO docker-mods scripts. We use plain `alpine:3.21` and rely on Docker's
  `init: true` for PID 1.
- **No `xmlstarlet`.** LSIO uses it in init scripts to patch `config.xml`
  based on env vars; we don't have those init scripts.
- **Fixed UID/GID baked into the image** (13001:13000). LSIO's `abc` user
  gets renumbered at runtime by their entrypoint based on PUID/PGID env;
  the chefcai image hardcodes the IDs and chowns at build.
- **No `Sonarr.Update` binary** (75 MB uncompressed) — in-app updates aren't
  used because we update via `docker pull`.
- **No `*.pdb`** debug symbols, `*.xml` ref docs.
- **No `UI/*.map`** SPA source maps.

## Iteration log

The brief asked for "smallest possible — keep iterating bases, prune steps,
and runtime layouts until the curve flattens." Every measured iteration is
recorded here, including the ones that lost. Sizes are **compressed
linux/amd64** as reported by the OCI manifest after each push.

### iter-0 — baseline `lscr.io/linuxserver/sonarr:latest`

| | |
|---|---|
| **Date** | 2026-04-25 |
| **Compressed** | **85.0 MB** (9 layers) |
| **On-disk** | 206 MB |
| **Base** | `ghcr.io/linuxserver/baseimage-alpine:3.23` |
| **Layout** | s6-overlay supervises `/app/sonarr/bin/Sonarr` as the `abc` user (UID/GID rewritten at runtime by an init script). |
| **Runtime deps** | `icu-libs sqlite-libs xmlstarlet` |
| **Source manifest** | `sha256:f0c4491ac40a97742201b07cc206b120703fcd398fd40536fdc47820d7a5c298` |

Layer breakdown: 5 + 0 + 0 + 0 + 0 + 5 + 0 + **73** + 0 MB. The 73 MB layer
is Sonarr + bundled .NET 6; the rest is baseimage-alpine + s6 + LSIO tooling.

### iter-1 — `alpine:3.21` + self-contained linux-musl-x64 tarball

| | |
|---|---|
| **Date** | 2026-04-25 |
| **Compressed** | **74.5 MB** (4 layers) — **−12.4 %** vs iter-0 |
| **Base** | `alpine:3.21` only |
| **Layout** | multi-stage: stage 1 fetches and unpacks the Sonarr tarball from `services.sonarr.tv`, prunes `Sonarr.Update*` (75 MB) + `*.pdb` (~5 MB) + `*/ref/*.xml`. Stage 2 is fresh `alpine:3.21` with `apk add icu-libs sqlite-libs tzdata ca-certificates libstdc++` and the unpacked Sonarr tree at `/app/sonarr/bin`. UID 13001 / GID 13000 baked in. CMD = bundled AppHost binary. |

Layer breakdown: 3.4 + 5.1 + **65.9** + 0 MB. The 65.9 MB layer is the same
Sonarr tarball as upstream's 73 MB, minus the prunes.

### iter-2 — `debian:bookworm-slim` + self-contained linux-x64 tarball

| | |
|---|---|
| **Date** | 2026-04-25 |
| **Compressed** | **111.92 MB** (4 layers) — **+31.7 %** vs iter-0 ❌ |
| **Base** | `debian:bookworm-slim` |
| **Layout** | apt `libsqlite3-0 libicu72 libstdc++6 ca-certificates tzdata` + Sonarr `linux-x64` (glibc, not musl) self-contained tarball. |

Layer breakdown: 26.9 + 18.5 + **66.4** + 0 MB. Bookworm + libicu72 alone
adds ~45 MB compressed vs Alpine's ~8 MB; the application layer is roughly
equal. `debian:stable-slim` was tried first but rolled to trixie which
renamed `libicu72` → `libicu76` and broke the apt-install.

### iter-3 — `mcr.microsoft.com/dotnet/aspnet:6.0-alpine` + bundled

| | |
|---|---|
| **Date** | 2026-04-25 |
| **Compressed** | **111.19 MB** (7 layers) — **+30.8 %** vs iter-0 ❌ |
| **Base** | `mcr.microsoft.com/dotnet/aspnet:6.0-alpine` |
| **Layout** | MCR base provides .NET 6 runtime in `/usr/share/dotnet/`; Sonarr's bundled `lib/` overrides it. Negative-result iteration as predicted — stacking two runtimes is strictly worse. |

Layer breakdown: 3.4 + 2.0 + **29.7** (.NET aspnet runtime) + **9.0** (icu data)
+ 0.9 + **65.9** (Sonarr) + 0 MB. A "real" iter-3 would build Sonarr
framework-dependent from source; out of scope for the chefcai/* pattern
which only fetches release tarballs.

### iter-4 — chiseled / ubi-micro / scratch (skipped)

All three options have the same blocker as iter-3: they require a
framework-dependent Sonarr build, which means rebuilding from source. Out
of scope.

### iter-5a — aggressive prune (rejected, broke runtime)

Tried removing all "Windows-only-by-name" DLLs from the bundled .NET inside
the tarball: `Microsoft.Win32.Registry.dll`, `Microsoft.Win32.SystemEvents.dll`,
`Microsoft.AspNetCore.Server.HttpSys.dll`, `Microsoft.AspNetCore.Server.IIS*.dll`,
`Microsoft.VisualBasic*.dll`, `WindowsBase.dll`, `System.Windows*.dll`,
`System.ServiceProcess*.dll`, `System.Diagnostics.EventLog.dll`,
`Microsoft.Extensions.Hosting.WindowsServices.dll`,
`Microsoft.Extensions.Logging.EventLog.dll`, `System.Data.SqlServerCe.dll`,
`Microsoft.Data.SqlClient.dll`. Combined ~4.5 MB uncompressed.

Result: image built fine, was **69.97 MB compressed** (−17.7 % vs iter-0),
but Sonarr **SIGSEGV'd at startup** with empty stdout (exit 139). These
DLLs are referenced from `Sonarr.deps.json` (or transitively via
`Microsoft.AspNetCore.App` / `Microsoft.NETCore.App` manifests); removing
them causes libcoreclr/libhostfxr to crash trying to resolve them. **LSIO
doesn't prune any of these** — that's the corroborating evidence. Trying to
be smarter than the .NET deps graph loses.

### iter-5 — alpine + safe prune (current `:latest`)

| | |
|---|---|
| **Date** | 2026-04-25 |
| **Compressed** | **71.86 MB** (4 layers) — **−15.5 %** vs iter-0 ✅ |
| **On-disk** | 170 MB (vs LSIO 206 MB → **−17.5 %**) |
| **Additional prunes vs iter-1** | `UI/*.map` (11 MB SPA source maps) + `ServiceInstall` / `ServiceUninstall` (160 KB Win-only ELF installers, not referenced by `deps.json` on Linux). |
| **Verified on squirttle** | 2026-04-25 — boots healthy in 35 s, all 217+ DB migrations applied, `/sonarr/ping` returns 200, `/api/v3/system/status` returns 401 (auth enforced as expected), 74 MB RSS at idle. |

Layer breakdown: 3.4 + 5.1 + **63.2** + 0 MB.

### iter-5b (not built) — strip ffprobe (no media analysis)

Removing the bundled `ffprobe` (16 MB binary) would compress to ~9 MB
saved, putting iter-5b at **~63 MB compressed = −26 %** vs iter-0. The
trade-off is that Sonarr can no longer analyse media files for custom format
quality detection (codec / bitrate / resolution / runtime probe). For homelab
users who only filter releases by name/quality and don't care about post-
import re-analysis, iter-5b would be acceptable. Not enabled by default
because the homelab use case relies on it. To build:

```bash
# In the prune RUN step, add:
rm -f /work/sonarr/ffprobe
# Then dispatch with tag_suffix=iter5b-no-ffprobe
```

### Why we stopped here

The 30 % reduction target named in the brief is not reachable while keeping
Sonarr fully functional. The application layer floor (~63–66 MB compressed)
is set by Sonarr's bundled .NET 6 self-contained tarball, which we don't
control. The base-image floor (~3 MB) is set by Alpine itself. The remaining
deltas are below 5 MB compressed. This is "the curve has flattened" in the
brief's terms — −15.5 % is the genuine ceiling without a destructive change
to Sonarr's behaviour.

## Usage

In `~/arrs/docker-compose.yml` on squirttle the `sonarr:` service block is:

```yaml
sonarr:
  image: ghcr.io/chefcai/sonarr-alpine:latest
  init: true   # chefcai image has no s6-overlay; Docker provides PID 1
  container_name: sonarr
  environment:
    - TZ=America/New_York
  healthcheck:
    test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:8989/ping"]
    interval: 1m30s
    timeout: 10s
    retries: 3
  ports:
    - "8989:8989"
  volumes:
    - /home/haadmin/config/sonarr-config:/config
    # …existing media/backup mounts…
  restart: unless-stopped
```

Notable differences from the LSIO-style block:
- `init: true` replaces s6-overlay's PID 1.
- `PUID=13001` / `PGID=13000` / `UMASK=002` env vars are dropped — UID/GID
  are baked into the image at build time.
- The compose-level `healthcheck:` uses `wget` because `curl` is not in the
  chefcai image. Image-level `HEALTHCHECK` is identical and would suffice
  if you remove the compose-level one entirely.

The bind-mounted `sonarr-config` directory must already be owned `13001:13000`.
If you're migrating from LSIO with `PUID=13001 PGID=13000`, it already is.
Otherwise: `sudo chown -R 13001:13000 /home/haadmin/config/sonarr-config`.

## Build pipeline

- Push to `main` or `workflow_dispatch` → build + push to ghcr.io.
- Daily cron at **07:00 UTC**, staggered after the existing chefcai/* daily
  builds (06:00 bazarr / 06:15 jellyfin / 06:30 ttyd / 06:45 seerr).
- Daily run skips the actual build if the upstream `v4-stable` version
  resolved from `services.sonarr.tv` is already published as a tag in GHCR
  (manifest API HEAD check).
- `concurrency: build-${{ github.ref }}, cancel-in-progress: true` prevents
  the parallel-push race that bit seerr-alpine on 2026-04-25.
- Workflow tags both `:latest` and `:<sonarr-version>` (e.g. `4.0.17.2952`).
- `workflow_dispatch` accepts `dockerfile` (variant chooser),
  `tag_suffix` (so iter-2/3 measurements don't overwrite `:latest`), and
  `measure_baseline=true` (run the iter-0 measurement job).
- Per-variant BuildKit cache scope so iter-2 / iter-3 don't poison the
  iter-1 cache.

## GHCR first-push note (didn't bite this repo)

The chefcai gh CLI token already has `write:packages`, which means the
workflow's `${{ secrets.GITHUB_TOKEN }}` (which inherits the repo's
collaborator scope on a public repo) was sufficient for the first push.
Repo↔package linkage happened automatically via the buildx provenance
attestation — no manual settings page step was needed.

If you fork this repo into an org or account whose default token is more
restricted, the workaround in
[homelab memory `feedback_ghcr_first_push.md`](https://github.com/chefcai)
still applies: bootstrap with a PAT, then revoke.
