#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
export LC_ALL=C

# shellcheck source=tests/integration/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_real_opt_in
load_state
assert_safe_state

REPO=${REPO:-$(repo_root)}
OPS_DIR=${OPS_DIR:-$TEST_ROOT/ops}
MAILU_DIR=${MAILU_DIR:-$TEST_ROOT/mailu}
IMAP_CONTAINER=${IMAP_CONTAINER:-}
[[ -n $IMAP_CONTAINER ]] || {
	printf 'IMAP_CONTAINER missing from integration state.\n' >&2
	exit 1
}

printf '%s\n' 'Writing passfiles...'
printf '%s\n' 'Source-Test-Only-1!' >"$OPS_DIR/secrets/source.pass"
printf '%s\n' 'Target-Test-Only-1!' >"$OPS_DIR/secrets/target.pass"
chmod 0600 "$OPS_DIR/secrets/source.pass" "$OPS_DIR/secrets/target.pass"

printf '%s\n' 'Seeding source mailbox via real IMAPS...'
TEST_ROOT=$TEST_ROOT "$(integration_dir)/seed.py"

printf '%s\n' 'Writing mailuops config/profile...'
IMAPSYNC_BIN=$(command -v imapsync)
jq -n \
	--arg imap_container "$IMAP_CONTAINER" \
	--arg project "$PROJECT" \
	--arg profiles "$OPS_DIR/migrations.d" \
	--arg secrets "$OPS_DIR/secrets" \
	--arg imapsync "$IMAPSYNC_BIN" \
	--arg ca "$TEST_ROOT/pki/ca.crt" \
	--arg log "$OPS_DIR/log" \
	--arg state "$OPS_DIR/state" \
	--arg run "$OPS_DIR/run" \
	'{
    schema_version: 1,
    mailu: { imap_container: $imap_container, compose_project: $project, quota_root: "User quota" },
    migration: {
      profiles_dir: $profiles,
      secrets_dir: $secrets,
      imapsync_binary: $imapsync,
      destination: { host: "localhost", port: 993, ca_file: $ca },
      source_default_ca_file: $ca,
      log_dir: $log,
      state_dir: $state,
      runtime_dir: $run,
      timeout_seconds: 120
    }
  }' >"$OPS_DIR/config.json"

jq -n \
	--arg ca "$TEST_ROOT/pki/ca.crt" \
	--arg source_pass "$OPS_DIR/secrets/source.pass" \
	--arg target_pass "$OPS_DIR/secrets/target.pass" \
	'{
    schema_version: 1,
    address: "target@example.test",
    source: {
      host: "localhost",
      port: 993,
      username: "source@example.test",
      password_file: $source_pass,
      ca_file: $ca
    },
    destination: { username: "target@example.test", password_file: $target_pass },
    folders: { automap: true, map: [] }
  }' >"$OPS_DIR/migrations.d/target.json"
chmod 0600 "$OPS_DIR/config.json" "$OPS_DIR/migrations.d/target.json"

printf '%s\n' 'Checking real doveadm quota through mailuops...'
cd "$TEST_ROOT"
"$REPO/mailuops" --config "$OPS_DIR/config.json" quota get source@example.test
"$REPO/mailuops" --config "$OPS_DIR/config.json" quota list --json | jq -e '.[] | select(.mailbox == "source@example.test")' >/dev/null

printf '%s\n' 'Running real migrate probe...'
"$REPO/mailuops" --config "$OPS_DIR/config.json" migrate probe target@example.test

printf '%s\n' 'Running real additive migration...'
"$REPO/mailuops" --config "$OPS_DIR/config.json" migrate run target@example.test --yes

printf '%s\n' 'Checking destination quota and mailbox contents...'
"$REPO/mailuops" --config "$OPS_DIR/config.json" quota get target@example.test
TEST_ROOT=$TEST_ROOT "$(integration_dir)/verify.py"

printf '%s\n' 'Checking rerun does not duplicate messages...'
"$REPO/mailuops" --config "$OPS_DIR/config.json" migrate run target@example.test --yes
TEST_ROOT=$TEST_ROOT "$(integration_dir)/verify.py"

if grep -R -F 'Source-Test-Only-1!' "$OPS_DIR/log" "$OPS_DIR/state" 2>/dev/null; then
	printf 'source password leaked into logs/state.\n' >&2
	exit 1
fi
if grep -R -F 'Target-Test-Only-1!' "$OPS_DIR/log" "$OPS_DIR/state" 2>/dev/null; then
	printf 'target password leaked into logs/state.\n' >&2
	exit 1
fi

printf 'Real Mailu integration test passed. Logs are under %s\n' "$OPS_DIR/log"
