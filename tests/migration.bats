#!/usr/bin/env bats
load helpers/test_helper

setup() { setup_mailuops_env; }
teardown() { teardown_mailuops_env; }

@test "probe preserves imapsync login failure status" {
	export IMAPSYNC_STATUS_LOGIN=12
	run mailuops_cmd migrate probe info@example.com
	assert_failure_status 12
}

@test "run --yes performs login, folder plan, repeated login, then sync" {
	run mailuops_cmd migrate run info@example.com --yes
	assert_success
	[ "$(grep -Fc -- '--justlogin' "$MAILUOPS_STUB_DIR/imapsync.argv")" -eq 2 ]
	[ "$(grep -Fc -- '--justfolders' "$MAILUOPS_STUB_DIR/imapsync.argv")" -eq 1 ]
	[ "$(grep -Fc -- 'imapsync' "$MAILUOPS_STUB_DIR/imapsync.argv")" -eq 4 ]
}

@test "real sync failure status is preserved" {
	export IMAPSYNC_STATUS_SYNC=113
	run mailuops_cmd migrate run info@example.com --yes
	assert_failure_status 113
}

@test "non-tty run without --yes fails before repeated login and sync" {
	run mailuops_cmd migrate run info@example.com
	assert_failure_status 64
	[ "$(grep -Fc -- 'imapsync' "$MAILUOPS_STUB_DIR/imapsync.argv")" -eq 2 ]
}

@test "confirmation mismatch does not invoke real sync" {
	run bash -c 'printf "wrong@example.com\n" | "$0" --config "$1" migrate run info@example.com' "$BATS_TEST_DIRNAME/../mailuops" "$TEST_ROOT/config.json"
	assert_failure_status 64
	[ "$(grep -Fc -- 'imapsync' "$MAILUOPS_STUB_DIR/imapsync.argv")" -eq 2 ]
}

@test "representative imapsync login failure statuses are preserved" {
	for code in 1 12 64 101 102 113 161 162 255; do
		teardown_mailuops_env
		setup_mailuops_env
		export IMAPSYNC_STATUS_LOGIN="$code"
		run mailuops_cmd migrate probe info@example.com
		assert_failure_status "$code"
		unset IMAPSYNC_STATUS_LOGIN
	done
}

@test "second concurrent migration operation fails with 75" {
	export IMAPSYNC_SLEEP=3
	"$BATS_TEST_DIRNAME/../mailuops" --config "$TEST_ROOT/config.json" migrate probe info@example.com >"$TEST_ROOT/first.out" 2>"$TEST_ROOT/first.err" &
	first_pid=$!
	for _ in {1..30}; do
		if [[ -s "$TEST_ROOT/run/migrate.lock" ]]; then
			break
		fi
		sleep 0.1
	done
	run mailuops_cmd migrate probe info@example.com
	assert_failure_status 75
	kill "$first_pid" 2>/dev/null || true
	wait "$first_pid" 2>/dev/null || true
}

@test "quota commands do not wait for migration lock" {
	export IMAPSYNC_SLEEP=3
	"$BATS_TEST_DIRNAME/../mailuops" --config "$TEST_ROOT/config.json" migrate probe info@example.com >"$TEST_ROOT/locked.out" 2>"$TEST_ROOT/locked.err" &
	pid=$!
	for _ in {1..30}; do
		if [[ -s "$TEST_ROOT/run/migrate.lock" ]]; then
			break
		fi
		sleep 0.1
	done
	run mailuops_cmd quota get info@example.com
	assert_success
	kill "$pid" 2>/dev/null || true
	wait "$pid" 2>/dev/null || true
}

@test "SIGTERM during sync is forwarded to imapsync process group" {
	export IMAPSYNC_CHILD_MARKER="$TEST_ROOT/child-signal.marker"
	"$BATS_TEST_DIRNAME/../mailuops" --config "$TEST_ROOT/config.json" migrate run info@example.com --yes >"$TEST_ROOT/signal.out" 2>"$TEST_ROOT/signal.err" &
	pid=$!
	for _ in {1..80}; do
		if [[ -e "$IMAPSYNC_CHILD_MARKER.ready" ]]; then
			break
		fi
		sleep 0.1
	done
	[[ -e "$IMAPSYNC_CHILD_MARKER.ready" ]]
	kill -TERM "$pid"
	set +e
	wait "$pid"
	st=$?
	set -e
	[[ $st -ne 0 ]]
	for _ in {1..30}; do
		if [[ -s "$IMAPSYNC_CHILD_MARKER" ]]; then
			break
		fi
		sleep 0.1
	done
	grep -Fx terminated "$IMAPSYNC_CHILD_MARKER"
}
