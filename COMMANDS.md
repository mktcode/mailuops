# Useful Mailu copy/paste commands

This file is a collection of practical commands for a Mailu host when you do **not** want to install `mailuops` or any extra helper.

Assumptions:

- Run these on the Docker host that runs Mailu.
- You already have Docker CLI access.
- Commands expect common tools normally present on Linux hosts plus `jq`: `bash`, `docker`, `jq`, `grep`, `awk`, `sort`, `date`, `find`, `du`, `stat`, `column`.
- Install `jq` from the distribution package manager if it is missing; structured Mailu/Dovecot output is much safer to inspect with JSON parsing than table parsing.

Most commands are read-only. Commands that can change state are explicitly marked.

## Set convenience variables

### Find the Mailu IMAP/Dovecot container by Compose label

Fails if zero or multiple IMAP containers are found.

```bash
mapfile -t IMAP_CONTAINERS < <(
  docker ps \
    --filter 'label=com.docker.compose.service=imap' \
    --format '{{.Names}}'
)

if [ "${#IMAP_CONTAINERS[@]}" -ne 1 ]; then
  printf 'Expected exactly one Mailu IMAP container, found %s:\n' "${#IMAP_CONTAINERS[@]}" >&2
  printf '  %s\n' "${IMAP_CONTAINERS[@]}" >&2
  exit 1
fi

IMAP_CONTAINER=${IMAP_CONTAINERS[0]}
printf 'IMAP_CONTAINER=%s\n' "$IMAP_CONTAINER"
```

### Find the Mailu admin container by Compose label

```bash
mapfile -t ADMIN_CONTAINERS < <(
  docker ps \
    --filter 'label=com.docker.compose.service=admin' \
    --format '{{.Names}}'
)

if [ "${#ADMIN_CONTAINERS[@]}" -ne 1 ]; then
  printf 'Expected exactly one Mailu admin container, found %s:\n' "${#ADMIN_CONTAINERS[@]}" >&2
  printf '  %s\n' "${ADMIN_CONTAINERS[@]}" >&2
  exit 1
fi

ADMIN_CONTAINER=${ADMIN_CONTAINERS[0]}
printf 'ADMIN_CONTAINER=%s\n' "$ADMIN_CONTAINER"
```

### List Mailu-related containers

```bash
docker ps \
  --filter 'label=com.docker.compose.project' \
  --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Labels}}' \
  | grep -E 'mailu|ghcr.io/mailu' || true
```

## Mailu admin CLI discovery

The Mailu admin container normally exposes Mailu's Flask CLI. Start with help output so the exact command surface matches your installed Mailu version.

```bash
docker exec -it "$ADMIN_CONTAINER" flask mailu --help
```

Show help for user-related commands:

```bash
docker exec -it "$ADMIN_CONTAINER" flask mailu user --help
```

Show help for domain-related commands:

```bash
docker exec -it "$ADMIN_CONTAINER" flask mailu domain --help
```

Show help for alias-related commands:

```bash
docker exec -it "$ADMIN_CONTAINER" flask mailu alias --help
```

## Mailbox existence and user database

### Check whether Dovecot knows a mailbox

```bash
ADDRESS='info@example.com'
docker exec "$IMAP_CONTAINER" doveadm user "$ADDRESS"
```

### Show Dovecot userdb fields for a mailbox

```bash
ADDRESS='info@example.com'
docker exec "$IMAP_CONTAINER" doveadm user -f table "$ADDRESS"
```

## Quota inspection

### Show quota for one mailbox, human/table output

```bash
ADDRESS='info@example.com'
docker exec "$IMAP_CONTAINER" doveadm quota get -u "$ADDRESS"
```

### Show quota for one mailbox, JSON output

```bash
ADDRESS='info@example.com'
docker exec "$IMAP_CONTAINER" doveadm -f json quota get -u "$ADDRESS"
```

### Show quota for all mailboxes in one command

```bash
docker exec "$IMAP_CONTAINER" doveadm quota get -A
```

### Show quota for all mailboxes as JSON

```bash
docker exec "$IMAP_CONTAINER" doveadm -f json quota get -A
```

### Quick quota summary with jq

```bash
docker exec "$IMAP_CONTAINER" doveadm -f json quota get -A \
  | jq -r '
      ["mailbox","root","type","value","limit"],
      (.[] | [(.username // .user // ""), (.quota_name // .root // .name // ""), (.quota_type // .type // ""), (.value|tostring), (.limit|tostring)])
      | @tsv
    ' \
  | column -t -s $'\t'
```

