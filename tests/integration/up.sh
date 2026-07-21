#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
export LC_ALL=C

# shellcheck source=tests/integration/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_real_opt_in
for cmd in docker jq openssl python3 imapsync ss awk grep date mktemp; do
	require_cmd "$cmd"
done

STATE=$(state_file)
if [[ -e $STATE ]]; then
	printf 'state file already exists: %s\n' "$STATE" >&2
	printf 'Run MAILUOPS_REAL_MAILU=1 tests/integration/down.sh first, or inspect/remove the state file manually.\n' >&2
	exit 1
fi

if ! port_993_free; then
	printf 'port 993 is already in use; refusing to start Mailu integration stack.\n' >&2
	ss -ltnp | awk 'NR == 1 || $4 ~ /(^|:)993$/' >&2 || true
	exit 1
fi

REPO=$(repo_root)
PROJECT="mailuops-it-${USER:-user}-$(date -u +%Y%m%dt%H%M%Sz)"
TEST_ROOT=$(mktemp -d "$HOME/.cache/mailuops-it.XXXXXX")
touch "$TEST_ROOT/.mailuops-integration-root"

MAILU_DIR=$TEST_ROOT/mailu
OPS_DIR=$TEST_ROOT/ops
mkdir -p \
	"$MAILU_DIR" \
	"$MAILU_DIR/certs" \
	"$TEST_ROOT/pki" \
	"$OPS_DIR/migrations.d" \
	"$OPS_DIR/secrets" \
	"$OPS_DIR/log" \
	"$OPS_DIR/state" \
	"$OPS_DIR/run"

printf 'PROJECT=%q\nTEST_ROOT=%q\nMAILU_DIR=%q\nOPS_DIR=%q\nREPO=%q\n' \
	"$PROJECT" "$TEST_ROOT" "$MAILU_DIR" "$OPS_DIR" "$REPO" >"$STATE"

printf 'Created integration root:\n  PROJECT=%s\n  TEST_ROOT=%s\n' "$PROJECT" "$TEST_ROOT"

cd "$TEST_ROOT/pki"
cat >ca.ext <<'CA_EXT'
basicConstraints = critical, CA:TRUE
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
CA_EXT
openssl req -x509 -newkey rsa:3072 -nodes -sha256 -days 30 \
	-subj '/CN=mailuops integration CA' \
	-addext 'basicConstraints = critical, CA:TRUE' \
	-addext 'keyUsage = critical, keyCertSign, cRLSign' \
	-keyout ca.key -out ca.crt >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -sha256 \
	-subj '/CN=localhost' \
	-keyout localhost.key -out localhost.csr >/dev/null 2>&1
cat >localhost.ext <<'CERT_EXT'
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:localhost,DNS:mailu.local
CERT_EXT
openssl x509 -req -sha256 -days 30 \
	-in localhost.csr \
	-CA ca.crt \
	-CAkey ca.key \
	-CAcreateserial \
	-extfile localhost.ext \
	-out localhost.crt >/dev/null 2>&1
cp localhost.key "$MAILU_DIR/certs/key.pem"
cat localhost.crt ca.crt >"$MAILU_DIR/certs/cert.pem"
chmod 0600 ca.key "$MAILU_DIR/certs/key.pem"

printf 'Generating Mailu 2024.06 Compose files via setup.mailu.io...\n'
MAILU_DIR=$MAILU_DIR python3 - <<'PY'
import os
import pathlib
import re
import urllib.parse
import urllib.request

root = os.environ['MAILU_DIR']
data = {
    'flavor': 'compose',
    'root': root,
    'domain': 'example.test',
    'postmaster': 'admin',
    'tls_flavor': 'cert',
    'auth_ratelimit_ip': '5',
    'auth_ratelimit_user': '50',
    'message_ratelimit_pd': '200',
    'site_name': 'Mailu',
    'website': 'https://mailu.io',
    'admin_enabled': 'true',
    'webmail_type': 'none',
    'bind4': '127.0.0.1',
    'subnet': '192.168.203.0/24',
    'bind6': '::1',
    'subnet6': 'fd4f:10be:9cd3:beef::/64',
    'resolver_enabled': 'true',
    'hostnames': 'mailu.local',
}
req = urllib.request.Request(
    'https://setup.mailu.io/2024.06/submit',
    data=urllib.parse.urlencode(data).encode(),
    method='POST',
)
with urllib.request.urlopen(req, timeout=30) as response:
    html = response.read().decode('utf-8', 'replace')
match = re.search(r'/2024\.06/file/([^/]+)/docker-compose\.yml', html)
if not match:
    raise SystemExit('setup.mailu.io did not return a downloadable compose file')
