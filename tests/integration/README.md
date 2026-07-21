# Real Mailu integration tests

This directory contains optional tests against a disposable Docker Compose Mailu stack.

Safe read-only preflight:

```bash
make integration-preflight
```

Run the real stack only with explicit opt-in and a per-host guard:

Create the per-host guard file once on a machine where this disposable test is allowed:

```bash
mkdir -p "$HOME/.config/mailuops"
chmod 700 "$HOME/.config/mailuops"
printf '%s\n' 'I_UNDERSTAND_THIS_STARTS_AND_REMOVES_A_DISPOSABLE_MAILU_STACK' > "$HOME/.config/mailuops/allow-destructive-mailu-integration-tests"
chmod 600 "$HOME/.config/mailuops/allow-destructive-mailu-integration-tests"
```

Then run with both explicit environment variables:

```bash
MAILUOPS_REAL_MAILU=1 \
MAILUOPS_DISPOSABLE_MAILU_STACK_OK='I_UNDERSTAND_THIS_STARTS_AND_REMOVES_A_DISPOSABLE_MAILU_STACK' \
make integration
```

Manual lifecycle, useful for debugging:

```bash
MAILUOPS_REAL_MAILU=1 MAILUOPS_DISPOSABLE_MAILU_STACK_OK='I_UNDERSTAND_THIS_STARTS_AND_REMOVES_A_DISPOSABLE_MAILU_STACK' make integration-up
MAILUOPS_REAL_MAILU=1 MAILUOPS_DISPOSABLE_MAILU_STACK_OK='I_UNDERSTAND_THIS_STARTS_AND_REMOVES_A_DISPOSABLE_MAILU_STACK' make integration-test
MAILUOPS_REAL_MAILU=1 MAILUOPS_DISPOSABLE_MAILU_STACK_OK='I_UNDERSTAND_THIS_STARTS_AND_REMOVES_A_DISPOSABLE_MAILU_STACK' make integration-down
```

Safety properties:

- requires `MAILUOPS_REAL_MAILU=1`, the exact `MAILUOPS_DISPOSABLE_MAILU_STACK_OK` phrase, and a matching per-host guard file for stack start/test/down scripts;
- uses a unique `mailuops-it-*` Compose project;
- writes all bind mounts under `$HOME/.cache/mailuops-it.XXXXXX`;
- records state in `tests/integration/.state.env`;
- patches generated Mailu Compose ports to publish only `127.0.0.1:993:993`;
- validates that no broader published ports remain before `docker compose up`;
- never edits `/etc/hosts`, firewall rules, Docker daemon settings, or system trust stores.

The design and operational concerns are documented in `../../TESTING.md`.
