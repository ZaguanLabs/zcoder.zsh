# Hard-stop policy for clearly catastrophic sysadmin commands.

typeset -g TOOL_SAFETY_REASON=""

_tool_sysadmin_broad_target() {
  local target="$1" root="${ZCODER_WORKSPACE:A}"
  target="${(Q)target}"
  while [[ "$target" != / && "$target" == */ ]]; do target="${target%/}"; done
  if [[ "$target" == "$root" || "$target" == "${root}/*" || "$target" == "${root}/**" ]]; then
    return 0
  fi
  case "$target" in
    /|/\*|/\*\*|/\.\*|/etc|/etc/\*|/usr|/usr/\*|/var|/var/\*|/boot|/boot/\*|/home|/home/\*|/root|/root/\*|/dev|/dev/\*|/opt|/opt/\*|/srv|/srv/\*|'$HOME'|'$HOME/*'|'${HOME}'|'${HOME}/*'|\~|\~/\*)
      return 0
      ;;
  esac
  return 1
}

# This is deliberately a narrow hard stop, not a promise to understand every
# possible shell program. It catches commands whose literal argv clearly aims
# at machine-wide data loss; the prompt and per-command approval cover the much
# larger class of context-dependent administrative risk.
tool_sysadmin_command_guard() {
  setopt localoptions extendedglob
  local command_text="$1" depth="${2:-0}" raw="" token="" executable="" next=""
  local -a tokens=()
  local -i i j
  (( depth == 0 )) && TOOL_SAFETY_REASON=""
  [[ "$ZCODER_PROFILE" == sysadmin ]] || return 0
  if (( depth > 4 )); then
    TOOL_SAFETY_REASON="excessively nested shell evaluation is blocked"
    return 1
  fi

  if [[ "$command_text" == *':(){ :|:& };:'* || "$command_text" == *':(){:|:&};:'* ]]; then
    TOOL_SAFETY_REASON="fork-bomb syntax is never executable from the sysadmin profile"
    return 1
  fi

  tokens=("${(z)command_text}")
  for (( i=1; i<=${#tokens}; i++ )); do
    raw="${tokens[i]}"
    token="${(Q)raw}"
    executable="${(L)${token:t}}"
    case "$executable" in
      sh|bash|zsh|dash|ksh|eval)
        for (( j=i+1; j<=${#tokens}; j++ )); do
          next="${(Q)tokens[j]}"
          if [[ "$executable" == eval || "$next" == -c ]]; then
            [[ "$executable" == eval ]] || (( j++ ))
            next="${(Q)tokens[j]:-}"
            [[ -n "$next" ]] && tool_sysadmin_command_guard "$next" $(( depth + 1 )) || {
              [[ -n "$TOOL_SAFETY_REASON" ]] && return 1
            }
            break
          fi
        done
        ;;
      mkfs|mkfs.*|blkdiscard)
        TOOL_SAFETY_REASON="filesystem formatting and whole-device discard commands must be run manually"
        return 1
        ;;
      rm)
        for (( j=i+1; j<=${#tokens}; j++ )); do
          next="${(Q)tokens[j]}"
          [[ "$next" == '&&' || "$next" == '||' || "$next" == ';' || "$next" == '|' || "$next" == '&' ]] && break
          [[ "$next" == -* ]] && continue
          if _tool_sysadmin_broad_target "$next"; then
            TOOL_SAFETY_REASON="recursive or broad deletion target ${(qqq)next} is blocked"
            return 1
          fi
        done
        ;;
      find)
        local -i broad_find=0 destructive_find=0
        for (( j=i+1; j<=${#tokens}; j++ )); do
          next="${(Q)tokens[j]}"
          [[ "$next" == '&&' || "$next" == '||' || "$next" == ';' || "$next" == '|' || "$next" == '&' ]] && break
          _tool_sysadmin_broad_target "$next" && broad_find=1
          [[ "$next" == -delete ]] && destructive_find=1
        done
        if (( broad_find && destructive_find )); then
          TOOL_SAFETY_REASON="find -delete on a broad system target is blocked"
          return 1
        fi
        ;;
      chmod|chown|chgrp)
        for (( j=i+1; j<=${#tokens}; j++ )); do
          next="${(Q)tokens[j]}"
          [[ "$next" == '&&' || "$next" == '||' || "$next" == ';' || "$next" == '|' || "$next" == '&' ]] && break
          if _tool_sysadmin_broad_target "$next"; then
            TOOL_SAFETY_REASON="ownership or permission changes on broad target ${(qqq)next} are blocked"
            return 1
          fi
        done
        ;;
      dd)
        for (( j=i+1; j<=${#tokens}; j++ )); do
          next="${(L)${(Q)tokens[j]}}"
          [[ "$next" == '&&' || "$next" == '||' || "$next" == ';' || "$next" == '|' || "$next" == '&' ]] && break
          if [[ "$next" == of=/dev/* ]]; then
            TOOL_SAFETY_REASON="raw writes to block devices must be run manually"
            return 1
          fi
        done
        ;;
      wipefs)
        for (( j=i+1; j<=${#tokens}; j++ )); do
          next="${(L)${(Q)tokens[j]}}"
          if [[ "$next" == -a || "$next" == --all ]]; then
            TOOL_SAFETY_REASON="erasing filesystem signatures must be run manually"
            return 1
          fi
        done
        ;;
      zpool)
        next="${(L)${(Q)tokens[i+1]:-}}"
        if [[ "$next" == destroy ]]; then
          TOOL_SAFETY_REASON="destroying storage pools must be run manually"
          return 1
        fi
        ;;
      lvremove|vgremove|pvremove)
        TOOL_SAFETY_REASON="destroying logical-volume storage must be run manually"
        return 1
        ;;
      shred)
        for (( j=i+1; j<=${#tokens}; j++ )); do
          next="${(Q)tokens[j]}"
          if [[ "$next" == /dev/* ]]; then
            TOOL_SAFETY_REASON="shredding a device must be run manually"
            return 1
          fi
        done
        ;;
    esac

    if [[ "$token" == '>' || "$token" == '>|' ]]; then
      next="${(Q)tokens[i+1]:-}"
      if [[ "$next" == /dev/* && "$next" != /dev/null ]]; then
        TOOL_SAFETY_REASON="direct redirection onto a device must be run manually"
        return 1
      fi
    fi
  done
  return 0
}
