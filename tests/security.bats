#!/usr/bin/env bats
load helpers/test_helper

setup() { setup_mailuops_env; }
teardown() { teardown_mailuops_env; }

@test "BASH_ENV is ignored before script startup" {
	printf 'printf executed >%q\n' "$TEST_ROOT/bash-env-marker" >"$TEST_ROOT/bash-env-hook"
	chmod 700 "$TEST_ROOT/bash-env-hook"
	run env BASH_ENV="$TEST_ROOT/bash-env-hook" "$BATS_TEST_DIRNAME/../mailuops" --version
	assert_success
	[ ! -e "$TEST_ROOT/bash-env-marker" ]
}

@test "inherited SHELLOPTS xtrace does not enable tracing" {
	run env SHELLOPTS=xtrace "$BATS_TEST_DIRNAME/../mailuops" --version
	assert_success
	[[ $output == "mailuops 1.0.0-rc1" ]]
}

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

@test "group writable imapsync executable is rejected before credentials are used" {
	chmod 775 "$TEST_ROOT/bin/imapsync"
	run mailuops_cmd migrate probe info@example.com
	assert_failure_status 77
	[ ! -e "$MAILUOPS_STUB_DIR/imapsync.argv" ]
}

@test "imapsync executable symlink is rejected before execution" {
	ln -s "$TEST_ROOT/bin/imapsync" "$TEST_ROOT/bin/imapsync-link"
	jq --arg p "$TEST_ROOT/bin/imapsync-link" '.migration.imapsync_binary = $p' "$TEST_ROOT/config.json" >"$TEST_ROOT/config.tmp"
	mv "$TEST_ROOT/config.tmp" "$TEST_ROOT/config.json"
	chmod 600 "$TEST_ROOT/config.json"
	run mailuops_cmd migrate probe info@example.com
	assert_failure_status 77
	[ ! -e "$MAILUOPS_STUB_DIR/imapsync.argv" ]
}

@test "sticky world writable imapsync parent directory is rejected" {
	mkdir "$TEST_ROOT/sticky-bin"
	chmod 1777 "$TEST_ROOT/sticky-bin"
	cp "$TEST_ROOT/bin/imapsync" "$TEST_ROOT/sticky-bin/imapsync"
	chmod 755 "$TEST_ROOT/sticky-bin/imapsync"
	jq --arg p "$TEST_ROOT/sticky-bin/imapsync" '.migration.imapsync_binary = $p' "$TEST_ROOT/config.json" >"$TEST_ROOT/config.tmp"
	mv "$TEST_ROOT/config.tmp" "$TEST_ROOT/config.json"
	chmod 600 "$TEST_ROOT/config.json"
	run mailuops_cmd migrate probe info@example.com
	assert_failure_status 77
	[ ! -e "$MAILUOPS_STUB_DIR/imapsync.argv" ]
}

@test "sticky world writable profiles_dir parent is rejected" {
	mkdir "$TEST_ROOT/sticky-profiles" "$TEST_ROOT/sticky-profiles/profiles"
	chmod 1777 "$TEST_ROOT/sticky-profiles"
	chmod 700 "$TEST_ROOT/sticky-profiles/profiles"
	cp "$TEST_ROOT/profiles/profile.json" "$TEST_ROOT/sticky-profiles/profiles/profile.json"
	chmod 600 "$TEST_ROOT/sticky-profiles/profiles/profile.json"
	jq --arg p "$TEST_ROOT/sticky-profiles/profiles" '.migration.profiles_dir = $p' "$TEST_ROOT/config.json" >"$TEST_ROOT/config.tmp"
	mv "$TEST_ROOT/config.tmp" "$TEST_ROOT/config.json"
	chmod 600 "$TEST_ROOT/config.json"
	run mailuops_cmd migrate probe info@example.com
	assert_failure_status 77
	[ ! -e "$MAILUOPS_STUB_DIR/imapsync.argv" ]
}

@test "sticky world writable secrets_dir parent is rejected" {
	mkdir "$TEST_ROOT/sticky-secrets" "$TEST_ROOT/sticky-secrets/secrets"
	chmod 1777 "$TEST_ROOT/sticky-secrets"
	chmod 700 "$TEST_ROOT/sticky-secrets/secrets"
	cp "$TEST_ROOT/secrets/source.pass" "$TEST_ROOT/sticky-secrets/secrets/source.pass"
	cp "$TEST_ROOT/secrets/destination.pass" "$TEST_ROOT/sticky-secrets/secrets/destination.pass"
	chmod 600 "$TEST_ROOT/sticky-secrets/secrets/source.pass" "$TEST_ROOT/sticky-secrets/secrets/destination.pass"
	jq --arg d "$TEST_ROOT/sticky-secrets/secrets" '.migration.secrets_dir = $d' "$TEST_ROOT/config.json" >"$TEST_ROOT/config.tmp"
	mv "$TEST_ROOT/config.tmp" "$TEST_ROOT/config.json"
	chmod 600 "$TEST_ROOT/config.json"
	jq \
		--arg s "$TEST_ROOT/sticky-secrets/secrets/source.pass" \
		--arg p "$TEST_ROOT/sticky-secrets/secrets/destination.pass" \
		'.source.password_file = $s | .destination.password_file = $p' \
		"$TEST_ROOT/profiles/profile.json" >"$TEST_ROOT/profiles/profile.tmp"
	mv "$TEST_ROOT/profiles/profile.tmp" "$TEST_ROOT/profiles/profile.json"
	chmod 600 "$TEST_ROOT/profiles/profile.json"
	run mailuops_cmd migrate probe info@example.com
	assert_failure_status 77
	[ ! -e "$MAILUOPS_STUB_DIR/imapsync.argv" ]
}

@test "sticky world writable runtime log and state parents are rejected" {
	for field in runtime_dir log_dir state_dir; do
		teardown_mailuops_env
		setup_mailuops_env
		mkdir "$TEST_ROOT/sticky-operational" "$TEST_ROOT/sticky-operational/value"
		chmod 1777 "$TEST_ROOT/sticky-operational"
		chmod 700 "$TEST_ROOT/sticky-operational/value"
		jq --arg p "$TEST_ROOT/sticky-operational/value" --arg field "$field" '.migration[$field] = $p' "$TEST_ROOT/config.json" >"$TEST_ROOT/config.tmp"
		mv "$TEST_ROOT/config.tmp" "$TEST_ROOT/config.json"
		chmod 600 "$TEST_ROOT/config.json"
		run mailuops_cmd migrate probe info@example.com
		assert_failure_status 77
		[ ! -e "$MAILUOPS_STUB_DIR/imapsync.argv" ]
	done
}

@test "docker exec uses discovered container ID, not mutable name" {
	run mailuops_cmd quota get info@example.com
	assert_success
	grep -F -- $'docker\texec\t--\tcid123\t' "$MAILUOPS_STUB_DIR/docker.argv"
	! grep -F -- $'docker\texec\t--\tmailu-imap-1\t' "$MAILUOPS_STUB_DIR/docker.argv"
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
