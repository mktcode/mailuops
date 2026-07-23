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

@test "group writable config parent directory is rejected" {
	chmod 770 "$TEST_ROOT"
	run mailuops_cmd quota list
	assert_failure_status 77
}

@test "sticky world writable config parent directory is rejected" {
	mkdir "$TEST_ROOT/sticky"
	chmod 1777 "$TEST_ROOT/sticky"
	cp "$TEST_ROOT/config.json" "$TEST_ROOT/sticky/config.json"
	chmod 600 "$TEST_ROOT/sticky/config.json"
	run mailuops_exec --config "$TEST_ROOT/sticky/config.json" quota list
	assert_failure_status 77
}

@test "invalid address is rejected before Docker" {
	run mailuops_cmd quota get $'bad\naddr@example.com'
	assert_failure_status 64
	[ ! -e "$MAILUOPS_STUB_DIR/docker.argv" ]
}

@test "global destination host rejects IPv4 literal" {
	jq '.migration.destination.host = "127.0.0.1"' "$TEST_ROOT/config.json" >"$TEST_ROOT/config.tmp"
	mv "$TEST_ROOT/config.tmp" "$TEST_ROOT/config.json"
	chmod 600 "$TEST_ROOT/config.json"
	run mailuops_cmd migrate probe info@example.com
	assert_failure_status 65
	[ ! -e "$MAILUOPS_STUB_DIR/docker.argv" ]
	[ ! -e "$MAILUOPS_STUB_DIR/imapsync.argv" ]
}

@test "global destination host rejects newline" {
	jq '.migration.destination.host = "mail.example.net\nbad"' "$TEST_ROOT/config.json" >"$TEST_ROOT/config.tmp"
	mv "$TEST_ROOT/config.tmp" "$TEST_ROOT/config.json"
	chmod 600 "$TEST_ROOT/config.json"
	run mailuops_cmd migrate probe info@example.com
	assert_failure_status 65
	[ ! -e "$MAILUOPS_STUB_DIR/docker.argv" ]
	[ ! -e "$MAILUOPS_STUB_DIR/imapsync.argv" ]
}
