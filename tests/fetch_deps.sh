set -euo pipefail

root=$(pwd)
work=$(mktemp -d)
trap 'chmod -R u+w "$work"; rm -rf -- "$work"' EXIT
mkdir -p "$work/sources/buff" "$work/sources/straps" "$work/bin"
printf 'pinned-buff\n' > "$work/sources/buff/source"
printf 'pinned-straps\n' > "$work/sources/straps/source"
chmod -R a-w "$work/sources"
export STRAPS_BUFF_BUFF_SOURCE="$work/sources/buff"
export STRAPS_BUFF_STRAPS_SOURCE="$work/sources/straps"
export FETCH_REAL_CP FETCH_REAL_MV
FETCH_REAL_CP=$(command -v cp)
FETCH_REAL_MV=$(command -v mv)
printf '%s\n' 'set -eu' 'if [ "${FETCH_FAIL_COPY:-}" = 1 ]; then exit 71; fi' 'exec "$FETCH_REAL_CP" "$@"' > "$work/bin/cp"
printf '%s\n' 'set -eu' 'if [ "${FETCH_FAIL_MOVE:-}" = 1 ] && [ "$3" = .deps/straps ]; then exit 72; fi' 'exec "$FETCH_REAL_MV" "$@"' > "$work/bin/mv"
chmod +x "$work/bin/cp" "$work/bin/mv"
export PATH="$work/bin:$PATH"
assertion=0
check() {
  assertion=$((assertion + 1))
  result=0
  "$@" || result=$?
  if [ "${STRAPS_BUFF_FETCH_INVERT:-}" = "$assertion" ]; then
    if [ "$result" -eq 0 ]; then result=1; else result=0; fi
  fi
  if [ "$result" -ne 0 ]; then printf 'ASSERTION FAILED %s\n' "$assertion" >&2; exit 1; fi
}

mkdir -p "$work/case/.deps/buff" "$work/case/.deps/straps" "$work/case/.deps/backup.existing"
cd "$work/case"
printf 'original-buff\n' > .deps/buff/original
printf 'original-straps\n' > .deps/straps/original
printf 'keep\n' > .deps/backup.existing/keep
bash "$root/scripts/fetch-deps.sh" > "$work/success"
check cmp .deps/buff/source "$work/sources/buff/source"
check cmp .deps/straps/source "$work/sources/straps/source"
backup=$(awk '/^Dependency backup: / {print $3}' "$work/success")
check test -f "$backup/buff/original"
check test -f "$backup/straps/original"
check test -w .deps/buff/source
check test -w .deps/straps/source
bash "$root/scripts/fetch-deps.sh" > "$work/repeat"
check test -f "$backup/buff/original"
check test -f "$backup/straps/original"
check test -f .deps/backup.existing/keep
status=0
FETCH_FAIL_COPY=1 bash "$root/scripts/fetch-deps.sh" > "$work/copy" 2>&1 || status=$?
check test "$status" -ne 0
check grep -Fq 'Dependency fetch failed; installation may be partial.' "$work/copy"
check cmp .deps/buff/source "$work/sources/buff/source"
check cmp .deps/straps/source "$work/sources/straps/source"
status=0
FETCH_FAIL_MOVE=1 bash "$root/scripts/fetch-deps.sh" > "$work/move" 2>&1 || status=$?
check test "$status" -ne 0
failed_backup=$(awk '/^Dependency backup: / {print $3}' "$work/move")
check test -n "$failed_backup"
check grep -Fq 'Dependency fetch failed; installation may be partial.' "$work/move"
check grep -Fq "Original dependencies remain in $failed_backup and/or .deps/{buff,straps}." "$work/move"
check cmp "$failed_backup/buff/source" "$work/sources/buff/source"
check cmp "$failed_backup/straps/source" "$work/sources/straps/source"
check cmp .deps/buff/source "$work/sources/buff/source"
check test -f .deps/backup.existing/keep
check test -f "$backup/buff/original"
check test -f "$backup/straps/original"
printf 'ASSERTIONS=%s\n' "$assertion"
