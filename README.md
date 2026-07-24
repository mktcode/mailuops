# mailuops

`mailuops` is a small, conservative command-line utility for operating a Mailu customer server and migrating existing IMAP mailboxes into it.

It provides four operations:

```text
mailuops quota get ADDRESS
mailuops quota list
mailuops migrate probe ADDRESS
mailuops migrate run ADDRESS
```

The repository contains one self-contained Bash entrypoint named `mailuops`. It can be run directly from a clone with root privileges or installed in `/usr/local/sbin`.

The utility is designed for unattended customer-server administration, but it intentionally defaults to fail-closed behavior. It never deletes source or destination messages, never accepts passwords on the command line, never silently disables certificate validation, and never starts a real migration before performing login and folder-mapping probes.

## What the commands do

| Command | Purpose | Modifies mailbox data? |
|---|---|---:|
| `quota get ADDRESS` | Show current storage use, storage limit, percentage, and message count for one Mailu mailbox | No |
| `quota list` | Show the same information for all Mailu mailboxes | No |
| `migrate probe ADDRESS` | Validate configuration, credentials, TLS, Mailu mailbox existence, quota availability, and the proposed folder mapping | No |
| `migrate run ADDRESS` | Repeat all probes and then perform an additive, one-way IMAP migration into Mailu | Yes, destination only |

Quota information is read directly from Dovecot with `doveadm quota get`. Mailu 2024.06 has no dedicated quota-display command in its administration CLI, while Dovecot is the component that maintains and enforces the mailbox quota.

Migrations use `imapsync`. Its normal operation is incremental: rerunning the same migration copies messages not already present and resynchronizes supported flags. This makes an initial copy, cutover copy, and final catch-up copy possible with the same command.

## Safety model

The following rules are part of the command contract, not optional recommendations:

- Source and destination connections use IMAPS on port 993.
- TLS peer verification is enabled explicitly for both endpoints.
- A trusted CA bundle must be supplied for both endpoints.
- Passwords are read only from protected passfiles.
- Passfiles must be regular, non-symlink files owned by root and have mode `0600`.
- Migration profiles are JSON data. They are never sourced or evaluated as shell code.
- There is no raw imapsync-argument passthrough.
- Destructive imapsync options are not exposed.
- `--delete1`, `--delete2`, folder deletion, and expunge behavior are prohibited.
- The utility explicitly requests no expunge on either endpoint.
- Every real run repeats a login probe and a dry folder-mapping probe.
- A global nonblocking lock prevents overlapping probe or migration processes.
- A real run requires typing the destination address exactly, unless `--yes` is supplied deliberately.
- Logs, state, runtime files, and temporary files are created under private directories with `umask 077`.

A successful migration does **not** change DNS, passwords, aliases, forwarding, filters, contacts, calendars, signatures, or provider-specific settings. Those remain separate cutover tasks.

## Supported environment

The initial implementation targets:

- Mailu 2024.06 deployed with Docker Compose
- Dovecot 2.3.x inside the Mailu IMAP container
- Debian 13 or a comparable GNU/Linux host with Bash installed at `/usr/bin/bash`
- Bash 5.2 or newer
- Docker CLI access
- `jq` 1.6 or newer
- GNU core utilities, including `sha256sum`, `stat`, `sort`, and `date`
- util-linux `flock`
- a locally installed `imapsync` containing the options checked during startup
- a system CA bundle, normally `/etc/ssl/certs/ca-certificates.crt` on Debian

The program does not assume that the current directory contains Mailu's Compose file. It discovers the running Dovecot container through Docker metadata or uses an explicitly configured container name.

`mailuops` is production root-only. It refuses to run when the effective UID is not 0. This avoids ambiguous Docker privilege boundaries, PATH trust, mixed ownership of configuration/secrets/logs, and partial non-root deployments.

## Installation

Clone the repository and make the entrypoint executable:

