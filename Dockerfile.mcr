# sonarr-alpine — iter-3 variant: mcr.microsoft.com/dotnet/aspnet:6.0-alpine.
#
# Hypothesis (this iteration is **measurement only**): Microsoft's
# aspnet:6.0-alpine ships the .NET 6 runtime in /usr/share/dotnet/, AND we
# leave Sonarr's self-contained tarball intact (it bundles its own copy in
# /app/sonarr/bin/). That means this image is strictly larger than iter-1
# (which uses bare alpine:3.21 with NO base-image runtime).
#
# Why bother building it then? To produce a credible "we measured this base
# and it lost by N MB" entry in the iteration log. The brief was "build on at
# least three bases before picking one." This is base #3.
#
# A "real" iter-3 would rebuild Sonarr from source with
# `<SelfContained>false</SelfContained>` (its repo's actual default) and use
# the MCR base's runtime instead of bundling. That requires a Sonarr
# msbuild/yarn build chain — way out of scope for the chefcai/*-alpine
# pattern, which only fetches release tarballs.
#
# Build with:  workflow_dispatch  →  dockerfile=Dockerfile.mcr,
#                                    tag_suffix=iter3-mcr

ARG SONARR_VERSION=4.0.17.2952
ARG SONARR_BRANCH=main

# ---- Stage 1: fetch & unpack ---------------------------------------------
FROM alpine:3.21 AS fetch
ARG SONARR_VERSION
ARG SONARR_BRANCH

RUN apk add --no-cache curl tar

WORKDIR /work
RUN curl -fsSL \
        "https://services.sonarr.tv/v1/update/${SONARR_BRANCH}/download?version=${SONARR_VERSION}&os=linuxmusl&runtime=netcore&arch=x64" \
        -o /work/sonarr.tar.gz \
 && mkdir -p /work/sonarr \
 && tar xzf /work/sonarr.tar.gz -C /work/sonarr --strip-components=1 \
 && rm /work/sonarr.tar.gz

RUN set -eux; \
    cd /work/sonarr; \
    rm -rf Sonarr.Update Sonarr.Update.* update; \
    find . -name '*.pdb' -type f -delete; \
    find . -name '*.xml' -path '*/ref/*' -type f -delete 2>/dev/null || true; \
    rm -rf logs MediaCover .git .github 2>/dev/null || true

ARG SONARR_VERSION
RUN printf 'UpdateMethod=docker\nBranch=%s\nPackageVersion=%s\nPackageAuthor=[chefcai/sonarr-alpine](https://github.com/chefcai/sonarr-alpine)\n' \
        "${SONARR_BRANCH:-main}" "${SONARR_VERSION}" \
        > /work/sonarr/package_info

# ---- Stage 2: runtime — Microsoft's aspnet:6.0-alpine --------------------
FROM mcr.microsoft.com/dotnet/aspnet:6.0-alpine
ARG SONARR_VERSION

LABEL org.opencontainers.image.title="sonarr-alpine (mcr aspnet:6.0-alpine variant — iter-3 measurement)"
LABEL org.opencontainers.image.source="https://github.com/chefcai/sonarr-alpine"
LABEL org.opencontainers.image.version="${SONARR_VERSION}"

ENV COMPlus_EnableDiagnostics=0 \
    XDG_CONFIG_HOME=/config/xdg \
    TZ=UTC

USER root
# aspnet:6.0-alpine already has icu-libs and ca-certificates baked in. We
# only need to add sqlite-libs (Sonarr's native sqlite wrapper P/Invokes it)
# and tzdata (the base ships timezone-tz but not /usr/share/zoneinfo).
RUN apk add --no-cache sqlite-libs tzdata \
 && addgroup -g 13000 sonarr \
 && adduser -D -u 13001 -G sonarr -h /config -s /sbin/nologin sonarr \
 && mkdir -p /config /app /media \
 && chown -R sonarr:sonarr /config /app /media

COPY --from=fetch --chown=sonarr:sonarr /work/sonarr /app/sonarr/bin

USER sonarr
WORKDIR /app/sonarr
EXPOSE 8989

HEALTHCHECK --interval=1m30s --timeout=10s --retries=3 --start-period=60s \
    CMD wget --no-verbose --tries=1 --spider http://localhost:8989/ping || exit 1

# Use the bundled AppHost (same as iter-1). The MCR base's /usr/share/dotnet/
# runtime is unused — Sonarr's self-contained lib/ takes precedence. This is
# the "negative result" iteration: shows what happens when you put the MCR
# base under a self-contained app.
CMD ["/app/sonarr/bin/Sonarr", "--data=/config", "--nobrowser"]
