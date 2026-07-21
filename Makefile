.PHONY: test integration-preflight integration

test:
	bash -n mailuops
	shellcheck mailuops tests/helpers/test_helper.bash tests/stubs/docker tests/stubs/imapsync tests/integration/preflight.sh
	shfmt -d mailuops tests
	bats tests

integration-preflight:
	tests/integration/preflight.sh

integration:
	@if [ "$${MAILUOPS_REAL_MAILU:-}" != 1 ]; then \
		printf '%s\n' 'Refusing to start real Mailu integration without MAILUOPS_REAL_MAILU=1.' >&2; \
		printf '%s\n' 'Run make integration-preflight first and read TESTING.md.' >&2; \
		exit 1; \
	fi
	@printf '%s\n' 'Real Mailu integration scripts are not implemented yet. See TESTING.md.' >&2
	@exit 1
