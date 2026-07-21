# AGENTS.md

This file is the implementation contract for coding agents working on `mailu-ops`.

Read `README.md` first. The README defines the user-facing behavior. This file defines the engineering constraints necessary to implement that behavior safely.

## Project objective

Implement one auditable Bash CLI, `mailu-ops`, for a Mailu 2024.06 customer server. It must support exactly these operational commands in version 1:

```text
mailu-ops quota get ADDRESS [--json]
mailu-ops quota list [--json]
mailu-ops migrate probe ADDRESS
mailu-ops migrate run ADDRESS [--yes]
```

Global `--config`, `--verbose`, `--help`, and `--version` are also required.

The implementation must be safe for multiple domains and many customer mailboxes. Correct refusal is preferable to a guessed or partial operation.

## Non-negotiable invariants

These requirements override convenience and backward compatibility:

1. The program is additive-only for migrations.
2. It must not expose or generate destructive imapsync options.
3. It must explicitly pass `--noexpunge1`, `--noexpunge2`, and `--nouidexpunge2` during every imapsync phase where those options are accepted.
4. It must never pass `--delete1`, `--delete2`, any destination/source folder deletion option, `--expunge1`, `--expunge2`, `--uidexpunge2`, or equivalents.
5. It must not accept arbitrary extra imapsync arguments from config, environment, or CLI.
6. It must not use `eval`, `bash -c`, `sh -c`, command strings, or sourced configuration.
7. External commands must be constructed as Bash arrays and invoked directly.
8. Passwords must be supplied only through imapsync `--passfile1` and `--passfile2`.
9. Password values must never be placed in argv, environment variables, logs, error messages, or process titles.
10. Both endpoints must use explicit IMAPS with `--ssl1` and `--ssl2`.
11. Both endpoints must use `SSL_verify_mode=1` and an explicit readable CA file.
12. No insecure TLS override may exist.
13. `migrate probe` and `migrate run` must acquire the same global nonblocking lock before shared operational preflight.
14. `migrate run` must perform a login test and dry folder plan before confirmation, then repeat the login test immediately before the real transfer.
15. A noninteractive real run must require `--yes`.
16. Interactive confirmation must require an exact match of the destination mailbox, not `y`, `yes`, or a default answer.
17. Quota commands must use Dovecot's JSON formatter. Do not parse the aligned table.
18. `quota list` must use one native `doveadm ... quota get -A` invocation, not a shell loop that starts one Docker process per user.
19. Unknown configuration keys and unknown schema versions must be rejected.
20. Ambiguous container discovery, ambiguous profile matching, ambiguous quota roots, and malformed external output must fail closed.
21. The implementation must set `umask 077` before creating any runtime, state, log, temporary, or PID file.
22. stdout is command data; diagnostics go to stderr. JSON mode must emit valid JSON and nothing else on stdout.
23. Exact imapsync exit statuses must be preserved for failed imapsync phases whenever the shell permits it.
24. Interrupted or failed processes must never be reported as successful.

Do not weaken these invariants to make a test pass or support an old dependency.

## Repository layout

Implement this minimal layout:

```text
.
├── mailu-ops
├── README.md
├── AGENTS.md
├── examples/
│   ├── config.json
│   └── migrations.d/
│       └── example.json
└── tests/
    ├── helpers/
    ├── fixtures/
    ├── stubs/
    ├── quota.bats
    ├── config.bats
    ├── migration.bats
    └── security.bats
```

`mailu-ops` must be executable and self-contained. Do not split runtime code into sourced shell files. A single file reduces deployment errors and prevents config/source confusion.

Test helpers may be sourced by Bats tests.

## Runtime language and shell rules

Use Bash, not POSIX `sh`.

