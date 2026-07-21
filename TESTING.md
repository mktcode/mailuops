# Testing `mailu-ops`

**ATTENTION:** This document is a draft / brainstorm. It still uses the old `mailu-ops` name and might not be fully aligned with the current repository structure / project ideas.

This document describes how to test `mailu-ops` locally against a disposable Mailu installation.

The recommended architecture is:

- Run `mailu-ops` on the Docker host.
- Run Mailu as a temporary Docker Compose stack.
- Do not install `mailu-ops`, Docker tooling, or `imapsync` inside a Mailu container.

Running the utility on the host exercises the same integration points used in production:

- Mailu/Dovecot container discovery
- `docker exec ... doveadm`
- configuration and passfile permission checks
- host-side logs, locks, PID files, and state
- the locally installed `imapsync` binary
- certificate-verified IMAPS connections

## Test layers

The project should have two test layers.

### Unit and command-contract tests

```bash
make test
```

These tests should use Bats with stubbed `docker` and `imapsync` executables. They should be fast and deterministic and should not require a real Mailu server.

Use this layer to test:

- argument validation
- malformed configuration
- malformed Dovecot output
- missing containers
- invalid mailbox addresses
- insecure passfile permissions
- lock behavior
- signal handling
- timeout handling
- exit-code propagation
- prohibited `imapsync` arguments
- JSON output validity

### Integration tests

```bash
make integration
```

This target should:

1. create a disposable Mailu stack;
2. create test mailboxes;
3. insert fixture messages;
4. run all four supported operations;
5. verify the destination mailbox;
6. destroy the Mailu stack and test data.

The integration test should remain optional. It is slower, requires Docker, and binds a local IMAPS port.

## Supported commands under test

The examples below assume this command structure:

```text
mailu-ops quota get ADDRESS [--json]
mailu-ops quota list [--json]
mailu-ops migrate probe ADDRESS
mailu-ops migrate run ADDRESS [--yes]
```

## Recommended first integration topology

A single Mailu stack is sufficient for the first end-to-end test.

Create two accounts:

```text
source@example.test
target@example.test
```

Use `source@example.test` as the source IMAP account and `target@example.test` as the destination. Both accounts connect through the same Mailu IMAPS endpoint.

This verifies:

- source and destination authentication
- TLS validation
- folder discovery and mapping
- message copying
- flag and date preservation
- rerunnable migration behavior
- quota reporting before and after migration

It does not simulate provider-specific quirks. A separate two-stack test is described later.

## Prerequisites

Install the following on the Docker host:

- Docker Engine
- Docker Compose v2
- Bash
- OpenSSL
- Python 3
- `jq`
- `imapsync`
- Bats, for the unit-test layer

Confirm the basic tools:

```bash
docker --version
docker compose version
openssl version
python3 --version
jq --version
imapsync --version
```

Use the same Mailu release line as the production server. For the server described during development, that is `2024.06`.

For a lightweight local stack, disable components that are unrelated to these tests, especially ClamAV, webmail, and WebDAV.

## 1. Create an isolated test root

Run these commands from the repository root:

```bash
REPO=$PWD

umask 077
TEST_ROOT=$(mktemp -d "$HOME/mailu-ops-it.XXXXXX")

mkdir -p \
    "$TEST_ROOT/mailu" \
    "$TEST_ROOT/data" \
    "$TEST_ROOT/pki" \
    "$TEST_ROOT/ops/migrations.d" \
    "$TEST_ROOT/ops/secrets" \
    "$TEST_ROOT/ops/log" \
    "$TEST_ROOT/ops/state" \
    "$TEST_ROOT/ops/run"

printf 'Test root: %s\n' "$TEST_ROOT"
```

Do not place the utility configuration under a globally writable directory such as `/tmp`. A production-oriented implementation should reject insecure parent directories.

Add a local hostname:

```bash
grep -q '# mailu-ops-it$' /etc/hosts ||
    printf '127.0.0.1 mailu.test # mailu-ops-it\n' |
    sudo tee -a /etc/hosts >/dev/null
```

Check that TCP port 993 is available:

