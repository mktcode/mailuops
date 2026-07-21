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