```bash
git clone YOUR-REPOSITORY-URL mailuops
cd mailuops
chmod 0755 mailuops
```

Run it from the clone:

```bash
sudo ./mailuops --help
```

Or install the executable globally:

```bash
sudo install -o root -g root -m 0755 mailuops /usr/local/sbin/mailuops
```

Create the protected configuration layout:

```bash
sudo install -d -o root -g root -m 0700 \
  /etc/mailuops \
  /etc/mailuops/migrations.d \
  /etc/mailuops/secrets \
  /var/log/mailuops \
  /var/lib/mailuops
```

`/run/mailuops` is created at runtime with mode `0700` when necessary.

## Dependencies

Verify the basic runtime dependencies:

```bash
bash --version | head -n 1
docker version --format '{{.Client.Version}}'
jq --version
flock --version
imapsync --version
```

The tool checks required commands and required imapsync options itself. It does not download or update imapsync automatically. Install and pin imapsync using a method appropriate for the server, review the source and license, and set its absolute path in the configuration.

Do not assume that `apt install imapsync` is available on every Debian release or repository configuration.

## Command synopsis

```text
Usage:
  mailuops [GLOBAL OPTIONS] quota get ADDRESS [--json]
  mailuops [GLOBAL OPTIONS] quota list [--json]
  mailuops [GLOBAL OPTIONS] migrate probe ADDRESS
  mailuops [GLOBAL OPTIONS] migrate run ADDRESS [--yes]

Global options:
  --config FILE   Read global configuration from FILE
                  Default: /etc/mailuops/config.json
  --verbose       Show additional non-secret diagnostics on stderr
  -h, --help      Show help
  --version       Show the mailuops version
```

There is no interactive password prompt. A migration profile and its passfiles must exist before `migrate probe` or `migrate run` is invoked.

## Global configuration

The default configuration path is:

```text
/etc/mailuops/config.json
```

Example:

```json
{
  "schema_version": 1,
  "mailu": {
    "imap_container": "mailu-imap-1",
    "compose_project": "mailu",
    "quota_root": "User quota"
  },
  "migration": {
    "profiles_dir": "/etc/mailuops/migrations.d",
    "secrets_dir": "/etc/mailuops/secrets",
    "imapsync_binary": "/usr/local/bin/imapsync",
    "destination": {
      "host": "mail.example.net",
      "port": 993,
      "ca_file": "/etc/ssl/certs/ca-certificates.crt"
    },
    "source_default_ca_file": "/etc/ssl/certs/ca-certificates.crt",
    "log_dir": "/var/log/mailuops",
    "state_dir": "/var/lib/mailuops",
    "runtime_dir": "/run/mailuops",
    "timeout_seconds": 120
  }
}
```

Protect it:

```bash
sudo chown root:root /etc/mailuops/config.json
sudo chmod 0600 /etc/mailuops/config.json
```

### Global configuration fields

#### `schema_version`

Must be the integer `1`. Unknown schema versions are rejected.

#### `mailu.imap_container`

An exact running Docker container name, for example `mailu-imap-1`.

Set it to `null` or omit it to enable automatic discovery. An explicit name is preferred on a host running more than one Mailu instance.

#### `mailu.compose_project`

Optional Docker Compose project name. When automatic discovery is used, this narrows containers with the label:

```text
com.docker.compose.project=mailu
```

Set it to `null` when there is only one unambiguous Mailu Dovecot container.

#### `mailu.quota_root`

The Dovecot quota root to report. Mailu commonly uses:

```text
User quota
```

Dovecot can expose more than one quota root. The utility refuses to guess when the configured root is absent or ambiguous.

#### `migration.profiles_dir`

Directory containing per-mailbox JSON migration profiles. Only direct child files ending in `.json` are considered.

#### `migration.secrets_dir`

Directory within which all source and destination password files must reside after canonical path resolution.

#### `migration.imapsync_binary`

Absolute path to the reviewed imapsync executable. Relative paths and PATH-only lookup are rejected for migration runs.