```bash
sudo ss -ltnp | grep -E '[:.]993[[:space:]]' || true
```

The examples in this document expose Mailu IMAPS on `127.0.0.1:993`.

## 2. Generate a private test CA and certificate

Create a private CA and a server certificate for `mailu.test`:

```bash
cd "$TEST_ROOT/pki"

openssl req \
    -x509 \
    -newkey rsa:3072 \
    -nodes \
    -sha256 \
    -days 3650 \
    -subj '/CN=mailu-ops integration test CA' \
    -keyout ca.key \
    -out ca.crt

openssl req \
    -newkey rsa:2048 \
    -nodes \
    -sha256 \
    -subj '/CN=mailu.test' \
    -keyout mailu.test.key \
    -out mailu.test.csr

cat > mailu.test.ext <<'CERT_EXT'
basicConstraints = CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:mailu.test
CERT_EXT

openssl x509 \
    -req \
    -sha256 \
    -days 365 \
    -in mailu.test.csr \
    -CA ca.crt \
    -CAkey ca.key \
    -CAcreateserial \
    -extfile mailu.test.ext \
    -out mailu.test.crt

mkdir -p "$TEST_ROOT/mailu/certs"
cp mailu.test.key "$TEST_ROOT/mailu/certs/key.pem"
cat mailu.test.crt ca.crt > "$TEST_ROOT/mailu/certs/cert.pem"

chmod 0600 \
    ca.key \
    "$TEST_ROOT/mailu/certs/key.pem"
```

The Mailu test stack should use `TLS_FLAVOR=cert` and mount the generated certificate directory at the location expected by the generated Compose configuration.

## 3. Generate the Mailu Compose configuration

Use Mailu’s official setup utility to generate a Docker Compose configuration in:

```text
$TEST_ROOT/mailu
```

Use values equivalent to these:

```text
Mailu version:        2024.06
Main mail domain:     example.test
Server hostname:      mailu.test
TLS flavor:           cert
Data root:            $TEST_ROOT/data
Admin interface:      enabled
Webmail:              disabled
WebDAV:               disabled
Antivirus/ClamAV:     disabled
Default quota:        100000000 bytes
IPv6:                 disabled
```

In the generated `docker-compose.yml`, expose only IMAPS from the `front` service:

```yaml
services:
  front:
    ports:
      - "127.0.0.1:993:993"
```

Review `mailu.env` and ensure the effective values include:

```dotenv
DOMAIN=example.test
HOSTNAMES=mailu.test
POSTMASTER=admin
TLS_FLAVOR=cert
DEFAULT_QUOTA=100000000
```

Use a Docker subnet that does not conflict with existing Docker networks or VPN routes.

## 4. Start Mailu

```bash
cd "$TEST_ROOT/mailu"

docker compose -p mailu-ops-it pull
docker compose -p mailu-ops-it up -d
docker compose -p mailu-ops-it ps
```

Wait until the required services are running and healthy. At minimum, inspect `front`, `admin`, and `imap`.

```bash
docker compose -p mailu-ops-it logs \
    --tail=200 \
    front admin imap
```

Create one administrator and two test mailboxes:

```bash
docker compose -p mailu-ops-it exec admin \
    flask mailu admin admin example.test 'Admin-Test-Only-1!'

docker compose -p mailu-ops-it exec admin \
    flask mailu user source example.test 'Source-Test-Only-1!'

docker compose -p mailu-ops-it exec admin \
    flask mailu user target example.test 'Target-Test-Only-1!'
```

Verify the certificate chain and hostname before testing the utility:

```bash
openssl s_client \
    -connect mailu.test:993 \
    -servername mailu.test \
    -CAfile "$TEST_ROOT/pki/ca.crt" \
    </dev/null 2>/dev/null |
grep 'Verify return code'
```

Expected output:

```text
Verify return code: 0 (ok)
```

Do not continue if TLS validation fails.

## 5. Create passfiles

