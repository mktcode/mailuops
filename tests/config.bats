#!/usr/bin/env bats
load helpers/test_helper

setup() { setup_mailuops_env; }
teardown() { teardown_mailuops_env; }

@test "unknown global config key is rejected" {
	jq '.unexpected = true' "$TEST_ROOT/config.json" >"$TEST_ROOT/config.tmp"
	mv "$TEST_ROOT/config.tmp" "$TEST_ROOT/config.json"
	chmod 600 "$TEST_ROOT/config.json"
	run mailuops_cmd quota list
	assert_failure_status 65
}

@test "insecure TLS key is rejected as unknown" {
	jq '.migration.destination.insecure = true' "$TEST_ROOT/config.json" >"$TEST_ROOT/config.tmp"
	mv "$TEST_ROOT/config.tmp" "$TEST_ROOT/config.json"
	chmod 600 "$TEST_ROOT/config.json"
	run mailuops_cmd migrate probe info@example.com
	assert_failure_status 65
}

@test "group writable config file is rejected" {
	chmod 620 "$TEST_ROOT/config.json"
	run mailuops_cmd quota list
	assert_failure_status 77
}

@test "invalid address is rejected before Docker" {
	run mailuops_cmd quota get $'bad\naddr@example.com'
	assert_failure_status 64
	[ ! -e "$MAILUOPS_STUB_DIR/docker.argv" ]
}
