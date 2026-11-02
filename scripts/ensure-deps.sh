set -euo pipefail

: "${STRAPS_BUFF_BUFF_SOURCE:?missing Buff source}"
: "${STRAPS_BUFF_STRAPS_SOURCE:?missing Straps source}"
: "${STRAPS_BUFF_FETCH_SCRIPT:?missing fetch script}"

if [ ! -f flake.nix ] || [ ! -f scripts/ensure-deps.sh ]; then
  printf 'Enter the development shell from the straps-buff repository root.\n' >&2
  exit 1
fi
expected=$(printf '%s\n%s' "$STRAPS_BUFF_BUFF_SOURCE" "$STRAPS_BUFF_STRAPS_SOURCE")
if [ -d .deps/buff ] && [ -d .deps/straps ] && [ -f .deps/.sources ] \
  && [ "$(< .deps/.sources)" = "$expected" ]; then
  exit 0
fi
bash "$STRAPS_BUFF_FETCH_SCRIPT"