## Dovecot health checks

### Confirm doveadm exists in the IMAP container

```bash
docker exec "$IMAP_CONTAINER" doveadm | head -40
```

### Show Dovecot version

```bash
docker exec "$IMAP_CONTAINER" dovecot --version
```

### Show enabled Dovecot protocols/config hints

```bash
docker exec "$IMAP_CONTAINER" doveconf protocols mail_plugins | sort
```

### Test IMAP login from inside the IMAP container

This checks authentication only. It does not copy or delete mail.

```bash
ADDRESS='info@example.com'
docker exec -it "$IMAP_CONTAINER" doveadm auth test "$ADDRESS"
```

## Logs

### Follow Mailu IMAP logs

```bash
docker logs -f --tail=200 "$IMAP_CONTAINER"
```

### Follow admin container logs

```bash
docker logs -f --tail=200 "$ADMIN_CONTAINER"
```

### Show recent errors from all running Mailu containers

```bash
for c in $(docker ps --format '{{.Names}}' | grep -E 'mailu|imap|admin|front|smtp|antispam|redis'); do
  printf '\n===== %s =====\n' "$c"
  docker logs --since=1h "$c" 2>&1 | grep -Ei 'error|warning|fail|fatal|panic|traceback' | tail -100 || true
done
```

## Mail storage inspection

### Show largest directories under Mailu volumes

Adjust the volume path if your Mailu deployment stores mail elsewhere.

```bash
sudo du -hxd1 /var/lib/docker/volumes 2>/dev/null \
  | sort -h \
  | tail -30
```

### Find Mailu Docker volumes

```bash
docker volume ls --format '{{.Name}}' | grep -Ei 'mailu|mail|imap|dovecot'
```

### Inspect a Mailu volume mountpoint

```bash
VOLUME='mailu_mail'
docker volume inspect "$VOLUME" --format '{{.Mountpoint}}'
```

## TLS and network checks

### Check the public IMAPS certificate

Run from any Linux host with OpenSSL.

```bash
IMAP_HOST='mail.example.net'
openssl s_client \
  -connect "$IMAP_HOST:993" \
  -servername "$IMAP_HOST" \
  -verify_return_error </dev/null
```

### Check whether port 993 is listening on the host

```bash
ss -ltnp | grep ':993 ' || true
```

### Check published Docker ports

```bash
docker ps --format 'table {{.Names}}\t{{.Ports}}' | grep -E '993|143|25|465|587|80|443'
```

## Backups and state snapshots

### List Mailu-related volumes before backup work

```bash
docker volume ls --format '{{.Name}}' | grep -Ei 'mailu|mail|imap|dovecot|redis|postgres|database'
```

### Record a lightweight diagnostic snapshot

This creates a text file only; it does not include mailbox contents or passwords.

```bash
OUT="mailu-diagnostic-$(date -u +%Y%m%dT%H%M%SZ).txt"
{
  printf 'Generated: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '\n## Containers\n'
  docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
  printf '\n## Volumes\n'
  docker volume ls
  printf '\n## Mailu images\n'
  docker images | grep -Ei 'mailu|dovecot|postfix|rspamd|redis|nginx' || true
} >"$OUT"
chmod 0600 "$OUT"
printf 'Wrote %s\n' "$OUT"
```

## State-changing commands

Use the following only when you understand the impact.

### Recalculate quota for one mailbox

This can be expensive on large mailboxes. Prefer inspecting quota first.

```bash
ADDRESS='info@example.com'
printf 'About to recalculate Dovecot quota for %s. Press Enter to continue or Ctrl-C to abort.\n' "$ADDRESS"
read -r _
docker exec "$IMAP_CONTAINER" doveadm quota recalc -u "$ADDRESS"
docker exec "$IMAP_CONTAINER" doveadm quota get -u "$ADDRESS"
```

### Restart one Mailu container

```bash
CONTAINER="$IMAP_CONTAINER"
printf 'About to restart container %s. Press Enter to continue or Ctrl-C to abort.\n' "$CONTAINER"
read -r _
docker restart "$CONTAINER"
```

## Notes

- Prefer Docker `--format` output over parsing the default human table.
- Avoid loops that run one Docker command per mailbox unless you really need per-user behavior.
- Use `doveadm -f json` when writing scripts around quota output.
- Do not put mailbox passwords in commands, environment variables, shell history, or logs.
- For migrations, use a reviewed `imapsync` command and avoid delete/expunge options unless you are deliberately performing destructive cleanup.