#### `migration.destination`

The Mailu IMAPS endpoint shared by all migration profiles:

- `host`: DNS hostname presented in the Mailu TLS certificate
- `port`: must be `993` in schema version 1
- `ca_file`: readable CA bundle used to authenticate the certificate

Use the public Mailu IMAP hostname, not a Docker container name, unless the certificate is valid for that exact name and the address is reachable from the host.

#### `migration.source_default_ca_file`

Default CA bundle for source providers. A profile can override it for a provider that uses a private CA. Do not work around an untrusted certificate by disabling verification; install the provider's CA into a dedicated bundle instead.

#### Runtime paths

- `log_dir`: durable operation logs
- `state_dir`: durable non-secret state
- `runtime_dir`: locks, PID files, and operation-local temporary files

All three must be absolute paths. The tool creates missing leaf directories with mode `0700` but does not create missing parent hierarchies outside the configured path.

#### `migration.timeout_seconds`

Positive integer passed to both imapsync endpoint timeouts. The default example is 120 seconds.

## Per-mailbox migration profiles

Create one JSON file per source mailbox under `/etc/mailuops/migrations.d`.

The filename is not used as the mailbox identifier. The tool scans profiles and matches the `address` field exactly. This avoids deriving a filesystem path from untrusted command-line input.

Example `/etc/mailuops/migrations.d/example-info.json`:

```json
{
  "schema_version": 1,
  "address": "info@example.com",
  "source": {
    "host": "imap.old-provider.example",
    "port": 993,
    "username": "info@example.com",
    "password_file": "/etc/mailuops/secrets/info.source.pass",
    "ca_file": "/etc/ssl/certs/ca-certificates.crt"
  },
  "destination": {
    "username": "info@example.com",
    "password_file": "/etc/mailuops/secrets/info.destination.pass"
  },
  "folders": {
    "automap": true,
    "map": [
      {
        "from": "Sent Items",
        "to": "Sent"
      },
      {
        "from": "Deleted Items",
        "to": "Trash"
      }
    ]
  }
}
```

Protect every profile:

```bash
sudo chown root:root /etc/mailuops/migrations.d/*.json
sudo chmod 0600 /etc/mailuops/migrations.d/*.json
```

### Profile fields

#### `schema_version`

Must be the integer `1`.

#### `address`

The destination Mailu mailbox selected by the CLI. It must match the CLI address exactly and must resolve through Mailu's Dovecot user database.

Use lower-case addresses consistently unless the Mailu installation intentionally uses a different canonical form.

#### `source`

- `host`: source provider's certificate-valid IMAPS hostname
- `port`: must be `993` in schema version 1
- `username`: source provider login name; it may differ from `address`
- `password_file`: protected passfile within `migration.secrets_dir`
- `ca_file`: optional CA bundle override; otherwise `source_default_ca_file` is used

Schema version 1 uses username/password IMAP authentication. OAuth-only providers are not supported by this version.

#### `destination`

- `username`: Mailu IMAP login, normally identical to `address`
- `password_file`: protected Mailu passfile within `migration.secrets_dir`

The destination host, port, and CA bundle come from the global configuration so that a profile cannot redirect imported customer mail to an arbitrary server.

#### `folders.automap`

Boolean. When true, imapsync's known-folder mapping is enabled. This helps map provider names such as Sent, Drafts, Junk, Archive, and Trash.

Automatic mapping is always previewed by `migrate probe` and again immediately before a real run.

#### `folders.map`

Optional array of explicit one-to-one folder mappings. Each element has:

- `from`: complete source folder name
- `to`: complete destination folder name

Explicit mappings are passed as individual `--f1f2` arguments and take precedence over automatic mapping. Duplicate mappings, empty names, control characters, newlines, and `=` characters are rejected in schema version 1.

Omit explicit mappings until the dry folder plan demonstrates that they are necessary.

Unknown JSON keys are rejected. A misspelled safety-relevant setting must not be silently ignored.

