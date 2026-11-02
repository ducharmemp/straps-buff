# Development

Contributors must run each spec in a separate Neovim process and retain Chromium's sandbox. The commands below describe verification procedures. The observed results section records completed checks and remaining platform limits.

## Sources and shells

The root flake pins nixpkgs inputs without a lockfile. The default shell selects Neovim from revision `3ec636362e1816bc2f0888fa0fa2c69f1bc9e504`; `nvim-0_11` selects Neovim from `ac62194c3917d5f474c1a844b6fd6da2db95077d`. Both provide LuaJIT busted and nlua. Linux shells also provide Chromium. Probe `nvim --version` in each shell before reporting version-specific acceptance.

Install direnv on the host and enable its shell hook (`eval "$(direnv hook bash)"` for Bash, or `direnv hook zsh` through `eval` for Zsh). From the repository root, run `direnv allow` once. `.envrc` loads the default flake shell and prepares pinned dependencies. Nix, direnv's host hook, and checkout authorization must exist before automatic entry; the development shell also supplies the direnv executable.

Without direnv, enter either shell from the repository root:

```sh
nix develop path:. --no-write-lock-file
nix develop path:.#nvim-0_11 --no-write-lock-file
```

Both shells provide Neovim, busted, nlua, direnv, coreutils, and `fetch-deps`; Linux adds Chromium. Preparation creates missing dependencies or refreshes changed pins. Matching source markers preserve local edits and avoid repeat backups. A preparation failure aborts shell entry before its command runs. `.envrc` repeats preparation after loading the environment so cached nix-direnv environments also repair missing dependencies.

Force a refresh with `fetch-deps` inside the shell or:

```sh
nix run path:.#fetch-deps --no-write-lock-file
```

The app stages both copies before replacing `.deps/buff` and `.deps/straps`. Existing copies move to a unique `.deps/backup.XXXXXX/{buff,straps}` directory. Backups remain until you remove them. A failed replacement returns nonzero and prints recovery locations; installation can be partial. Recover each dependency from the printed backup or its unchanged destination before rerunning. The fetcher never deletes backups. Concurrent preparation is rejected by `.deps/.fetch-lock`; retry after the active fetch finishes. If a process is killed before cleanup, remove that empty lock directory only after confirming no fetch is running. `.deps/` is ignored and is not part of the repository.

Revisions live in `flake.nix`; update those pins and the documented revisions together. Package checks use Nix source inputs and need no local `.deps` directories. Local tests load `.deps/buff` and `.deps/straps`; override them with absolute `STRAPS_BUFF_BUFF_PATH` and `STRAPS_BUFF_STRAPS_PATH` paths. The `.busted` helper adds sources to runtimepath without setup, permission grants, or guard changes.

Run from the repository root. The distributed plugin source excludes `.deps`, tests, and development configuration. No command below creates a lockfile or a result symlink.

## Focused and full tests

Run focused specs:

```sh
nix develop path:. --no-write-lock-file --command busted tests/adapter_spec.lua
nix develop path:. --no-write-lock-file --command busted tests/permissions_spec.lua
nix develop path:. --no-write-lock-file --command busted tests/session_spec.lua
nix develop path:. --no-write-lock-file --command bash -c 'BUFF_REQUIRE_CHROME=1 busted tests/chromium_spec.lua'
```

Run the full suite with one busted process per spec:

```sh
nix develop path:. --no-write-lock-file --command bash -c 'fail=0; count=0; for spec in tests/*_spec.lua; do [ -f "$spec" ] || continue; count=$((count + 1)); BUFF_REQUIRE_CHROME=1 busted "$spec" || fail=1; done; [ "$count" -gt 0 ] && [ "$fail" -eq 0 ]'
nix develop path:.#nvim-0_11 --no-write-lock-file --command bash -c 'fail=0; count=0; for spec in tests/*_spec.lua; do [ -f "$spec" ] || continue; count=$((count + 1)); BUFF_REQUIRE_CHROME=1 busted "$spec" || fail=1; done; [ "$count" -gt 0 ] && [ "$fail" -eq 0 ]'
```

`BUFF_REQUIRE_CHROME=1` must make browser unavailability fail the browser spec. Set `BUFF_CHROME` to an executable path when Chrome is not on PATH. Do not add `--no-sandbox`. macOS users must supply Chrome; macOS runtime acceptance is pending.

Run package checks and build:

```sh
nix flake check path:. --no-write-lock-file
nix build path:.#default --no-link --no-write-lock-file
```

The flake defines unit checks for both Neovim inputs, with isolated HOME and XDG directories. Each check runs specs in separate processes and excludes `tests/chromium_spec.lua`. These checks fail when no unit specs exist. They do not replace the real-browser development-shell suite.

Run the fetched Buff dependency's full per-file suite using the root shell's tools:

```sh
nix develop path:. --no-write-lock-file --command bash -c 'cd .deps/buff && fail=0; for spec in tests/*_spec.lua; do BUFF_REQUIRE_CHROME=1 busted "$spec" || fail=1; done; exit "$fail"'
nix develop path:.#nvim-0_11 --no-write-lock-file --command bash -c 'cd .deps/buff && fail=0; for spec in tests/*_spec.lua; do BUFF_REQUIRE_CHROME=1 busted "$spec" || fail=1; done; exit "$fail"'
```

