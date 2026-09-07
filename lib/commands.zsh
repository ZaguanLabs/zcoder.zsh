# A trusted command catalog shared by palette filtering and dispatch. Queries
# only select catalog entries; they are never evaluated as shell commands.
typeset -ga COMMAND_LABELS=() COMMAND_TEXTS=() COMMAND_ACTIONS=() COMMAND_KEYWORDS=() COMMAND_MATCHES=()

_commands_add() {
  local scope="${4:-all}"
  [[ "$scope" == local && "${REMOTE_MODE:-local}" == client ]] && return 0
  [[ "$scope" == goals && "${REMOTE_MODE:-local}" == client && ${REMOTE_GOALS_SUPPORTED:-0} != 1 ]] && return 0
  COMMAND_LABELS+=("$1"); COMMAND_TEXTS+=("$2"); COMMAND_ACTIONS+=("$3"); COMMAND_KEYWORDS+=("${5:-}")
}

commands_init() {
  emulate -L zsh
  COMMAND_LABELS=(); COMMAND_TEXTS=(); COMMAND_ACTIONS=(); COMMAND_KEYWORDS=(); COMMAND_MATCHES=()
  _commands_add "Inspect context" /context run all 'tokens budget usage'
  _commands_add "Inspect queued messages" /queue run all 'steer follow-up pending input'
  _commands_add "Resume queued messages" '/queue resume' run all 'steer follow-up pending input'
  _commands_add "Inspect terminal" /terminal run all 'diagnostics capabilities synchronized output paste'
  _commands_add "Switch Ollama model" /model run local 'picker local'
  _commands_add "Change Ollama host" '/host ' draft local 'server connection'
  _commands_add "Start a new session" /new run all 'clear conversation job'
  _commands_add "Browse saved sessions" /sessions run all 'history jobs'
  _commands_add "Copy transcript" /copy run all 'clipboard export'
  _commands_add "Compact conversation" /compact run local 'context checkpoint'
  _commands_add "Show goal status" /goal run goals 'objective verifier'
  _commands_add "Start a persistent goal" '/goal ' draft goals 'objective work'
  _commands_add "Pause goal" '/goal pause' run goals 'stop'
  _commands_add "Resume goal" '/goal resume' run goals 'continue'
  _commands_add "Inspect MCP servers" /mcp run local 'connections tools restart'
  _commands_add "Reload MCP configuration" '/mcp reload' run local 'servers tools'
  _commands_add "List skills" /skills run local 'instructions'
  _commands_add "Activate a skill" '/skill ' draft local 'instructions'
  _commands_add "Reload skills" '/skills reload' run local 'instructions'
  _commands_add "Inspect project instructions" /instructions run local 'agents.md guidance'
  _commands_add "List local agents" /list-agents run local 'relay peers'
  _commands_add "Inspect incoming agent work" /agents run local 'relay queue status'
  _commands_add "Pause incoming agent work" '/agents pause' run local 'relay'
  _commands_add "Resume incoming agent work" '/agents resume' run local 'relay'
  _commands_add "Choose OpenCode model" /opencode-model run local 'provider'
  local provider=""
  for provider in claude codex agy opencode; do
    if [[ "${REMOTE_MODE:-local}" == client && ${REMOTE_HARNESS_DISCOVERY_SUPPORTED:-0} == 1 && ${DELEGATE_AVAILABLE[$provider]:-0} != 1 ]]; then
      continue
    fi
    _commands_add "Consult ${provider}" "/${provider} " draft all 'read-only review'
    [[ "${ZCODER_PROFILE:-coding}" == sysadmin ]] || _commands_add "Run ${provider} worker" "/${provider}! " draft all 'edit implement'
  done
  _commands_add "Show help" /help run all 'shortcuts commands'
  _commands_add "Quit zcoder" /quit run all 'exit'
}