## Password files

Create the source and destination passfiles without placing passwords in shell history:

```bash
sudo bash -c 'umask 077; read -r -s -p "Source IMAP password: " p; printf "\n"; printf "%s\n" "$p" > /etc/mailuops/secrets/info.source.pass; unset p'

sudo bash -c 'umask 077; read -r -s -p "Mailu migration password: " p; printf "\n"; printf "%s\n" "$p" > /etc/mailuops/secrets/info.destination.pass; unset p'
```

Then enforce ownership and mode:

```bash
sudo chown root:root \
  /etc/mailuops/secrets/info.source.pass \
  /etc/mailuops/secrets/info.destination.pass

sudo chmod 0600 \
  /etc/mailuops/secrets/info.source.pass \
  /etc/mailuops/secrets/info.destination.pass
```

Each passfile contains the password on its first line. The utility rejects:

- symlinks
- non-regular files
- files outside the configured secrets directory
- files not owned by root
- modes other than `0600`
- empty first lines
- additional nonempty lines

Use a temporary Mailu password for migration where operationally possible. Rotate it after the final catch-up sync. The source provider password should also be changed or retired after migration.

## Quota commands

### Show one mailbox

```bash
sudo mailuops quota get info@example.com
```

Example output:

```text
Mailbox:        info@example.com
Storage used:   1.08 MiB
Storage limit:  1.40 GiB
Usage:          0.08%
Messages:       24
```

The utility first verifies the mailbox with Dovecot's user database and then runs the equivalent of:

```bash
docker exec mailu-imap-1 \
  doveadm -f json quota get -u info@example.com
```

Dovecot reports storage values in kilobytes. `mailuops` treats those values as 1024-byte KiB, converts them to IEC display units, and calculates a non-rounded percentage from the reported values.

For an unlimited quota:

```text
Mailbox:        archive@example.net
Storage used:   37.24 GiB
Storage limit:  unlimited
Usage:          n/a
Messages:       182340
```

### Show all mailboxes

```bash
sudo mailuops quota list
```

Example output:

```text
MAILBOX                                      USED       LIMIT     USAGE   MESSAGES
archive@example.net                    37.24 GiB   unlimited       n/a     182340
info@example.com                         1.08 MiB    1.40 GiB     0.08%         24
postmaster@example.net                       0 B    1.00 GiB     0.00%          0
```

The all-mailbox command uses Dovecot's native all-user operation rather than invoking one Docker process per mailbox:

```bash
docker exec mailu-imap-1 \
  doveadm -f json quota get -A
```

Rows are sorted by mailbox address for deterministic output. The command fails instead of presenting partial data when Dovecot returns an error or an unrecognized output structure.

### Machine-readable quota output

Add `--json`:

```bash
sudo mailuops quota get info@example.com --json
sudo mailuops quota list --json
```

Single-mailbox schema:

```json
{
  "mailbox": "info@example.com",
  "quota_root": "User quota",
  "storage": {
    "used_kib": 1110,
    "limit_kib": 1464844,
    "used_bytes": 1136640,
    "limit_bytes": 1500000256,
    "percent": 0.075776
  },
  "messages": {
    "used": 24,
    "limit": null,
    "percent": null
  }
}
```

`quota list --json` returns an array of the same objects, sorted by `mailbox`.

The JSON percentage is a number in the range 0 through 100, not a fraction. A missing or unlimited limit is represented by `null`. JSON mode writes JSON only to stdout; diagnostics remain on stderr.

## Migration probe

Run a probe before every initial migration and after every profile change:

```bash
sudo mailuops migrate probe info@example.com
```

The probe performs these checks in order:

