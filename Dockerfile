# sonarr-alpine — minimal Sonarr (v4-stable, .NET 6) image on Alpine.
#
# Pattern mirrors chefcai/jellyfin-alpine, chefcai/seerr-alpine, chefcai/bazarr-alpine:
#   - Build runs in GitHub Actions, not on squirttle's eMMC.
#   - Final image is plain alpine + nodejs/dotnet/etc. + only the runtime
#     artifacts needed to launch the app.
#
# Sonarr v4 specifics:
#   - Targets net6.0 (see global.json on tag v4.0.17.2953 → SDK 6.0.405).
#   - Alpine's apk does not ship dotnet6-runtime, so we use Sonarr's
#     SELF-CONTAINED linux-musl-x64 tarball from services.sonarr.tv. That
#     tarball bundles its own .NET 6 runtime alongside Sonarr.dll, which
#     means the base image only needs:
#         icu-libs       (CoreCLR globalization native, used by Sonarr)
#         sqlite-libs    (Sonarr's main DB engine — bundled wrapper expects
#                         a native libsqlite3 on the system)
#         tzdata         (TZ env support)
#         ca-certificates (HTTPS to indexers/notifications)
#   - Sonarr.Update is the in-app updater binary; we delete it because Docker
#     image rebuilds are how we update, not Sonarr's self-update.
#
# Compared to upstream linuxserver/sonarr the savings come from:
#   - Dropping ghcr.io/linuxserver/baseimage-alpine and its s6-overlay,
#     bash, jq, curl, procps-ng, shadow, ca-certificates, docker-mods scripts.
#     The compose runtime uses `init: true` instead of s6 for PID 1.
#   - Dropping xmlstarlet (only used by LSIO's init script for config patching).
#   - Using a numbered, pinned UID/GID baked into the image rather than the
#     LSIO `abc` user that gets renumbered at runtime by their entrypoint.

ARG SONARR_VERSION=4.0.17.2952
ARG SONARR_BRANCH=main

# ---- Stage 1: fetch & unpack the upstream tarball --------------------------
FROM alpine:3.21 AS fetch
ARG SONARR_VERSION
ARG SONARR_BRANCH

RUN apk add --no-cache curl tar

WORKDIR /work
# The services.sonarr.tv update endpoint is what the official LSIO image and
# the Sonarr installer scripts both use. `runtime=netcore` is the .NET-based
# build (vs the deprecated mono one), and the linuxmusl-x64 variant is the
# self-contained build for musl-libc systems (Alpine).
#
# This URL serves a SELF-CONTAINED tarball — the Sonarr repo's
# Directory.Build.props sets <SelfContained>false</SelfContained> for the
# msbuild publish, but the docker-targeted build pipeline overrides this so
# the downloadable artifact bundles dotnet6. (Confirmed empirically: the
# upstream LSIO Dockerfile installs no dotnet*-runtime apk and the container
# still boots.)
RUN curl -fsSL \
        "https://services.sonarr.tv/v1/update/${SONARR_BRANCH}/download?version=${SONARR_VERSION}&os=linuxmusl&runtime=netcore&arch=x64" \
        -o /work/sonarr.tar.gz \
 && mkdir -p /work/sonarr \
 && tar xzf /work/sonarr.tar.gz -C /work/sonarr --strip-components=1 \
 && rm /work/sonarr.tar.gz

