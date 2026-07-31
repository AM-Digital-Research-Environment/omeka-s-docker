# Docker security and maintainability review

**Review date:** 2026-07-31  
**Scope:** Dockerfile, base and AMIRA Compose files, nginx/PHP configuration,
entrypoint and maintenance scripts, backup/restore, and GitHub Actions.

## Executive assessment

The stack has a strong container-level baseline: only nginx publishes a port
(loopback by default), application services use private networks, capabilities
are dropped, `no-new-privileges` is enabled, and nginx/Typesense use read-only
root filesystems. The review found no privileged container, host Docker socket
mount, or publicly published database/search port.

The largest remaining risk is architectural rather than a missing flag: the
entire Omeka document root is a persistent read-write volume. That volume masks
new image contents after first boot, so image rebuilds, CVE scans, SBOMs, and
rollbacks do not describe or control all code actually running. The migration
is already designed in [PROPOSAL_immutable_code.md](PROPOSAL_immutable_code.md)
and should be the next substantial change.

## Remediation completed in this review

| Area | Change |
|---|---|
| Supply chain | Pinned nginx, PHP, MySQL, Typesense, Alpine helper, Composer, and PHP extension installer images by version and digest; pinned APCu by version; removed the downloaded `master`-branch FPM healthcheck script. |
| Compose correctness | PHP now receives the same configurable database/user values as MySQL; nginx is isolated from the database/search network; AMIRA MCP has a dedicated proxy network and requires an explicit public hostname; a redundant startup dependency was removed. |
| Runtime checks | PHP health probes FPM directly; its generated database credential file is mode `0600`; the smoke suite asserts capability drops, `no-new-privileges`, read-only roots, non-root PHP execution, network exposure, required PHP extensions, and custom database settings. |
| Backup safety | Backups use container-side credentials (including quoted/special-character passwords), restrictive permissions, pinned helpers, required-artifact checks, and `SHA256SUMS`. |
| Restore safety | Checksums are verified before changes; existing stopped volumes also trigger confirmation; `--force` is explicit; database identifiers are validated before SQL interpolation. |
| CI | Added ShellCheck, PHP/JSON validation, Docker build checks, base/overlay Compose security-contract tests, parallel smoke jobs, and an end-to-end backup/restore round trip. The checkout action is commit-pinned with credentials disabled. |
| Cleanup | Removed the unused `ensure-composer.sh` fallback, which could not repair a root-owned binary while the runtime container was intentionally non-root. |

## Open findings, ordered by priority

### High: running code is mutable and masks the image

`omeka_files` is mounted at `/var/www/html`, including Omeka core, modules, and
themes. An old volume therefore hides updated code baked into a new image, and
the current update scripts mutate production code in place. This weakens image
scanning, rollback, reproducibility, and incident response.

**Recommendation:** implement the documented immutable-code migration, keeping
only uploads, configuration, sessions, and other genuinely mutable data in
volumes. Treat it as a maintenance-window migration with a tested backup.

### High: application dependencies follow mutable branches

Default module downloads do not consistently name a release or commit; helper
scripts follow `main`/`master`; the AMIRA MCP image builds directly from remote
`main`. A rebuild can therefore execute different upstream code without a local
repository change or a reliable rollback point.

**Recommendation:** maintain a lock manifest containing release tags or commit
SHAs plus archive checksums. Build AMIRA MCP from an explicit commit. Update the
lock through reviewed dependency pull requests rather than at container start.

### Medium: credentials remain in environment variables and plaintext backups

Database, Omeka bootstrap, and Typesense credentials are passed as container
environment variables and can be read by principals allowed to inspect Docker.
Backups intentionally contain `.env`; restrictive modes and checksums do not
encrypt it.

**Recommendation:** restrict Docker access as root-equivalent, remove Omeka
bootstrap credentials after installation, and migrate long-lived secrets to
file-based Docker secrets where the applications support them. Encrypt every
backup before off-host transfer and test key recovery.

### Medium: forwarded client IP trust is broader than some deployments need

nginx trusts `X-Forwarded-For` from every RFC1918 address. This is suitable when
the default loopback binding is used behind a local proxy. If `NGINX_BIND` is
changed to `0.0.0.0`, a client arriving from a trusted private range can spoof
its apparent address and weaken IP rate limiting/log attribution.

**Recommendation:** keep the default loopback binding behind the reverse proxy,
or narrow `set_real_ip_from` to the actual proxy subnet before direct exposure.

### Medium: live updates and long immutable asset caching can disagree

Module/core update scripts replace live files non-atomically, while nginx gives
many JavaScript/CSS assets a one-year `immutable` cache lifetime. A failed
update can leave mixed code; a successful update can leave browsers using stale
assets when URLs are not content-hashed.

**Recommendation:** the immutable image/rollback work should replace live code
mutation. Until then, back up first, use a maintenance window, and reduce the
long cache policy to content-hashed assets only.

### Medium: a live backup is consistent within each source, not globally atomic

The SQL dump is a consistent InnoDB snapshot and volume mounts are read-only,
but the database and file archives are not captured at the exact same instant.
Schema-changing operations are unsafe during the dump. This is acceptable for
normal Omeka traffic because uploaded media are effectively write-once, but it
is not a transactional whole-system snapshot.

**Recommendation:** prohibit module/core upgrades during backup, retain several
generations, and regularly restore one into an isolated staging project. Use a
short maintenance window if a globally aligned snapshot is required.

### Medium: database durability is intentionally relaxed

`innodb_flush_log_at_trx_commit=2` improves write performance but can lose about
one second of committed transactions after an OS or power failure.

**Recommendation:** decide explicitly whether the performance trade-off matches
the host's storage and recovery objectives; use `1` when transaction durability
is more important.

### Low: the one-line bootstrap follows mutable remote content

The convenience install command pipes the repository's `main` branch directly
to a shell. A compromised repository or changed script receives host-level
installation authority without a local review step.

**Recommendation:** publish versioned bootstrap releases with a SHA-256 value or
signature, download to disk, verify, inspect, and then run.

## CI and vulnerability-scanning follow-up

The CI security contract deliberately tests rendered Compose behavior rather
than only YAML text: public ports, private networks, security options, read-only
roots, healthchecks, image digest pins, and cross-service database settings.
The smoke tests add runtime assertions and backup/restore recovery.

No Trivy GitHub Action was added during this review. Aqua disclosed a March 2026
supply-chain compromise affecting Trivy GitHub Actions and related artifacts:
[GHSA-69fq-xp46-6x23](https://github.com/aquasecurity/trivy/security/advisories/GHSA-69fq-xp46-6x23).
Before adding any hosted scanner, confirm the repaired release, pin its full
commit SHA, and review how it obtains vulnerability databases. A scheduled,
non-blocking Docker Scout scan on the built image is a reasonable interim
option; define a severity/exception policy before making CVE counts release
blocking.

## Review limitations

Static linters and rendered Compose contracts were run locally. The local Docker
daemon was unavailable, so the image build and runtime smoke/restore scenarios
added by this review still require the GitHub Actions runner (or another host
with Docker) for execution.
