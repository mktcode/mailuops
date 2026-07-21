# Release checklist

Current release candidate: `mailuops 1.0.0-rc1`

Use this checklist before tagging or installing a production build.

## Required local checks

Run from a clean repository checkout:

```bash
git status --short
./mailuops --version
./mailuops --help
make test
make integration-preflight
```

Expected:

- `git status --short` is empty before tagging.
- `./mailuops --version` prints exactly one line with the release candidate version.
- `./mailuops --help` matches the command surface documented in `README.md`.
- `make test` passes without Docker daemon, network, or real credentials.
- `make integration-preflight` passes before any real Mailu integration run.

## Required real-Mailu integration check

Run only after reading `TESTING.md` and confirming the disposable Docker stack is acceptable on the machine:

The host must also be explicitly armed with `$HOME/.config/mailuops/allow-real-mailu-integration` containing `I_UNDERSTAND_THIS_STARTS_AND_REMOVES_A_DISPOSABLE_MAILU_STACK`. Do not create that guard file on a production Mailu host unless you intentionally allow disposable integration testing there.

```bash
MAILUOPS_REAL_MAILU=1 \
MAILUOPS_DISPOSABLE_MAILU_STACK_OK='I_UNDERSTAND_THIS_STARTS_AND_REMOVES_A_DISPOSABLE_MAILU_STACK' \
make integration
```

Expected:

- The stack binds only `127.0.0.1:993:993`.
- Real `quota get` and `quota list --json` succeed against Mailu/Dovecot.
- `migrate probe` succeeds.
- `migrate run --yes` copies the fixture messages.
- A second `migrate run --yes` does not duplicate messages.
- Cleanup removes the exact `mailuops-it-*` Compose project, network, and test root.
- Port `993` is free afterward.

## Manual security review

Before release, manually review generated imapsync argv from tests or integration logs and confirm:

- both endpoints use `--ssl1` and `--ssl2`;
- both endpoints include `SSL_verify_mode=1`;
- both endpoints include explicit `SSL_ca_file=...` arguments;
- passwords are represented only as `--passfile1` and `--passfile2` paths;
- `--noexpunge1`, `--noexpunge2`, and `--nouidexpunge2` are present;
- no destructive option is present, especially `--delete1`, `--delete2`, folder deletion options, `--expunge1`, `--expunge2`, or `--uidexpunge2`;
- folder mappings are separate `--f1f2` value arguments and cannot become standalone options;
- the real sync phase does not contain `--dry`, `--justlogin`, or `--justfolders`.

## Production deployment checklist

On the production host:

```bash
sudo install -o root -g root -m 0755 mailuops /usr/local/sbin/mailuops
sudo install -d -o root -g root -m 0700 \
  /etc/mailuops \
  /etc/mailuops/migrations.d \
  /etc/mailuops/secrets \
  /var/log/mailuops \
  /var/lib/mailuops
```

Verify configuration and secret ownership/modes:

```bash
sudo chown root:root /etc/mailuops/config.json /etc/mailuops/migrations.d/*.json /etc/mailuops/secrets/*.pass
sudo chmod 0600 /etc/mailuops/config.json /etc/mailuops/migrations.d/*.json /etc/mailuops/secrets/*.pass
sudo chmod 0700 /etc/mailuops /etc/mailuops/migrations.d /etc/mailuops/secrets /var/log/mailuops /var/lib/mailuops
```

The normal unprivileged test suite does not create passfiles owned by another UID. For production, manually verify passfiles are owned by the runtime user, normally `root:root`, and have mode `0600`; the runtime rejects mismatches with status `77`.

## Tagging

After all required checks pass and the repository is clean:

```bash
git tag -a v1.0.0-rc1 -m 'mailuops 1.0.0-rc1'
```
