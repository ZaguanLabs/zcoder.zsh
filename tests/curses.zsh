# lib/curses.zsh is loaded with the UI; preserve its rendering mock here.

# Exercise selection independently of curses, a compiler, or terminal state.
() {
  local test_root="$TEST_TMP/curses-loader"
  local test_build="$test_root/vendor/zdraw/.build"
  local signature="$ZSH_VERSION:$ZSH_PATCHLEVEL:$MACHTYPE:$OSTYPE:$HOST"
  local ZCODER_CURSES=auto ZCODER_CURSES_BACKEND=unloaded
  local ZCODER_CURSES_MODULE=zsh/curses ZCODER_CURSES_COMMAND=zcurses
  local -a original_path=("${module_path[@]}") loaded_paths=() loaded_modules=()
  local preloaded=''
  local -i bundled_result=0 stock_result=0
  zf_mkdir -p "$test_build/modules"
  mapfile[$test_build/modules/zdraw.so]=''
  mapfile[$test_build/zcoder-abi]="$signature"
  zmodload() {
    if [[ $1 == -e ]]; then [[ $2 == "$preloaded" ]]; return $?; fi
    loaded_paths+=("$module_path[1]")
    loaded_modules+=("$1")
    [[ $module_path[1] == "$test_build/modules" ]] && return "$bundled_result"
    return "$stock_result"
  }
  {
    zcoder_curses_load "$test_root"
    assert_success 'matching local curses build loads' $?
    assert_eq bundled "$ZCODER_CURSES_BACKEND" 'matching build selects bundled curses'
    assert_eq zdraw "$loaded_modules[-1]" 'bundle loads the independent zdraw module'
    assert_eq zdraw:zdraw "$ZCODER_CURSES_MODULE:$ZCODER_CURSES_COMMAND" 'bundle selects zdraw command and discovery namespace'
    assert_eq "$test_build/modules" "$loaded_paths[-1]" 'dependency path precedes system module paths'
    assert_eq "${(j.:.)original_path}" "${(j.:.)module_path}" 'loader restores caller module search path'
    ZCODER_CURSES=stock
    zcoder_curses_load "$test_root"
    assert_eq stock "$ZCODER_CURSES_BACKEND" 'stock override bypasses a matching dependency'
    assert_eq zsh/curses:zcurses "$ZCODER_CURSES_MODULE:$ZCODER_CURSES_COMMAND" 'stock override selects the stock namespace'
    ZCODER_CURSES=auto
    mapfile[$test_build/zcoder-abi]="other-host"
    zcoder_curses_load "$test_root"
    assert_eq stock "$ZCODER_CURSES_BACKEND" 'copied or incompatible binary uses stock module'
    zf_rm -- "$test_build/zcoder-abi"
    zcoder_curses_load "$test_root"
    assert_eq stock "$ZCODER_CURSES_BACKEND" 'unbuilt dependency uses stock module'
    mapfile[$test_build/zcoder-abi]="$signature"
    bundled_result=1; loaded_paths=()
    zcoder_curses_load "$test_root"
    assert_success 'failed bundled load recovers with stock module' $?
    assert_eq 2 "${#loaded_paths}" 'failed dependency load retries outside the dependency path'
    assert_eq "$original_path[1]" "$loaded_paths[-1]" 'fallback uses original module path'
    assert_eq zsh/curses "$loaded_modules[-1]" 'failed zdraw load falls back to stock module identity'
    stock_result=1
    zcoder_curses_load "$test_root"
    assert_failure 'unavailable stock and bundled modules propagate failure' $?
    preloaded=zsh/curses; loaded_paths=(); ZCODER_CURSES_BACKEND=unloaded
    zcoder_curses_load "$test_root"
    assert_eq preloaded "$ZCODER_CURSES_BACKEND" 'already loaded curses is retained'
    assert_eq 0 "${#loaded_paths}" 'loader never replaces an active module'
    preloaded=zdraw; ZCODER_CURSES_BACKEND=unloaded
    zcoder_curses_load "$test_root"
    assert_eq preloaded:zdraw:zdraw "$ZCODER_CURSES_BACKEND:$ZCODER_CURSES_MODULE:$ZCODER_CURSES_COMMAND" 'preloaded zdraw selects its own command and parameters'
    assert_eq 0 "${#loaded_paths}" 'preloaded zdraw never loads stock curses alongside it'
    ZCODER_CURSES=stock
    zcoder_curses_load "$test_root"
    assert_eq zdraw "$ZCODER_CURSES_COMMAND" 'policy changes never switch a loaded drawing session'
    ZCODER_CURSES=invalid
    zcoder_curses_load "$test_root" 2>/dev/null
    assert_failure 'invalid curses policy fails explicitly' $?
  } always {
    unfunction zmodload
  }
}
