#!/usr/bin/env bats
load helpers/test_helper

setup() { setup_mailuops_env; }
teardown() { teardown_mailuops_env; }

@test "quota get renders captured storage and message values" {
	run mailuops_cmd quota get info@example.com
	assert_success
	assert_output_contains "Mailbox:        info@example.com"
	assert_output_contains "Storage used:   1.08 MiB"
	assert_output_contains "Storage limit:  1.40 GiB"
	assert_output_contains "Usage:          0.08%"
	assert_output_contains "Messages:       24"
}

@test "quota get --json emits valid normalized JSON" {
	run mailuops_cmd quota get info@example.com --json
	assert_success
	printf '%s\n' "$output" | jq -e '.mailbox == "info@example.com" and .storage.used_kib == 1110 and .storage.used_bytes == 1136640 and .messages.used == 24' >/dev/null
}

@test "quota list uses one native all-user doveadm invocation and sorts output" {
	run mailuops_cmd quota list --json
	assert_success
	printf '%s\n' "$output" | jq -e 'length == 2 and .[0].mailbox == "info@example.com" and .[1].mailbox == "z@example.com"' >/dev/null
	[ "$(tr '\t' '\n' <"$MAILUOPS_STUB_DIR/docker.argv" | grep -Fx -- '-A' | wc -l)" -eq 1 ]
}

@test "quota parser rejects duplicate storage rows" {
	export DOCKER_QUOTA_SINGLE_FILE="$BATS_TEST_DIRNAME/fixtures/quota-duplicate-storage.json"
	run mailuops_cmd quota get info@example.com --json
	assert_failure_status 65
}

@test "quota get handles unlimited storage" {
	export DOCKER_QUOTA_SINGLE_FILE="$BATS_TEST_DIRNAME/fixtures/quota-unlimited.json"
	run mailuops_cmd quota get info@example.com
	assert_success
	assert_output_contains "Storage limit:  unlimited"
	assert_output_contains "Usage:          n/a"
}

@test "quota parser rejects unrecognized row types" {
	export DOCKER_QUOTA_SINGLE_FILE="$BATS_TEST_DIRNAME/fixtures/quota-unknown-type.json"
	run mailuops_cmd quota get info@example.com --json
	assert_failure_status 65
}

@test "quota parser rejects negative message usage" {
	export DOCKER_QUOTA_SINGLE_FILE="$BATS_TEST_DIRNAME/fixtures/quota-negative-message.json"
	run mailuops_cmd quota get info@example.com --json
	assert_failure_status 65
}

@test "quota parser rejects stderr mixed with JSON output" {
	export DOCKER_QUOTA_STDERR="dovecot warning before json"
	run mailuops_cmd quota get info@example.com --json
	assert_failure_status 65
}