_commands_score() {
  local needle="$1" haystack="$2" ch="" prefix="" rest="$2"
  local -i score=500
  if [[ -z "$needle" || "$haystack" == "$needle"* ]]; then REPLY=0; return 0; fi
  if [[ "$haystack" == *"$needle"* ]]; then
    prefix="${haystack%%"$needle"*}"; REPLY=$(( 50 + ${#prefix} )); return 0
  fi
  for ch in "${(@s::)needle}"; do
    [[ "$rest" == *"$ch"* ]] || return 1
    prefix="${rest%%"$ch"*}"
    (( score += ${#prefix} ))
    rest="${rest#*"$ch"}"
  done
  REPLY=$score
}

commands_match() {
  emulate -L zsh
  setopt extendedglob
  local query="${1:l}" record="" score="" ordinal="" candidate=""
  local -i i best candidate_score field
  local -a ranked=()
  query="${query##[[:space:]]#}"; query="${query%%[[:space:]]#}"
  COMMAND_MATCHES=()
  for (( i=1; i<=${#COMMAND_LABELS}; i++ )); do
    best=100000; field=0
    for candidate in "${COMMAND_LABELS[i]:l}" "${${COMMAND_TEXTS[i]#/}:l}" "${COMMAND_KEYWORDS[i]}"; do
      (( field++ ))
      _commands_score "$query" "$candidate" || continue
      candidate_score=$REPLY
      (( field == 3 && ${#query} > 0 )) && (( candidate_score+=1000 ))
      (( candidate_score < best )) && best=$candidate_score
    done
    (( best < 100000 )) || continue
    printf -v score '%06d' "$best"; printf -v ordinal '%06d' "$i"
    ranked+=("${score}:${ordinal}:${i}")
  done
  for record in "${(@o)ranked}"; do COMMAND_MATCHES+=("${record##*:}"); done
}

_ui_palette_draw() {
  local -a modal_items=() modal_item_attrs=()
  local index="" modal_hint="Type to filter · ↑/↓ Select · Enter Choose · Esc Close"
  local query_view="${palette_query[-$(( modal_w-6 )),-1]}"
  for index in "${COMMAND_MATCHES[@]}"; do
    modal_items+=("${COMMAND_LABELS[index]} · ${COMMAND_TEXTS[index]}")
  done
  ui_modal_text 1 "> ${query_view}" "bold white/black"
  _ui_modal_list_draw
  zcurses move overlay_win 1 $(( 4 + ${#query_view} ))
}

_ui_palette_input() {
  local previous_query="$palette_query" inserted=""
  # A bare Escape closes after one short input timeout. Delimited paste keeps
  # using the normal decoder without touching the main editor's decoder state.
  if [[ "$INPUT_TERM_STATE" == escape && -z "$modal_ch" && -z "$modal_key" ]]; then
    modal_done=1; return 0
  fi
  if [[ "$modal_ch" == $'\x03' || "$modal_ch" == $'\x10' ]]; then modal_done=1; return 0; fi
  if input_decode_terminal_event "$modal_ch" "$modal_key"; then
    if [[ "$INPUT_EVENT_ACTION" == paste ]]; then
      inserted="${INPUT_EVENT_TEXT//[^[:print:]]/ }"
      palette_query+="$inserted"
    fi
  elif _ui_modal_navigate ${#COMMAND_MATCHES}; then return 0
  elif [[ "$modal_key" == BACKSPACE || "$modal_ch" == $'\x7f' || "$modal_ch" == $'\b' ]]; then
    palette_query="${palette_query[1,-2]}"
  elif [[ "$modal_ch" == $'\x15' ]]; then palette_query=""
  elif [[ "$modal_ch" == $'\r' || "$modal_ch" == $'\n' || "$modal_key" == ENTER || "$modal_key" == PADENTER ]]; then
    if (( ${#COMMAND_MATCHES} > 0 )); then
      modal_result="${COMMAND_MATCHES[modal_selected]}"; modal_accepted=1; modal_done=1
    fi
  elif [[ -n "$modal_ch" && "$modal_ch" == [[:print:]] ]]; then palette_query+="$modal_ch"
  fi
  palette_query="${palette_query[1,128]}"
  if [[ "$palette_query" != "$previous_query" ]]; then
    commands_match "$palette_query"
    modal_selected=1; modal_scroll=1; modal_dirty=1
  fi
  return 0
}

ui_command_palette() {
  emulate -L zsh
  setopt extendedglob
  local palette_query="" command_text=""
  local INPUT_TERM_STATE=normal INPUT_ESCAPE_BUF="" INPUT_PASTE_BUF="" INPUT_EVENT_ACTION="" INPUT_EVENT_TEXT=""
  local -i chosen=0
  commands_init; commands_match ""
  ui_modal_run "Commands" _ui_palette_draw _ui_palette_input 20 88 || return 0
  chosen=$REPLY
  (( chosen > 0 && chosen <= ${#COMMAND_TEXTS} )) || return 1
  command_text="${COMMAND_TEXTS[chosen]}"
  if [[ "${COMMAND_ACTIONS[chosen]}" == draft ]]; then
    INPUT_BUF="${command_text}${INPUT_BUF}"; INPUT_POS=${#INPUT_BUF}; INPUT_GOAL_COL=-1
    UI_FOCUS=input
    ui_input_changed
    ui_refresh_all
  else
    handle_slash_command "$command_text"
  fi
}

ui_context_lines() {
  emulate -L zsh
  local -i capacity=${AGENT_CONTEXT_WINDOW:-0} estimate=${AGENT_ESTIMATED_TOKENS:-0} i cells limit
  local label="" bar="" value="" window_note="configured" last_prompt="not reported yet"
  UI_CONTEXT_LINES=()
  if [[ "${REMOTE_MODE:-local}" == client ]]; then
    UI_CONTEXT_LINES=("Model: ${ZCODER_MODEL}" "Server: ${REMOTE_SERVER_NAME:-remote}"
      "" "Context accounting is maintained by the server." "This connection does not expose a component breakdown.")
    return 0
  fi
  [[ "$ZCODER_CONTEXT_WINDOW" == auto ]] && window_note="Ollama allocation"
  (( ${AGENT_CONTEXT_DISCOVERY_PENDING:-0} )) && window_note="fallback estimate; allocation not reported"
  (( ${AGENT_LAST_PROMPT_TOKENS:-0} > 0 )) && last_prompt="$AGENT_LAST_PROMPT_TOKENS tokens"
  agent_compaction_limit; limit=$REPLY
  UI_CONTEXT_LINES=("Estimated next prompt: ${estimate} tokens"
    "Context window: ${capacity} (${window_note})" "Last Ollama prompt: ${last_prompt}"
    "Last Ollama output: ${AGENT_LAST_OUTPUT_TOKENS:-0} tokens" ""
    "Component estimates (not an exact additive breakdown):")
  for (( i=1; i<=${#AGENT_CONTEXT_COMPONENT_VALUES}; i++ )); do
    value="${AGENT_CONTEXT_COMPONENT_VALUES[i]}"; cells=0
    (( capacity > 0 )) && cells=$(( value * 16 / capacity ))
    (( value > 0 && cells == 0 )) && cells=1
    (( cells > 16 )) && cells=16
    bar="${(pl:cells::#:)}"
    zcoder_pad "$bar" 16; bar="$REPLY"
    zcoder_pad "${AGENT_CONTEXT_COMPONENT_LABELS[i]}" 20; label="$REPLY"
    UI_CONTEXT_LINES+=("${label} ${value}  [${bar}]")
  done
  UI_CONTEXT_LINES+=("" "Bars are scaled to the context window."
    "Compaction threshold: ${limit} tokens; setting ${ZCODER_COMPACT_PERCENT}%."
    "Saved checkpoints: ${AGENT_COMPACTION_COUNT:-0}")
}

_ui_context_draw() {
  local line=""
  modal_lines=()
  for line in "${UI_CONTEXT_LINES[@]}"; do
    zcoder_terminal_safe "$line"
    zcoder_wrap "$REPLY" $(( modal_w-4 ))
    modal_lines+=("${ZCODER_WRAPPED[@]}")
  done
  _ui_modal_view_draw
}

ui_show_context() {
  local -a modal_lines=()
  if [[ "${REMOTE_MODE:-local}" != client ]]; then agent_context_summary || return $?; fi
  ui_context_lines
  modal_lines=("${UI_CONTEXT_LINES[@]}")
  ui_modal_run "Context usage" _ui_context_draw _ui_modal_view_input 24 92 || true
}

typeset -ga UI_CONTEXT_LINES=()

_ui_terminal_draw() {
  local line='' paste_state=inactive
  [[ -n "$TERMINAL_FD" ]] && paste_state=enabled
  terminal_poll
  terminal_inspected_state="$TERMINAL_SYNC_STATE"
  local -a lines=("Terminal: ${TERM:-unset}" "Size: ${SCREEN_W} columns × ${SCREEN_H} rows"
    "Synchronized output: ${TERMINAL_SYNC_STATE}" "Policy: ${TERMINAL_SYNC_POLICY}"
    "Bracketed paste: ${paste_state}" ""
    "ZCODER_SYNC_OUTPUT=auto queries terminal support once on UI entry."
    "No reply within one second keeps ordinary curses updates."
    "Use false to disable, or true to force support for a known terminal."
    "" "Detection uses the terminal's reply, including through a multiplexer.")
  modal_lines=()
  for line in "${lines[@]}"; do
    zcoder_terminal_safe "$line"
    zcoder_wrap "$REPLY" $(( modal_w-4 ))
    modal_lines+=("${ZCODER_WRAPPED[@]}")
  done
  _ui_modal_view_draw
}

_ui_terminal_input() {
  [[ "$terminal_inspected_state" != "$TERMINAL_SYNC_STATE" ]] && modal_dirty=1
  _ui_modal_view_input
}

ui_show_terminal() {
  local -a modal_lines=()
  local terminal_inspected_state=''
  ui_modal_run "Terminal diagnostics" _ui_terminal_draw _ui_terminal_input 20 88 || true
}
