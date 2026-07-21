#!/usr/bin/env bats
load helpers/test_helper

setup() { setup_mailuops_env; }
teardown() { teardown_mailuops_env; }

@test "0644 passfile is rejected before imapsync" {
	chmod 644 "$TEST_ROOT/secrets/source.pass"
	run mailuops_cmd migrate probe info@example.com
	assert_failure_status 77
	[ ! -e "$MAILUOPS_STUB_DIR/imapsync.argv" ]
}

@test "0660 passfile is rejected before imapsync" {
	chmod 660 "$TEST_ROOT/secrets/source.pass"
	run mailuops_cmd migrate probe info@example.com
	assert_failure_status 77
	[ ! -e "$MAILUOPS_STUB_DIR/imapsync.argv" ]
}

@test "symlink passfile is rejected" {
	rm "$TEST_ROOT/secrets/source.pass"
	ln -s "$TEST_ROOT/secrets/destination.pass" "$TEST_ROOT/secrets/source.pass"
	run mailuops_cmd migrate probe info@example.com
	assert_failure_status 77
}

@test "passfile outside secrets_dir is rejected" {
	printf '%s\n' 'outside-password-fixture' >"$TEST_ROOT/outside.pass"
	chmod 600 "$TEST_ROOT/outside.pass"
	jq --arg p "$TEST_ROOT/outside.pass" '.source.password_file = $p' "$TEST_ROOT/profiles/profile.json" >"$TEST_ROOT/profiles/profile.tmp"
	mv "$TEST_ROOT/profiles/profile.tmp" "$TEST_ROOT/profiles/profile.json"
	chmod 600 "$TEST_ROOT/profiles/profile.json"
	run mailuops_cmd migrate probe info@example.com
	assert_failure_status 77
}

@test "missing CA file is rejected before imapsync" {
	rm "$TEST_ROOT/ca.pem"
	run mailuops_cmd migrate probe info@example.com
	assert_failure_status 69
	[ ! -e "$MAILUOPS_STUB_DIR/imapsync.argv" ]
}

@test "generated imapsync argv forces TLS verification and no-expunge" {
	run mailuops_cmd migrate probe info@example.com
	assert_success
	argv=$(cat "$MAILUOPS_STUB_DIR/imapsync.argv")
	[[ $argv == *--ssl1* && $argv == *--ssl2* ]]
	[[ $argv == *SSL_verify_mode=1* && $argv == *SSL_ca_file=* ]]
	[[ $argv == *--noexpunge1* && $argv == *--noexpunge2* && $argv == *--nouidexpunge2* ]]
}

@test "generated imapsync argv contains no destructive positive options" {
	run mailuops_cmd migrate probe info@example.com
	assert_success
	argv=$(tr '\t' '\n' <"$MAILUOPS_STUB_DIR/imapsync.argv")
	! grep -Ex -- '--delete1|--delete2|--expunge1|--expunge2|--uidexpunge2' <<<"$argv"
}

@test "folder mapping value cannot inject an imapsync option" {
	jq '.folders.map = [{"from":"--delete2","to":"Imported"}]' "$TEST_ROOT/profiles/profile.json" >"$TEST_ROOT/profiles/profile.tmp"
	mv "$TEST_ROOT/profiles/profile.tmp" "$TEST_ROOT/profiles/profile.json"
	chmod 600 "$TEST_ROOT/profiles/profile.json"
	run mailuops_cmd migrate probe info@example.com
	assert_success
	argv=$(tr '\t' '\n' <"$MAILUOPS_STUB_DIR/imapsync.argv")
	! grep -Fx -- '--delete2' <<<"$argv"
	grep -Fx -- '--delete2=Imported' <<<"$argv"
}

@test "password values do not appear in output or argv" {
	run mailuops_cmd migrate probe info@example.com
	assert_success
	combined="$output $(cat "$MAILUOPS_STUB_DIR/imapsync.argv") $(find "$TEST_ROOT/log" -type f -exec cat {} +)"
	[[ $combined != *source-password-fixture* ]]
	[[ $combined != *destination-password-fixture* ]]
}

@test "runtime executable has no prohibited shell constructs or destructive option literals" {
	exe="$BATS_TEST_DIRNAME/../mailuops"
	! grep -En '(^|[;&|[:space:]])(eval|source)([[:space:]]|$)|bash[[:space:]]+-c|sh[[:space:]]+-c' "$exe"
	! grep -En -- '(^|[^A-Za-z0-9-])--(delete1|delete2|expunge1|expunge2|uidexpunge2)([^A-Za-z0-9-]|$)' "$exe"
}

@test "profile symlink is rejected during scanning" {
	rm "$TEST_ROOT/profiles/profile.json"
	ln -s "$TEST_ROOT/config.json" "$TEST_ROOT/profiles/profile.json"
	run mailuops_cmd migrate probe info@example.com
	assert_failure_status 77
}

@test "duplicate migration profile addresses are rejected" {
	cp "$TEST_ROOT/profiles/profile.json" "$TEST_ROOT/profiles/duplicate.json"
	chmod 600 "$TEST_ROOT/profiles/duplicate.json"
	run mailuops_cmd migrate probe info@example.com
	assert_failure_status 65
}

@test "malformed unrelated migration profile is rejected during scanning" {
	printf '{not json\n' >"$TEST_ROOT/profiles/broken.json"
	chmod 600 "$TEST_ROOT/profiles/broken.json"
	run mailuops_cmd migrate probe info@example.com
	assert_failure_status 65
}
