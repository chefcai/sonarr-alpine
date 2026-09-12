# Compose patch for `~/arrs/docker-compose.yml`

After `iter-1` is verified working (see README iteration log), apply this
patch on a resource-constrained homelab host.

## One-line replacement

In the `sonarr:` service block, change:

```yaml
    image: lscr.io/linuxserver/sonarr:latest
```

to:

```yaml
    image: ghcr.io/chefcai/sonarr-alpine:latest
```

## Required compose-level additions

The chefcai image does not ship s6-overlay, so PID 1 must be provided by
Docker. Add (or confirm present) at the same indent as `image:`:

```yaml
    init: true
```

Keep the `PUID` and `PGID` env vars in the `sonarr:` block -- the chefcai
image reads them directly (default 1000:1000 if unset). Drop `UMASK`
though; that one is LSIO-specific and has no equivalent here.

The bind-mounted config dir must be owned by whatever UID/GID you set via
`PUID`/`PGID` (default 1000:1000 if unset). If migrating from LSIO with
`PUID=13001 PGID=13000`, keep those values and it already is. To verify
and fix preemptively (idempotent if already correct):

```bash
sudo chown -R 1000:1000 /path/to/sonarr-config
```

## Resulting block (suggested final state)

```yaml
  sonarr:
    image: ghcr.io/chefcai/sonarr-alpine:latest
    container_name: sonarr
    init: true
    environment:
      - TZ=UTC  # override to your local zone
    volumes:
      - /path/to/sonarr-config:/config
      - /mnt/Media:/media
    ports:
      - "8989:8989"
    restart: unless-stopped
```

## Rollback

Reverting is one-line — change the `image:` back to
`lscr.io/linuxserver/sonarr:latest` (the `PUID=13001 PGID=13000` env vars
can stay, LSIO reads them too), remove `init: true` (or leave it; it's
compatible with the LSIO image too).
The `sonarr-config` directory format is identical between the two images,
so no migration of the SQLite DB or settings is needed.
