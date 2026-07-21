# Real Mailu integration tests

This directory contains optional tests against a disposable Docker Compose Mailu stack.

Safe read-only preflight:

```bash
make integration-preflight
```

Run the real stack only with explicit opt-in:

```bash
MAILUOPS_REAL_MAILU=1 make integration
```

Manual lifecycle, useful for debugging:

```bash
MAILUOPS_REAL_MAILU=1 make integration-up
MAILUOPS_REAL_MAILU=1 make integration-test
MAILUOPS_REAL_MAILU=1 make integration-down
```

Safety properties:

- requires `MAILUOPS_REAL_MAILU=1` for stack start/test/down scripts;
- uses a unique `mailuops-it-*` Compose project;
- writes all bind mounts under `$HOME/.cache/mailuops-it.XXXXXX`;
- records state in `tests/integration/.state.env`;
- patches generated Mailu Compose ports to publish only `127.0.0.1:993:993`;
- validates that no broader published ports remain before `docker compose up`;
- never edits `/etc/hosts`, firewall rules, Docker daemon settings, or system trust stores.

The design and operational concerns are documented in `../../TESTING.md`.
