#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
export LC_ALL=C

# shellcheck source=tests/integration/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_real_opt_in
load_state
assert_safe_state

printf 'Removing Mailu integration stack:\n  PROJECT=%s\n  TEST_ROOT=%s\n' "$PROJECT" "$TEST_ROOT"
if [[ -d ${MAILU_DIR:-$TEST_ROOT/mailu} ]]; then
	cd "${MAILU_DIR:-$TEST_ROOT/mailu}"
	docker compose -p "$PROJECT" down --volumes --remove-orphans || true
else
	docker compose -p "$PROJECT" down --volumes --remove-orphans || true
fi

if docker image inspect redis:alpine >/dev/null 2>&1; then
	docker run --rm --network none -v "$TEST_ROOT:/target" redis:alpine sh -c 'find /target -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +'
fi
rmdir "$TEST_ROOT" 2>/dev/null || rm -rf -- "$TEST_ROOT" 2>/dev/null || {
	printf 'warning: could not remove %s; root-owned files may remain.\n' "$TEST_ROOT" >&2
}
rm -f -- "$(state_file)"
printf '%s\n' 'Integration cleanup finished.'
