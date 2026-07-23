#!/usr/bin/env bash

setup_mailuops_env() {
	local test_base
	test_base=${MAILUOPS_TEST_BASE:-${HOME:?}/.mailuops-test-tmp}
	mkdir -p -- "$test_base"
	chmod 700 -- "$test_base"
	TEST_ROOT=$(mktemp -d -p "$test_base" mailuops.XXXXXX)
	chmod 700 "$TEST_ROOT"
	mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/etc" "$TEST_ROOT/profiles" "$TEST_ROOT/secrets" "$TEST_ROOT/log" "$TEST_ROOT/state" "$TEST_ROOT/run" "$TEST_ROOT/stub"
	chmod 700 "$TEST_ROOT"/*
	export PATH="$TEST_ROOT/bin:$PATH"
	export MAILUOPS_STUB_DIR="$TEST_ROOT/stub"
	cp "$BATS_TEST_DIRNAME/stubs/docker" "$TEST_ROOT/bin/docker"
	cp "$BATS_TEST_DIRNAME/stubs/imapsync" "$TEST_ROOT/bin/imapsync"
	chmod 755 "$TEST_ROOT/bin/docker" "$TEST_ROOT/bin/imapsync"
	printf 'CA fixture\n' >"$TEST_ROOT/ca.pem"
	chmod 644 "$TEST_ROOT/ca.pem"
	printf 'source-password-fixture\n' >"$TEST_ROOT/secrets/source.pass"
	printf 'destination-password-fixture\n' >"$TEST_ROOT/secrets/destination.pass"
	chmod 600 "$TEST_ROOT/secrets/source.pass" "$TEST_ROOT/secrets/destination.pass"
	write_config
	write_profile info@example.com
}

teardown_mailuops_env() {
	if [[ -n ${TEST_ROOT:-} ]]; then
		rm -rf "$TEST_ROOT"
	fi
}

write_config() {
	cat >"$TEST_ROOT/config.json" <<EOF_CONFIG
{
  "schema_version": 1,
  "mailu": {
    "imap_container": "mailu-imap-1",
    "compose_project": "mailu",
    "quota_root": "User quota"
  },
  "migration": {
    "profiles_dir": "$TEST_ROOT/profiles",
    "secrets_dir": "$TEST_ROOT/secrets",
    "imapsync_binary": "$TEST_ROOT/bin/imapsync",
    "destination": {
      "host": "mail.example.net",
      "port": 993,
      "ca_file": "$TEST_ROOT/ca.pem"
    },
    "source_default_ca_file": "$TEST_ROOT/ca.pem",
    "log_dir": "$TEST_ROOT/log",
    "state_dir": "$TEST_ROOT/state",
    "runtime_dir": "$TEST_ROOT/run",
    "timeout_seconds": 120
  }
}
EOF_CONFIG
	chmod 600 "$TEST_ROOT/config.json"
}

write_profile() {
	local address=$1
	cat >"$TEST_ROOT/profiles/profile.json" <<EOF_PROFILE
{
  "schema_version": 1,
  "address": "$address",
  "source": {
    "host": "imap.old-provider.example",
    "port": 993,
    "username": "$address",
    "password_file": "$TEST_ROOT/secrets/source.pass",
    "ca_file": "$TEST_ROOT/ca.pem"
  },
  "destination": {
    "username": "$address",
    "password_file": "$TEST_ROOT/secrets/destination.pass"
  },
  "folders": {
    "automap": true,
    "map": [
      {"from": "Sent Items", "to": "Sent"}
    ]
  }
}
EOF_PROFILE
	chmod 600 "$TEST_ROOT/profiles/profile.json"
}

mailuops_cmd() {
	"$BATS_TEST_DIRNAME/../mailuops" --config "$TEST_ROOT/config.json" "$@"
}

assert_success() {
	# Bats defines $status and $output after `run`; this helper is sourced by tests.
	# shellcheck disable=SC2154
	[ "$status" -eq 0 ] || {
		printf 'expected success, got %s\noutput:\n%s\n' "$status" "$output" >&2
		return 1
	}
}

assert_failure_status() {
	local expected=$1
	# Bats defines $status and $output after `run`; this helper is sourced by tests.
	# shellcheck disable=SC2154
	[ "$status" -eq "$expected" ] || {
		printf 'expected status %s, got %s\nstdout/stderr:\n%s\n' "$expected" "$status" "$output" >&2
		return 1
	}
}

assert_output_contains() {
	# Bats defines $output after `run`; this helper is sourced by tests.
	# shellcheck disable=SC2154
	[[ $output == *"$1"* ]] || {
		printf 'expected output to contain: %s\nactual:\n%s\n' "$1" "$output" >&2
		return 1
	}
}
