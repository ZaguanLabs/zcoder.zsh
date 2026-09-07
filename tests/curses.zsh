source "$PROJECT_DIR/lib/curses.zsh"

# Exercise selection independently of curses, a compiler, or terminal state.
() {
  local test_root="$TEST_TMP/curses-loader"
  local test_build="$test_root/vendor/zcurses/.build"
  local signature="$ZSH_VERSION:$ZSH_PATCHLEVEL:$MACHTYPE:$OSTYPE:$HOST"
  local ZCODER_CURSES=auto ZCODER_CURSES_BACKEND=unloaded
  local -a original_path=("${module_path[@]}") loaded_paths=()
  local -i preloaded=0 bundled_result=0 stock_result=0
  zf_mkdir -p "$test_build/modules/zsh"
  mapfile[$test_build/modules/zsh/curses.so]=''
  mapfile[$test_build/zcoder-abi]="$signature"
  zmodload() {
    [[ $1 == -e ]] && return $(( ! preloaded ))
    loaded_paths+=("$module_path[1]")
    [[ $module_path[1] == "$test_build/modules" ]] && return "$bundled_result"
    return "$stock_result"
  }
  {
    zcoder_curses_load "$test_root"
    assert_success 'matching local curses build loads' $?
    assert_eq bundled "$ZCODER_CURSES_BACKEND" 'matching build selects bundled curses'
    assert_eq "$test_build/modules" "$loaded_paths[-1]" 'dependency path precedes system module paths'
    assert_eq "${(j.:.)original_path}" "${(j.:.)module_path}" 'loader restores caller module search path'
    ZCODER_CURSES=stock
    zcoder_curses_load "$test_root"
    assert_eq stock "$ZCODER_CURSES_BACKEND" 'stock override bypasses a matching dependency'
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
    stock_result=1
    zcoder_curses_load "$test_root"
    assert_failure 'unavailable stock and bundled modules propagate failure' $?
    preloaded=1; loaded_paths=(); ZCODER_CURSES_BACKEND=unloaded
    zcoder_curses_load "$test_root"
    assert_eq preloaded "$ZCODER_CURSES_BACKEND" 'already loaded curses is retained'
    assert_eq 0 "${#loaded_paths}" 'loader never replaces an active module'
    ZCODER_CURSES=invalid
    zcoder_curses_load "$test_root" 2>/dev/null
    assert_failure 'invalid curses policy fails explicitly' $?
  } always {
    unfunction zmodload
  }
}
