# Completion state is independent of terminal input and command dispatch.
() {
  local saved_changed=${functions[ui_input_changed]}
  local -i UI_ACTIVE=1 UI_MODAL_ACTIVE=0 UI_ACTIVITY_DEPTH=0 UI_SLASH_ROWS=0 UI_SLASH_SELECTED=1
  local -i SCREEN_H=24 SCREEN_W=80 TOP_H=3 FOOT_H=1 INPUT_POS=1
  local UI_FOCUS=input INPUT_BUF=/ INPUT_TERM_STATE=normal INPUT_ESCAPE_BUF=''
  local UI_SLASH_BUFFER='' UI_SLASH_DISMISSED='' UI_SLASH_CACHE_KEY=''
  local REMOTE_MODE=local ZCODER_PROFILE=coding
  local -i REMOTE_GOALS_SUPPORTED=0 REMOTE_HARNESS_DISCOVERY_SUPPORTED=0
  local -a UI_SLASH_TEXTS=() UI_SLASH_LABELS=()
  ui_input_changed() { ui_slash_update; }
  {
    ui_slash_update
    assert_eq 6 "$UI_SLASH_ROWS" 'slash opens a bounded suggestion list'
    assert_contains "${(F)UI_SLASH_TEXTS}" /commands 'slash suggestions include the command palette'
    ui_slash_input '' UP
    assert_eq "${#UI_SLASH_TEXTS}" "$UI_SLASH_SELECTED" 'Up wraps from the first command to the last'
    ui_slash_input '' DOWN
    assert_eq 1 "$UI_SLASH_SELECTED" 'Down wraps from the last command to the first'
    assert_eq / "$INPUT_BUF" 'browsing suggestions does not modify the prompt'
    INPUT_BUF=/co; INPUT_POS=3; ui_slash_update
    assert_eq /context "${UI_SLASH_TEXTS[1]}" 'type-ahead filters literal command prefixes'
    assert_not_contains "${(F)UI_SLASH_TEXTS}" /queue 'type-ahead omits commands that do not match the prefix'
    ui_slash_input $'\n' SENTER
    assert_failure 'Shift+Enter stays with the newline decoder while suggestions are open' $?
    assert_eq /co "$INPUT_BUF" 'enhanced newline does not accept a suggestion'
    ui_slash_input '' DOWN
    ui_slash_update
    assert_eq 2 "$UI_SLASH_SELECTED" 'unchanged layout updates preserve the selected command'
    ui_slash_input '' UP
    ui_slash_input $'\r' ''
    assert_success 'Enter completes a partial command without submitting it' $?
    assert_eq '/context:8:0' "$INPUT_BUF:$INPUT_POS:$UI_SLASH_ROWS" 'completion fills the prompt, places the cursor, and closes the list'
    ui_slash_input $'\r' ''
    assert_failure 'Enter after completion returns to normal command dispatch' $?
    INPUT_BUF=/; INPUT_POS=1; ui_slash_update
    INPUT_BUF=/context; INPUT_POS=8; ui_slash_update
    ui_slash_input $'\r' ''
    assert_failure 'an exactly typed command retains single-Enter dispatch' $?
    INPUT_BUF=/ho; INPUT_POS=3; ui_slash_update
    ui_slash_input $'\t' ''
    assert_eq '/host :6:0' "$INPUT_BUF:$INPUT_POS:$UI_SLASH_ROWS" 'Tab completes an argument-taking command with a trailing space'
    INPUT_BUF='/host example'; INPUT_POS=${#INPUT_BUF}; ui_slash_update
    assert_eq 0 "$UI_SLASH_ROWS" 'argument text uses ordinary editor behavior'
    INPUT_BUF='/*'; INPUT_POS=2; ui_slash_update
    assert_eq 0 "$UI_SLASH_ROWS" 'slash query metacharacters stay literal'
    INPUT_BUF=/co; INPUT_POS=2; ui_slash_update
    assert_eq 0 "$UI_SLASH_ROWS" 'editing inside the command hides suggestions'
    INPUT_POS=3; ui_slash_update
    ui_slash_input $'\e' ''
    input_decode_terminal_event $'\e' ''
    UI_SLASH_ESCAPE_AT=0
    ui_slash_input '' ''
    assert_eq '/co:0:normal' "$INPUT_BUF:$UI_SLASH_ROWS:$INPUT_TERM_STATE" 'bare Escape dismisses suggestions and preserves the draft'
    ui_slash_update
    assert_eq 0 "$UI_SLASH_ROWS" 'a dismissed list stays closed on repaint'
    INPUT_BUF=/con; INPUT_POS=4; ui_slash_update
    assert_eq 2 "$UI_SLASH_ROWS" 'editing after dismissal reopens matching suggestions'
    UI_ACTIVITY_DEPTH=1; ui_slash_update
    assert_eq 0 "$UI_SLASH_ROWS" 'activity drafts keep their existing arrow and submission behavior'
    UI_ACTIVITY_DEPTH=0; UI_FOCUS=chat; ui_slash_update
    assert_eq 0 "$UI_SLASH_ROWS" 'transcript focus hides prompt suggestions'
    UI_FOCUS=input; SCREEN_H=10; ui_slash_update
    assert_eq 0 "$UI_SLASH_ROWS" 'tiny terminals reserve space for the prompt and transcript'
    SCREEN_H=24; INPUT_BUF=/; INPUT_POS=1; REMOTE_MODE=client
    ui_slash_update
    assert_not_contains "${(F)UI_SLASH_TEXTS}" /compact 'remote suggestions omit local-only commands'
    assert_not_contains "${(F)UI_SLASH_TEXTS}" /goal 'remote suggestions omit unsupported goals'
    REMOTE_MODE=local; ZCODER_PROFILE=sysadmin; ui_slash_update
    assert_not_contains "${(F)UI_SLASH_TEXTS}" '/codex!' 'sysadmin suggestions omit editing workers'
  } always {
    functions[ui_input_changed]=$saved_changed
  }
}

# Real terminal input, drawing, and resize behavior on both available backends.
slash_pty_wait() {
  local file=$1 expected=$2 chunk=''
  local -F deadline=$(( EPOCHREALTIME + 5 ))
  while (( EPOCHREALTIME < deadline )); do
    while zpty -r slash-ui chunk 2>/dev/null; do :; done
    [[ "${mapfile[$file]:-}" == "$expected" ]] && return 0
    zselect -t 1
  done
  return 1
}
slash_pty_run() {
  trap - EXIT INT TERM
  exec zsh -f "$TEST_DIR/fixtures/slash_ui.zsh" "$PROJECT_DIR" "$slash_base" "$slash_backend"
}
typeset -g slash_base='' slash_backend='' slash_tty=''
for slash_backend in stock auto; do
  slash_base="$TEST_TMP/slash-$slash_backend"
  TERM=xterm-256color zpty -b slash-ui slash_pty_run
  slash_pty_wait "$slash_base.state" ':0::100:24'
  assert_success "$slash_backend inline completion fixture opens an ordinary prompt" $?
  zpty -w -n slash-ui /co
  slash_pty_wait "$slash_base.state" '/co:6:/context:100:24'
  assert_success "$slash_backend typed slash prefix renders matching commands" $?
  zpty -w -n slash-ui $'\eOB'
  slash_pty_wait "$slash_base.state" '/co:6:/copy:100:24'
  assert_success "$slash_backend arrow key selects the next suggestion without changing the draft" $?
  assert_eq '›' "${mapfile[$slash_base.marker]:-}" "$slash_backend curses window displays the selected command marker"
  slash_tty=${mapfile[$slash_base.tty]:-}
  [[ -c $slash_tty ]] && command stty cols 60 rows 14 < "$slash_tty"
  slash_pty_wait "$slash_base.state" '/co:4:/copy:60:14'
  assert_success "$slash_backend resizing keeps the selected command and bounds the list height" $?
  zpty -w -n slash-ui $'\t'
  slash_pty_wait "$slash_base.state" '/copy:0::60:14'
  assert_success "$slash_backend Tab completes the selected command and closes the list" $?
  zpty -w -n slash-ui $'\x15/ho'
  slash_pty_wait "$slash_base.state" '/ho:2:/host :60:14'
  assert_success "$slash_backend argument-taking commands remain discoverable" $?
  zpty -w -n slash-ui $'\e'
  slash_pty_wait "$slash_base.state" '/ho:0::60:14'
  assert_success "$slash_backend Escape closes suggestions without discarding input" $?
  zpty -w -n slash-ui $'s\r'
  slash_pty_wait "$slash_base.state" '/host :0::60:14'
  assert_success "$slash_backend editing after Escape reopens completion and Enter inserts an argument prefix" $?
  zpty -w -n slash-ui $'\x15\e[200~/host example\nsecond line\e[201~'
  slash_pty_wait "$slash_base.state" $'/host example\nsecond line:0::60:14'
  assert_success "$slash_backend bracketed paste preserves multiline arguments without suggestions" $?
  zpty -w -n slash-ui $'\x04'
  slash_pty_wait "$slash_base.done" 1
  assert_success "$slash_backend inline completion restores the terminal on exit" $?
  zpty -d slash-ui
done
unfunction slash_pty_wait slash_pty_run
