set -euo pipefail

root=$(pwd)
work=$(mktemp -d)
trap 'chmod -R u+w "$work"; rm -rf -- "$work"' EXIT
mkdir -p "$work/repo/scripts" "$work/state"
cp flake.nix .envrc "$work/repo/"
cp scripts/*.sh "$work/repo/scripts/"
cd "$work/repo"
for shell in default nvim-0_11; do
  rm -rf .deps
  nix develop "path:.#$shell" --no-write-lock-file --command bash -c 'test -d .deps/buff/lua && test -d .deps/straps/lua && command -v direnv && command -v busted'
done
export XDG_DATA_HOME="$work/state"
export XDG_CONFIG_HOME="$work/config"
mkdir -p "$XDG_CONFIG_HOME"
direnv allow .
direnv exec . bash -c 'test -d .deps/buff/lua && test -f .deps/.sources && command -v busted && command -v nvim'
rm -rf .deps/straps
direnv exec . bash -c 'test -d .deps/straps/lua'
printf 'exit 43\n' > scripts/ensure-deps.sh
status=0
direnv exec . touch "$work/direnv-sentinel" || status=$?
test "$status" -ne 0
test ! -e "$work/direnv-sentinel"
for shell in default nvim-0_11; do
  status=0
  nix develop "path:.#$shell" --no-write-lock-file --command touch "$work/sentinel" || status=$?
  test "$status" -ne 0
  test ! -e "$work/sentinel"
done
printf 'Devshell preparation, direnv entry, and both failure sentinels passed.\n'
cd "$root"
