# A trusted command catalog shared by palette filtering and dispatch. Queries
# only select catalog entries; they are never evaluated as shell commands.
typeset -ga COMMAND_LABELS=() COMMAND_TEXTS=() COMMAND_ACTIONS=() COMMAND_KEYWORDS=() COMMAND_MATCHES=()
typeset -ga UI_SLASH_TEXTS=() UI_SLASH_LABELS=()
typeset -g UI_SLASH_BUFFER='' UI_SLASH_DISMISSED='' UI_SLASH_CACHE_KEY=''
typeset -gF UI_SLASH_ESCAPE_AT=0

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
  _commands_add "Drop a queued message" '/queue drop ' draft all 'pending input discard'
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
  _commands_add "Clear goal" '/goal clear' run goals 'objective'
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
  _commands_add "Open command palette" /commands run all 'search shortcuts'
  _commands_add "Quit zcoder" /quit run all 'exit'
}

# Inline completion uses literal command prefixes and copies its matches so a
# modal palette can rebuild the shared catalog without changing the draft list.
ui_slash_update() {
  emulate -L zsh
  UI_SLASH_ROWS=0
  if [[ "$INPUT_BUF" != "$UI_SLASH_BUFFER" ]]; then
    UI_SLASH_BUFFER=$INPUT_BUF; UI_SLASH_DISMISSED=''; UI_SLASH_CACHE_KEY=''
    UI_SLASH_SELECTED=1
  fi
  [[ "$UI_FOCUS" == input && "$INPUT_BUF" == /* && "$INPUT_BUF" != *[[:space:]]* &&
     "$INPUT_BUF" != "$UI_SLASH_DISMISSED" ]] || return 0
  (( INPUT_POS == ${#INPUT_BUF} && UI_ACTIVITY_DEPTH == 0 )) || return 0
  local cache_key="$INPUT_BUF:${REMOTE_MODE:-local}:${ZCODER_PROFILE:-coding}:${REMOTE_GOALS_SUPPORTED:-0}:${REMOTE_HARNESS_DISCOVERY_SUPPORTED:-0}:${DELEGATE_AVAILABLE[claude]:-0}:${DELEGATE_AVAILABLE[codex]:-0}:${DELEGATE_AVAILABLE[agy]:-0}:${DELEGATE_AVAILABLE[opencode]:-0}"
  local -i i available=$(( SCREEN_H - TOP_H - FOOT_H - 6 ))
  if [[ "$cache_key" != "$UI_SLASH_CACHE_KEY" ]]; then
    commands_init
    UI_SLASH_TEXTS=(); UI_SLASH_LABELS=(); UI_SLASH_SELECTED=1
    for (( i=1; i<=${#COMMAND_TEXTS}; i++ )); do
      [[ "${COMMAND_TEXTS[i]:l}" == "${INPUT_BUF:l}"* ]] || continue
      UI_SLASH_TEXTS+=("${COMMAND_TEXTS[i]}"); UI_SLASH_LABELS+=("${COMMAND_LABELS[i]}")
      [[ "${COMMAND_TEXTS[i]}" == "$INPUT_BUF" ]] && UI_SLASH_SELECTED=${#UI_SLASH_TEXTS}
    done
    UI_SLASH_CACHE_KEY=$cache_key
  fi
  (( ${#UI_SLASH_TEXTS} > 0 && available >= 2 )) || return 0
  UI_SLASH_ROWS=$(( ${#UI_SLASH_TEXTS} + 1 ))
  (( UI_SLASH_ROWS > 6 )) && UI_SLASH_ROWS=6
  (( UI_SLASH_ROWS > available )) && UI_SLASH_ROWS=$available
  return 0
}

ui_slash_input() {
  emulate -L zsh
  local ch="$1" key="$2" command_text=''
  (( UI_SLASH_ROWS > 0 && UI_ACTIVITY_DEPTH == 0 && ! ${UI_MODAL_ACTIVE:-0} )) || return 1
  [[ "$UI_FOCUS" == input ]] || return 1
  # Enhanced newline and structured paste events belong to the editor decoder.
  [[ "$key" == SENTER || "$key" == PASTE* ]] && return 1
  # Let the shared decoder distinguish paste/newline sequences from bare Esc.
  if [[ "$INPUT_TERM_STATE" == escape && "$INPUT_ESCAPE_BUF" == $'\e' && -z "$ch$key" ]] &&
     (( EPOCHREALTIME - UI_SLASH_ESCAPE_AT >= 0.05 )); then
    INPUT_TERM_STATE=normal; INPUT_ESCAPE_BUF=''
    UI_SLASH_DISMISSED=$INPUT_BUF
    ui_input_changed
    return 0
  fi
  [[ "$INPUT_TERM_STATE" == normal ]] || return 1
  if [[ "$ch" == $'\e' ]]; then UI_SLASH_ESCAPE_AT=$EPOCHREALTIME; return 1; fi
  if [[ "$key" == UP ]]; then
    (( UI_SLASH_SELECTED-- ))
    (( UI_SLASH_SELECTED < 1 )) && UI_SLASH_SELECTED=${#UI_SLASH_TEXTS}
  elif [[ "$key" == DOWN ]]; then
    (( UI_SLASH_SELECTED++ ))
    (( UI_SLASH_SELECTED > ${#UI_SLASH_TEXTS} )) && UI_SLASH_SELECTED=1
  elif [[ "$key" == TAB || "$ch" == $'\t' || "$key" == ENTER || "$key" == PADENTER || "$ch" == $'\r' || "$ch" == $'\n' ]]; then
    command_text=${UI_SLASH_TEXTS[UI_SLASH_SELECTED]}
    # A fully typed command keeps the ordinary single-Enter dispatch behavior.
    [[ "$INPUT_BUF" == "$command_text" && "$key" != TAB && "$ch" != $'\t' ]] && return 1
    INPUT_BUF=$command_text; INPUT_POS=${#INPUT_BUF}; INPUT_GOAL_COL=-1
    UI_SLASH_BUFFER=$INPUT_BUF; UI_SLASH_DISMISSED=$INPUT_BUF
  else
    return 1
  fi
  ui_input_changed
  return 0
}

ui_slash_draw() {
  emulate -L zsh
  (( UI_SLASH_ROWS > 0 )) || return 0
  local -i capacity=$(( UI_SLASH_ROWS - 1 )) first=1 row i
  local text=''
  (( UI_SLASH_SELECTED > capacity )) && first=$(( UI_SLASH_SELECTED - capacity + 1 ))
  zcoder_curses move input_win $(( INPUT_VISIBLE_ROWS + 1 )) 2
  ui_attr input_win dim cyan/black
  zcoder_clip "↑/↓ Select · Tab/Enter Complete · Esc Close · $UI_SLASH_SELECTED/${#UI_SLASH_TEXTS}" $(( SCREEN_W - 4 ))
  zcoder_curses string input_win "$REPLY"
  for (( row=0; row<capacity; row++ )); do
    i=$(( first + row ))
    text="  ${UI_SLASH_TEXTS[i]} · ${UI_SLASH_LABELS[i]}"
    if (( i == UI_SLASH_SELECTED )); then
      text="› ${UI_SLASH_TEXTS[i]} · ${UI_SLASH_LABELS[i]}"
      ui_attr input_win -dim bold accent/surface
    else
      ui_attr input_win -dim -bold white/black
    fi
    zcoder_curses move input_win $(( INPUT_VISIBLE_ROWS + 2 + row )) 2
    zcoder_clip "$text" $(( SCREEN_W - 4 )); zcoder_curses string input_win "$REPLY"
  done
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
  zcoder_curses move overlay_win 1 $(( 4 + ${#query_view} ))
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
    elif [[ "$INPUT_EVENT_ACTION" == paste_rejected ]]; then
      ui_status_notice warning "$INPUT_EVENT_TEXT"
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
    "Context window: ${capacity} (${window_note})" "Last reported Ollama prompt: ${last_prompt}"
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

ui_show_help() {
  emulate -L zsh
  local availability=$1 id kind text body=''
  # One source for the structured reader and plain-text transcript fallback.
  local -a blocks=(
    prompt heading 'Prompt editing'
    send bullet 'Enter: Send a prompt, or steer an active turn.'
    queue_key bullet 'Ctrl+G: Queue a follow-up while busy.'
    newline bullet 'Shift+Enter: Insert a newline. Use Alt+Enter if your terminal does not report Shift+Enter separately.'
    paste bullet 'Paste: Multiline text keeps its formatting.'
    stop bullet 'Escape: Stop a running Ollama response, local tool wait, or external delegate.'
    clear bullet 'Ctrl+U: Clear input.'
    word bullet 'Ctrl+W: Delete a word.'
    exit bullet 'Ctrl+Q: Exit.'

    navigation heading 'Navigation and copying'
    sidebar bullet 'Ctrl+B: Hide or show the sidebar.'
    focus bullet 'Tab: Move focus between the prompt, visible session sidebar, and transcript.'
    saved_jobs bullet 'Up/Down in the sidebar: Resume another saved job.'
    copy bullet 'Ctrl+Y or /copy: Open a stable plain-text view for terminal selection and copying.'
    scroll bullet 'PgUp/PgDn: Scroll.'

    commands heading 'Commands and transcript'
    suggestions bullet '/ in an idle prompt: Show slash suggestions. Up/Down selects; Tab or Enter completes; Escape closes. Enter on a complete command runs it.'
    palette bullet 'Ctrl+P or /commands: Open the searchable command palette.'
    select_entry bullet 'Up/Down or k/j with transcript focus: Select an entry.'
    first_last bullet 'Home/End with transcript focus: Select the first or last entry.'
    fold bullet 'Enter/Space with transcript focus: Fold or unfold the entry body.'
    reasoning bullet 'Ctrl+R: Toggle selected reasoning, or the latest reasoning when editing the prompt.'

    tools heading 'Tools and sessions'
    goals subheading 'Persistent goals'
    goal_start bullet '/goal OBJECTIVE: Run a persistent, independently verified goal.'
    goal_tokens bullet '/goal --tokens N OBJECTIVE: Set a token limit for the goal.'
    goal_status bullet '/goal: Show goal status.'
    goal_control bullet '/goal pause | /goal resume | /goal clear: Control the current goal.'

    delegates subheading 'External agents'
    claude bullet '/claude REQUEST: Ask Claude for a read-only consultation.'
    codex bullet '/codex REQUEST: Ask Codex for a read-only consultation.'
    agy bullet '/agy REQUEST: Ask Antigravity for a read-only consultation.'
    opencode bullet '/opencode REQUEST: Ask OpenCode for a read-only consultation.'
    workers bullet 'Add ! for a workspace-editing worker, for example /codex! REQUEST.'
    opencode_model bullet '/opencode with no request: Select its provider/model.'
    local_agents bullet '/list-agents: List other local zcoder instances.'
    incoming bullet '/agents pause | /agents resume: Pause or resume incoming work.'

    skills subheading 'Skills and MCP'
    skill_list bullet '/skills: List installed Agent Skills.'
    skill_activate bullet '/skill NAME: Activate a skill. You can also prefix a request with $skill-name.'
    mcp bullet '/mcp: Show configured servers and live status.'
    mcp_reload bullet '/mcp reload: Reload MCP configuration.'

    models subheading 'Models and environment'
    model bullet '/model or Ctrl+O: Open the Ollama model picker.'
    host bullet '/host HOST: Change the Ollama host.'
    instructions bullet '/instructions: List active AGENTS.md files.'
    terminal bullet '/terminal: Show terminal capabilities.'

    sessions subheading 'Sessions and context'
    session_list bullet '/sessions: Focus saved jobs.'
    new_session bullet '/new or Ctrl+N: Start a new saved session.'
    compact bullet '/compact: Create a context checkpoint.'
    context bullet '/context: Open the context usage inspector.'
    queue bullet '/queue: List pending input.'
    queue_resume bullet '/queue resume: Restart pending input.'
    queue_drop bullet '/queue drop ID: Discard a queued message.'
  )
  for id kind text in "${blocks[@]}"; do
    if [[ $kind == (heading|subheading) ]]; then
      [[ -n $body ]] && body+=$'\n'
      body+="$text"$'\n'
    else
      body+="- $text"$'\n'
    fi
  done
  body=${body%$'\n'}
  blocks+=(availability heading 'Available agent runtimes' runtimes paragraph "$availability")
  if (( UI_ACTIVE )) && ui_document_view 'Help' "${blocks[@]}"; then
    return 0
  fi
  # Preserve access to help outside curses or when a terminal cannot fit a view.
  ui_append_message system "$body"
  ui_append_message system "$availability"
}

typeset -ga UI_CONTEXT_LINES=()

_ui_terminal_draw() {
  local line='' paste_state=inactive geometry_state=unprobed features_state=unknown
  local -a reply=()
  if zcoder_curses_features; then
    features_state="${(j:, :)reply}"
    [[ -n $features_state ]] || features_state=none
  fi
  local -a terminal_features=("${reply[@]}")
  case $UI_NATIVE_GEOMETRY in
    0) geometry_state='stty fallback' ;;
    1) geometry_state='native (no subprocess)' ;;
  esac
  [[ -n "$TERMINAL_FD" ]] && paste_state=enabled
  (( TERMINAL_NATIVE_PASTE )) && paste_state='native chunks (1 MiB limit)'
  terminal_poll
  terminal_inspected_state="$TERMINAL_SYNC_STATE"
  if [[ -n ${UI_COLOR_INFO[initialized]:-} ]]; then
    zcoder_curses colorinfo UI_COLOR_INFO 2>/dev/null
  fi
  local clipping_state='Zsh fallback'
  (( UI_STYLED_SPANS && UI_CLIPPED_SPANS )) && clipping_state='native cell budget'
  local input_state='curses default'
  (( TERMINAL_NOREFRESH_INPUT )) && input_state='explicit refresh (zdraw)'
  (( TERMINAL_EVENT_POLL )) && input_state+=' · activity polling'
  local frame_state='ordinary refresh' query_state='Zsh decoder'
  if (( TERMINAL_NATIVE_SYNC )); then
    frame_state='native stage/present'
  elif (( TERMINAL_SYNC_ENABLED )); then
    frame_state='Zsh frame markers'
  fi
  (( TERMINAL_NATIVE_QUERY )) && query_state='native event queue'
  local editing_state='character offsets (fallback)'
  (( INPUT_GRAPHEME )) && editing_state='grapheme boundaries (native)'
  local -a lines=("Terminal: ${TERM:-unset}" "Size: ${SCREEN_W} columns × ${SCREEN_H} rows"
    "Curses module: ${ZCODER_CURSES_BACKEND:-preloaded}" "Resize queries: ${geometry_state}"
    "Compiled features: ${features_state}"
    "Input presentation: ${input_state}"
    "Palette: ${UI_COLOR_MODE} · Borders: ${UI_BORDER_MODE}"
    "Styled rows: ${UI_STYLED_SPANS} · Wide spans: ${UI_WIDE_SPANS} · Row fallbacks: ${UI_SPAN_FALLBACKS}"
    "Row clipping: ${clipping_state}"
    "RGB supported/enabled: ${UI_COLOR_INFO[truecolor_supported]:-unknown}/${UI_COLOR_INFO[truecolor_enabled]:-unknown}"
    "Color pairs used/free: ${UI_COLOR_INFO[pairs_used]:-unknown}/${UI_COLOR_INFO[pairs_free]:-unknown}"
    "Synchronized output: ${TERMINAL_SYNC_STATE}" "Policy: ${TERMINAL_SYNC_POLICY}"
    "Frame presentation: ${frame_state}" "Reply decoder: ${query_state}"
    "Prompt editing: ${editing_state}"
    "Bracketed paste: ${paste_state}")
  local -A terminal_caps=() terminal_resources=()
  local capability=''
  if (( ${terminal_features[(Ie)capability_evidence]} )); then
    if zcoder_curses capabilities terminal_caps 2>/dev/null; then
      lines+=("" 'Capability evidence (support / enabled / source):')
      for capability in colors truecolor wide_text norefresh_events suspend_resume streaming_paste focus_events synchronized_output keyboard_events; do
        lines+=("${capability}: ${terminal_caps[$capability,support]:-unknown} / ${terminal_caps[$capability,enabled]:-unknown} / ${terminal_caps[$capability,source]:-none}")
      done
      lines+=("Sync report/query: ${terminal_caps[synchronized_output,reported]:-unknown} / ${terminal_caps[synchronized_output,query]:-unknown}")
    else
      lines+=('Capability evidence: unavailable')
    fi
  fi
  if (( ${terminal_features[(Ie)resource_info]} )); then
    if zcoder_curses resourceinfo terminal_resources 2>/dev/null; then
      lines+=("" "Resources (${terminal_resources[session]:-unknown}):"
        "Windows / owned / shared: ${terminal_resources[windows]:-unknown} / ${terminal_resources[owned_windows]:-unknown} / ${terminal_resources[child_windows]:-unknown}"
        "Backing cells: ${terminal_resources[backing_cells]:-unknown}"
        "Pads / cells / input pads: ${terminal_resources[pads]:-unknown} / ${terminal_resources[pad_cells]:-unknown} / ${terminal_resources[private_input_pads]:-unknown}"
        "Prepared rows / bytes: ${terminal_resources[prepared_rows]:-unknown} / ${terminal_resources[prepared_bytes]:-unknown}"
        "Prepared created / draws: ${terminal_resources[prepared_created]:-unknown} / ${terminal_resources[prepared_draws]:-unknown}"
        "Retired tree handles: ${terminal_resources[retired_tree_windows]:-unknown}"
        'Counts describe toolkit resources, not process memory.')
    else
      lines+=('Resource inspection: unavailable')
    fi
  fi
  lines+=(""
    "ZCODER_SYNC_OUTPUT=auto queries terminal support once on UI entry."
    "No reply within one second keeps ordinary curses updates."
    "Native sync requires a reset reply; an already-set mode stays untouched."
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
