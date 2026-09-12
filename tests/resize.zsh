# Feature discovery selects a backend without terminal I/O or command probes.
() {
  local -i UI_NATIVE_GEOMETRY=-1 discovery_result=0
  local ZCODER_CURSES_MODULE=zsh/curses ZCODER_CURSES_COMMAND=zcurses
  local discovery_call=''
  local -a zcurses_features=(future_feature mouse geometry resize)
  local -a zdraw_features=(styled_spans geometry clipped_spans)
  zmodload() { discovery_call="${(j: :)@}"; return "$discovery_result"; }
  {
    ui_detect_geometry
    assert_eq 1 "$UI_NATIVE_GEOMETRY" 'feature discovery selects native geometry before querying the terminal'
    zcurses_features=(resize future_feature)
    ui_detect_geometry
    assert_eq 0 "$UI_NATIVE_GEOMETRY" 'known feature set without geometry selects stty without a command probe'
    zcurses_features=()
    ui_detect_geometry
    assert_eq 0 "$UI_NATIVE_GEOMETRY" 'empty compiled feature set selects stock fallback'
    discovery_result=1
    ui_detect_geometry
    assert_eq -1 "$UI_NATIVE_GEOMETRY" 'missing or disabled discovery keeps legacy module probing'
    discovery_result=0
    ZCODER_CURSES_MODULE=zdraw ZCODER_CURSES_COMMAND=zdraw
    ui_detect_geometry
    assert_eq 1 "$UI_NATIVE_GEOMETRY" 'zdraw discovery reads zdraw_features even when stock features are empty'
    assert_eq '-F -e zdraw +p:zdraw_features' "$discovery_call" 'feature check uses the selected module namespace'
  } always {
    unfunction zmodload
  }
}

# Exercise scheduling and failed native queries without a terminal.
() {
  local saved_curses=${functions[zcoder_curses]}
  local saved_setup=${functions[ui_setup_windows]} saved_refresh=${functions[ui_refresh_all]}
  local -i UI_ACTIVE=0 UI_NATIVE_GEOMETRY=-1 UI_RESIZE_PENDING=1
  local -i SCREEN_H=24 SCREEN_W=80 geometry_calls=0 resize_calls=0 layout_calls=0
  local -F UI_NEXT_RESIZE_CHECK=0
  local -i geometry_result=0
  local invalid=''
  local -a geometry_value=(40 120)
  zcoder_curses() {
    case "$1" in
      geometry) (( geometry_calls++ )); dimensions=("${geometry_value[@]}"); return "$geometry_result" ;;
      resize) (( resize_calls++ )); return 0 ;;
    esac
    return 1
  }
  ui_setup_windows() { (( layout_calls++ )); SCREEN_H=$h; SCREEN_W=$w; }
  ui_refresh_all() { return 0; }
  {
    UI_NATIVE_GEOMETRY=1; geometry_result=1
    ui_poll_resize
    assert_eq '1:0:0:24:80' "$UI_NATIVE_GEOMETRY:$resize_calls:$layout_calls:$SCREEN_H:$SCREEN_W" 'advertised geometry survives a failed first query without changing layout'
    UI_NATIVE_GEOMETRY=-1; geometry_result=0; geometry_calls=0; UI_RESIZE_PENDING=1
    ui_poll_resize
    assert_eq '1:1:1:40:120' "$UI_NATIVE_GEOMETRY:$resize_calls:$layout_calls:$SCREEN_H:$SCREEN_W" 'native geometry resizes and relays fresh dimensions to layout'
    UI_NEXT_RESIZE_CHECK=$(( EPOCHREALTIME + 100 ))
    ui_poll_resize
    assert_eq 1 "$geometry_calls" 'resize polling gate avoids unnecessary geometry queries'
    UI_RESIZE_PENDING=1
    ui_poll_resize
    assert_eq '2:1' "$geometry_calls:$resize_calls" 'resize signals bypass polling gate without rebuilding unchanged dimensions'
    geometry_result=1; geometry_value=(50 150); UI_RESIZE_PENDING=1
    ui_poll_resize
    assert_eq '1:1:40:120' "$UI_NATIVE_GEOMETRY:$resize_calls:$SCREEN_H:$SCREEN_W" 'native query failure preserves dimensions and native selection'
    geometry_result=0; UI_RESIZE_PENDING=1
    ui_poll_resize
    assert_eq '2:50:150' "$resize_calls:$SCREEN_H:$SCREEN_W" 'next native poll recovers after transient failure'
    for invalid in '0' '-1' 'bad'; do
      geometry_value=("$invalid" 80); UI_RESIZE_PENDING=1
      ui_poll_resize
    done
    geometry_value=(24); UI_RESIZE_PENDING=1
    ui_poll_resize
    assert_eq 2 "$resize_calls" 'invalid dimensions never reach curses resize'
  } always {
    functions[zcoder_curses]=$saved_curses
    functions[ui_setup_windows]=$saved_setup
    functions[ui_refresh_all]=$saved_refresh
  }
}