Straps is unmodified; any Straps change requires separate approval before running a changed-core acceptance process.

## Platform acceptance

The flake declares `x86_64-linux`, `aarch64-linux`, and `aarch64-darwin`. Evaluate every platform's package, shells, and unit checks without claiming a build or runtime result:

```sh
nix flake check path:. --all-systems --no-build --no-write-lock-file
```

Runtime acceptance requires a machine for each platform. On each machine, run both root per-file commands and both Buff per-file commands above, then run the package checks and build. On macOS, set `BUFF_CHROME` to the installed Chrome executable for both shells. Keep the sandbox enabled. Record the architecture, Neovim version, Chrome version, and full test outcomes. A derivation evaluation or a package build does not establish browser runtime acceptance.

The current verification host is `x86_64-linux`; `nix config show builders` returned no configured remote builders. `aarch64-linux` and `aarch64-darwin` runtime acceptance require additional execution environments.

## Observed results

On 2026-11-06, `x86_64-linux` runs passed all four root specs on Neovim 0.12.6 and 0.11.5: adapter, permissions, session, and real Chromium. All fifteen patched Buff specs passed in separate processes on both versions. Browser runs required Chromium and used Chromium 156.0.8078.47 without disabling its sandbox. Added assertions received selected-failure counterfactual checks on both inputs, followed by restored passing runs. Separate fresh code and documentation reviews found no remaining findings after fixes.

Host flake checks and the adapter package build passed. All declared platform derivations evaluated with `--all-systems --no-build`; that evaluation established neither non-host builds nor runtime behavior. A later request to repeat that evaluation was denied and was not retried. `aarch64-linux` and `aarch64-darwin` runtime acceptance remain blocked by unavailable execution environments. That run preceded the published dependency pins now recorded in `flake.nix`.

The dependency-fetch change fetched Buff `45ad0cb763138be7eeb03436bd34f0add7036257` and Straps `7396033c8f3b59d0664a030e5cbd6457e77e9ef7` from their upstream sources. Local copies matched the Nix inputs. Fetch fixtures passed all 23 assertion inversions and a restored run. Host flake checks and the package build passed. Both root Neovim suites passed; the first default-shell run reported a Chromium cleanup error, while its subsequent full rerun passed. The cleanup failure's cause remains unverified.

The direnv/devshell change passed real isolated entry tests for both shells, standard direnv loading and missing-dependency repair, and failure tests proving that neither shell nor direnv commands run after preparation failure. The ensure fixture passed all 24 selected assertion inversions; the fetch fixture passed all 23. Host flake checks and the package build passed. Both root suites passed; one baseline run reported the existing Chromium cleanup assertion error before a full rerun passed. Its cause remains unverified. The working checkout's `.envrc` was not authorized during these tests.

## Change acceptance

Assert observable effects, including model-origin Straps permission decisions. A direct registry call does not test tool admission. For every new assertion, invert its condition, observe failure, restore it, and rerun. Run the full suites after fixes. Report skipped tests and unavailable platforms as unverified.

The adapter, session, and permissions specs print `ASSERTIONS=N`. After each restored passing run, run every assertion index from 1 through that spec's reported N with `STRAPS_BUFF_INVERT` set. Each run must fail at the selected assertion; an unrelated failure does not establish the assertion's sensitivity. For example, these commands invert assertion 1:

```sh
nix develop path:. --no-write-lock-file --command env STRAPS_BUFF_INVERT=1 busted tests/adapter_spec.lua
nix develop path:. --no-write-lock-file --command env STRAPS_BUFF_INVERT=1 busted tests/session_spec.lua
nix develop path:. --no-write-lock-file --command env STRAPS_BUFF_INVERT=1 busted tests/permissions_spec.lua
```

List real-browser assertion names with `BUFF_CHECK_LIST=1`, then run each reported name through `BUFF_COUNTERFACTUAL`. Replace `CHECK_NAME` with one exact name from that run; each inversion must fail at that check. These variables select assertion inversions and do not replace the restored browser run:

```sh
nix develop path:. --no-write-lock-file --command env BUFF_REQUIRE_CHROME=1 BUFF_CHECK_LIST=1 busted tests/chromium_spec.lua
nix develop path:. --no-write-lock-file --command env BUFF_REQUIRE_CHROME=1 BUFF_COUNTERFACTUAL=CHECK_NAME busted tests/chromium_spec.lua
```

Run restored focused tests and both full per-file commands after counterfactual checks. To repeat a focused or inversion command on the baseline shell, use `path:.#nvim-0_11` in place of `path:.`.

Keep README.md, DESIGN.md, and doc/straps-buff.txt consistent with implemented schemas and behavior. Code and documentation receive separate fresh reviews. Source inspection establishes what the implementation declares; runtime tests must establish its behavior before release. Keep pinned dependency revisions and unverified platforms visible. Record observed test results separately from verification procedures. Unexpected backend disconnect invalidates browser resources while preserving operation history and sequence counters. Do not create commits, tags, branches, or lockfiles as part of verification.
