# Modal state is dynamically scoped by ui_modal_run and its callers. Draw and
# input handlers are internal function names, never model/user-provided code.
typeset -gi UI_MODAL_ACTIVE=0
typeset -gi UI_PICKER_HELPERS=0
# Passive, optional libraries: stock curses can use the pure state/geometry
# helpers too. Missing vendor sources leave the original picker available.
() {
  emulate -L zsh
  local root="${1:A:h:h}/vendor/zdraw/lib" component
  for component in layout list help; do
    [[ -r "$root/zdraw-$component.zsh" ]] || return 0
  done
  for component in layout list help; do
    source "$root/zdraw-$component.zsh" || return 0
  done
  UI_PICKER_HELPERS=1
} "${(%):-%x}"

ui_modal_text() {
  emulate -L zsh
  local -i row=$1 col=${4:-2} available
  available=$(( modal_w - col - 1 ))
  local value="$2" attr="${3:-white/black}"
  (( row >= 0 && row < modal_h && available > 0 )) || return 0
  value="${value//$'\n'/ }"
  zcoder_terminal_safe "$value"; value="$REPLY"
  zcoder_curses move overlay_win "$row" "$col"
  ui_attr overlay_win -bold -dim -reverse -underline default/default
  ui_attr overlay_win $=attr
  zcoder_clip "$value" "$available"
  zcoder_curses string overlay_win "$REPLY"
}

ui_modal_run() {
  emulate -L zsh
  setopt extendedglob
  local modal_title="$1" modal_draw="$2" modal_input="$3"
  local -i wanted_h=${4:-20} wanted_w=${5:-78}
  local -i modal_h=0 modal_w=0 modal_rows=1 modal_selected=${modal_initial:-1} modal_scroll=1
  local -a reply=()
  local -i modal_y modal_x
  local -i modal_done=0 modal_accepted=0 modal_dirty=1 previous_h=0 previous_w=0
  local modal_result="" modal_ch="" modal_key="" modal_mouse=""
  (( UI_ACTIVE && ! UI_MODAL_ACTIVE )) || { REPLY=""; return 1; }
  (( $+functions[$modal_draw] && $+functions[$modal_input] )) || { REPLY=""; return 1; }
  UI_MODAL_ACTIVE=1
  {
    while (( ! modal_done )); do
      ui_poll_resize
      # Collect an already-running local warm-up without admitting new work or
      # dispatching commands while this modal owns input and the screen.
      if (( ${AGENT_WARMUP_ACTIVE:-0} && $+functions[agent_warmup_poll] )); then
        agent_warmup_poll
      fi
      if (( SCREEN_H != previous_h || SCREEN_W != previous_w )); then
        zcoder_curses delwin overlay_win 2>/dev/null || true
        modal_h=$(( SCREEN_H - 2 )); modal_w=$(( SCREEN_W - 2 ))
        (( modal_h > wanted_h )) && modal_h=$wanted_h
        (( modal_w > wanted_w )) && modal_w=$wanted_w
        modal_y=$(( (SCREEN_H-modal_h)/2 )); modal_x=$(( (SCREEN_W-modal_w)/2 ))
        if (( ${modal_picker_helpers:-0} )); then
          zdraw-layout-center 1 1 "$(( SCREEN_H-2 ))" "$(( SCREEN_W-2 ))" "$wanted_h" "$wanted_w" || return 1
          modal_y=$reply[1]; modal_x=$reply[2]; modal_h=$reply[3]; modal_w=$reply[4]
        fi
        # There must be room for a border, title, content, and close hint.
        (( modal_h >= 6 && modal_w >= 24 )) || return 1
        modal_rows=$(( modal_h - 4 ))
        zcoder_curses addwin overlay_win "$modal_h" "$modal_w" "$modal_y" "$modal_x" || return 1
        ui_window_background overlay_win
        previous_h=$SCREEN_H; previous_w=$SCREEN_W; modal_dirty=1
      fi
      if (( modal_dirty )); then
        zcoder_curses clear overlay_win
        ui_attr overlay_win -reverse -dim -bold border/surface
        ui_border overlay_win
        ui_modal_text 0 " ${modal_title} " "bold white/black"
        "$modal_draw" || return 1
        terminal_refresh overlay_win
        modal_dirty=0
      fi
      modal_ch=""; modal_key=""; modal_mouse=""
      zcoder_curses timeout overlay_win 100
      terminal_read_event overlay_win modal_ch modal_key modal_mouse
      if [[ "$modal_key" == RESIZE ]]; then
        UI_RESIZE_PENDING=1
        continue
      fi
      "$modal_input" || return 1
    done
  } always {
    zcoder_curses delwin overlay_win 2>/dev/null || true
    UI_MODAL_ACTIVE=0
    ui_invalidate
    zcoder_curses touch top_win chat_win input_win foot_win 2>/dev/null || true
    (( SIDE_W > 0 )) && zcoder_curses touch side_win 2>/dev/null
    ui_refresh_all
    REPLY="$modal_result"
  }
  (( modal_accepted ))
}

