# External harness catalog shared by remote handshakes and delegate commands.

typeset -ga DELEGATE_PROVIDERS=(claude codex agy opencode)
typeset -gA DELEGATE_AVAILABLE=()
typeset -gi DELEGATE_AVAILABILITY_KNOWN=0

delegate_label() {
  case "$1" in
    claude) REPLY="Claude" ;;
    codex) REPLY="Codex" ;;
    agy) REPLY="Antigravity" ;;
    opencode) REPLY="OpenCode" ;;
    *) REPLY="$1" ;;
  esac
}

delegate_binary() {
  case "$1" in
    claude) REPLY="claude" ;;
    codex) REPLY="codex" ;;
    agy) REPLY="agy" ;;
    opencode) REPLY="opencode" ;;
    *) REPLY=""; return 1 ;;
  esac
}

delegate_command_available() {
  (( $+commands[$1] ))
}

delegate_refresh_availability() {
  local provider="" binary=""
  DELEGATE_AVAILABLE=()
  for provider in "${DELEGATE_PROVIDERS[@]}"; do
    delegate_binary "$provider" || continue
    binary="$REPLY"
    if delegate_command_available "$binary"; then
      DELEGATE_AVAILABLE[$provider]=1
    else
      DELEGATE_AVAILABLE[$provider]=0
    fi
  done
  DELEGATE_AVAILABILITY_KNOWN=1
}

# Restore the server-authored availability snapshot on a remote client. The
# handshake uses a comma-separated scalar to remain compatible with the native
# flat-object JSON parser and protocol-1 peers.
delegate_set_available_csv() {
  local csv="$1" provider=""
  local -a reported=()
  DELEGATE_AVAILABLE=()
  for provider in "${DELEGATE_PROVIDERS[@]}"; do DELEGATE_AVAILABLE[$provider]=0; done
  [[ -n "$csv" ]] && reported=("${(@s:,:)csv}")
  for provider in "${reported[@]}"; do
    [[ " ${(j: :)DELEGATE_PROVIDERS} " == *" ${provider} "* ]] && DELEGATE_AVAILABLE[$provider]=1
  done
  DELEGATE_AVAILABILITY_KNOWN=1
}

delegate_available() {
  (( DELEGATE_AVAILABILITY_KNOWN )) || delegate_refresh_availability
  [[ "${DELEGATE_AVAILABLE[$1]:-0}" == 1 ]]
}

delegate_available_csv() {
  local provider=""
  local -a available=()
  (( DELEGATE_AVAILABILITY_KNOWN )) || delegate_refresh_availability
  for provider in "${DELEGATE_PROVIDERS[@]}"; do
    [[ "${DELEGATE_AVAILABLE[$provider]:-0}" == 1 ]] && available+=("$provider")
  done
  REPLY="${(j:,:)available}"
}

delegate_availability_summary() {
  local host_label="${1:-this zcoder host}" provider=""
  local -a available=() unavailable=()
  (( DELEGATE_AVAILABILITY_KNOWN )) || delegate_refresh_availability
  for provider in "${DELEGATE_PROVIDERS[@]}"; do
    if [[ "${DELEGATE_AVAILABLE[$provider]:-0}" == 1 ]]; then
      available+=("/${provider}")
    else
      unavailable+=("/${provider}")
    fi
  done
  REPLY="External harnesses on ${host_label}: available ${(j:, :)available:-none}; unavailable ${(j:, :)unavailable:-none}. Add ! to an available command for workspace-editing mode."
}

delegate_unavailable_message() {
  local provider="$1" host_label="${2:-this zcoder host}" binary="" available_csv="" item=""
  local -a available=() names=()
  delegate_binary "$provider" || { REPLY="Unknown external harness: /${provider}."; return 2; }
  binary="$REPLY"
  delegate_available_csv; available_csv="$REPLY"
  [[ -n "$available_csv" ]] && available=("${(@s:,:)available_csv}")
  for item in "${available[@]}"; do names+=("/${item}"); done
  REPLY="/${provider} is unavailable on ${host_label}: '${binary}' was not found in PATH. Available external harnesses: ${(j:, :)names:-none}."
}

delegate_require_available() {
  local provider="$1" host_label="${2:-this zcoder host}"
  delegate_available "$provider" && return 0
  delegate_unavailable_message "$provider" "$host_label"
  DELEGATE_ERROR="$REPLY"
  return 127
}