test_integration resize || return 0

# Run the real UI on stock curses, and optionally the experimental module.
resize_pty_wait() {
  local -F deadline=$(( EPOCHREALTIME + 8 ))
  local chunk=''
  while (( EPOCHREALTIME < deadline )); do
    while zpty -r resize-ui chunk 2>/dev/null; do :; done
    [[ -f $resize_base.done ]] && return 0
    zselect -t 1 2>/dev/null
  done
  return 1
}
resize_pty_run() {
  trap - EXIT INT TERM
  exec zsh -f "$TEST_DIR/fixtures/resize_ui.zsh" "$PROJECT_DIR" "$resize_base" "$resize_module" "$resize_phase"
}
typeset -a resize_modules=('')
[[ -n ${ZCODER_TEST_CURSES_PATH:-} ]] && resize_modules+=("$ZCODER_TEST_CURSES_PATH")
# The ordinary suite exercises the production loader whenever a local build
# is enabled; no environment override is needed after `make curses`.
resize_backend=$(ZCODER_CURSES=auto zsh -dfc 'source "$1/lib/curses.zsh"; zcoder_curses_load "$1" || exit; print -r -- "$ZCODER_CURSES_BACKEND"' zcoder-test "$PROJECT_DIR")
[[ $resize_backend == bundled ]] && resize_modules+=(auto)
typeset -g resize_module='' resize_base='' resize_phase='' resize_restored=''
for resize_module in "${resize_modules[@]}"; do
  resize_phase=''
  resize_label=stock; resize_expected=0
  [[ -n $resize_module ]] && { resize_label=fork; resize_expected=1; }
  [[ $resize_module == auto ]] && resize_label=bundled
  resize_base="$TEST_TMP/resize-$resize_label"
  TERM=xterm-256color zpty -b resize-ui resize_pty_run
  assert_success "$resize_label resize fixture starts" $?
  zpty -w -n resize-ui $'\x02'
  resize_pty_wait
  assert_success "$resize_label UI completes repeated resize and reentry" $?
  if [[ $resize_module == auto ]]; then
    assert_eq 1 "${mapfile[$resize_base.initial]:-}" 'bundled UI selects advertised geometry before its first poll'
  fi
  assert_eq '40:120:20:60:40:120' "${mapfile[$resize_base.sizes]:-}" "$resize_label UI layout follows terminal grow, shrink, and grow"
  assert_eq '1:0:preserved draft:15' "${mapfile[$resize_base.hidden]:-}" "$resize_label Ctrl+B hides the sidebar during activity without changing the draft"
  assert_eq '0:120:0:60:0:120' "${mapfile[$resize_base.widths]:-}" "$resize_label hidden sidebar stays hidden through resizes and gives chat the full width"
  assert_eq '25:95:1' "${mapfile[$resize_base.shown]:-}" "$resize_label showing the sidebar restores its width and rewraps the transcript"
  assert_eq 'input:preserved draft:15' "${mapfile[$resize_base.focus]:-}" "$resize_label hiding a focused sidebar returns to the intact prompt"
  assert_eq '1:preserved draf' "${mapfile[$resize_base.backspace]:-}" "$resize_label Ctrl+H still deletes a character without toggling the sidebar"
  assert_eq '1:0' "${mapfile[$resize_base.reentry]:-}" "$resize_label hidden preference survives UI reentry"
  assert_eq 0 "${mapfile[$resize_base.initial_preference]:-}" "$resize_label a narrow first launch does not save an automatic preference"
  assert_eq "$resize_expected:$resize_expected" "${mapfile[$resize_base.native]:-}" "$resize_label selects geometry backend across UI reentry"
  if (( resize_expected )); then
    assert_eq '' "${mapfile[$resize_base.stty]:-}" 'native resize polling launches no stty processes'
    assert_eq 5 "${mapfile[$resize_base.probes]:-}" 'native backend queries current dimensions on every due poll'
  else
    assert_eq $'size\nsize\nsize\nsize\nsize\n' "${mapfile[$resize_base.stty]:-}" 'stock resize polling uses stty fallback'
    assert_eq 2 "${mapfile[$resize_base.probes]:-}" 'stock module is probed only once per UI session'
  fi
  zpty -d resize-ui
  resize_phase=restore
  for resize_restored in '1:0' '0:25'; do
    zf_rm -f -- "$resize_base.done"
    TERM=xterm-256color zpty -b resize-ui resize_pty_run
    resize_pty_wait
    assert_success "$resize_label fresh UI process loads and changes sidebar preferences" $?
    assert_eq "$resize_restored" "${mapfile[$resize_base.restored]:-}" "$resize_label sidebar choice survives exit and restart after a narrow terminal"
    zpty -d resize-ui
  done
done
unfunction resize_pty_wait resize_pty_run