```bash
printf '%s\n' 'Source-Test-Only-1!' \
    > "$TEST_ROOT/ops/secrets/source.pass"

printf '%s\n' 'Target-Test-Only-1!' \
    > "$TEST_ROOT/ops/secrets/target.pass"

chmod 0600 "$TEST_ROOT/ops/secrets/"*.pass
```

The utility should reject passfiles that are readable by group or other users.

## 6. Seed the source mailbox

The following Python script creates several folders and appends three messages with known flags, message IDs, and internal dates.

```bash
TEST_ROOT=$TEST_ROOT python3 - <<'PY'
import imaplib
import os
import ssl
from datetime import datetime, timezone
from email.message import EmailMessage
from email.policy import SMTP
from email.utils import format_datetime
from pathlib import Path

root = Path(os.environ["TEST_ROOT"])
password = (root / "ops/secrets/source.pass").read_text().rstrip("\n")

context = ssl.create_default_context(cafile=str(root / "pki/ca.crt"))

with imaplib.IMAP4_SSL(
    "mailu.test",
    993,
    ssl_context=context,
) as client:
    client.login("source@example.test", password)

    # Existing folders may return NO. That is harmless for repeated tests.
    for folder in ("Sent", "Archive", "Archive/2024"):
        client.create(folder)

    fixtures = [
        ("INBOX", False, "Inbox test"),
        ("Sent", True, "Sent test"),
        ("Archive/2024", True, "Archive test"),
    ]

    for number, (folder, seen, subject) in enumerate(fixtures, start=1):
        timestamp = datetime(
            2024,
            1,
            number,
            12,
            0,
            tzinfo=timezone.utc,
        )

        message = EmailMessage()
        message["From"] = "source@example.test"
        message["To"] = "recipient@example.test"
        message["Subject"] = subject
        message["Date"] = format_datetime(timestamp)
        message["Message-ID"] = (
            f"<mailu-ops-integration-{number}@example.test>"
        )
        message.set_content(f"Integration test message {number}.\n")

        flags = r"(\Seen)" if seen else None
        internal_date = imaplib.Time2Internaldate(timestamp)

        status, response = client.append(
            folder,
            flags,
            internal_date,
            message.as_bytes(policy=SMTP),
        )

        if status != "OK":
            raise RuntimeError(
                f"APPEND to {folder!r} failed: {response!r}"
            )

    client.logout()
PY
```

## 7. Determine the Dovecot container name

```bash
IMAP_ID=$(
    docker compose -p mailu-ops-it ps -q imap
)

IMAP_CONTAINER=$(
    docker inspect --format '{{.Name}}' "$IMAP_ID"
)

IMAP_CONTAINER=${IMAP_CONTAINER#/}

printf 'IMAP container: %s\n' "$IMAP_CONTAINER"
```

A typical result is:

```text
mailu-ops-it-imap-1
```

Do not hard-code that value in automated tests. Resolve it from Compose or Docker metadata.

## 8. Configure `mailu-ops`

Create a global configuration file such as:

```text
$TEST_ROOT/ops/config.json
```

Example:

```json
{
  "schema_version": 1,
  "mailu": {
    "imap_container": "mailu-ops-it-imap-1",
    "compose_project": "mailu-ops-it",
    "quota_root": "User quota"
  },
  "migration": {
    "profiles_dir": "/ABSOLUTE/TEST/ROOT/ops/migrations.d",
    "secrets_dir": "/ABSOLUTE/TEST/ROOT/ops/secrets",
    "imapsync_binary": "/ABSOLUTE/PATH/TO/imapsync",
    "destination": {
      "host": "mailu.test",
      "port": 993,
      "ca_file": "/ABSOLUTE/TEST/ROOT/pki/ca.crt"
    },
    "source_default_ca_file": "/ABSOLUTE/TEST/ROOT/pki/ca.crt",
    "log_dir": "/ABSOLUTE/TEST/ROOT/ops/log",
    "state_dir": "/ABSOLUTE/TEST/ROOT/ops/state",
    "runtime_dir": "/ABSOLUTE/TEST/ROOT/ops/run",
    "timeout_seconds": 120
  }
}
```

Replace every placeholder with an absolute path. Set `mailu.imap_container` to the value discovered in the previous step.