1. Acquires the global migration lock.
2. Validates the global configuration and matching mailbox profile.
3. Validates ownership, mode, file type, canonical path, and containment of all sensitive files.
4. Locates and validates the running Mailu Dovecot container.
5. Verifies that the destination mailbox exists in Dovecot.
6. Reads and displays the destination quota and fails when a finite quota has no remaining capacity.
7. Verifies the selected imapsync executable and all required options.
8. Rejects an obviously identical source and destination endpoint.
9. Performs an imapsync `--justlogin` test against both endpoints.
10. Performs an imapsync `--dry --justfolders` pass and displays the proposed folder mapping.

The probe forces IMAPS and certificate verification on both sides. It does not create folders, copy messages, change flags, or expunge anything.

A successful probe ends with a summary similar to:

```text
Migration probe: info@example.com
Source:      info@example.com @ imap.old-provider.example:993 (verified IMAPS)
Destination: info@example.com @ mail.example.net:993 (verified IMAPS)
Mailu quota: 1.08 MiB used of 1.40 GiB
Login test:  passed
Folder plan: passed; see /var/log/mailuops/20260721T143210Z-info_example.com-fb1a4757f83b/
Result:      safe to run an additive migration
```

Inspect the folder plan in the terminal and log. Pay particular attention to Sent, Trash, Junk, Drafts, Archive, and any provider-specific folders. Adjust `folders.map`, rerun the probe, and proceed only when the mapping is correct.

## Run a migration

Interactive run:

```bash
sudo mailuops migrate run info@example.com
```

After validation, login testing, and the dry folder plan, the tool prints a redacted operation summary and requires an exact confirmation:

```text
This operation will add or update mail in the destination mailbox.
It will not delete or expunge messages on either endpoint.

Type the destination mailbox exactly to continue: info@example.com
```

For controlled automation:

```bash
sudo mailuops migrate run info@example.com --yes
```

`--yes` suppresses only the exact-address prompt. It does not skip the lock, file checks, TLS checks, mailbox check, quota check, login test, or dry folder plan. A noninteractive invocation without `--yes` fails.

Immediately before the real transfer, the tool repeats the login test. It then runs imapsync with additive settings equivalent to the following conceptual argument set:

```text
--ssl1 --ssl2
--sslargs1 SSL_verify_mode=1
--sslargs2 SSL_verify_mode=1
--sslargs1 SSL_ca_file=SOURCE_CA_FILE
--sslargs2 SSL_ca_file=DESTINATION_CA_FILE
--passfile1 SOURCE_PASSFILE
--passfile2 DESTINATION_PASSFILE
--subscribe
--resyncflags
--syncinternaldates
--noexpunge1
--noexpunge2
--nouidexpunge2
--pidfile PHASE_SPECIFIC_PIDFILE
--pidfilelocking
--tmpdir PRIVATE_OPERATION_TMPDIR
--logdir PRIVATE_OPERATION_LOG_DIR
--logfile PHASE_LOG_BASENAME
--noreleasecheck
```

`--automap` and validated `--f1f2` arguments are appended from the mailbox profile. Passwords are never expanded into the process argument list.

The utility mirrors imapsync output to the terminal and a private console log while preserving imapsync's actual exit status. On success it displays the new Mailu quota. Failure logs are retained for diagnosis.

## Recommended migration and DNS cutover sequence

For each mailbox:

1. Create the destination domain and mailbox in Mailu.
2. Assign a quota large enough for the existing mailbox plus expected growth.
3. Create a temporary destination password when possible.
4. Create the migration profile and both protected passfiles.
5. Confirm destination capacity:

   ```bash
   sudo mailuops quota get info@example.com
   ```

6. Probe credentials and mappings:

   ```bash
   sudo mailuops migrate probe info@example.com
   ```

7. Perform the initial copy while the source mailbox is still live:

   ```bash
   sudo mailuops migrate run info@example.com
   ```

8. Verify folders, messages, dates, attachments, read/unread state, and sent mail in Mailu.
9. Change MX and client-facing mail DNS to Mailu according to the deployment's cutover plan.
10. Keep the old provider mailbox active during DNS propagation.
11. Rerun the same migration command to copy mail that arrived at the old provider during the transition:

    ```bash
    sudo mailuops migrate run info@example.com
    ```