# Prune step — every byte counts on squirttle's 12 GB eMMC.
# Numbers in parentheses are uncompressed sizes from the v4.0.17.2952
# linuxmusl-x64 tarball; compressed savings are typically ~30-40 % of those.
#
#   - Sonarr.Update* (75 MB): in-app updater bundling its own .NET runtime.
#     We update via `docker pull`, never via Sonarr's self-update.
#   - *.pdb (~5 MB): .NET debug symbols. Stack traces still resolve method
#     names without them; only line numbers are lost.
#   - *.xml under ref/ (none in v4 tarball, but kept for forward-compat).
#
# iter-5 prune levers (all safe on Linux/x64; rationale per file):
#   - UI/*.map (11 MB): SPA source maps. Used only by browser dev tools to
#     debug minified JS. Sonarr functionality unaffected.
#   - ServiceInstall, ServiceUninstall (~160 KB total): Windows service
#     installer binaries. Never invoked on Linux.
#   - Microsoft.AspNetCore.Server.HttpSys.dll, Microsoft.AspNetCore.Server.IIS*.dll:
#     Windows HTTP.SYS / IIS integration. Sonarr uses Kestrel on Linux.
#   - Microsoft.Win32.Registry.dll, Microsoft.Win32.SystemEvents.dll:
#     Windows registry / system events. Linux has neither.
#   - Microsoft.VisualBasic*.dll: VB.NET runtime. Sonarr is C#.
#   - WindowsBase.dll, System.Windows*.dll: WPF / Windows Forms runtime.
#   - System.ServiceProcess*.dll: Windows service hosting.
#   - System.Diagnostics.EventLog.dll, Microsoft.Extensions.Logging.EventLog.dll,
#     Microsoft.Extensions.Hosting.WindowsServices.dll: Windows-only logging.
#   - System.Data.SqlServerCe.dll, Microsoft.Data.SqlClient.dll (~1.5 MB):
#     SQL Server Compact / SQL Server clients. Sonarr uses SQLite (or
#     optionally PostgreSQL via Npgsql.dll which we keep).
#
# What we deliberately DON'T prune (would break things):
#   - ffprobe (16 MB): Sonarr's media analyzer. Removing it disables
#     "Analyse video files" — homelab Sonarr uses this for custom format
#     quality detection. iter-5b (no-ffprobe) is documented in README as
#     an option for users who don't need media analysis.
#   - Sonarr.Mono.dll: small (27 KB) shim referenced by Sonarr.deps.json.
#     Even though we run .NET Core, the deps graph loads it; safer to keep.
#   - System.Drawing.Common.dll: poster/banner thumbnail generation might
#     P/Invoke libgdiplus. Untested; kept to be safe.
RUN set -eux; \
    cd /work/sonarr; \
    rm -rf Sonarr.Update Sonarr.Update.* update; \
    find . -name '*.pdb' -type f -delete; \
    find . -name '*.xml' -path '*/ref/*' -type f -delete 2>/dev/null || true; \
    rm -rf logs MediaCover .git .github 2>/dev/null || true; \
    # iter-5 prune levers — see comment block above.
    rm -f UI/*.map; \
    rm -f ServiceInstall ServiceUninstall; \
    rm -f Microsoft.AspNetCore.Server.HttpSys.dll \
          Microsoft.AspNetCore.Server.IIS.dll \
          Microsoft.AspNetCore.Server.IISIntegration.dll \
          Microsoft.Win32.Registry.dll \
          Microsoft.Win32.SystemEvents.dll \
          Microsoft.VisualBasic.Core.dll \
          Microsoft.VisualBasic.dll \
          WindowsBase.dll \
          System.Windows.dll \
          System.Windows.Extensions.dll \
          System.ServiceProcess.dll \
          System.ServiceProcess.ServiceController.dll \
          System.Diagnostics.EventLog.dll \
          Microsoft.Extensions.Hosting.WindowsServices.dll \
          Microsoft.Extensions.Logging.EventLog.dll \
          System.Data.SqlServerCe.dll \
          Microsoft.Data.SqlClient.dll

# Write a package_info file matching LSIO's convention so Sonarr knows it was
# installed via Docker and disables in-app updates that would re-download
# Sonarr.Update.
ARG SONARR_VERSION
RUN printf 'UpdateMethod=docker\nBranch=%s\nPackageVersion=%s\nPackageAuthor=[chefcai/sonarr-alpine](https://github.com/chefcai/sonarr-alpine)\n' \
        "${SONARR_BRANCH:-main}" "${SONARR_VERSION}" \
        > /work/sonarr/package_info

# ---- Stage 2: runtime ------------------------------------------------------
FROM alpine:3.21

ARG SONARR_VERSION
LABEL org.opencontainers.image.title="sonarr-alpine"
LABEL org.opencontainers.image.description="Footprint-minimized Sonarr image on Alpine. See https://github.com/chefcai/sonarr-alpine"
LABEL org.opencontainers.image.source="https://github.com/chefcai/sonarr-alpine"
LABEL org.opencontainers.image.licenses="GPL-3.0-only"
LABEL org.opencontainers.image.version="${SONARR_VERSION}"

# Disable .NET diagnostics — saves a tiny bit of RAM, and lines up with what
# the LSIO image sets. (Same value, same reasoning: no perf counters/CTRs.)
ENV COMPlus_EnableDiagnostics=0 \
    XDG_CONFIG_HOME=/config/xdg \
    TZ=UTC

# Runtime deps (mirrors what upstream linuxserver/sonarr installs, minus the
# xmlstarlet they only need for their init scripts):
#   - icu-libs:        .NET globalization. Without it, .NET 6 throws
#                      System.Globalization.CultureNotFoundException at startup
#                      unless DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1 is set —
#                      Sonarr depends on culture-aware string compares, so
#                      invariant mode is not safe. (See iter-5 prune lever for
#                      "icu-data-en only" experiment.)
#   - sqlite-libs:     native libsqlite3 — Sonarr's bundled SQLite.Core P/Invokes it.
#   - tzdata:          /usr/share/zoneinfo so TZ=America/New_York works.
#   - ca-certificates: outbound HTTPS to indexers, sonarr.tv update check, etc.
#   - libstdc++:       transitively required by some self-contained .NET 6
#                      native libs; pulled by icu-libs but listed for clarity.
#
# UID/GID 13001:13000 — homelab convention, matches sonarr/radarr/jellyfin/
# seerr-alpine. Fixed at image build time so config-dir bind mounts already
# owned 13001:13000 on squirttle Just Work.
RUN apk add --no-cache \
        icu-libs \
        sqlite-libs \
        tzdata \
        ca-certificates \
        libstdc++ \
 && addgroup -g 13000 sonarr \
 && adduser -D -u 13001 -G sonarr -h /config -s /sbin/nologin sonarr \
 && mkdir -p /config /app /media \
 && chown -R sonarr:sonarr /config /app /media

COPY --from=fetch --chown=sonarr:sonarr /work/sonarr /app/sonarr/bin

USER sonarr
WORKDIR /app/sonarr
EXPOSE 8989

# Healthcheck uses busybox wget — no curl in the image. /ping is a v4 endpoint
# that responds 200 once Sonarr is fully started.
HEALTHCHECK --interval=1m30s --timeout=10s --retries=3 --start-period=60s \
    CMD wget --no-verbose --tries=1 --spider http://localhost:8989/ping || exit 1

# Sonarr's bundled AppHost binary launches the .NET runtime and assembly.
# `--data` points at the per-instance config dir (DB, indexer/profile XML,
# logs). `--nobrowser` is a no-op in headless mode but signals intent.
CMD ["/app/sonarr/bin/Sonarr", "--data=/config", "--nobrowser"]
