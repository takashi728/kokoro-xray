# Security Audit Report

Date: 2026-11-17

Scope: repository at `feature/upstream-security-2026-11` (`770ab68`)

Method: source review, focused adversarial reproduction, shell syntax checks, and the repository test suite.

## Executive summary

The audit verified two security findings. The highest impact issue is command injection into root-owned systemd service units through configuration-controlled executable and configuration paths. The bootstrap installer also installs and executes code from a mutable Git branch, leaving a supply-chain trust gap for a root installation. Existing checksum tests and the current shell/render test suite pass; those checks do not cover either finding.

## Findings

### KX-001 — Root systemd unit command injection through mutable path settings

**Severity:** High

**CWE:** CWE-78, CWE-94

**Affected code:** `lib/xray.sh:45-64`, `lib/caddy.sh:270-295`, `lib/preflight.sh:28-37`

The service-unit writers interpolate `.paths.xray_bin`, `.paths.xray_config`, `.paths.caddy_bin`, and `.paths.caddyfile` directly into a here-document. Preflight checks only that three path values are non-empty; it does not reject newlines, unit-control characters, or paths outside an approved installation set. A value containing a newline can add a second `ExecStart=` or other systemd directive. The resulting unit is installed under `/etc/systemd/system` and enabled by root.

**Reproduction**

With a configuration value equivalent to:

```text
/usr/local/bin/xray
ExecStart=/bin/sh -c 'echo UNIT_INJECTION > /tmp/kokoro-unit-proof' #
```

the exact interpolation used by `lib/xray.sh` renders:

```text
ExecStart=/usr/local/bin/xray
ExecStart=/bin/sh -c 'echo UNIT_INJECTION > /tmp/kokoro-unit-proof' # run -config /tmp/kokoro-xray/config.json
```

The same sink exists in the Caddy unit for both `ExecStart` and `ExecReload`. Any operator who runs the documented root commands with a tampered or shared configuration can therefore cause arbitrary root service execution.

**Impact**

An attacker who can modify the state JSON before a privileged `edge`, `exit`, `apply`, or service-install operation can execute arbitrary commands as root, persist through systemd, or replace service binaries. This is especially relevant when the management command is delegated through a narrowly scoped `sudoers` rule or when configuration is restored from an untrusted backup.

**Remediation**

Do not construct unit files from unconstrained configuration strings. Restrict executable and config paths to fixed, canonical locations, reject control characters and whitespace, and quote/escape values according to systemd unit syntax. Write units through a dedicated renderer with tests for newline, backslash, and leading-dash inputs; verify the generated unit with `systemd-analyze verify` before installation.

### KX-002 — Root bootstrap follows a mutable Git branch

**Severity:** High (supply-chain)

**CWE:** CWE-494

**Affected code:** `README.md:31-58`, `install.sh:6-9,141-165,169-184`

The documented install command downloads `install.sh` from the `codebase-redesign-with-func` branch and pipes it to `sudo bash`. The script then performs a shallow `git clone` of the selected branch and activates that checkout as `/opt/kokoro-xray`. There is no immutable commit check, signed release manifest, or independent verification that the cloned tree matches a reviewed revision.

**Trigger**

If the referenced branch, repository, or GitHub account is compromised or intentionally moved, the next install or reinstall executes the changed bootstrap and repository scripts with root privileges. `KOKORO_REPO_URL`, `KOKORO_REPO_BRANCH`, and `KOKORO_DEFAULT_REPO_BRANCH` also make this trust decision mutable at runtime.

**Impact**

A repository or branch compromise becomes full root code execution on every new installation and on documented clean reinstalls. HTTPS and Git's transport integrity do not authenticate that the branch still points to the reviewed source.

**Remediation**

Publish a signed release or project-owned manifest containing the expected installer commit and artifact hashes. Pin the bootstrap to an immutable commit or tag, verify `git rev-parse HEAD` after cloning, and abort before replacing the live installation when the revision is unexpected. Prefer staging plus verification before activation and document the exact reviewed revision in installation instructions.

## Lower-confidence observations

- `lib/reality-scan.sh:28-43` performs certificate SAN checks with substring matching and treats `*.example.com` as covering the apex `example.com`. This can select an invalid REALITY target, but it requires attacker-controlled scan input and was not rated as an independent privilege or data-confidentiality issue.
- `lib/preflight.sh` permits operator-controlled filesystem paths. That broadens the impact of KX-001 and can cause root writes outside the intended installation tree; path allowlisting should be part of the same remediation.

## Validation performed

- `bash -n install.sh kokoro-xray.sh lib/*.sh roles/*.sh tests/*.sh`
- `git diff --check`
- All repository shell/fixture checks under `tests/` and `.github/scripts/*test.sh` passed, including download verification, rendering, Xray config validation, state migration, firewall parsing, service reload, and link generation.
- The KX-001 reproduction was isolated to a temporary unit file; no system service or repository state was changed.

## Scope limits

This was a read-only security assessment. No remediation was applied, no live service was restarted, and no external account or release state was modified.

## Remediation status

Applied on `feature/upstream-security-2026-11`:

- **KX-001 fixed:** service executables, configuration files, and geodata
  locations are restricted to canonical system paths. Control characters,
  whitespace, quoting, metacharacters, relative paths, and non-canonical forms
  are rejected. Every direct consumer validates paths before executing or
  writing. Xray, Caddy, and certificate-renewal units are rendered from the
  validated values and checked with `systemd-analyze verify` before atomic
  installation.
- **KX-002 fixed:** the bootstrap has no fallback commit. It requires a full
  reviewed SHA, fetches that object directly, verifies the checked-out commit,
  records it in `~/.kokoro-xray/installed-commit`, and refuses local trees
  without a verifiable revision. `reinstall` uses only the recorded SHA.
- **Hysteria2 filesystem boundary fixed:** certificate and key paths must be
  regular, non-symlink, root-owned files without group/world write permission
  beneath Caddy's certificate root. Certificate discovery applies the same
  checks before recording a generated certificate.
- **REALITY scanner hardening applied:** hostnames are normalized and
  validated; SAN matching uses exact labels and wildcard rules instead of
  substring matching.

Regression coverage is in `tests/security.sh`, `tests/installer.sh`, and
`tests/reload.sh`. The tests cover unit injection, execution before path
validation, certificate-root escape, exact SAN matching, local-tree trust,
immutable remote fetch, mismatch rollback, and installed-commit recording.