Create a migration profile for the destination address:

```text
$TEST_ROOT/ops/migrations.d/target.json
```

Example:

```json
{
  "schema_version": 1,
  "address": "target@example.test",
  "source": {
    "host": "mailu.test",
    "port": 993,
    "username": "source@example.test",
    "password_file": "/ABSOLUTE/TEST/ROOT/ops/secrets/source.pass",
    "ca_file": "/ABSOLUTE/TEST/ROOT/pki/ca.crt"
  },
  "destination": {
    "username": "target@example.test",
    "password_file": "/ABSOLUTE/TEST/ROOT/ops/secrets/target.pass"
  },
  "folders": {
    "automap": true,
    "map": []
  }
}
```

Protect both files:

```bash
chmod 0600 \
    "$TEST_ROOT/ops/config.json" \
    "$TEST_ROOT/ops/migrations.d/target.json"
```

Validate the JSON before invoking the utility:

```bash
jq -e . "$TEST_ROOT/ops/config.json" >/dev/null
jq -e . "$TEST_ROOT/ops/migrations.d/target.json" >/dev/null
```

## 9. Run the four supported operations

From any directory:

```bash
"$REPO/mailu-ops" \
    --config "$TEST_ROOT/ops/config.json" \
    quota get source@example.test
```

```bash
"$REPO/mailu-ops" \
    --config "$TEST_ROOT/ops/config.json" \
    quota list
```

```bash
"$REPO/mailu-ops" \
    --config "$TEST_ROOT/ops/config.json" \
    migrate probe target@example.test
```

```bash
"$REPO/mailu-ops" \
    --config "$TEST_ROOT/ops/config.json" \
    migrate run target@example.test --yes
```

Verify destination quota and message count:

```bash
"$REPO/mailu-ops" \
    --config "$TEST_ROOT/ops/config.json" \
    quota get target@example.test
```

The destination should report three messages and nonzero storage use.

## 10. Verify rerunnable migration behavior

Run the migration a second time:

```bash
"$REPO/mailu-ops" \
    --config "$TEST_ROOT/ops/config.json" \
    migrate run target@example.test --yes
```

The destination should still contain exactly three fixture messages. A normal rerun must not create duplicates.

Then append a fourth source message and run the migration again. The destination should contain exactly four messages afterward.

## 11. Validate JSON output

```bash
"$REPO/mailu-ops" \
    --config "$TEST_ROOT/ops/config.json" \
    quota get source@example.test --json |
jq -e .
```

```bash
"$REPO/mailu-ops" \
    --config "$TEST_ROOT/ops/config.json" \
    quota list --json |
jq -e .
```

The commands must return valid JSON and a zero exit status.

Tests should also verify stable field names and types. A recommended quota record shape is:

```json
{
  "address": "source@example.test",
  "storage_used_bytes": 4096,
  "storage_limit_bytes": 100000000,
  "usage_percent": 0.004096,
  "messages": 3
}
```

Exact schema choices belong to the command contract and should be documented in `README.md`.

## 12. Required integration assertions

The integration harness should fail unless all of the following are true:

1. `quota get source@example.test` reports three source messages before migration.
2. `quota list` contains the administrator, source, and target accounts.
3. `migrate probe target@example.test` exits successfully.
4. Probing does not copy messages or otherwise modify the destination mailbox.
5. `migrate run target@example.test --yes` copies all three fixture messages.
6. `Sent` and `Archive/2024` exist on the destination.
7. Read and unread flags are preserved.
8. IMAP internal dates are preserved.
9. Message IDs are preserved.
10. A second migration run creates no duplicates.
11. Adding one source message and rerunning produces exactly one additional destination message.
12. JSON quota output parses successfully with `jq`.
13. Logs are written to the configured log directory.
14. Runtime and state files are written only to their configured directories.
15. No password appears in logs, process arguments, or command output.

## 13. Required failure-path tests

Most of these tests are better implemented with stubbed commands because they are faster and more deterministic than manipulating a real server.

At minimum, test:

### Invalid source password

