# kokoro-xray — functional & modular redesign (design)

Companion to `docs/architecture.md`. Goal: keep the "shell dispatches, jq
renders" rule, make every module **deep** (lots of behaviour behind a small
interface), cut process-spawn overhead, and make the seams testable.

Vocabulary: **module** (interface + implementation), **seam** (where the
interface lives), **adapter** (concrete thing satisfying an interface),
**depth** (leverage per unit of interface learned).

## Current shape — shallow seams, hidden deps

- `lib/common.sh` owns state access: `kokoro_cfg` / `kokoro_sec` read
  `KOKORO_CONFIG` / `KOKORO_SECRETS` by spawning a fresh `jq` on every call.
  Any function that touches config is coupled to files, `$HOME`, and `PATH`.
  No caller is testable without real state files.
- `kokoro-xray.sh` dispatches with a `case` and spawns `bash roles/*.sh`
  subprocesses that re-source and re-read everything.
- `lib/render.jq` + `lib/caddy.jq` are **already pure** (slurpfile cfg/sec →
  JSON/text, no globals). This is the deep module that earns its keep; the
  redesign builds everything else around it.

## Target module map

```
cli/          run(cmd, args, ctx)        — thin dispatch, i18n
core/state    load_state(paths) -> (cfg, sec)   — read/merge/migrate/perms
core/render   render(cfg, sec, role) -> json    — jq, pure (exists)
core/validate validate(cfg, paths) -> ok|errs   — pure checks + xray adapter
core/apply    apply(ctx)                        — snapshot→render→validate→reload→firewall
adapters/     firewall, xray, caddy, geodata, keys, tor, reality-scan
```

| module | interface (the seam) | hidden (implementation) | depth |
|---|---|---|---|
| `core/state` | `load_state(paths) -> (cfg, sec)` | file read, `kokoro_migrate`, perms | deep |
| `core/render` | `render(cfg, sec, role) -> json` | inbounds/outbounds/routing | deep |
| `core/apply` | `apply(ctx)` | snapshot, rollback, ordering | deep |
| `adapters/firewall` | `apply_rules(spec)` | ufw calls | shallow |
| `adapters/xray` | `start/stop/test(cfg)` | systemd, binary | shallow |
| `cli/` | `run(cmd, args, ctx)` | dispatch, menu | shallow |

Depth rule applied: state, render, and apply are deep; everything touching a
binary is a shallow adapter. Shallow adapters are fine — the logic lives in
the deep modules, adapters only translate.

## Functional style rules (bash + jq)

1. **State is loaded once, passed down.** No function reads config files.
   Functions take `cfg`/`sec` (or their values) as args and return via stdout.
   `KOKORO_CONFIG`/`KOKORO_SECRETS` are read only inside `core/state`.
2. **Pure where possible.** `f() { ...; printf '%s' "$result"; }` — args in,
   stdout out, no globals, no mutation of files. Side effects only in
   adapters and `core/apply` orchestration.
3. **All JSON transforms stay in jq.** One jq program per concern; never
   `sed`/`grep`/bash-string JSON munging.
4. **`run_cmd` seam for external tools.** Everything that shells out
   (`xray`, `caddy`, `ufw`, `systemctl`) goes through one injected runner so
   tests can swap a fake.

## Performance work (measurable)

- **Kill subprocess spam.** `kokoro_cfg` ≈ one `jq` spawn (~5–10 ms). A single
  `apply`/`onboard` currently makes dozens. `core/state` reads both files
  once; callers pass strings. Target: `time kokoro-xray status` drops by >50%.
- **Keep render single-pass.** `render.jq` is one `jq -n -f` call — do not
  split into stages; depth lives in one pass.
- **Lazy module loading.** Commands source only what they need; `common.sh`
  stops auto-loading file I/O helpers unless asked.

## Seam & test strategy

- **The interface is the test surface.** Tests call the same functions the
  CLI calls:
  - `state-test`: fixture dirs as paths; asserts merged cfg/sec.
  - `render-test`: existing — cfg/sec fixtures → JSON, plus `xray -test`.
  - `apply-test`: fake `run_cmd` recording calls; asserts ordering + rollback.
- **One adapter means a hypothetical seam; two adapters mean a real one.**
  `run_cmd` (real shell + fake) is justified. Do not add ports for things
  that never vary.
- **Replace, don't layer.** When `core/state` tests exist, delete the ad-hoc
  per-module config tests; behaviour is tested once at the seam.

## Migration (incremental, keep green)

1. Extract `core/state`; convert the hottest loops (`onboard`, `apply`,
   `link`, `status`) to load-once-pass-down.
2. Introduce `run_cmd`; route `xray`/`caddy`/`ufw`/`systemctl` calls through it;
   add fake-runner tests.
3. Move render/validate calls onto the new seams; drop the
   `kokoro_cfg`-inside-every-module pattern; re-run `render-test` + friends.

Phase 1 is the big win (process count + testability); 2 and 3 are cleanup.

## Low-spec VPS build patch (Phase 2/3 scope)

Caddy's Go compile OOMs on 1–3 GB, single-core Intel VPSes. Handled as a pure,
testable module in `lib/caddy.sh`:

- `kokoro_build_tuning(cpus, mem_mb)` → env: `GOFLAGS=-p=1` (cpus≤2),
  `GOGC=25/50` + `GOMEMLIMIT=75%` (mem≤6GB) so the build fits in RAM.
- `kokoro_build_env()` detects `nproc`/`/proc/meminfo`, exports the tuning, and
  warns when ≤2GB with no swap.
- `kokoro_run_cmd(label, ...)` is the Phase 2 seam: real build uses
  `kokoro_run_with_timer`, tests inject `KOKORO_RUNNER` fake.

Fast single-core Ryzen boxes get the same `-p=1` but rarely need the memory
limits; big multi-core hosts build unrestricted.
