set -euo pipefail

root=$(pwd)
work=$(mktemp -d)
trap 'chmod -R u+w "$work"; rm -rf -- "$work"' EXIT
mkdir -p "$work/sources/buff" "$work/sources/straps" "$work/bin" "$work/repo/scripts" "$work/outside"
touch "$work/repo/flake.nix" "$work/repo/scripts/ensure-deps.sh"
printf 'buff\n' > "$work/sources/buff/value"
printf 'straps\n' > "$work/sources/straps/value"
export STRAPS_BUFF_BUFF_SOURCE="$work/sources/buff"
export STRAPS_BUFF_STRAPS_SOURCE="$work/sources/straps"
export STRAPS_BUFF_FETCH_SCRIPT="$root/scripts/fetch-deps.sh"
export REAL_CP REAL_MV
REAL_CP=$(command -v cp)
REAL_MV=$(command -v mv)
printf '%s\n' "#!$(command -v bash)" 'if [ "${FAIL_COPY:-}" = 1 ]; then exit 71; fi' 'exec "$REAL_CP" "$@"' > "$work/bin/cp"
printf '%s\n' "#!$(command -v bash)" 'if [ "${FAIL_MOVE:-}" = 1 ] && [ "$3" = .deps/straps ]; then exit 72; fi' 'exec "$REAL_MV" "$@"' > "$work/bin/mv"
chmod +x "$work/bin/cp" "$work/bin/mv"
export PATH="$work/bin:$PATH"
assertion=0
check() {
  assertion=$((assertion + 1))
  result=0
  "$@" || result=$?
  if [ "${STRAPS_BUFF_ENSURE_INVERT:-}" = "$assertion" ]; then
    if [ "$result" -eq 0 ]; then result=1; else result=0; fi
  fi
  if [ "$result" -ne 0 ]; then printf 'ASSERTION FAILED %s\n' "$assertion" >&2; exit 1; fi
}
ensure() { bash "$root/scripts/ensure-deps.sh"; }
cd "$work/outside"
status=0
ensure > "$work/outside-log" 2>&1 || status=$?
check test "$status" -ne 0
check test ! -e .deps
cd "$work/repo"
status=0
FAIL_COPY=1 ensure > "$work/first-fail" 2>&1 || status=$?
check test "$status" -ne 0
check test ! -e .deps/.sources
ensure > "$work/first"
check cmp .deps/buff/value "$STRAPS_BUFF_BUFF_SOURCE/value"
check cmp .deps/straps/value "$STRAPS_BUFF_STRAPS_SOURCE/value"
printf '%s\n%s\n' "$STRAPS_BUFF_BUFF_SOURCE" "$STRAPS_BUFF_STRAPS_SOURCE" > "$work/expected"
check cmp .deps/.sources "$work/expected"
printf 'local-edit\n' > .deps/buff/value
before=$(printf '%s\n' .deps/backup.*)
ensure > "$work/repeat"
check grep -Fxq local-edit .deps/buff/value
check test "$(printf '%s\n' .deps/backup.*)" = "$before"
mkdir -p "$work/changed/buff" "$work/changed/straps"
printf 'changed-buff\n' > "$work/changed/buff/value"
printf 'changed-straps\n' > "$work/changed/straps/value"
export STRAPS_BUFF_BUFF_SOURCE="$work/changed/buff"
export STRAPS_BUFF_STRAPS_SOURCE="$work/changed/straps"
cp .deps/.sources "$work/old-marker"
for failure in FAIL_COPY FAIL_MOVE; do
  status=0
  export "$failure=1"
  ensure > "$work/$failure" 2>&1 || status=$?
  unset "$failure"
  check test "$status" -ne 0
  check cmp .deps/.sources "$work/old-marker"
done
ensure > "$work/changed-log"
check cmp .deps/buff/value "$STRAPS_BUFF_BUFF_SOURCE/value"
check cmp .deps/straps/value "$STRAPS_BUFF_STRAPS_SOURCE/value"
printf '%s\n%s\n' "$STRAPS_BUFF_BUFF_SOURCE" "$STRAPS_BUFF_STRAPS_SOURCE" > "$work/expected"
check cmp .deps/.sources "$work/expected"
rm -rf .deps/straps
ensure > "$work/missing"
check cmp .deps/straps/value "$STRAPS_BUFF_STRAPS_SOURCE/value"
bash "$STRAPS_BUFF_FETCH_SCRIPT" > "$work/manual"
check cmp .deps/.sources "$work/expected"
after=$(printf '%s\n' .deps/backup.*)
ensure > "$work/after-manual"
check test "$(printf '%s\n' .deps/backup.*)" = "$after"
mkdir .deps/.fetch-lock
status=0
bash "$STRAPS_BUFF_FETCH_SCRIPT" > "$work/overlap" 2>&1 || status=$?
check test "$status" -ne 0
check grep -Fq 'Dependency preparation is already running' "$work/overlap"
check cmp .deps/.sources "$work/expected"
check test -d .deps/.fetch-lock
rmdir .deps/.fetch-lock
check test ! -e .deps/buff/buff
printf 'ASSERTIONS=%s\n' "$assertion"