Required header:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
```

Also set a deterministic locale early:

```bash
export LC_ALL=C
```

Use:

- indexed arrays for command construction
- associative arrays only when they improve clarity and do not hide ordering
- `printf`, never `echo` for variable data
- `[[ ... ]]` for tests
- `mapfile` with NUL-delimited input where filenames are enumerated
- `local` variables inside functions
- explicit `--` terminators for utilities that support them
- `trap` for `ERR`, `INT`, `TERM`, `HUP`, and cleanup

Do not use:

- `eval`
- `source` or `.` on configuration files
- `bash -c` or `sh -c`
- unquoted expansions
- dynamically generated shell fragments
- `for file in $(find ...)`
- parsing `ls`
- temporary files in a shared `/tmp` path
- silent `|| true` around security checks

Pass ShellCheck without project-wide suppression. A local suppression is allowed only with a comment explaining the precise false positive.

Format with `shfmt` using a documented repository configuration or fixed CI arguments.

## Dependencies

The executable may depend on:

- Bash 5.2+
- Docker CLI
- jq 1.6+
- util-linux `flock`
- GNU `stat`, `date`, `sort`, `find`, `sha256sum`, `readlink`, `mktemp`
- `imapsync`

Perform dependency checks relevant to the selected command. Quota commands must not require imapsync. Migration commands must require all dependencies.

Do not auto-install, auto-download, or auto-update anything.

`migration.imapsync_binary` must be an absolute path to a regular executable file. Reject symlinks if the final target is outside an administrator-controlled path, and reject an executable that is group- or world-writable.

## CLI grammar

Implement strict parsing. Options after an unexpected positional argument must not be guessed.

Accepted forms:

```text
mailu-ops [--config FILE] [--verbose] quota get ADDRESS [--json]
mailu-ops [--config FILE] [--verbose] quota list [--json]
mailu-ops [--config FILE] [--verbose] migrate probe ADDRESS
mailu-ops [--config FILE] [--verbose] migrate run ADDRESS [--yes]
mailu-ops --help
mailu-ops --version
```

Reject:

- missing or extra positional arguments
- repeated mutually exclusive options
- unknown options
- `--json` on migration commands
- `--yes` on any command except `migrate run`
- empty addresses
- addresses containing whitespace, NUL-equivalent input, CR, LF, or shell control characters
- addresses without exactly one `@` and nonempty local/domain portions

Do not attempt full RFC 5322 validation. Dovecot remains authoritative for mailbox existence.

Global options may precede the command. Command-specific options may follow their documented command operands. Keep the accepted grammar deterministic and test it.

## Exit statuses

Use these wrapper statuses for errors that occur before invoking imapsync:

| Status | Class |
|---:|---|
| `64` | invalid CLI usage |
| `65` | malformed or semantically invalid JSON/configuration/data |
| `66` | required profile or input file not found |
| `69` | dependency, Docker service, container, or endpoint unavailable before imapsync |
| `70` | internal parser/invariant failure |
| `73` | cannot create private runtime, state, or log data |
| `75` | global migration lock already held |
| `77` | insecure ownership, permissions, symlink, or access policy violation |

For every imapsync invocation:

- capture the command's real exit status
- if it is nonzero, return that status unchanged
- do not translate it into a generic wrapper status
- do not lose it through a `tee` pipeline

Use a pattern equivalent to:

```bash
set +e
"${cmd[@]}" 2>&1 | tee -- "$console_log"
status=${PIPESTATUS[0]}
set -e
return "$status"
```

Implement this inside a function so `set -e` behavior is controlled and tested. Verify behavior for statuses `1`, `12`, `64`, `101`, `102`, `113`, `161`, `162`, and `255`.

A signal should result in a conventional nonzero status. Forward termination to the active child process or process group, wait for it, and release the lock. Never print the success footer from cleanup.

## Global configuration schema

Default path:

```text
/etc/mailu-ops/config.json
```

Required schema:

```json
{
  "schema_version": 1,
  "mailu": {
    "imap_container": "mailu-imap-1",
    "compose_project": "mailu",
    "quota_root": "User quota"
  },
  "migration": {
    "profiles_dir": "/etc/mailu-ops/migrations.d",
    "secrets_dir": "/etc/mailu-ops/secrets",
    "imapsync_binary": "/usr/local/bin/imapsync",
    "destination": {
      "host": "mail.example.net",
      "port": 993,
      "ca_file": "/etc/ssl/certs/ca-certificates.crt"
    },
    "source_default_ca_file": "/etc/ssl/certs/ca-certificates.crt",
    "log_dir": "/var/log/mailu-ops",
    "state_dir": "/var/lib/mailu-ops",
    "runtime_dir": "/run/mailu-ops",
    "timeout_seconds": 120
  }
}
```

### Validation rules

- The root must be a JSON object.
- `schema_version` must be exactly integer `1`.
- Reject every unknown key at every object level.
- `mailu.imap_container` may be a nonempty string or null.
- `mailu.compose_project` may be a nonempty string or null.
- `mailu.quota_root` must be a nonempty string without CR/LF/NUL-equivalent input.
- All path fields must be absolute.
- `destination.host` must be a DNS hostname, not empty, not whitespace, and not contain URI syntax.
- Both configured IMAP ports must be integer `993` in schema version 1.
- `timeout_seconds` must be an integer from 1 through 3600.
- The global config must be a regular non-symlink file.
- It must be owned by the effective UID.
- It must not be writable by group or others.
- Parent configuration directories must not be group- or world-writable.

Use jq to validate types and unknown keys. Do not recover from a jq parse failure by applying defaults.

Defaults may be applied only to fields documented as optional. Prefer requiring explicit security-sensitive values.

## Migration profile schema

Profiles are direct `*.json` children of `migration.profiles_dir`.

Required shape:

```json
{
  "schema_version": 1,
  "address": "info@example.com",
  "source": {
    "host": "imap.old-provider.example",
    "port": 993,
    "username": "info@example.com",
    "password_file": "/etc/mailu-ops/secrets/info.source.pass",
    "ca_file": "/etc/ssl/certs/ca-certificates.crt"
  },
  "destination": {
    "username": "info@example.com",
    "password_file": "/etc/mailu-ops/secrets/info.destination.pass"
  },
  "folders": {
    "automap": true,
    "map": [
      { "from": "Sent Items", "to": "Sent" }
    ]
  }
}
```

`source.ca_file` is optional and falls back to `migration.source_default_ca_file`. `folders` may be omitted and then behaves as `{"automap": true, "map": []}`. All other displayed keys are required.

### Profile lookup

Do not build a filename from the address.

Algorithm:

1. Enumerate direct regular `*.json` files with `find -P ... -maxdepth 1 -type f -print0`.
2. Sort paths deterministically with NUL-safe tooling.
3. Validate each candidate's top-level JSON structure sufficiently to read `.address`.
4. Select files whose `.address` exactly equals the CLI argument.
5. Fail with `66` for zero matches.
6. Fail with `65` for more than one match.
7. Fully validate the selected profile.

A malformed unrelated profile should be reported during profile scanning rather than silently ignored. Administrators need deterministic awareness of broken repository state.

### Profile validation

- Reject unknown keys at every level.
- `schema_version` must be integer `1`.
- `.address` must exactly equal the CLI address.
- Source and destination usernames must be nonempty and contain no controls or newlines.
- Hostnames must be plain DNS hostnames.
- Port must be integer `993`.
- `folders.automap` must be boolean.
- `folders.map` must be an array.
- Each mapping must have exactly `from` and `to` string keys.
- Folder names must be nonempty and contain no NUL-equivalent input, CR, LF, or `=`.
- Reject duplicate `from` names and duplicate identical pairs.
- Limit mappings to a defensible maximum, for example 100.
- Profile files must be regular non-symlink files owned by the effective UID and not group/world writable.
- Profile directory must not be group/world writable.

Check the obvious self-sync case and fail with `65` when all of these are identical:

- source host and destination host, compared case-insensitively
- source port and destination port
- source username and destination username

Do not attempt DNS/IP equivalence as a security decision; log a warning in verbose mode when both hosts resolve to an overlapping address set.

## Secret-file validation

Before every imapsync invocation, revalidate both passfiles.

For each passfile:

1. Require an absolute configured path.
2. Canonicalize the path without following an untrusted final symlink.
3. Require canonical containment within `migration.secrets_dir`.
4. Require a regular file.
5. Reject symlinks.
6. Require owner UID equal to the effective UID.
7. Require mode exactly `0600`.
8. Require a nonempty first line.
9. Reject additional nonempty lines.
10. Reject CR and other control bytes in the first line where detectable.
11. Never print, capture, compare, hash, or retain the password value beyond validation needs.

Prefer validating structural properties without reading the secret into a long-lived shell variable. If reading is necessary to check emptiness, unset the variable immediately and do not invoke tracing.

Ensure `set -x` is never enabled. Reject or neutralize inherited `BASH_XTRACEFD`, `SHELLOPTS` behavior where appropriate.

Do not support passwords through environment variables, stdin, command options, JSON values, keyrings, or prompts in schema version 1.

## CA-file validation

CA files are not secret and may be system-owned.

Require:

- absolute path
- readable regular file
- no symlink loop
- not group- or world-writable
- nonzero size

Do not require effective-user ownership because the Debian system CA bundle is normally root-owned and world-readable.

No `insecure`, `skip_verify`, `verify=false`, or similar key may exist.

## Mailu container discovery

Implement this exact precedence:

1. If `mailu.imap_container` is non-null, select only that exact container.
2. Otherwise query running containers with label `com.docker.compose.service=imap`.
3. If `mailu.compose_project` is non-null, also require label `com.docker.compose.project=<value>`.
4. If the label query yields no candidate, query running containers and select images matching `ghcr.io/mailu/dovecot:*`.
5. Require exactly one candidate.

Use Docker's structured `--format` output. Do not parse the default human table.

For the selected container:

- require `.State.Running == true`
- record its exact ID and name
- verify `doveadm` exists via direct `docker exec`
- verify `doveadm` advertises `quota get`
- do not depend on `man` being installed in the container
- do not depend on the current directory or a Compose YAML file

Do not automatically choose the first candidate. Ambiguity is an error.

A container restart between discovery and command execution must produce a clear failure. It is acceptable to rediscover once only when the configured identity remains unambiguous; do not loop indefinitely.

## Dovecot quota implementation

### Single mailbox

Before requesting quota, run:

```text
docker exec CONTAINER doveadm user ADDRESS
```

Suppress normal userdb output unless `--verbose` is active. A failure means the mailbox does not exist or is not available and the command must fail.

Then run, as an argument array:

```text
docker exec CONTAINER doveadm -f json quota get -u ADDRESS
```

### All mailboxes

Run exactly one quota command:

```text
docker exec CONTAINER doveadm -f json quota get -A
```

Do not enumerate users and call `quota get` individually.

### JSON parsing

Capture representative JSON fixtures from the target Dovecot 2.3.21.1 installation. Include at least:

- the observed mailbox values `1110`, `1464844`, and `24`
- single user, finite storage quota
- single user, unlimited storage quota
- all users with a username field
- multiple quota roots
- missing `MESSAGE` row
- malformed numeric value
- duplicated storage row
- Dovecot error mixed with or preceding output
- empty result

The parser must:

- require a JSON array
- validate every object and expected field type
- select `mailu.quota_root` exactly
- require exactly one `STORAGE` row per selected mailbox/root
- accept zero or one `MESSAGE` row
- reject duplicate or conflicting rows
- reject negative usage
- interpret a missing, `-`, null, or nonpositive storage limit according to the captured Dovecot schema as unlimited
- convert reported storage KiB to bytes by multiplying by 1024
- calculate percentage as `used / limit * 100` from unrounded values
- not trust Dovecot's rounded integer `%` field for the normalized percentage
- sort all-user results by mailbox under `LC_ALL=C`
- reject partial or unrecognized results

Do not parse column positions from table output. Do not use human-readable strings as intermediate numeric data.

### Normalized quota object

Internally normalize each mailbox to:

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

Keep numeric fields numeric. Unlimited limits are null.

The exact floating-point representation may contain more precision than the README example. Human output rounds only at presentation time.

### Human formatting

Use IEC units:

- B
- KiB
- MiB
- GiB
- TiB
- PiB if necessary

Rules:

- `0` displays as `0 B`
- byte values below 1024 display as an integer number of bytes
- larger values display with two decimals
- finite percentages display with two decimals and `%`
- unlimited limit displays as `unlimited`
- unlimited percentage displays as `n/a`
- do not truncate mailbox addresses
- determine a reasonable dynamic mailbox-column width for list output

Human formatting must be locale-independent.

## Migration locking and operation directories

Both `migrate probe` and `migrate run` use one global lock:

```text
<RUNTIME_DIR>/migrate.lock
```

Create `runtime_dir` with mode `0700`, open the lock file on a dedicated file descriptor, and call nonblocking `flock -n`.

Return `75` when another migration or probe holds the lock. Include the lock path and, when safely available, the recorded operation metadata in the diagnostic.

Quota commands do not acquire the migration lock.

For each probe or run, create a durable operation log directory:

```text
<LOG_DIR>/<UTC_TIMESTAMP>-<SANITIZED_ADDRESS>-<HASH_SUFFIX>/
```

Requirements:

- UTC timestamp format `YYYYMMDDTHHMMSSZ`
- sanitize address characters to `[A-Za-z0-9._-]`, replacing all others with `_`
- cap the sanitized fragment at 48 characters
- append the first 12 hexadecimal characters of SHA-256 over the exact address
- use collision-safe creation; never reuse an existing operation directory
- mode `0700`

Create a private temporary directory beneath the operation's runtime path, not shared `/tmp`.

Each imapsync phase must receive a unique PID file. Do not reuse a PID file between login, folder-plan, and sync phases.

Suggested phase names:

```text
01-login
02-folders
03-login
04-sync
```

Probe uses `01-login` and `02-folders`. Run uses all four.

## imapsync capability validation

Before network access, run the configured binary with `--version` and help output. Verify support for every option the program will use:

```text
--host1
--host2
--port1
--port2
--user1
--user2
--passfile1
--passfile2
--ssl1
--ssl2
--sslargs1
--sslargs2
--timeout1
--timeout2
--justlogin
--dry
--justfolders
--nofoldersizes
--nofoldersizesatend
--subscribe
--resyncflags
--syncinternaldates
--noexpunge1
--noexpunge2
--nouidexpunge2
--tmpdir
--pidfile
--pidfilelocking
--logfile
--noreleasecheck
--automap
--f1f2
```

Capability detection must avoid substring false positives such as matching `--nossl1` for `--ssl1`. Parse option tokens with boundaries.

Do not enforce an arbitrary version number when direct feature detection is possible. Record the detected version in the operation wrapper log.

If any required option is absent, fail before sending credentials.

## imapsync command construction

Build a fresh array for every phase. Never reuse a mutable array without reconstructing phase-specific paths.

Base arguments:

```text
--host1 SOURCE_HOST
--port1 SOURCE_PORT
--ssl1
--sslargs1 SSL_verify_mode=1
--sslargs1 SSL_ca_file=SOURCE_CA_FILE
--user1 SOURCE_USERNAME
--passfile1 SOURCE_PASSFILE

