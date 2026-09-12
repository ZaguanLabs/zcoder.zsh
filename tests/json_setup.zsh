#!/usr/bin/env zsh
# Exercise real submodule initialization and compilation using local Git only.
emulate -R zsh
setopt extendedglob errexit pipefail
zmodload zsh/files zsh/mapfile
typeset root=${0:A:h:h} scratch shell_bin=${commands[zsh]} output revision source_file
scratch=$(mktemp -d "${TMPDIR:-/tmp}/zcoder-json-setup.XXXXXXXX")
trap 'zf_rm -rf -- "$scratch"' EXIT
typeset fake=$scratch/project
fail() { print -ru2 -- "FAIL: $*"; exit 1; }
zf_mkdir -p "$fake/lib" "$fake/scripts" "$fake/tests/fixtures"
cp "$root/Makefile" "$root/zcoder.zsh" "$root/chat.sh" "$fake/"
cp "$root"/lib/*.zsh "$fake/lib/"
cp "$root/scripts/setup-json.zsh" "$fake/scripts/"
: > "$fake/tests/example.zsh"
: > "$fake/tests/fixtures/example.zsh"
git -C "$fake" init -q
revision=$(git -C "$root/vendor/zjson" rev-parse HEAD)
print -r -- '[submodule "vendor/zjson"]' > "$fake/.gitmodules"
print -r -- $'\tpath = vendor/zjson' >> "$fake/.gitmodules"
print -r -- $'\turl = '"$root/vendor/zjson" >> "$fake/.gitmodules"
git -C "$fake" add .
git -C "$fake" update-index --add --cacheinfo "160000,$revision,vendor/zjson"

if output=$(ZCODER_RUNTIME=system "$shell_bin" -df "$fake/zcoder.zsh" --version 2>&1); then
  fail 'startup accepted a missing JSON dependency'
fi
[[ $output == *'Missing zjson dependency. Run make json'* && $output != *'command not found'* ]] || fail "missing dependency diagnostic: $output"

GIT_ALLOW_PROTOCOL=file make -s -C "$fake" compile > "$scratch/build.log" 2>&1 || fail "fresh compile: $(<"$scratch/build.log")"
[[ $(git -C "$fake/vendor/zjson" rev-parse HEAD) == "$revision" ]] || fail 'setup changed the pinned revision'
for source_file in "$fake"/lib/*.zsh "$fake/vendor/zjson/zjson.zsh" "$fake"/vendor/zjson/lib/*.zsh; do
  [[ -s $source_file.zwc ]] || fail "missing compiled library: $source_file"
done
[[ -z $(git -C "$fake/vendor/zjson" status --porcelain) ]] || fail 'compiled wordcode dirties the dependency'
output=$(ZCODER_RUNTIME=system "$shell_bin" -df "$fake/zcoder.zsh" --version 2>&1) || fail "compiled startup: $output"
[[ $output == zcoder.zsh\ * ]] || fail "version output: $output"

# Complete checkouts compile offline and retain local source edits.
print -r -- '# preserved local edit' >> "$fake/vendor/zjson/lib/zjson.zsh"
GIT_ALLOW_PROTOCOL=none make -s -C "$fake" compile > "$scratch/repeat.log" 2>&1 || fail "offline repeat: $(<"$scratch/repeat.log")"
[[ ${mapfile[$fake/vendor/zjson/lib/zjson.zsh]} == *'# preserved local edit'* ]] || fail 'local source edit lost'
make -s -C "$fake" clean
[[ ! -e $fake/lib/json.zsh.zwc && ! -e $fake/vendor/zjson/lib/zjson.zsh.zwc && ! -e $fake/vendor/zjson/zjson.zsh.zwc ]] || fail 'clean left compiled libraries'

# An incomplete edited checkout must fail without resetting those edits.
zf_rm "$fake/vendor/zjson/lib/pointer.zsh"
if output=$(GIT_ALLOW_PROTOCOL=none "$shell_bin" -df "$fake/scripts/setup-json.zsh" 2>&1); then
  fail 'incomplete edited dependency accepted'
fi
[[ $output == *'vendor/zjson has local edits'* && ! -e $fake/vendor/zjson/lib/pointer.zsh ]] || fail "edited dependency recovery: $output"
[[ ${mapfile[$fake/vendor/zjson/lib/zjson.zsh]} == *'# preserved local edit'* ]] || fail 'failure reset local source edits'
print -r -- 'PASS: missing-dependency startup, pinned bootstrap, compiled startup, offline repeat, clean and edited-dependency protection'