12. Perform a final catch-up run after the old provider has stopped receiving new mail.
13. Record the final quota and verify representative messages.
14. Rotate the Mailu migration password, retire the old provider credentials, and remove the passfiles and profile when retention is no longer required.

Do not cancel the old provider immediately after changing MX records. Cached DNS and remote sender behavior can continue delivering mail to the old system for some time.

## Logs and runtime data

Each probe or run creates a private operation directory under `migration.log_dir`:

```text
/var/log/mailuops/
└── 20260721T143210Z-info_example.com-fb1a4757f83b/
    ├── wrapper.log
    ├── 01-login.imapsync.log
    ├── 01-login.console.log
    ├── 02-folders.imapsync.log
    ├── 02-folders.console.log
    ├── 03-login.imapsync.log
    ├── 03-login.console.log
    ├── 04-sync.imapsync.log
    └── 04-sync.console.log
```

Probe operations normally contain only the first two phases. Run operations contain the repeated login and real sync phases.

Operation identifiers use a sanitized mailbox fragment plus a short SHA-256 suffix. Raw addresses are never used unchecked as filesystem paths.

The runtime directory contains the global lock, phase-specific PID files, and private temporary data. Each phase receives a unique PID file and imapsync is invoked with pidfile locking; the wrapper does not blindly delete PID files that may belong to an active process.

Logs can contain mailbox names, server names, folder names, message statistics, and imapsync diagnostics. They must be treated as customer data. Password values must never appear, but passfile paths and account metadata may appear in diagnostic context.

Define a log retention and deletion policy appropriate for the server's data-protection obligations.

## Exit behavior

`0` means the requested operation completed successfully.

For migration phases, a nonzero imapsync status is returned unchanged whenever possible. This preserves distinctions such as TLS failure, source or destination connection failure, authentication failure, and destination over-quota failure.

Common imapsync statuses include:

| Status | Meaning |
|---:|---|
| `12` | TLS failure |
| `101` | Source connection failure |
| `102` | Destination connection failure |
| `113` | Destination over quota |
| `161` | Source authentication failure |
| `162` | Destination authentication failure |

Wrapper validation failures use conventional nonzero statuses and a clear diagnostic on stderr. Scripts should test for zero versus nonzero unless they deliberately handle a documented imapsync status.

The program does not print a success message after a failed or interrupted imapsync process.

## Container discovery

Container selection follows this order:

1. Use `mailu.imap_container` when configured.
2. Otherwise select a running container with `com.docker.compose.service=imap`, narrowed by `mailu.compose_project` when set.
3. Otherwise select exactly one running container whose image is `ghcr.io/mailu/dovecot:*`.
4. Fail when there are zero or multiple candidates.

After selection, the tool verifies that the container is running and that `doveadm` and the quota subcommand are available inside it.

An explicit container is recommended when a host serves multiple Mailu installations:

```json
{
  "mailu": {
    "imap_container": "customer-a-imap-1",
    "compose_project": "customer-a",
    "quota_root": "User quota"
  }
}
```

## Troubleshooting

### No Mailu Dovecot container found

Check running containers:

```bash
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Labels}}'
```

Set `mailu.imap_container` to the exact running IMAP container name.

### Multiple Dovecot containers found

Configure both `mailu.compose_project` and `mailu.imap_container`. The utility intentionally refuses to choose an arbitrary customer instance.

### Mailbox not found

Verify it directly:

```bash
docker exec mailu-imap-1 doveadm user info@example.com
```

Create or enable the mailbox in Mailu before migrating. Aliases are not destination mailboxes and cannot receive an IMAP mailbox import by themselves.

### Quota output is unavailable

Verify the Dovecot command:

```bash
docker exec mailu-imap-1 doveadm quota get -u info@example.com
```