_ui_modal_list_draw() {
  local -i count=${#modal_items} i row=2
  local item="" attr=""
  if (( ${modal_picker_helpers:-0} )); then
    _ui_picker_update keep || return 1
  fi
  if (( ${modal_picker_widgets:-0} )); then
    _ui_picker_draw 2>/dev/null && return 0
    # A later native failure can leave a partial paint. The modal owns this
    # rectangle; clear it and repaint the complete frame through legacy calls.
    modal_picker_widgets=0
    zcoder_curses clear overlay_win
    ui_attr overlay_win -reverse -dim -bold border/surface
    ui_border overlay_win
    ui_modal_text 0 " ${modal_title} " "bold white/black"
  fi
  if (( ! ${modal_picker_helpers:-0} )); then
    (( modal_selected > count )) && modal_selected=$count
    (( modal_selected < 1 )) && modal_selected=1
    (( modal_selected < modal_scroll )) && modal_scroll=$modal_selected
    (( modal_selected >= modal_scroll + modal_rows )) && modal_scroll=$(( modal_selected-modal_rows+1 ))
  fi
  for (( i=modal_scroll; i<=count && row<modal_h-2; i++,row++ )); do
    item="${modal_items[i]}"
    [[ "$item" == "${modal_current:-}" && -n "$item" ]] && item="* ${item}"
    attr="${modal_item_attrs[i]:-white/black}"
    (( i == modal_selected )) && attr="reverse bold cyan/black"
    ui_modal_text "$row" "$item" "$attr"
  done
  (( count )) || ui_modal_text 2 "No entries" "dim white/black"
  ui_modal_text $(( modal_h-2 )) "${modal_hint:-↑/↓ Select · Enter Accept · Esc Close}" "dim white/black"
  return 0
}

_ui_modal_navigate() {
  local -i count=$1
  if (( ${modal_picker_helpers:-0} )); then
    local action
    case "$modal_key" in
      UP) action=up ;; DOWN) action=down ;; PPAGE) action=page-up ;;
      NPAGE) action=page-down ;; HOME) action=home ;; END) action=end ;;
      *) return 1 ;;
    esac
    _ui_picker_update "$action" || return 1
    modal_dirty=1
    return 0
  fi
  case "$modal_key" in
    UP) (( modal_selected-- )) ;;
    DOWN) (( modal_selected++ )) ;;
    PPAGE) (( modal_selected-=modal_rows )) ;;
    NPAGE) (( modal_selected+=modal_rows )) ;;
    HOME) modal_selected=1 ;;
    END) modal_selected=$count ;;
    *) return 1 ;;
  esac
  (( modal_selected < 1 )) && modal_selected=1
  (( modal_selected > count && count > 0 )) && modal_selected=$count
  modal_dirty=1
  return 0
}

