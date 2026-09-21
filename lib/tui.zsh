# Interactive TUI lifecycle and event loop.

zcoder_refresh_sessions() {
  if [[ "$REMOTE_MODE" == client && ${REMOTE_SESSIONS_SUPPORTED:-0} -eq 1 ]]; then
    remote_client_refresh_sessions
  else
    state_save_and_refresh
  fi
  (( $+functions[relay_refresh_manifest] )) && relay_refresh_manifest || true
}

main_tui() {
  local ch="" key="" mouse="" text="" previous_model="" relay_context="" relay_display=""
  local -i current_index=1 i=1 relay_claim_status=1
  input_reset
  if [[ "$REMOTE_MODE" != client ]] && ! state_init "${RESUME_SESSION_ID:+resume}" "$RESUME_SESSION_ID"; then
    if [[ -n "$RESUME_SESSION_ID" ]]; then
      print -u2 -r -- "Error: could not resume $RESUME_SESSION_ID: $STATE_ERROR"
      return 1
    fi
    print -u2 -- "Warning: could not initialize session storage at $ZCODER_SESSIONS_DIR"
  fi
  if [[ "$REMOTE_MODE" == local ]]; then
    zcoder_require relay
    if ! relay_start && [[ "$ZCODER_RELAY" != off ]]; then
      ui_append_message system "Inter-agent relay unavailable: ${RELAY_ERROR:-startup failed}."
    fi
  fi
  if [[ "$REMOTE_MODE" == local && "$ZCODER_WARMUP" == true ]]; then
    ui_set_status "Warming Up"
  elif [[ "$REMOTE_MODE" == client ]]; then
    case "$REMOTE_MODEL_STATUS" in
      warming) ui_set_status "Warming Up" ;;
      error) ui_set_status "Warm-up Failed" ;;
      *) ui_set_status "Ready" ;;
    esac
  fi
  ui_init || { print -u2 -- "Error: could not initialize curses UI"; return 1; }
  if (( REMOTE_HANDSHAKE_PENDING )); then
    ui_set_status Connecting
    remote_client_handshake
    local -i handshake_status=$?
    if (( handshake_status != 0 )); then
      ui_end
      print -u2 -r -- "Remote connection stopped: $REMOTE_ERROR"
      return "$handshake_status"
    fi
    REMOTE_HANDSHAKE_PENDING=0
    case "$REMOTE_MODEL_STATUS" in
      warming) ui_set_status 'Warming Up' ;;
      error) ui_set_status 'Warm-up Failed' ;;
      *) ui_set_status Ready ;;
    esac
    ui_invalidate; ui_refresh_all
  fi
  TUI_SESSION_STARTED=1
  agent_warmup_start || true
  while (( RUNNING )); do
    (( UI_ACTIVE )) || return 1
    ui_poll_resize
    if [[ "$REMOTE_MODE" == client ]]; then
      remote_client_model_poll || true
    else
      agent_warmup_poll
    fi
    if [[ "$REMOTE_MODE" == local ]] && (( $+functions[relay_claim_one] && ${RELAY_ACTIVE:-0} )); then
      relay_refresh_manifest || true
      relay_claim_one
      relay_claim_status=$?
      if (( relay_claim_status == 0 )); then
        relay_relay_context; relay_context="$REPLY"
        relay_relay_display; relay_display="$REPLY"
        agent_relay_turn "$relay_context" "$relay_display" "$RELAY_CLAIM_SENDER_ID"
        relay_complete_claim || ui_append_message error "Could not finalize relayed message ${RELAY_CLAIM_MESSAGE_ID}."
        zcoder_refresh_sessions
        continue
      elif (( relay_claim_status == 2 )); then
        ui_append_message error "$RELAY_ERROR"
        ui_refresh_all
        continue
      fi
    fi
    ch=""; key=""; mouse=""
    zcoder_curses timeout input_win 100
    terminal_read_event input_win ch key mouse
    if [[ "$key" == RESIZE ]]; then
      UI_RESIZE_PENDING=1
      ui_poll_resize
      continue
    fi
    ui_slash_input "$ch" "$key" && continue
    [[ -z "$ch" && -z "$key" ]] && continue
    if input_decode_terminal_event "$ch" "$key"; then
      if [[ "$INPUT_EVENT_ACTION" == focus_sessions || "$INPUT_EVENT_ACTION" == focus_prompt ]]; then
        ui_focus_panel "${INPUT_EVENT_ACTION#focus_}"
      elif [[ "$INPUT_EVENT_ACTION" == newline ]]; then
        input_insert $'\n'
        ui_input_changed
      elif [[ "$INPUT_EVENT_ACTION" == paste && -n "$INPUT_EVENT_TEXT" ]]; then
        input_insert "$INPUT_EVENT_TEXT"
        ui_input_changed
      elif [[ "$INPUT_EVENT_ACTION" == paste_rejected ]]; then
        ui_status_notice warning "$INPUT_EVENT_TEXT"
      fi
      continue
    elif [[ $UI_FOCUS != input && -z $key && $ch == (1|2) ]]; then
      ui_focus_panel "$ch"
    elif [[ "$ch" == $'\x11' || "$ch" == $'\x04' ]]; then
      break
    elif [[ "$ch" == $'\x03' ]]; then
      input_clear; ui_input_changed
    elif [[ "$ch" == $'\x0e' ]]; then
      handle_slash_command /new
    elif [[ "$ch" == $'\x19' ]]; then
      ui_copy_view
    elif [[ "$ch" == $'\x10' ]]; then
      ui_command_palette
    elif [[ "$ch" == $'\x0f' ]]; then
      if [[ "$REMOTE_MODE" == client ]]; then
        ui_append_message system "Remote model: $ZCODER_MODEL (selected by $REMOTE_SERVER_NAME)"
        ui_refresh_all
      else
        previous_model="$ZCODER_MODEL"
        ui_select_model
        [[ "$ZCODER_MODEL" != "$previous_model" ]] && agent_warmup_start || true
        zcoder_refresh_sessions
      fi
    elif [[ "$ch" == $'\x12' ]]; then
      ui_toggle_reasoning
    elif [[ "$ch" == $'\x02' ]]; then
      ui_toggle_sidebar
    elif [[ "$ch" == $'\t' || "$key" == TAB ]]; then
      case "$UI_FOCUS" in
        input) (( SIDE_W > 0 )) && UI_FOCUS="sidebar" || UI_FOCUS="chat" ;;
        sidebar) UI_FOCUS="chat" ;;
        *) UI_FOCUS="input" ;;
      esac
      [[ "$UI_FOCUS" == chat ]] && { UI_AUTO_SCROLL=0; UI_REVEAL_SELECTED=1; }
      ui_refresh_all
    elif [[ "$key" == PPAGE ]]; then
      UI_AUTO_SCROLL=0; (( UI_SCROLL -= 6 )); (( UI_SCROLL < 0 )) && UI_SCROLL=0; ui_draw_chat
    elif [[ "$key" == NPAGE ]]; then
      (( UI_SCROLL += 6 )); ui_draw_chat
    elif [[ "$UI_FOCUS" == sidebar ]]; then
      current_index=${SESSION_IDS[(Ie)$CURRENT_SESSION_ID]}
      (( current_index > 0 )) || current_index=1
      if [[ "$key" == UP || "$ch" == k ]]; then
        if (( current_index > 1 )); then
          if [[ "$REMOTE_MODE" == client ]]; then
            remote_client_select_session "${SESSION_IDS[current_index-1]}" || ui_append_message error "Could not load remote session: $REMOTE_ERROR"
          else
            state_load_session "${SESSION_IDS[current_index-1]}"
            agent_warmup_start || true
          fi
          ui_set_status "Ready"
          ui_refresh_all
        fi
      elif [[ "$key" == DOWN || "$ch" == j ]]; then
        if (( current_index < ${#SESSION_IDS} )); then
          if [[ "$REMOTE_MODE" == client ]]; then
            remote_client_select_session "${SESSION_IDS[current_index+1]}" || ui_append_message error "Could not load remote session: $REMOTE_ERROR"
          else
            state_load_session "${SESSION_IDS[current_index+1]}"
            agent_warmup_start || true
          fi
          ui_set_status "Ready"
          ui_refresh_all
        fi
      elif [[ "$ch" == $'\n' || "$ch" == $'\r' || "$key" == ENTER || "$key" == PADENTER ]]; then
        UI_FOCUS="input"
        ui_refresh_all
      fi
    elif [[ "$UI_FOCUS" == chat ]]; then
      ui_chat_input "$ch" "$key"
    elif [[ "$ch" == $'\n' || "$ch" == $'\r' || "$key" == ENTER || "$key" == PADENTER ]]; then
      input_submit; text="$INPUT_SUBMITTED"
      ui_input_changed
      if [[ -n "$text" ]]; then
        if [[ "$text" == /* ]]; then
          handle_slash_command "$text" || { agent_user_turn "$text"; zcoder_refresh_sessions; }
        else
          agent_user_turn "$text"
          zcoder_refresh_sessions
        fi
      fi
    else
      ui_editor_input "$ch" "$key" || true
    fi
  done
}
