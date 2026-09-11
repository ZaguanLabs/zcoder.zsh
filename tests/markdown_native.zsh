#!/usr/bin/env zsh
emulate -R zsh
zmodload zsh/files zsh/mapfile zsh/zpty zsh/zselect zsh/datetime
typeset root=${0:A:h:h} scratch=${TMPDIR:-/tmp}/zcoder-markdown-test-$$
zf_mkdir -p "$scratch/vendor/zmdown/.build/modules"
trap 'zpty -d markdown-native 2>/dev/null; zf_rm -rf -- "$scratch"' EXIT
source "$root/lib/markdown_native.zsh"
fail() { print -ru2 -- "FAIL: $*"; exit 1; }
() {
  local build=$scratch/vendor/zmdown/.build preloaded='' result=0
  local -a original_path=("${module_path[@]}") calls=()
  zmodload() {
    [[ $1 == -e ]] && { [[ $2 == "$preloaded" ]]; return; }
    calls+=("$module_path[1]")
    return $result
  }
  {
    zcoder_markdown_load "$scratch" && fail 'missing build loaded'
    mapfile[$build/modules/zmdown.so]=''
    mapfile[$build/zcoder-abi]=foreign
    zcoder_markdown_load "$scratch" && fail 'foreign host loaded'
    (( ${#calls} == 0 )) || fail 'loader tried untrusted ABI'
    mapfile[$build/zcoder-abi]="$ZSH_VERSION:$ZSH_PATCHLEVEL:$MACHTYPE:$OSTYPE:$HOST"
    zcoder_markdown_load "$scratch" || fail 'matching module not loaded'
    [[ $calls[1] == "$build/modules" && ${(j.:.)module_path} == ${(j.:.)original_path} ]] || fail 'module path leaked'
    result=1
    zcoder_markdown_load "$scratch" && fail 'load failure ignored'
    preloaded=zmdown; calls=()
    zcoder_markdown_load "$scratch" || fail 'preloaded module rejected'
    (( ${#calls} == 0 )) || fail 'preloaded module replaced'
  } always { unfunction zmodload }
}
# Capability gating is independent of any installed native modules.
zcoder_curses_features() { reply=(text_policy); }
ui_markdown_init
[[ $UI_MARKDOWN_BACKEND == zsh ]] || fail 'old zdraw enabled native Markdown'
ZCODER_MARKDOWN=zsh ui_markdown_init
[[ $UI_MARKDOWN_BACKEND == zsh ]] || fail 'explicit fallback ignored'
_ui_markdown_ascii $'a\u0301\u0301\n👩‍💻'
[[ $REPLY == 'a\u{0301}\u{0301}'$'\n''\u{1F469}\u{200D}\u{1F4BB}' ]] || fail "visible scalar fallback: $REPLY"
run_fixture() {
  trap - EXIT
  export TERM=xterm-256color LC_ALL=C.UTF-8
  exec zsh -df "$root/tests/fixtures/markdown_native.zsh" "$root" "$scratch/result"
}
zpty -b markdown-native run_fixture || fail 'PTY startup'
typeset output='' chunk
typeset -F deadline=$(( EPOCHREALTIME + 30 ))
while (( EPOCHREALTIME < deadline )); do
  while zpty -r markdown-native chunk 2>/dev/null; do output+=$chunk; done
  [[ -f $scratch/result ]] && break
  zselect -t 1
done
[[ -f $scratch/result ]] || fail "PTY timeout: ${(V)output[-2000,-1]}"
[[ $mapfile[$scratch/result] == PASS* || $mapfile[$scratch/result] == SKIP* ]] || fail "$mapfile[$scratch/result]"
print -r -- "$mapfile[$scratch/result]"
