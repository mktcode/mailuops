.PHONY: test integration-preflight integration-up integration-test integration-down integration

test:
	bash -n mailuops
	shellcheck mailuops tests/helpers/test_helper.bash tests/stubs/docker tests/stubs/imapsync tests/integration/*.sh
	shfmt -d mailuops tests
	bats tests

integration-preflight:
	tests/integration/preflight.sh

integration-up:
	MAILUOPS_REAL_MAILU=1 tests/integration/up.sh

integration-test:
	MAILUOPS_REAL_MAILU=1 tests/integration/test.sh

integration-down:
	MAILUOPS_REAL_MAILU=1 tests/integration/down.sh

integration:
	@if [ "$${MAILUOPS_REAL_MAILU:-}" != 1 ]; then \
		printf '%s\n' 'Refusing to start real Mailu integration without MAILUOPS_REAL_MAILU=1.' >&2; \
		printf '%s\n' 'Run make integration-preflight first and read TESTING.md.' >&2; \
		exit 1; \
	fi
	@set -eu; \
	trap 'MAILUOPS_REAL_MAILU=1 tests/integration/down.sh' EXIT INT TERM; \
	MAILUOPS_REAL_MAILU=1 tests/integration/up.sh; \
	MAILUOPS_REAL_MAILU=1 tests/integration/test.sh
