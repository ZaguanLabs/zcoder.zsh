#!/usr/bin/env zsh
emulate -R zsh
setopt extendedglob
zmodload zsh/files zsh/mapfile zsh/system
typeset root=${0:A:h:h} scratch
scratch=$(mktemp -d "${TMPDIR:-/tmp}/zcoder-native-setup.XXXXXXXX") || exit 1
trap 'zf_rm -rf -- "$scratch"' EXIT
typeset shell_bin=${commands[zsh]} output
typeset fake=$scratch/project runtime=$scratch/project/.build/native/builds/test/runtime
typeset -i checks=0
fail() { print -ru2 -- "FAIL: $*"; exit 1; }
check() { (( checks++ )); [[ $1 == "$2" ]] || fail "$3: ${(qqq)1}"; }
zf_mkdir -p "$runtime/bin" "$fake/scripts"
print -r -- "$runtime" > "$fake/.build/native/current"
print -r -- "$MACHTYPE:$OSTYPE:$HOST:$fake" > "$runtime/zcoder-host"
print -r -- "#!$shell_bin" > "$runtime/bin/zsh"
print -r -- 'print -rl -- "$@"' >> "$runtime/bin/zsh"
chmod 0755 "$runtime/bin/zsh"
select_runtime() {
  "$shell_bin" -dfc 'source "$1"; shift; zcoder_runtime_select "$@" || exit; print fallback' \
    native-test "$root/lib/runtime.zsh" "$fake/zcoder.zsh" "$@"
}
output=$(select_runtime 'two words' '$literal;*') || fail selection
check "$output" $'-df\n'"$fake/scripts/run-native.zsh"$'\n'"$fake/zcoder.zsh"$'\n'"$runtime"$'\ntwo words\n$literal;*' 'launcher preserves arguments'
output=$(ZCODER_RUNTIME=system select_runtime)
check "$output" fallback 'system override'
print -r -- foreign > "$runtime/zcoder-host"
output=$(select_runtime)
check "$output" fallback 'copied runtime falls back'
print -r -- "$MACHTYPE:$OSTYPE:$HOST:$fake" > "$runtime/zcoder-host"
print -r -- /tmp/unrelated-runtime > "$fake/.build/native/current"
output=$(select_runtime)
check "$output" fallback 'pointer cannot select another runtime tree'
zf_rm "$fake/.build/native/current"
output=$(select_runtime)
check "$output" fallback 'fresh checkout uses installed shell'
ZCODER_RUNTIME=invalid select_runtime > /dev/null 2>&1 && fail 'invalid runtime policy accepted'
(( checks++ ))
# The wrapper must source the requested entry with its original arguments and
# keep its recursion marker out of shells launched by application tools.
print -r -- "$runtime" > "$fake/.build/native/current"
print -r -- "source ${(q)root}/lib/runtime.zsh" > "$fake/zcoder.zsh"
print -r -- 'zcoder_runtime_select "$0" "$@" || exit' >> "$fake/zcoder.zsh"
print -r -- 'print -r -- "$1|$2|${parameters[ZCODER_RUNTIME_ACTIVE]}"; zsh -dfc '\''print -r -- ${ZCODER_RUNTIME_ACTIVE-unset}'\' >> "$fake/zcoder.zsh"
output=$(ZCODER_RUNTIME_ACTIVE=inherited "$shell_bin" -df "$root/scripts/run-native.zsh" "$fake/zcoder.zsh" "$runtime" 'two words' literal)
check "$output" $'two words|literal|scalar-readonly\nunset' 'private marker and source arguments'

# Failure paths need no compiler or network. Only Git's submodule bookkeeping
# is stubbed; the production script performs the digest and lock operations.
cp "$root/scripts/setup-native.zsh" "$fake/scripts/setup-native.zsh"
typeset mock_bin=$scratch/bin checksum_bin
zf_mkdir -p "$mock_bin"
print -r -- "#!$shell_bin" > "$mock_bin/git"
print -r -- '[[ $* == *rev-parse* ]] && print revision; exit 0' >> "$mock_bin/git"
print -r -- "#!$shell_bin" > "$mock_bin/curl"
print -r -- 'exit 22' >> "$mock_bin/curl"
chmod 0755 "$mock_bin/git" "$mock_bin/curl"
for tool in make cc autoconf autoheader m4 patch awk sed tar xz cp cmp install; do
  zf_ln -s /bin/true "$mock_bin/$tool"
done
if (( ${+commands[sha256sum]} )); then
  zf_ln -s "$commands[sha256sum]" "$mock_bin/sha256sum"
else
  # Use an absolute Perl interpreter when shasum's shebang uses env.
  zf_ln -s "$commands[shasum]" "$mock_bin/shasum"
  (( ${+commands[perl]} )) && zf_ln -s "$commands[perl]" "$mock_bin/perl"
fi
print -r -- preserved > "$fake/.build/native/current"
print -r -- corrupt > "$fake/.build/native/zsh-5.9.2.tar.xz"
setup_failure() {
  output=$(PATH="$mock_bin" MAKE=make CC=cc "$shell_bin" -df "$fake/scripts/setup-native.zsh" 2>&1)
  [[ $? != 0 ]] || fail 'setup unexpectedly succeeded'
}
repeat 2; do
  setup_failure
  [[ $output == *'checksum mismatch'* ]] || fail "corrupt archive/lock release: $output"
  (( checks++ ))
done
check "$(<"$fake/.build/native/current")" preserved 'failed build preserves current runtime'
zf_rm "$fake/.build/native/zsh-5.9.2.tar.xz"
setup_failure
[[ $output == *'Native setup failed'* && ! -e $fake/.build/native/zsh-5.9.2.tar.xz ]] || fail 'failed download was published'
(( checks++ ))
zf_rm "$mock_bin/cc"
setup_failure
[[ $output == *'Missing build tools: cc'* ]] || fail "missing compiler diagnostic: $output"
(( checks++ ))
typeset -i lock_fd
zsystem flock -t 0 -f lock_fd "$fake/.build/native/lock" || fail 'test lock'
setup_failure
[[ $output == *'Another native build'* ]] || fail "concurrent build entered: $output"
zsystem flock -u "$lock_fd"
(( checks++ ))
print -r -- "PASS: $checks native setup and launcher checks"
