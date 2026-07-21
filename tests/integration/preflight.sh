#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
export LC_ALL=C

missing=0
require_cmd() {
	local cmd=$1
	if command -v "$cmd" >/dev/null 2>&1; then
		printf 'ok: %-10s %s\n' "$cmd" "$(command -v "$cmd")"
	else
		printf 'missing: %s\n' "$cmd" >&2
		missing=1
	fi
}

printf 'mailuops real-Mailu integration preflight\n'
printf '==========================================\n\n'

printf 'Tools:\n'
for cmd in bash docker jq openssl python3 imapsync ss awk grep date mktemp; do
	require_cmd "$cmd"
done

printf '\nVersions:\n'
docker --version 2>&1 || true
docker compose version 2>&1 || true
jq --version 2>&1 || true
openssl version 2>&1 || true
python3 --version 2>&1 || true
if command -v imapsync >/dev/null 2>&1; then
	imapsync --version 2>&1 | head -5 || true
fi

printf '\nDocker daemon/access:\n'
if ! docker info --format 'ServerVersion={{.ServerVersion}}' 2>&1; then
	printf 'error: Docker daemon is not reachable or this user lacks Docker access.\n' >&2
	missing=1
fi

printf '\nExisting containers:\n'
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' 2>&1 || true

printf '\nPort 993 listeners:\n'
port_output=$(ss -ltnp 2>/dev/null | awk 'NR == 1 || $4 ~ /(^|:)993$/')
printf '%s\n' "$port_output"
if awk 'NR > 1 { found=1 } END { exit found ? 0 : 1 }' <<<"$port_output"; then
	printf 'error: port 993 is already listening; the real Mailu test should not start.\n' >&2
	missing=1
fi

printf '\nExisting mailuops integration Docker resources:\n'
docker ps -a \
	--filter 'label=com.docker.compose.project' \
	--format '{{.Label "com.docker.compose.project"}}\t{{.Names}}\t{{.Status}}' |
	awk '$1 ~ /^mailuops-it-/ { print }' || true

docker network ls --format '{{.Name}}' | awk '/^mailuops-it-/ { print }' || true

printf '\nRepository checks:\n'
bash -n mailuops
shellcheck mailuops tests/helpers/test_helper.bash tests/stubs/docker tests/stubs/imapsync
shfmt -d mailuops tests
bats tests

printf '\nResult:\n'
if [[ $missing -ne 0 ]]; then
	printf 'preflight failed; do not start the real Mailu integration stack yet.\n' >&2
	exit 1
fi

printf 'preflight passed; it is reasonable to start a disposable loopback-only Mailu stack after explicit confirmation.\n'