_ui_modal_list_input() {
  if _ui_modal_navigate ${#modal_items}; then return 0; fi
  case "$modal_ch" in
    k) modal_key=UP; _ui_modal_navigate ${#modal_items} ;;
    j) modal_key=DOWN; _ui_modal_navigate ${#modal_items} ;;
    $'\e'|$'\x03'|q) modal_done=1 ;;
    $'\r'|$'\n')
      if (( ${#modal_items} )); then modal_result="$modal_selected"; modal_accepted=1; modal_done=1; fi
      ;;
    *)
      if [[ "$modal_key" == ENTER || "$modal_key" == PADENTER ]] && (( ${#modal_items} )); then
        modal_result="$modal_selected"; modal_accepted=1; modal_done=1
      fi
      ;;
  esac
  return 0
}

ui_modal_choose() {
  emulate -L zsh
  local title="$1" modal_current="$2"; shift 2
  local modal_hint='Enter Use  Esc Close  Up/Down Select  PgUp/PgDn Page'
  local -a modal_items=("$@") modal_item_attrs=()
  (( ${#modal_items} )) || modal_hint='Esc Close'
  local -i modal_initial=${modal_items[(Ie)$modal_current]}
  local -i modal_picker_helpers=$UI_PICKER_HELPERS modal_picker_widgets=0
  local -A zdraw_ui_list zdraw_ui_theme
  local -A picker_colors=(black 0 red 1 green 2 yellow 3 blue 4 magenta 5 cyan 6 white 7)
  local -a picker_labels=() reply=()
  local label feature
  # The toolkit's state has bounded indexes. Larger catalogs use the original
  # picker instead of becoming unselectable.
  (( ${#modal_items} <= 32767 )) || modal_picker_helpers=0
  if (( modal_picker_helpers )) && [[ $ZCODER_CURSES_COMMAND == zdraw ]] &&
     (( UI_STYLED_SPANS && UI_CLIPPED_SPANS )) && zcoder_curses_features; then
    modal_picker_widgets=1
    for feature in region_fill textinfo styled_spans clipped_spans; do
      (( ${reply[(Ie)$feature]} )) || modal_picker_widgets=0
    done
  fi
  if (( modal_picker_widgets )); then
    # Sanitize display labels once; selection always returns the original
    # array index, never a decorated or sanitized model name.
    for label in "${modal_items[@]}"; do
      [[ -n $modal_current && $label == "$modal_current" ]] && label="* $label"
      zcoder_terminal_safe "${label//$'\n'/ }"
      picker_labels+=("$REPLY")
    done
    # Reuse the application's negotiated palette, including direct color.
    zdraw_ui_theme=(profile "$UI_COLOR_MODE" text "${UI_THEME_COLORS[text]:-default}"
      surface "${UI_THEME_COLORS[surface]:-default}" canvas "${UI_THEME_COLORS[surface]:-default}"
      muted "${UI_THEME_COLORS[muted]:-default}" accent "${UI_THEME_COLORS[accent]:-default}"
      selection "${UI_THEME_COLORS[accent]:-default}" on-selection "${UI_THEME_COLORS[surface]:-default}"
      inactive "${UI_THEME_COLORS[surface]:-default}" on-inactive "${UI_THEME_COLORS[text]:-default}")
    for feature in ${(k)zdraw_ui_theme}; do
      [[ $feature == profile ]] && continue
      label=$zdraw_ui_theme[$feature]
      zdraw_ui_theme[$feature]=${picker_colors[$label]:-$label}
      [[ $UI_COLOR_MODE == mono ]] && zdraw_ui_theme[$feature]=default
    done
  fi
  ui_modal_run "$title" _ui_modal_list_draw _ui_modal_list_input
}

# Caller-owned state is local to ui_modal_choose and ui_modal_run; no widget
# reads input or presents a frame. Other modal kinds keep their own navigation.
_ui_picker_update() {
  emulate -L zsh
  zdraw_ui_list=(selected "$modal_selected" first "$modal_scroll")
  zdraw-list-update "${#modal_items}" "$modal_rows" "$1" || return
  modal_selected=$zdraw_ui_list[selected]; modal_scroll=$zdraw_ui_list[first]
}

_ui_picker_draw() {
  emulate -L zsh
  zdraw-list overlay_win 2 2 "$modal_rows" "$(( modal_w-4 ))" focus empty-text='No entries' -- "${picker_labels[@]}" || return
  local -a shortcuts=(Esc Close)
  (( ${#picker_labels} )) && shortcuts=(Enter Use "${shortcuts[@]}" '↑/↓' Select PgUp/PgDn Page)
  zdraw-help overlay_win "$(( modal_h-2 ))" 2 "$(( modal_w-4 ))" normal bg=surface -- \
    "${shortcuts[@]}"
}

_ui_modal_view_draw() {
  local -i i row=2 max_scroll=$(( ${#modal_lines}-modal_rows+1 ))
  (( max_scroll < 1 )) && max_scroll=1
  (( modal_selected > max_scroll )) && modal_selected=$max_scroll
  for (( i=modal_selected; i<=${#modal_lines} && row<modal_h-2; i++,row++ )); do
    ui_modal_text "$row" "${modal_lines[i]}"
  done
  ui_modal_text $(( modal_h-2 )) "${modal_hint:-↑/↓ Scroll · PgUp/PgDn · Esc Close}" "dim cyan/black"
  return 0
}

_ui_modal_view_input() {
  _ui_modal_navigate ${#modal_lines} && return 0
  case "$modal_ch" in
    $'\e'|$'\x03'|q|$'\n'|$'\r') modal_done=1; modal_accepted=1 ;;
  esac
  [[ "$modal_key" == ENTER || "$modal_key" == PADENTER ]] && { modal_done=1; modal_accepted=1; }
  return 0
}

ui_select_model() {
  local previous_status="$UI_STATUS"
  local -i discovery_status=0
  ui_set_status "Loading models"; ui_draw_header
  ollama_get_models "$OLLAMA_HOST" || discovery_status=$?
  if (( discovery_status == 130 )); then
    ui_set_status "$previous_status"; ui_draw_header; return 130
  fi
  if (( discovery_status != 0 || ! ${#OLLAMA_MODELS} )); then
    ui_set_status Error
    ui_append_message error "Could not load Ollama models: ${HTTP_ERROR:-the server returned no models}"
    ui_refresh_all
    return 1
  fi
  if ui_modal_choose "Select Ollama Model" "$ZCODER_MODEL" "${OLLAMA_MODELS[@]}"; then
    ZCODER_MODEL="${OLLAMA_MODELS[REPLY]}"
    ui_set_status Ready
  else ui_set_status "$previous_status"
  fi
  ui_draw_header
}

ui_select_opencode_model() {
  local previous_status="$UI_STATUS"
  local -i accepted=0 discovery_status=0
  ui_set_status "Loading OpenCode models"; ui_draw_header
  delegate_discover_opencode_models || discovery_status=$?
  if (( discovery_status == 130 )); then
    ui_set_status "$previous_status"; ui_draw_header; return 130
  fi
  if (( discovery_status != 0 || ! ${#DELEGATE_MODELS} )); then
    ui_set_status Error
    ui_append_message error "Could not load OpenCode models: ${DELEGATE_ERROR:-no models}"
    ui_refresh_all
    return 1
  fi
  if ui_modal_choose "Select OpenCode Model" "$ZCODER_OPENCODE_MODEL" "${DELEGATE_MODELS[@]}"; then
    ZCODER_OPENCODE_MODEL="${DELEGATE_MODELS[REPLY]}"
    accepted=1; ui_set_status Ready
  else ui_set_status "$previous_status"
  fi
  ui_draw_header
  (( accepted ))
}

_ui_mcp_items() {
  local name="" item=""
  modal_items=(); modal_item_attrs=()
  for name in "${MCP_NAMES[@]}"; do
    item="${name} · ${MCP_STATUS[$name]} · ${MCP_TYPE[$name]} · ${MCP_SCOPE[$name]}"
    [[ -n "${MCP_PROTOCOL[$name]:-}" ]] && item+=" · ${MCP_PROTOCOL[$name]}"
    modal_items+=("$item")
    [[ "${MCP_STATUS[$name]}" == connected ]] && modal_item_attrs+=(green/black) || modal_item_attrs+=(white/black)
  done
}

_ui_mcp_draw() {
  local name="${MCP_NAMES[modal_selected]:-}"
  local modal_hint="r Restart · Esc Close · ${MCP_DETAIL[$name]:-No details}"
  _ui_modal_list_draw
}

_ui_mcp_input() {
  if [[ "$modal_ch" == r && ${#MCP_NAMES} -gt 0 ]]; then
    # Release the overlay before the activity loop owns draft input.
    modal_result="restart:$modal_selected"; modal_accepted=1; modal_done=1
  else _ui_modal_list_input
  fi
  return 0
}

ui_mcp_servers() {
  local previous_status="$UI_STATUS" name=''
  local -i modal_initial=1 MCP_INTERACTIVE_CONNECT=1
  local -a modal_items=() modal_item_attrs=()
  ui_set_status "Connecting MCP"; ui_draw_header
  mcp_connect_all >/dev/null 2>&1 || true
  while true; do
    _ui_mcp_items
    ui_modal_run "MCP Servers" _ui_mcp_draw _ui_mcp_input 20 88 || break
    [[ "$REPLY" == restart:* ]] || break
    modal_initial=${REPLY#restart:}
    name="${MCP_NAMES[modal_initial]}"
    mcp_broker_stop "$name"; MCP_PROTOCOL[$name]=''; MCP_SERVER_TOOLS[$name]=''
    if (( ${MCP_ENABLED[$name]:-0} )); then
      MCP_STATUS[$name]=configured
      mcp_connect "$name" || MCP_DETAIL[$name]="$MCP_ERROR"
    else MCP_STATUS[$name]=disabled; MCP_DETAIL[$name]=''
    fi
    _mcp_rebuild_tool_catalog
  done
  ui_set_status "$previous_status"; ui_draw_header
}

_ui_approval_draw() {
  local -a modal_lines=() wrapped=()
  local line=""
  zcoder_terminal_safe "$action_text"
  for line in "${(@f)REPLY}"; do
    zcoder_wrap "$line" $(( modal_w-4 ))
    modal_lines+=("${ZCODER_WRAPPED[@]}")
  done
  _ui_modal_view_draw
}

_ui_approval_input() {
  case "${(L)modal_ch}" in
    y) modal_result=y; modal_accepted=1; modal_done=1 ;;
    a) (( allow_session )) && { modal_result=a; modal_accepted=1; modal_done=1; } ;;
    n|q|$'\e'|$'\x03') modal_result=n; modal_accepted=1; modal_done=1 ;;
    *)
      # The draw handler rebuilds wrapped text after each resize.
      _ui_modal_navigate 2147483647 || true
      ;;
  esac
  return 0
}

_ui_confirm_action() {
  local kind="$1" action_text="$2" answer=n title="Shell command approval"
  local -i allow_session=0
  [[ "$kind" == command && "$ZCODER_PROFILE" != sysadmin ]] && allow_session=1
  [[ "$kind" == external ]] && title="External action confirmation"
  local modal_hint="y Allow once · n/Esc Deny · ↑/↓ Scroll"
  (( allow_session )) && modal_hint="y Allow once · a Allow session · n/Esc Deny · ↑/↓ Scroll"
  if (( ! UI_ACTIVE )); then
    if [[ -r /dev/tty && -w /dev/tty ]]; then
      zcoder_terminal_safe "$action_text"
      print -r -- $'\n'"${title}:"$'\n'"$REPLY" > /dev/tty
      print -rn -- "${modal_hint} [n]: " > /dev/tty
      read -r answer < /dev/tty
    fi
    REPLY="$answer"
    return 0
  fi
  if ! ui_modal_run "$title" _ui_approval_draw _ui_approval_input 18 88; then
    REPLY=n
    return 1
  fi
  [[ "$REPLY" == y || ( "$REPLY" == a && allow_session -eq 1 ) ]] || REPLY=n
  return 0
}

ui_confirm_command() { _ui_confirm_action command "$1"; }
ui_confirm_external_action() { _ui_confirm_action external "$1"; }
