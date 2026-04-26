# Compose patch for `~/arrs/docker-compose.yml`

After `iter-1` is verified working (see README iteration log), apply this
patch on squirttle.

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

Drop the `PUID` and `PGID` env vars from the `sonarr:` block — the chefcai
image hardcodes UID 13001 / GID 13000 and will ignore those vars. Also drop
`UMASK` (LSIO-specific).

The bind-mounted config dir must already be owned `13001:13000`. If migrating
from LSIO with `PUID=13001 PGID=13000`, it already is. To verify and fix
preemptively (idempotent if already correct):

```bash
sudo chown -R 13001:13000 /home/haadmin/config/sonarr-config
```

## Resulting block (suggested final state)

```yaml
  sonarr:
    image: ghcr.io/chefcai/sonarr-alpine:latest
    container_name: sonarr
    init: true
    environment:
      - TZ=America/New_York
    volumes:
      - /home/haadmin/config/sonarr-config:/config
      - /mnt/Media:/media
    ports:
      - "8989:8989"
    restart: unless-stopped
```

## Rollback

Reverting is one-line — change the `image:` back to
`lscr.io/linuxserver/sonarr:latest`, re-add `PUID=13001 PGID=13000` env vars,
remove `init: true` (or leave it; it's compatible with the LSIO image too).
The `sonarr-config` directory format is identical between the two images,
so no migration of the SQLite DB or settings is needed.