Replace the source passfile content temporarily and assert:

- `migrate probe` exits nonzero;
- no migration is started;
- no message is added to the destination;
- the password is absent from logs.

### Invalid destination password

Assert the same behavior for destination authentication failure.

### Untrusted CA

Use a CA file that does not sign the Mailu certificate. The command must fail before migration.

The utility must not silently add permissive TLS options such as disabling peer or hostname verification.

### Insecure passfile permissions

```bash
chmod 0644 "$TEST_ROOT/ops/secrets/source.pass"
```

The utility should reject the file before starting `imapsync`.

Restore the permissions afterward:

```bash
chmod 0600 "$TEST_ROOT/ops/secrets/source.pass"
```

### Missing mailbox

```bash
"$REPO/mailu-ops" \
    --config "$TEST_ROOT/ops/config.json" \
    quota get missing@example.test
```

The command should return a clear error and a nonzero exit status.

### Lock contention

Start one migration and attempt a second migration concurrently. The second process should fail cleanly or wait according to the documented locking contract. It must not start another `imapsync` process for the same protected scope.

### Timeout and signal handling

Using a stubbed `imapsync`, verify that:

- a timeout terminates the process tree;
- `SIGINT` and `SIGTERM` are forwarded or handled cleanly;
- lock and PID files are cleaned up;
- the command exits nonzero;
- partial logs remain available for diagnosis.

### Exit-code propagation

When `imapsync` exits nonzero, `mailu-ops` must return a nonzero status even when output is piped through `tee` or another logging process.

Use `set -o pipefail` or explicit pipeline status handling.

## 14. Inspect the migrated mailbox directly

Quota counts alone are insufficient. Verify folders, flags, message IDs, and internal dates through IMAP.

Example Python inspection script:

```bash
TEST_ROOT=$TEST_ROOT python3 - <<'PY'
import imaplib
import os
import ssl
from pathlib import Path

root = Path(os.environ["TEST_ROOT"])
password = (root / "ops/secrets/target.pass").read_text().rstrip("\n")
context = ssl.create_default_context(cafile=str(root / "pki/ca.crt"))

expected_ids = {
    "<mailu-ops-integration-1@example.test>",
    "<mailu-ops-integration-2@example.test>",
    "<mailu-ops-integration-3@example.test>",
}

found_ids = set()

with imaplib.IMAP4_SSL("mailu.test", 993, ssl_context=context) as client:
    client.login("target@example.test", password)

    status, folders = client.list()
    if status != "OK":
        raise RuntimeError(f"LIST failed: {folders!r}")

    folder_text = b"\n".join(folders or []).decode(errors="replace")
    for expected_folder in ("Sent", "Archive/2024"):
        if expected_folder not in folder_text:
            raise RuntimeError(f"Missing destination folder: {expected_folder}")

    for folder in ("INBOX", "Sent", "Archive/2024"):
        status, _ = client.select(f'"{folder}"', readonly=True)
        if status != "OK":
            raise RuntimeError(f"Cannot select {folder!r}")

        status, data = client.search(None, "ALL")
        if status != "OK":
            raise RuntimeError(f"SEARCH failed in {folder!r}")

        for message_number in data[0].split():
            status, response = client.fetch(
                message_number,
                "(BODY.PEEK[HEADER.FIELDS (MESSAGE-ID)] FLAGS INTERNALDATE)",
            )
            if status != "OK":
                raise RuntimeError(
                    f"FETCH failed for {message_number!r} in {folder!r}"
                )

            for item in response:
                if not isinstance(item, tuple):
                    continue
                header = item[1].decode(errors="replace")
                for line in header.splitlines():
                    if line.lower().startswith("message-id:"):
                        found_ids.add(line.split(":", 1)[1].strip())

    client.logout()

missing = expected_ids - found_ids
if missing:
    raise RuntimeError(f"Missing migrated messages: {sorted(missing)!r}")

print("Destination mailbox verification passed.")
PY
```

For a complete automated test, also parse the returned `FLAGS` and `INTERNALDATE` metadata and compare them with the seeded fixtures.

## 15. Two-stack same-address test