--host2 DESTINATION_HOST
--port2 DESTINATION_PORT
--ssl2
--sslargs2 SSL_verify_mode=1
--sslargs2 SSL_ca_file=DESTINATION_CA_FILE
--user2 DESTINATION_USERNAME
--passfile2 DESTINATION_PASSFILE

--timeout1 TIMEOUT_SECONDS
--timeout2 TIMEOUT_SECONDS
--subscribe
--resyncflags
--syncinternaldates
--noexpunge1
--noexpunge2
--nouidexpunge2
--tmpdir PHASE_PRIVATE_TMPDIR
--pidfile PHASE_PIDFILE
--pidfilelocking
--logfile PHASE_IMAPSYNC_LOG
--noreleasecheck
```

Append `--automap` when configured true.

For each explicit mapping, append two array elements:

```text
--f1f2
SOURCE_FOLDER=DESTINATION_FOLDER
```

Do not join or quote the complete command as a string.

Use verified DNS hostnames with `--ssl1` and `--ssl2`; do not substitute resolved IP addresses. `SSL_verify_mode=1` and the CA file are mandatory on both endpoints.

Do not include `--showpasswords`, debug-content options, authentication debug output, email reports, release checks, or provider presets in schema version 1.

## Migration preflight

After acquiring the global lock, both probe and run execute the same structural preflight:

1. Revalidate global config and selected profile.
2. Revalidate profile uniqueness.
3. Revalidate secret and CA files.
4. Validate dependencies and imapsync capabilities.
5. Discover and validate the Mailu Dovecot container.
6. Verify the destination mailbox through `doveadm user`.
7. Query and normalize destination quota.
8. Fail if a finite quota has `limit_bytes <= used_bytes`.
9. Print a warning when finite remaining capacity is small, but do not invent a source-size estimate.
10. Reject the obvious identical-endpoint case.
11. Create phase-specific private paths.

Do not automatically recalculate Dovecot quota. `quota recalc` is an explicit repair action outside version 1 scope.

## Probe phases

`migrate probe ADDRESS` performs two imapsync phases.

### Phase 01: login

Base arguments plus:

```text
--justlogin
```

No folder or message changes are allowed.

### Phase 02: dry folder plan

Base arguments plus:

```text
--dry
--justfolders
--nofoldersizes
--nofoldersizesatend
```

Include configured folder arguments. This phase must not modify either endpoint.

On success, print a redacted endpoint summary, normalized destination quota, pass/fail status, and operation-log directory. Do not print password values. Prefer redacting passfile paths in terminal summaries; full protected paths may remain in private wrapper diagnostics when useful.

If either phase fails, return its exact imapsync status and do not print a safe-to-run conclusion.

## Run phases

`migrate run ADDRESS` executes this exact sequence while holding the global lock:

1. Full structural preflight.
2. Phase 01 login test.
3. Phase 02 dry folder plan.
4. Display redacted plan and operation scope.
5. Obtain exact-address confirmation, unless `--yes` was supplied.
6. Revalidate both passfiles after confirmation.
7. Phase 03 repeated login test.
8. Phase 04 actual additive imapsync transfer.
9. On success, query and display destination quota as a best-effort postflight check.
10. Print the success footer and log path only after phase 04 returns zero.

If stdin is not a TTY and `--yes` is absent, fail with `64` before prompting.

Confirmation must read one line without interpretation and compare it byte-for-byte to the selected destination address. Empty input, EOF, or mismatch aborts without running phase 03 or 04.

Phase 04 uses only the base and folder arguments. It must not contain `--dry`, `--justlogin`, or `--justfolders`.

A postflight quota query failure after successful imapsync is a warning and does not change the successful imapsync status. State clearly that transfer succeeded but quota display failed.

## Logging

Each phase has:

- `<phase>.imapsync.log`, supplied through imapsync `--logfile`
- `<phase>.console.log`, written by `tee` from combined stdout/stderr

The wrapper has `wrapper.log` for timestamps, selected non-secret configuration, detected versions, phase starts, statuses, and final result.

Requirements:

- directories mode `0700`
- files mode `0600`
- no passwords
- no passfile contents
- no environment dump
- no shell tracing
- no unredacted reconstructed command in stdout
- private logs may contain usernames, hosts, folders, statistics, and passfile paths
- write timestamps in UTC
- flush phase status immediately after completion

When logging a command, render a redacted representation from the argument array. Replace the argument following `--passfile1` and `--passfile2` with a stable marker such as `<protected-passfile>`. Never read a secret to redact it.

The terminal should receive enough imapsync output for an administrator to monitor progress. Preserve the true child status through every pipeline.

## Signals and cleanup

Track the active imapsync PID or process group.

On `INT`, `TERM`, or `HUP`:

1. mark the operation interrupted
2. forward the signal to the active child/process group
3. wait for child termination
4. record interruption in `wrapper.log`
5. remove only temporary files created and owned by this operation
6. release the flock descriptor by exiting
7. retain durable logs
8. return nonzero

Do not delete a phase PID file that may belong to a still-running process. Let imapsync remove its own PID file when possible. If cleanup encounters a stale file, record it rather than guessing.

Do not trap `KILL`; it cannot be trapped.

## Output contract

### stdout versus stderr

stdout:

- human quota results
- JSON quota results
- migration progress and final operator-facing result

stderr:

- validation errors
- warnings
- verbose diagnostics
- dependency and Docker errors

In JSON mode, stdout must contain exactly one valid JSON document followed by a newline. No heading, warning, Docker message, or progress text may precede or follow it.

### Determinism

- set `LC_ALL=C`
- sort mailbox arrays by exact mailbox string
- keep JSON key order stable where jq output allows it
- use UTC timestamps
- do not include random values in normalized quota JSON

## Security tests

Automated tests must prove at least the following:

1. A password value never appears in captured argv when passfiles are used.
2. Passwords do not appear in stdout, stderr, wrapper logs, or console logs.
3. A mode `0644` passfile is rejected with `77`.
4. A mode `0660` passfile is rejected with `77`.
5. A passfile owned by another UID is rejected.
6. A symlink passfile is rejected.
7. A passfile resolving outside `secrets_dir` is rejected.
8. A profile symlink is rejected.
9. Group/world-writable config directories are rejected.
10. An unknown JSON key is rejected.
11. An insecure TLS key is rejected as unknown.
12. Missing CA files are rejected before imapsync runs.
13. The generated argv always contains both SSL verification arguments and both CA-file arguments.
14. Generated argv contains all three no-expunge arguments.
15. Generated argv never contains any delete or expunge-positive option.
16. Folder mappings are separate array arguments and cannot inject options.
17. Hostnames, usernames, addresses, and folder names containing newlines are rejected.
18. A profile cannot redirect the destination host.
19. Raw imapsync arguments cannot be introduced through config, environment, or CLI.
20. The second concurrent probe/run fails with `75`.
21. Quota commands remain available while a migration lock is held.
22. Exact confirmation is required and mismatches do not invoke the real sync.
23. `--yes` skips only confirmation, not probes.
24. A non-TTY run without `--yes` fails.
25. Every imapsync failure status is preserved through `tee`.

Add a static security test that inspects only the runtime executable, not documentation or fixtures, for prohibited constructs and option literals. Avoid simplistic tests that flag explanatory text in `README.md` or `AGENTS.md`.

## Functional tests

Use Bats and PATH-injected command stubs. No test may require Docker, a live IMAP server, network access, or real credentials.

### Docker stub

The Docker stub must simulate:

- exact configured container
- label-based discovery
- image fallback discovery
- zero candidates
- multiple candidates
- stopped container
- missing `doveadm`
- failed `doveadm user`
- single-user JSON quota output
- all-user JSON quota output
- Dovecot command failure

Record argv in a NUL-safe form for assertions.

### imapsync stub

The imapsync stub must:

- provide configurable version/help output
- record argv without exposing passfile contents
- return selectable statuses per phase
- write recognizable output for tee/log assertions
- optionally sleep to test locks and signal forwarding
- simulate stale and active PID-file behavior

### Quota fixtures

Include fixtures for:

```text
Quota name Type    Value   Limit %
User quota STORAGE  1110 1464844 0
User quota MESSAGE    24       - 0
```

The runtime parser uses JSON, so create the matching captured JSON fixture from Dovecot 2.3.21.1 rather than synthesizing unverified field names. Keep a comment identifying the Dovecot version and the exact command used to capture it.

Test:

- human single output
- human all output
- JSON schemas
- `0 B`
- KiB/MiB/GiB/TiB boundaries
- exact byte conversion
- percentage precision
- unlimited storage
- missing message row
- multiple quota roots
- duplicate rows
- malformed JSON
- malformed numbers
- deterministic sorting
- long addresses without truncation

### Migration tests

Assert exact phase order:

Probe:

```text
lock -> preflight -> login -> dry folders -> success
```

Run:

```text
lock -> preflight -> login -> dry folders -> confirmation -> passfile recheck -> login -> sync -> quota postcheck -> success
```

For every failure injection, assert that no later phase runs.

Specifically test:

- initial login failure
- folder-plan failure
- confirmation mismatch
- passfile changed to insecure mode during confirmation
- repeated-login failure
- real-sync failure
- successful sync with failed quota postcheck
- SIGINT during real sync
- two concurrent operations

## Code organization

Suggested top-level functions:

```text
main
parse_cli
usage
fatal
warn
verbose
require_command
load_global_config
validate_global_config
find_profile
validate_profile
validate_sensitive_file
validate_ca_file
canonical_path_within
resolve_mailu_container
check_doveadm
verify_mailbox
fetch_quota_single_json
fetch_quota_all_json
normalize_quota_json
render_quota_human
render_quota_json
acquire_migration_lock
create_operation_context
check_imapsync_capabilities
build_imapsync_base_args
append_folder_args
run_imapsync_phase
migration_preflight
migration_probe
migration_run
confirm_exact_address
cleanup
```

Names may differ, but keep responsibilities narrow. Avoid functions that mutate unrelated globals invisibly.

A small number of explicitly named readonly globals is acceptable for parsed CLI state and operation context. Prefer passing values by arguments or using clearly documented output conventions.

When returning structured data between functions, prefer JSON through a controlled variable or nameref over delimiter-packed strings containing user data.

## Error messages

Every fatal diagnostic should answer:

- what failed
- which non-secret object was involved
- how the administrator can correct it

Examples:

```text
mailu-ops: error: multiple running Mailu IMAP containers match project "mailu"; set mailu.imap_container explicitly
```

```text
mailu-ops: error: passfile /etc/mailu-ops/secrets/info.source.pass has mode 0644; required mode is 0600
```

```text
mailu-ops: error: no migration profile has address "info@example.com"
```

Do not print stack traces or secret-bearing shell expansions by default. `--verbose` still must not expose secrets.

## Performance constraints

- `quota list` uses one Docker exec and one jq normalization pass.
- Profile scanning may parse all profiles but must not run external network operations.
- Do not fork one `jq` process per quota row when a single filter can normalize the full document.
- Do not hold large mailbox data in shell variables; imapsync streams it directly.
- It is acceptable to serialize all migrations with the global lock in version 1.
- Do not introduce background jobs or parallel migrations.

## Documentation and examples

Keep `README.md`, `examples/config.json`, and `examples/migrations.d/example.json` consistent with the implemented schema.

Examples must use reserved example domains and obvious placeholders. Never commit real customer addresses, hostnames, passwords, tokens, logs, or message metadata.

The README is written as the user-facing contract. If implementation behavior must change, update tests and documentation in the same commit. Do not silently diverge from documented command names, output fields, or safety guarantees.

## Out of scope for version 1

Do not implement any of the following unless the project owner explicitly changes the specification and schema version:

- mailbox creation or deletion
- quota modification or automatic quota recalculation
- DNS or MX changes
- Mailu REST API authentication
- source or destination deletion
- folder deletion
- expunge operations
- strict mirroring
- arbitrary imapsync flags
- STARTTLS or plaintext IMAP
- TLS verification bypass
- OAuth, XOAUTH2, or token refresh
- administrative/master-user proxy authentication
- provider presets such as `--gmail1` or `--office1`
- contacts, calendars, Sieve, forwarding, identities, or signatures
- password rotation
- parallel migrations
- scheduled or daemon mode
- web UI

## Acceptance criteria

A change is complete only when all of the following pass:

```bash
bash -n mailu-ops
shellcheck mailu-ops
shfmt -d mailu-ops tests
bats tests
```

Additionally:

- `./mailu-ops --help` matches the README command surface.
- `./mailu-ops --version` prints a single stable version string.
- tests run without network or Docker daemon access.
- JSON output validates with `jq -e`.
- no test fixture contains a real password.
- no runtime path is group/world accessible.
- no destructive imapsync option can appear in generated argv.
- TLS peer verification is present for both endpoints in every phase.
- a real sync cannot execute unless both prior probes succeeded.
- imapsync statuses survive logging pipelines unchanged.
- behavior is verified against a captured Dovecot 2.3.21.1 JSON fixture before release.

## Review checklist

Before merging, review the generated imapsync argv from tests manually and answer all of these with yes:

- Are both endpoints forced to IMAPS?
- Is certificate verification explicitly enabled for both?
- Is a CA file passed for both?
- Are credentials represented only by protected passfile paths?
- Are source and destination expunges disabled?
- Are all destructive options absent?
- Is folder mapping shown in a dry phase before the real transfer?
- Is the login test repeated after confirmation?
- Is the exact child status retained?
- Are concurrent runs prevented?
- Does every ambiguous condition fail rather than guess?

If any answer is no or uncertain, do not release.
