# Select the locally built dependency before anything loads zsh/curses.
# Never replace an already loaded module or modify the system installation.
typeset -g ZCODER_CURSES_BACKEND=unloaded

zcoder_curses_load() {
  emulate -L zsh
  local root="${1:-$ZCODER_DIR}/vendor/zcurses/.build"
  local signature="$ZSH_VERSION:$ZSH_PATCHLEVEL:$MACHTYPE:$OSTYPE:$HOST"
  local policy=${ZCODER_CURSES:-auto}
  case "$policy" in
    auto|stock) ;;
    *) print -u2 -r -- 'Error: ZCODER_CURSES expects auto or stock'; return 1 ;;
  esac
  if zmodload -e zsh/curses; then
    [[ $ZCODER_CURSES_BACKEND == unloaded ]] && ZCODER_CURSES_BACKEND=preloaded
    return 0
  fi
  # Host identity also prevents rsynced native binaries being selected on the
  # farm. The build stamp is data, never sourced as shell code.
  if [[ $policy == auto && -r $root/zcoder-abi &&
        -f $root/modules/zsh/curses.so && $(<"$root/zcoder-abi") == "$signature" ]]; then
    local -a module_path=("$root/modules" "${module_path[@]}")
    if zmodload zsh/curses 2>/dev/null; then
      ZCODER_CURSES_BACKEND=bundled
      return 0
    fi
    module_path=("${module_path[@]:1}")
  fi
  zmodload zsh/curses || return 1
  ZCODER_CURSES_BACKEND=stock
}