The single-stack test uses different source and destination addresses. For a higher-fidelity test, run two independent Mailu projects:

```text
mailu-source-it       127.0.0.2    oldmail.test
mailu-destination-it  127.0.0.3    mailu.test
```

Create the same mailbox address on both stacks:

```text
customer@example.test
```

Seed messages only on the source stack. Configure the profile so that:

- source host is `oldmail.test`;
- destination host is `mailu.test`;
- source and destination usernames are both `customer@example.test`;
- each host uses its own CA or a shared integration-test CA.

Each stack must have distinct:

- Docker Compose project names
- Docker networks and subnets
- host bind addresses
- data roots
- certificate files
- Mailu hostnames
- exposed host ports or IP addresses

This test more closely matches a real provider-to-Mailu migration and validates that the CLI does not assume source and destination usernames differ.

## 16. Cleanup

Destroy the Compose stack and its managed volumes:

```bash
cd "$TEST_ROOT/mailu"

docker compose -p mailu-ops-it \
    down \
    --volumes \
    --remove-orphans
```

Remove the test hostname:

```bash
sudo sed -i '/# mailu-ops-it$/d' /etc/hosts
```

Remove bind-mounted Mailu data, certificates, logs, state, and secrets:

```bash
rm -rf -- "$TEST_ROOT"
```

`docker compose down --volumes` removes Compose-managed volumes. It does not remove data stored in host bind mounts. Keeping all bind-mounted paths below `$TEST_ROOT` is therefore required for reliable cleanup.

## 17. Suggested Make targets

The repository should expose these targets:

```make
.PHONY: test integration integration-up integration-test integration-down

test:
	bats tests

integration-up:
	./tests/integration/up.sh

integration-test:
	./tests/integration/test.sh

integration-down:
	./tests/integration/down.sh

integration:
	@set -eu; \
	trap '$(MAKE) integration-down' EXIT INT TERM; \
	$(MAKE) integration-up; \
	$(MAKE) integration-test
```

The integration scripts should derive all paths from a dedicated test root and should not modify production Mailu configuration.

## 18. Suggested repository layout

```text
.
├── mailu-ops
├── README.md
├── AGENTS.md
├── TESTING.md
├── Makefile
├── examples/
│   ├── config.json
│   └── migration-profile.json
└── tests/
    ├── helpers/
    ├── stubs/
    │   ├── docker
    │   └── imapsync
    ├── quota.bats
    ├── migration.bats
    ├── security.bats
    └── integration/
        ├── up.sh
        ├── seed.py
        ├── verify.py
        ├── test.sh
        └── down.sh
```

## 19. CI guidance

Run the stubbed Bats suite on every commit and pull request.

Run the full Mailu integration test:

- manually;
- on a scheduled workflow;
- before a release;
- after changes to Docker discovery, Dovecot parsing, TLS handling, or `imapsync` construction.

Do not store real customer credentials in CI secrets for this test. Use only generated fixture credentials and disposable certificates.

## 20. Security rules for tests

The test suite must preserve the same safety contract as production:

- never print passwords;
- never pass passwords directly as command-line arguments;
- never disable TLS peer verification;
- never use delete, expunge, or destructive `imapsync` options;
- never operate on a production Compose project;
- never use production Mailu data directories;
- never rely on DNS that could resolve to a production server;
- use explicit test hostnames and loopback addresses;
- require exact confirmation for interactive destructive or state-changing operations;
- leave logs for failed tests, but remove credentials and temporary data during cleanup.

## References

- Mailu setup and Docker Compose documentation: <https://mailu.io/2024.06/compose/setup.html>
- Mailu CLI documentation: <https://mailu.io/2024.06/cli.html>
- Mailu system requirements: <https://mailu.io/2024.06/compose/requirements.html>
- Dovecot `doveadm quota` documentation: <https://doc.dovecot.org/main/core/man/doveadm-quota.1.html>
- imapsync project and documentation: <https://github.com/imapsync/imapsync>
- Docker Compose `down` reference: <https://docs.docker.com/reference/cli/docker/compose/down/>
