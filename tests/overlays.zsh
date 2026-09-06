# The parent suite supplies assertions and a curses recorder.
functions[_overlay_saved_curses]="${functions[zcurses]}"
functions[_overlay_saved_resize]="${functions[ui_poll_resize]}"
typeset -ga OVERLAY_CHARS=() OVERLAY_KEYS=() OVERLAY_CALLS=()
typeset -gi OVERLAY_CURSOR=0 OVERLAY_ADD_FAIL=0 OVERLAY_RESIZE_W=80 OVERLAY_RESIZE_H=24
zcurses() {
  OVERLAY_CALLS+=("${(j: :)@}")
  if [[ "$1" == addwin && "$2" == overlay_win ]] && (( OVERLAY_ADD_FAIL )); then return 1; fi
  if [[ "$1" == input ]]; then
    (( OVERLAY_CURSOR++ ))
    local next_ch="${OVERLAY_CHARS[OVERLAY_CURSOR]:-}" next_key="${OVERLAY_KEYS[OVERLAY_CURSOR]:-}"
    if (( OVERLAY_CURSOR > ${#OVERLAY_CHARS} && OVERLAY_CURSOR > ${#OVERLAY_KEYS} )); then
      if [[ "$TERMINAL_SEQUENCE" == $'\e' ]]; then TERMINAL_ESCAPE_AT=0
      elif [[ "${INPUT_TERM_STATE:-normal}" != escape ]]; then next_ch=$'\e'
      fi
    fi
    printf -v "$3" '%s' "$next_ch"
    printf -v "$4" '%s' "$next_key"
    (( OVERLAY_CURSOR > 200 )) && modal_done=1
  fi
  return 0
}
ui_poll_resize() {
  if (( UI_RESIZE_PENDING )); then
    SCREEN_W=$OVERLAY_RESIZE_W; SCREEN_H=$OVERLAY_RESIZE_H; UI_RESIZE_PENDING=0
  fi
  return 0
}
overlay_keys() {
  OVERLAY_CURSOR=0; OVERLAY_CALLS=(); OVERLAY_CHARS=(); OVERLAY_KEYS=()
  TERMINAL_SEQUENCE=''; TERMINAL_INPUT_QUEUE=()
}
UI_ACTIVE=1; STATE_ENABLED=0; SCREEN_W=80; SCREEN_H=24; SIDE_W=0; UI_RESIZE_PENDING=0
INPUT_BUF="unfinished prompt"; INPUT_POS=6; UI_FOCUS=input
overlay_keys
OVERLAY_KEYS=(DOWN ENTER)
ui_modal_choose "Models" alpha alpha beta gamma
assert_success "shared picker accepts a selected item" $?
assert_eq "2" "$REPLY" "shared picker returns the chosen index"
assert_eq "0" "$UI_MODAL_ACTIVE" "accepted modals release their active state"
assert_contains "${(F)OVERLAY_CALLS}" "delwin overlay_win" "accepted modals delete their window"
assert_contains "${(F)OVERLAY_CALLS}" "touch top_win chat_win input_win foot_win" "closing an overlay marks the underlying windows for restoration"
assert_eq "unfinished prompt" "$INPUT_BUF" "picker use preserves the editor draft"
assert_eq "6" "$INPUT_POS" "picker use preserves the editor cursor"

overlay_keys
OVERLAY_CHARS=($'\e')
ui_modal_choose "Models" alpha alpha beta
assert_failure "Escape cancels a shared picker" $?
assert_eq "" "$REPLY" "cancelled pickers return no selection"
OVERLAY_ADD_FAIL=1
ui_modal_choose "Models" alpha alpha beta
assert_failure "failed modal creation cannot accept a choice" $?
assert_eq "0" "$UI_MODAL_ACTIVE" "failed modal creation releases ownership"
OVERLAY_ADD_FAIL=0

overlay_keys
OVERLAY_KEYS=(RESIZE DOWN ENTER)
OVERLAY_RESIZE_W=60; OVERLAY_RESIZE_H=14
ui_modal_choose "Models" alpha alpha beta
assert_eq "2" "$REPLY" "a resized picker still accepts the intended selection"
assert_contains "${(F)OVERLAY_CALLS}" "addwin overlay_win 12 58 1 1" "modal geometry is rebuilt within the resized terminal"
SCREEN_W=80; SCREEN_H=24

overlay_keys
OVERLAY_CHARS=(a n)
ZCODER_PROFILE=coding
ui_confirm_external_action 'Publish the exact change'
assert_eq "n" "$REPLY" "external approvals reject session-wide acceptance"
overlay_keys
OVERLAY_CHARS=(a y)
ZCODER_PROFILE=sysadmin
ui_confirm_command 'print approved'
assert_eq "y" "$REPLY" "sysadmin approval ignores session-wide acceptance and waits for a per-call answer"
overlay_keys
OVERLAY_CHARS=(a)
ZCODER_PROFILE=coding
ui_confirm_command 'print approved'
assert_eq "a" "$REPLY" "coding approval retains its existing session-approval choice"
SCREEN_W=20
ui_confirm_command 'print rejected'
assert_failure "approval fails closed when the terminal cannot fit the dialog" $?
assert_eq "n" "$REPLY" "an unavailable approval dialog never grants permission"
SCREEN_W=80
overlay_keys
OVERLAY_CHARS=("" n); OVERLAY_KEYS=(NPAGE '')
long_approval=""
for approval_line in {1..32}; do long_approval+="action line ${approval_line}"$'\n'; done
ui_confirm_command "$long_approval"
assert_contains "${(F)OVERLAY_CALLS}" "action line 20" "approval details can scroll beyond the first page"
assert_eq "n" "$REPLY" "scrolling an approval does not approve it"

REMOTE_MODE=local
commands_init
commands_match ctx
assert_eq "/context" "${COMMAND_TEXTS[COMMAND_MATCHES[1]]}" "fuzzy command matching prioritizes the actual command name"
commands_match 'COMPACT'
assert_eq "/compact" "${COMMAND_TEXTS[COMMAND_MATCHES[1]]}" "command matching ignores case"
commands_match '*'
assert_eq "0" "${#COMMAND_MATCHES}" "query metacharacters are matched literally"
commands_match '$(print injected)'
assert_eq "0" "${#COMMAND_MATCHES}" "palette queries cannot become shell code"
REMOTE_MODE=client; REMOTE_GOALS_SUPPORTED=0
commands_init; commands_match ''
assert_not_contains "${(F)COMMAND_TEXTS}" /compact "remote palettes omit unavailable local compaction"
assert_not_contains "${(F)COMMAND_TEXTS}" /goal "remote palettes omit unsupported goals"
assert_contains "${(F)COMMAND_TEXTS}" /context "remote palettes retain the context information view"
assert_contains "${(F)COMMAND_TEXTS}" '/codex ' "remote palettes retain external consultation commands on legacy servers"
REMOTE_HARNESS_DISCOVERY_SUPPORTED=1; DELEGATE_AVAILABLE=(codex 1)
commands_init
assert_contains "${(F)COMMAND_TEXTS}" '/codex ' "remote palettes include advertised harnesses"
assert_not_contains "${(F)COMMAND_TEXTS}" '/claude ' "remote palettes omit unavailable advertised harnesses"
REMOTE_HARNESS_DISCOVERY_SUPPORTED=0
REMOTE_MODE=local
ZCODER_PROFILE=sysadmin
commands_init
assert_not_contains "${(F)COMMAND_TEXTS}" '/codex!' "sysadmin palettes omit editing workers"
assert_contains "${(F)COMMAND_TEXTS}" '/codex ' "sysadmin palettes retain consultations"
ZCODER_PROFILE=coding

# A selected command goes through the existing dispatcher only after closing.
typeset -g OVERLAY_DISPATCHED="" OVERLAY_DISPATCH_ACTIVE=""
handle_slash_command() { OVERLAY_DISPATCHED="$1"; OVERLAY_DISPATCH_ACTIVE="$UI_MODAL_ACTIVE"; }
overlay_keys
palette_test_query=context
OVERLAY_CHARS=("${(@s::)palette_test_query}" $'\r')
INPUT_TERM_STATE=normal
ui_command_palette
assert_eq "/context" "$OVERLAY_DISPATCHED" "palette selection uses the slash-command dispatcher"
assert_eq "0" "$OVERLAY_DISPATCH_ACTIVE" "palette closes before opening another command view"
overlay_keys
palette_test_query='Change Ollama host'
OVERLAY_CHARS=("${(@s::)palette_test_query}" $'\r')
OVERLAY_DISPATCHED=""
INPUT_BUF=localhost; INPUT_POS=3; UI_FOCUS=chat
ui_command_palette
assert_eq "/host localhost" "$INPUT_BUF" "argument-taking commands prepare an editable prompt using the existing draft"
assert_eq "" "$OVERLAY_DISPATCHED" "draft commands are never executed on selection"
assert_eq input "$UI_FOCUS" "draft commands return focus to the editor"
overlay_keys
OVERLAY_CHARS=($'\e' '')
INPUT_BUF="keep this"; INPUT_POS=4
ui_command_palette
assert_eq "keep this" "$INPUT_BUF" "cancelling the palette preserves the draft"
assert_eq "4" "$INPUT_POS" "cancelling the palette preserves cursor position"
unfunction handle_slash_command

AGENT_CONTEXT_WINDOW=1000; AGENT_ESTIMATED_TOKENS=350; ZCODER_COMPACT_PERCENT=85
AGENT_COMPACTION_REARM_TOKENS=900; AGENT_CONTEXT_DISCOVERY_PENDING=1
AGENT_CONTEXT_COMPONENT_LABELS=("Base" "Tools")
AGENT_CONTEXT_COMPONENT_VALUES=(0 2000)
AGENT_LAST_PROMPT_TOKENS=123; AGENT_LAST_OUTPUT_TOKENS=27
ui_context_lines
assert_contains "${(F)UI_CONTEXT_LINES}" "Estimated next prompt: 350" "context inspector labels the next-prompt estimate"
assert_contains "${(F)UI_CONTEXT_LINES}" "Last Ollama prompt: 123" "context inspector distinguishes reported prompt usage"
assert_contains "${(F)UI_CONTEXT_LINES}" "fallback estimate" "unknown allocations are labelled as fallback estimates"
assert_contains "${(F)UI_CONTEXT_LINES}" '2000  [################]' "context bars are bounded even when a component exceeds capacity"
assert_contains "${(F)UI_CONTEXT_LINES}" "threshold: 900" "context inspector uses the effective compaction threshold including rearming"
REMOTE_MODE=client
ui_context_lines
assert_contains "${(F)UI_CONTEXT_LINES}" "maintained by the server" "remote context inspection explains unavailable accounting"
assert_not_contains "${(F)UI_CONTEXT_LINES}" "350" "remote context inspection never substitutes local counters"
REMOTE_MODE=local

functions[zcurses]="${functions[_overlay_saved_curses]}"
functions[ui_poll_resize]="${functions[_overlay_saved_resize]}"
unfunction _overlay_saved_curses _overlay_saved_resize overlay_keys
SCREEN_W=80; SCREEN_H=24; UI_RESIZE_PENDING=0; UI_FOCUS=input
MOCK_ZCURSES_CALLS=()

# Exercise actual ncurses windows, input decoding, and resizing in a PTY.
typeset -g overlay_pty_base="$TEST_TMP/overlay-pty" overlay_pty_output="" overlay_pty_chunk=""
overlay_pty_wait() {
  local file="$1" expected="$2"
  local -F deadline=$(( EPOCHREALTIME + 5.0 ))
  while (( EPOCHREALTIME < deadline )); do
    while zpty -r overlays-ui overlay_pty_chunk 2>/dev/null; do
      overlay_pty_output+="$overlay_pty_chunk"
    done
    [[ "${mapfile[$file]:-}" == "$expected"* ]] && return 0
    zselect -t 1 2>/dev/null
  done
  return 1
}
overlay_pty_run() {
  trap - EXIT INT TERM
  exec zsh -f "$TEST_DIR/fixtures/overlays_ui.zsh" "$PROJECT_DIR" "$overlay_pty_base"
}
TERM=xterm-256color zpty -b overlays-ui overlay_pty_run
assert_success "real curses modal fixture starts in a PTY" $?
overlay_pty_wait "$overlay_pty_base.palette_draw" ':80'
assert_success "real curses palette renders its initial frame" $?
assert_eq "1" "${mapfile[$overlay_pty_base.warmup_done]:-}" "local warm-up completes while the palette retains modal ownership"
zpty -w -n overlays-ui host
overlay_pty_wait "$overlay_pty_base.palette_draw" 'host:80'
assert_success "real palette filters typed input" $?
overlay_pty_tty="${mapfile[$overlay_pty_base.tty]:-}"
if [[ -n "$overlay_pty_tty" && -c "$overlay_pty_tty" ]]; then
  command stty cols 60 rows 18 < "$overlay_pty_tty"
fi
overlay_pty_wait "$overlay_pty_base.palette_draw" 'host:60'
assert_success "real modal resize preserves the search query" $?
zpty -w -n overlays-ui $'\r'
overlay_pty_wait "$overlay_pty_base.palette_done" '/host draft text:16::0'
assert_success "real palette prepares a draft and releases the overlay" $?
overlay_pty_wait "$overlay_pty_base.view_draw" 'Context usage:60'
assert_success "real context inspector opens after the palette" $?
zpty -w -n overlays-ui $'\e'
overlay_pty_wait "$overlay_pty_base.context_done" '1:0'
assert_success "context inspection takes one snapshot and closes cleanly" $?
overlay_pty_wait "$overlay_pty_base.view_draw" 'External action confirmation:60'
assert_success "external confirmation uses the shared modal" $?
zpty -w -n overlays-ui an
overlay_pty_wait "$overlay_pty_base.approval_done" n
assert_success "real external confirmation ignores session approval and accepts denial" $?
overlay_pty_wait "$overlay_pty_base.list_draw" 'Select Ollama Model:1:60'
assert_success "real model picker opens in the resized terminal" $?
zpty -w -n overlays-ui $'\eOB\r'
overlay_pty_wait "$overlay_pty_base.model_done" beta
assert_success "real model picker applies the selected model" $?
overlay_pty_wait "$overlay_pty_base.done" 1
overlay_pty_exit_status=$?
assert_success "real modal fixture restores the terminal on exit" "$overlay_pty_exit_status"
if (( overlay_pty_exit_status )); then
  print -r -- "Modal PTY output tail: ${(V)overlay_pty_output[-1000,-1]}"
fi
zpty -d overlays-ui
unfunction overlay_pty_wait overlay_pty_run
