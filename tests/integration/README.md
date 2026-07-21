# Real Mailu integration tests

This directory is for optional tests against a disposable Docker Compose Mailu stack.

Start with the read-only preflight:

```bash
tests/integration/preflight.sh
```

The preflight is safe to run on a development machine. It checks tools, Docker access, port 993, stale `mailuops-it-*` Docker resources, and the stubbed test suite. It does **not** pull images, start containers, remove containers, or modify host files.

Do not add scripts here that start or remove Docker resources unless they require an explicit opt-in, for example:

```bash
MAILUOPS_REAL_MAILU=1 tests/integration/up.sh
```

The intended real-stack design is documented in `../../TESTING.md`.
