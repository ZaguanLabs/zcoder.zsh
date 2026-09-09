# Select zdraw or stock curses before starting a terminal session.
# Never replace an already loaded module or modify the system installation.
typeset -g ZCODER_CURSES_BACKEND=unloaded
typeset -g ZCODER_CURSES_MODULE=zsh/curses ZCODER_CURSES_COMMAND=zcurses

# No locals: module output parameters must reach the caller's dynamic scope.
zcoder_curses() { builtin "$ZCODER_CURSES_COMMAND" "$@"; }

# Return the selected module's optional features in the caller-owned reply array.
zcoder_curses_features() {
  emulate -L zsh
  local feature_parameter=${ZCODER_CURSES_COMMAND}_features
  reply=()
  zmodload -F -e "$ZCODER_CURSES_MODULE" "+p:$feature_parameter" || return 1
  reply=("${(@P)feature_parameter}")
}

zcoder_curses_load() {
  emulate -L zsh
  local root="${1:-$ZCODER_DIR}/vendor/zdraw/.build"
  local signature="$ZSH_VERSION:$ZSH_PATCHLEVEL:$MACHTYPE:$OSTYPE:$HOST"
  local policy=${ZCODER_CURSES:-auto}
  case "$policy" in
    auto|stock) ;;
    *) print -u2 -r -- 'Error: ZCODER_CURSES expects auto or stock'; return 1 ;;
  esac
  if [[ $ZCODER_CURSES_BACKEND != unloaded ]] && zmodload -e "$ZCODER_CURSES_MODULE"; then
    return 0
  fi
  if zmodload -e zsh/curses; then
    ZCODER_CURSES_MODULE=zsh/curses ZCODER_CURSES_COMMAND=zcurses
    ZCODER_CURSES_BACKEND=preloaded
    return 0
  fi
  if zmodload -e zdraw; then
    ZCODER_CURSES_MODULE=zdraw ZCODER_CURSES_COMMAND=zdraw
    ZCODER_CURSES_BACKEND=preloaded
    return 0
  fi
  # Host identity also prevents rsynced native binaries being selected on the
  # farm. The build stamp is data, never sourced as shell code.
  if [[ $policy == auto && -r $root/zcoder-abi &&
        -f $root/modules/zdraw.so && $(<"$root/zcoder-abi") == "$signature" ]]; then
    local -a module_path=("$root/modules" "${module_path[@]}")
    if zmodload zdraw 2>/dev/null; then
      ZCODER_CURSES_BACKEND=bundled
      ZCODER_CURSES_MODULE=zdraw ZCODER_CURSES_COMMAND=zdraw
      return 0
    fi
    module_path=("${module_path[@]:1}")
  fi
  zmodload zsh/curses || return 1
  ZCODER_CURSES_BACKEND=stock
  ZCODER_CURSES_MODULE=zsh/curses ZCODER_CURSES_COMMAND=zcurses
}