The quota plugin must be enabled. Do not automatically run `quota recalc` as part of routine display; recalculation can be expensive and is an explicit administrative repair operation.

### Source or destination TLS failure

Confirm that:

- the configured host is the certificate hostname, not merely an IP address
- port 993 is reachable
- the certificate chain is complete
- the correct CA bundle is configured
- system time is accurate

Do not add an insecure mode. For a private CA, create a trusted bundle containing the correct CA certificate and reference it in the configuration.

A basic certificate inspection can be performed without sending credentials:

```bash
openssl s_client \
  -connect imap.old-provider.example:993 \
  -servername imap.old-provider.example \
  -verify_return_error </dev/null
```

### Authentication failure

Check the source provider's exact IMAP username, whether basic password authentication is still permitted, and whether an application-specific password is required. Schema version 1 does not support OAuth-only providers.

For Mailu, verify the temporary destination password by logging in through a normal IMAP client or rerunning `migrate probe` after replacing the destination passfile.

### Wrong folder mapping

Do not run the migration. Update `folders.map`, then repeat:

```bash
sudo mailuops migrate probe info@example.com
```

Use explicit mappings only after observing the dry plan. Provider folder names are case-sensitive and can contain hierarchy separators.

### Destination over quota

Increase the Mailu mailbox quota or remove unrelated destination data using a separately reviewed procedure. Then verify:

```bash
sudo mailuops quota get info@example.com
```

Rerun the same migration after capacity is available. Incremental behavior normally avoids retransferring messages already copied successfully.

### Interrupted migration

Inspect the operation logs and ensure that no imapsync process remains:

```bash
pgrep -a -f '[i]mapsync'
```

Then rerun `migrate probe` and `migrate run`. Do not manually delete a PID file while an imapsync process may still be using it.

### imapsync option check fails

The installed version lacks an option required by the safety contract. Install a reviewed compatible version or update the repository only after tests and documentation have been adapted. The utility must not silently omit a safety option to accommodate an older executable.

## Deliberate non-features

Schema version 1 does not provide:

- source or destination deletion
- strict mirroring with `--delete2`
- source cleanup with `--delete1`
- folder deletion
- expunge operations
- raw imapsync argument passthrough
- passwords in arguments or environment variables
- unverified TLS
- plaintext IMAP
- STARTTLS mode
- OAuth token handling
- administrative master-user migration
- parallel migrations
- automatic DNS changes
- automatic password rotation
- mailbox creation or quota modification
- contacts, calendars, Sieve rules, identities, signatures, or forwarding migration

These omissions keep the utility's operational scope narrow and auditable. A future feature that changes the safety boundary requires a schema-version change, explicit documentation, and dedicated tests.

## Why the utility uses Dovecot directly

Mailu's administration CLI manages configuration objects such as domains, users, passwords, aliases, and imports. Mailbox usage is runtime state maintained by Dovecot. Dovecot provides native quota queries for one user and all users, plus structured JSON output.

Mailu also has a REST API, but enabling and authenticating an HTTP API solely for local quota inspection adds unnecessary exposure and configuration. `mailuops` therefore queries Dovecot inside the already running Mailu IMAP container.

## Reference documentation

The behavior and command contract are based on:

- [Mailu 2024.06 command-line documentation](https://mailu.io/2024.06/cli.html)
- [Mailu 2024.06 REST API documentation](https://mailu.io/2024.06/api.html)
- [Dovecot `doveadm-quota` manual](https://doc.dovecot.org/main/core/man/doveadm-quota.1.html)
- [imapsync upstream repository and manual](https://github.com/imapsync/imapsync)
- [imapsync security FAQ](https://imapsync.lamiral.info/FAQ.d/FAQ.Security.txt)

Use documentation matching the installed Mailu and Dovecot versions. Review upstream imapsync changes before replacing the pinned executable.

## Repository development

Implementation requirements, invariants, tests, and acceptance criteria for coding agents are defined in [`AGENTS.md`](AGENTS.md).
