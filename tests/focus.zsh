# Decoder and activity paths use the real UI with the suite's curses recorder.
() {
  local sequence ch expected
  local UI_FOCUS=input INPUT_TERM_STATE=normal INPUT_ESCAPE_BUF=''
  local -i UI_ACTIVE=1 UI_MODAL_ACTIVE=0 UI_ACTIVITY_DEPTH=0 SCREEN_W=120 SIDE_W=25
  local -i UI_SIDEBAR_HIDDEN=0
  input_reset
  for sequence in $'\e1' $'\e2' $'\e[49;3u' $'\e[50;3u' $'\e[27;3;49~' $'\e[27;3;50~'; do
    for ch in "${(@s::)sequence}"; do input_decode_terminal_event "$ch" ''; done
    expected=focus_prompt
    [[ $sequence == $'\e1' || $sequence == *49* ]] && expected=focus_sessions
    assert_eq "$expected:normal" "$INPUT_EVENT_ACTION:$INPUT_TERM_STATE" "Alt focus sequence ${(V)sequence} decodes completely"
  done
  input_decode_terminal_event $'\e' ''
  INPUT_ESCAPE_AT=$(( EPOCHREALTIME - 1 ))
  input_decode_terminal_event 1 ''
  assert_eq '1:normal:' "$?:$INPUT_TERM_STATE:$INPUT_EVENT_ACTION" 'a separate Escape does not consume a later digit'
  ui_activity_input 1 ''; ui_activity_input 2 ''
  assert_eq input:12 "$UI_FOCUS:$INPUT_BUF" 'digits remain editable prompt text'
  ui_focus_panel 1
  assert_eq sidebar:12 "$UI_FOCUS:$INPUT_BUF" 'focusing Sessions preserves the draft'
  MOCK_ZCURSES_CALLS=()
  _ui_paint_sidebar 1
  assert_contains "${(F)MOCK_ZCURSES_CALLS}" '[1] Sessions' 'sidebar title exposes its number'
  assert_contains "${(F)MOCK_ZCURSES_CALLS}" 'attr side_win -dim reverse bold' 'focused sidebar title has a non-color focus cue'
  ui_activity_input 2 ''
  assert_eq input:12 "$UI_FOCUS:$INPUT_BUF" 'bare 2 returns from Sessions without inserting text'
  MOCK_ZCURSES_CALLS=()
  _ui_paint_input 1
  assert_not_contains "${(F)MOCK_ZCURSES_CALLS}" ' reverse ' 'focused Prompt instructions have no reverse background'
  UI_ACTIVITY_DEPTH=1; UI_FOCUS=chat
  for ch in $'\e' 2; do ui_activity_input "$ch" ''; done
  assert_eq input:12 "$UI_FOCUS:$INPUT_BUF" 'Alt+2 returns to the draft during activity'
  for ch in $'\e' 1; do ui_activity_input "$ch" ''; done
  assert_eq input "$UI_FOCUS" 'Alt+1 cannot switch sessions during activity'
  UI_ACTIVITY_DEPTH=0; SCREEN_W=80
  ui_focus_panel 1
  assert_eq input "$UI_FOCUS" 'a narrow terminal cannot focus an invisible sidebar'
  SCREEN_W=120; UI_MODAL_ACTIVE=1
  ui_focus_panel 1
  assert_eq input "$UI_FOCUS" 'panel shortcuts cannot steal dialog focus'
  UI_MODAL_ACTIVE=0
  sequence=$'\e[200~123\e1\e[201~'
  for ch in "${(@s::)sequence}"; do ui_activity_input "$ch" ''; done
  assert_eq $'input:12123\e1' "$UI_FOCUS:$INPUT_BUF" 'pasted digits and an Alt-like sequence stay draft content'
  input_reset
}

# Exercise the actual idle application loop in a PTY on both backend choices.
() {
  local backend base chunk output='' tty_path
  focus_wait() {
    local expected=$1
    local -F deadline=$(( EPOCHREALTIME + 8 ))
    while (( EPOCHREALTIME < deadline )); do
      while zpty -r focus-ui chunk 2>/dev/null; do
        [[ -n $chunk ]] || break
        output+=$chunk
        (( EPOCHREALTIME < deadline )) || break
      done
      [[ ${mapfile[$base.state]:-} == "$expected" ]] && return 0
      zselect -t 1
    done
    print -r -- "Focus state: ${mapfile[$base.state]:-}; output: ${(V)output[-500,-1]}"
    return 1
  }
  focus_run() {
    trap - EXIT INT TERM
    exec zsh -f "$TEST_DIR/fixtures/focus_ui.zsh" "$PROJECT_DIR" "$base" "$backend"
  }
  for backend in stock auto; do
    base="$TEST_TMP/focus-$backend"
    zf_mkdir -p "$base.workspace"
    TERM=xterm-256color zpty -b focus-ui focus_run
    focus_wait 'input:25:0:'
    assert_success "$backend: numbered focus fixture opens the real application" $?
    zpty -w -n focus-ui $'12\eOD'
    focus_wait 'input:25:1:12'
    assert_success "$backend: prompt digits and caret movement remain normal" $?
    zpty -w -n focus-ui $'\e1'
    focus_wait 'sidebar:25:1:12'
    assert_success "$backend: Alt+1 focuses Sessions and preserves draft and caret" $?
    zpty -w -n focus-ui 2
    focus_wait 'input:25:1:12'
    assert_success "$backend: bare 2 returns to the draft" $?
    zpty -w -n focus-ui $'\x02'
    focus_wait 'input:0:1:12'
    assert_success "$backend: sidebar can still be hidden" $?
    zpty -w -n focus-ui $'\e1'
    focus_wait 'sidebar:25:1:12'
    assert_success "$backend: Alt+1 reveals and focuses a hidden sidebar" $?
    zpty -w -n focus-ui $'\t'
    focus_wait 'chat:25:1:12'
    assert_success "$backend: Tab still visits the transcript" $?
    zpty -w -n focus-ui 1
    focus_wait 'sidebar:25:1:12'
    assert_success "$backend: bare 1 jumps from transcript to Sessions" $?
    zpty -w -n focus-ui $'\e2'
    focus_wait 'input:25:1:12'
    assert_success "$backend: Alt+2 returns directly to the prompt" $?
    tty_path=${mapfile[$base.tty]}
    command stty cols 70 < "$tty_path"
    focus_wait 'input:0:1:12'
    zpty -w -n focus-ui $'\e1x'
    focus_wait 'input:0:2:1x2'
    assert_success "$backend: unavailable Sessions focus leaves the narrow prompt usable" $?
    zpty -w -n focus-ui $'\x11'
    zselect -t 10
    zpty -d focus-ui
  done
  unfunction focus_wait focus_run
}