setup_id = match.group(1)
for name in ('docker-compose.yml', 'mailu.env'):
    url = f'https://setup.mailu.io/2024.06/file/{setup_id}/{name}'
    with urllib.request.urlopen(url, timeout=30) as response:
        pathlib.Path(root, name).write_bytes(response.read())
PY

printf 'Restricting generated Compose ports to loopback IMAPS only...\n'
MAILU_DIR=$MAILU_DIR python3 - <<'PY'
from pathlib import Path
import os

path = Path(os.environ['MAILU_DIR']) / 'docker-compose.yml'
lines = path.read_text().splitlines()
out = []
in_front = False
in_ports = False
for line in lines:
    if line.startswith('  front:'):
        in_front = True
        out.append(line)
        continue
    if in_front and line.startswith('  ') and not line.startswith('    ') and not line.startswith('  front:'):
        in_front = False
        in_ports = False
    if in_front and line == '    ports:':
        in_ports = True
        out.append(line)
        continue
    if in_ports:
        if line.startswith('      - '):
            if '127.0.0.1:993:993' in line:
                out.append(line)
            continue
        in_ports = False
    out.append(line)
path.write_text('\n'.join(out) + '\n')
PY

if grep -E '"(0\.0\.0\.0|::|[0-9.]+):' "$MAILU_DIR/docker-compose.yml" | grep -v '"127\.0\.0\.1:993:993"'; then
	printf 'unexpected public or non-IMAPS port binding remains in generated Compose file; aborting.\n' >&2
	exit 1
fi
if [[ $(grep -c '127\.0\.0\.1:993:993' "$MAILU_DIR/docker-compose.yml") -ne 1 ]]; then
	printf 'expected exactly one loopback IMAPS port binding in generated Compose file; aborting.\n' >&2
	exit 1
fi

printf 'Pulling and starting Mailu stack %s...\n' "$PROJECT"
cd "$MAILU_DIR"
docker compose -p "$PROJECT" pull
docker compose -p "$PROJECT" up -d

docker compose -p "$PROJECT" ps

printf 'Waiting for admin, imap, and front containers...\n'
for _ in {1..60}; do
	admin_id=$(docker compose -p "$PROJECT" ps -q admin || true)
	imap_id=$(docker compose -p "$PROJECT" ps -q imap || true)
	front_id=$(docker compose -p "$PROJECT" ps -q front || true)
	if [[ -n $admin_id && -n $imap_id && -n $front_id ]]; then
		admin_state=$(docker inspect --format '{{.State.Running}}' "$admin_id" 2>/dev/null || true)
		imap_state=$(docker inspect --format '{{.State.Running}}' "$imap_id" 2>/dev/null || true)
		front_state=$(docker inspect --format '{{.State.Running}}' "$front_id" 2>/dev/null || true)
		if [[ $admin_state == true && $imap_state == true && $front_state == true ]]; then
			break
		fi
	fi
	sleep 2
done

docker compose -p "$PROJECT" ps

printf 'Waiting for Mailu admin database migrations...\n'
for _ in {1..90}; do
	if docker compose -p "$PROJECT" exec -T admin flask mailu config-export domain.name >/dev/null 2>&1; then
		break
	fi
	sleep 2
done
docker compose -p "$PROJECT" exec -T admin flask mailu config-export domain.name >/dev/null

printf 'Creating Mailu test users...\n'
docker compose -p "$PROJECT" exec -T admin flask mailu domain example.test
docker compose -p "$PROJECT" exec -T admin flask mailu admin admin example.test 'Admin-Test-Only-1!'
docker compose -p "$PROJECT" exec -T admin flask mailu user source example.test 'Source-Test-Only-1!'
docker compose -p "$PROJECT" exec -T admin flask mailu user target example.test 'Target-Test-Only-1!'

IMAP_ID=$(docker compose -p "$PROJECT" ps -q imap)
IMAP_CONTAINER=$(docker inspect --format '{{.Name}}' "$IMAP_ID")
IMAP_CONTAINER=${IMAP_CONTAINER#/}
printf 'IMAP_CONTAINER=%q\n' "$IMAP_CONTAINER" >>"$STATE"

printf 'Waiting for IMAPS/TLS on localhost:993...\n'
for _ in {1..60}; do
	if openssl s_client -connect localhost:993 -servername localhost -CAfile "$TEST_ROOT/pki/ca.crt" </dev/null 2>/dev/null | grep -q 'Verify return code: 0'; then
		break
	fi
	sleep 2
done
openssl s_client -connect localhost:993 -servername localhost -CAfile "$TEST_ROOT/pki/ca.crt" </dev/null 2>/dev/null | grep 'Verify return code: 0'

printf '%s\n' 'Mailu integration stack is up.'
printf 'State: %s\n' "$STATE"
