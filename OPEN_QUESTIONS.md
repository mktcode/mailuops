# Open questions for `mailuops`

These are product, operational, and release questions to revisit before a final `1.0.0` release or wider production rollout.

## Product and scope

1. Is `mailuops` meant to be used only by the project owner, or by less experienced administrators too?
2. Should `--yes` remain sufficient for noninteractive real migration, or should it also require a second explicit environment variable such as `MAILUOPS_ASSUME_YES=...`?
3. Should there be a command that validates all configured migration profiles without running imapsync?
4. Should mailbox creation ever be supported, or should destination mailbox provisioning remain outside the tool?
5. Is one global migration/probe lock too conservative for the expected migration timeline?

## Migration correctness

6. How will operators decide whether destination quota is large enough before migration?
7. Is a pre-migration source mailbox size estimate needed?
8. Could `--subscribe` surprise customers, or is syncing subscriptions desirable?
9. Are IMAP flags important enough to keep `--resyncflags`, even though flags are metadata changes on the destination?
10. Are contacts, calendars, Sieve rules, forwarding, signatures, and aliases explicitly handled elsewhere?

## Customer and domain assumptions

11. Do any customer mailboxes use unusual RFC-valid addresses that the conservative address validator rejects?
12. Are internationalized domains or local parts relevant?
13. Is one destination IMAP hostname sufficient for all customer domains?
14. Can multiple Mailu stacks exist on the same host?
15. Are provider-specific folder separators or names, especially `/`, `=`, CR, or LF, likely in source folder names?

## Security and operations

16. Who owns `/etc/mailuops` and related runtime paths in production: root only, or another dedicated user?
17. Will operators run `mailuops` as root or as a Docker-group user?
18. Is Docker-group access acceptable in the deployment threat model?
19. Should the repository include a sample `logrotate` configuration for operation logs?
20. Should private wrapper logs avoid full passfile paths, or is storing passfile paths in protected logs acceptable?

## Release and testing

21. Is local `make test` enough, or should CI be configured before final release?
22. Should releases be signed or packaged as a reviewed artifact?
23. Should `RELEASE.md` include exact post-install verification commands for a production host?
24. Should we add a sample manual migration runbook covering quota sizing, DNS/cutover, customer communication, and postflight checks?
25. Should an optional privileged test script be added for the passfile-owned-by-another-UID branch before final `1.0.0`?

## Blunt summary

The current codebase appears suitable for a `1.0.0-rc1` of the narrow utility: quota display, safe probing, and additive IMAP migration. The largest remaining questions are about the surrounding operational workflow rather than the core implementation: mailbox prep, quota sizing, cutover, customer communication, post-migration verification, and release process.
