set -euo pipefail

: "${STRAPS_BUFF_BUFF_SOURCE:?missing Buff source}"
: "${STRAPS_BUFF_STRAPS_SOURCE:?missing Straps source}"

mkdir -p .deps
if ! mkdir .deps/.fetch-lock 2>/dev/null; then
  printf 'Dependency preparation is already running; retry after it finishes.\n' >&2
  exit 1
fi
stage=
backup=
finish() {
  status=$?
  trap - EXIT
  if [ -n "$stage" ]; then rm -rf -- "$stage"; fi
  rmdir .deps/.fetch-lock
  if [ "$status" -ne 0 ]; then
    printf 'Dependency fetch failed; installation may be partial.\n' >&2
    if [ -n "$backup" ]; then
      printf 'Original dependencies remain in %s and/or .deps/{buff,straps}.\n' "$backup" >&2
    fi
  fi
  exit "$status"
}
trap finish EXIT
stage=$(mktemp -d .deps/.fetch.XXXXXX)

cp -R -- "$STRAPS_BUFF_BUFF_SOURCE" "$stage/buff"
cp -R -- "$STRAPS_BUFF_STRAPS_SOURCE" "$stage/straps"
chmod -R u+w -- "$stage/buff" "$stage/straps"
backup=$(mktemp -d .deps/backup.XXXXXX)
printf 'Dependency backup: %s\n' "$backup"
for dependency in buff straps; do
  if [ -e ".deps/$dependency" ] || [ -L ".deps/$dependency" ]; then
    mv -- ".deps/$dependency" "$backup/$dependency"
  fi
  mv -- "$stage/$dependency" ".deps/$dependency"
done
printf '%s\n%s\n' "$STRAPS_BUFF_BUFF_SOURCE" "$STRAPS_BUFF_STRAPS_SOURCE" > "$stage/sources"
mv -- "$stage/sources" .deps/.sources
printf 'Fetched pinned Buff and Straps into .deps/buff and .deps/straps.\n'
