# Small native Zsh helpers shared by the TUI and tools.

typeset -ga ZCODER_WRAPPED=() ZCODER_WRAPPED_LENGTHS=()
typeset -g ZCODER_DEBUG_LOG="${ZCODER_DEBUG_LOG:-}"
typeset -gi ZCODER_DEBUG_ACTIVE=0
typeset -gi ZCODER_DEBUG_MAX_CHARS="${ZCODER_DEBUG_MAX_CHARS:-16000}"
typeset -gi ZCODER_DEBUG_FD=-1
typeset -g ZCODER_RUNTIME_PARENT="" ZCODER_RUNTIME_DIR=""
typeset -gi ZCODER_RUNTIME_SEQUENCE=0

# Display-only repository metadata, independent of Git, curses, and tool access.
# Walk from the workspace (not $PWD); gitfiles cover worktrees and submodules.
# Only read HEAD: never evaluate repository contents or traverse the work tree.
zcoder_git_status() {
  emulate -L zsh
  setopt extendedglob
  local directory="${1:A}" gitdir='' line='' head=''
  REPLY='No Git'
  [[ -n "$1" && -d "$directory" ]] || return 0
  while true; do
    if [[ -d "$directory/.git" ]]; then
      gitdir="$directory/.git"
      break
    elif [[ -f "$directory/.git" ]]; then
      REPLY='Git: unavailable'
      { IFS= read -r line < "$directory/.git"; } 2>/dev/null
      [[ "$line" == 'gitdir: '?* ]] || return 0
      gitdir="${line#gitdir: }"
      [[ "$gitdir" == /* ]] || gitdir="$directory/$gitdir"
      break
    elif [[ -f "$directory/HEAD" && -d "$directory/objects" && -d "$directory/refs" ]]; then
      gitdir="$directory"
      break
    fi
    [[ "$directory" == / ]] && return 0
    directory="${directory:h}"
  done
  REPLY='Git: unavailable'
  [[ -f "$gitdir/HEAD" && -r "$gitdir/HEAD" ]] || return 0
  { IFS= read -r head < "$gitdir/HEAD"; } 2>/dev/null
  if [[ "$head" == 'ref: refs/heads/'?* ]]; then
    REPLY="Git: ${head#ref: refs/heads/}"
  elif [[ "$head" == [[:xdigit:]]## ]] && (( ${#head} == 40 || ${#head} == 64 )); then
    REPLY="Git: detached ${head[1,8]}"
  fi
  return 0
}

# syswrite(1) may successfully write only part of its input. Keep the byte
# boundary explicit so large HTTP payloads and files cannot be silently
# truncated. Callers own and close the descriptor.
zcoder_syswrite_all() {
  emulate -L zsh
  setopt nomultibyte
  local fd="$1" remaining="${2:-}"
  local -i written=0
  while (( ${#remaining} > 0 )); do
    written=0
    syswrite -c written -o "$fd" -- "$remaining" 2>/dev/null || return 1
    (( written > 0 && written <= ${#remaining} )) || return 1
    (( written == ${#remaining} )) && return 0
    remaining="${remaining[$(( written + 1 )),-1]}"
  done
  return 0
}

# Create one private scratch directory for this process. Individual subsystems
# allocate names below it, where another user cannot pre-create symlinks for
# predictable output files. mkdir is the atomic capability check.
zcoder_runtime_init() {
  emulate -L zsh
  if [[ -n "$ZCODER_RUNTIME_DIR" && -d "$ZCODER_RUNTIME_DIR" ]]; then
    return 0
  fi

  local parent="${TMPDIR:-/tmp}" candidate="" old_umask="$(umask)"
  local -i attempt
  parent="${parent:A}"
  [[ -d "$parent" && -w "$parent" ]] || return 1
  umask 077
  for (( attempt=1; attempt<=32; attempt++ )); do
    candidate="${parent%/}/zcoder-${UID}-${sysparams[pid]:-$$}-${RANDOM}-${attempt}"
    if zf_mkdir -- "$candidate" 2>/dev/null; then
      ZCODER_RUNTIME_PARENT="$parent"
      ZCODER_RUNTIME_DIR="$candidate"
      ZCODER_RUNTIME_SEQUENCE=0
      umask "$old_umask"
      return 0
    fi
  done
  umask "$old_umask"
  return 1
}

zcoder_temp_path() {
  emulate -L zsh
  setopt extendedglob
  local prefix="${1:-tmp}" suffix="${2:-}"
  [[ "$prefix" == [A-Za-z0-9_.-]## ]] || prefix="tmp"
  zcoder_runtime_init || return 1
  (( ZCODER_RUNTIME_SEQUENCE++ ))
  REPLY="${ZCODER_RUNTIME_DIR}/${prefix}.${sysparams[pid]:-$$}.${ZCODER_RUNTIME_SEQUENCE}${suffix}"
}

zcoder_runtime_cleanup() {
  emulate -L zsh
  local directory="$ZCODER_RUNTIME_DIR" parent="$ZCODER_RUNTIME_PARENT"
  ZCODER_RUNTIME_DIR=""
  ZCODER_RUNTIME_PARENT=""
  ZCODER_RUNTIME_SEQUENCE=0
  [[ -n "$directory" && -n "$parent" && -d "$directory" ]] || return 0
  [[ "${directory:h:A}" == "$parent" && "${directory:t}" == zcoder-${UID}-* ]] || return 1
  zf_rm -rf -- "$directory" 2>/dev/null
}

# Preserve newlines while rendering every other control character visibly.
# This is for direct terminal output only; persisted transcripts remain exact.
zcoder_terminal_safe() {
  emulate -L zsh
  local -a lines=("${(@ps:\n:)1}")
  REPLY="${(F)${(@V)lines}}"
}

# Display only: execution and approval continue to use the original argument.
zcoder_display_path() {
  local requested="$1" workspace_root='' resolved='' prefix=''
  REPLY="$requested"
  [[ "$requested" == /* && -n "${ZCODER_WORKSPACE:-}" ]] || return 0
  if [[ "${REMOTE_MODE:-local}" == client ]]; then
    # Remote paths must not be resolved through the client's filesystem.
    workspace_root="${ZCODER_WORKSPACE:a}"; resolved="${requested:a}"
  else
    workspace_root="${ZCODER_WORKSPACE:A}"; resolved="${requested:A}"
  fi
  prefix="${workspace_root%/}/"
  if [[ "$resolved" == "$workspace_root" ]]; then REPLY='.'
  elif [[ "$resolved" == "$prefix"* ]]; then REPLY="${resolved#"$prefix"}"
  fi
}

zcoder_fd_safe() {
  emulate -L zsh
  local fd="$1" value="${2:-}"
  if [[ -t "$fd" ]]; then
    zcoder_terminal_safe "$value"
  else
    REPLY="$value"
  fi
}

# Open the final path without following a last-moment symlink and write its
# complete text through the owned descriptor. New files use the caller's umask.
zcoder_write_text_file() {
  emulate -L zsh
  local path="$1" content="${2:-}" options="create,excl,nofollow,cloexec" fd=""
  local -i write_status=0 close_status=0
  [[ -h "$path" && ! -e "$path" ]] && return 1
  [[ -e "$path" && ! -f "$path" ]] && return 1
  [[ -e "$path" ]] && options="truncate,nofollow,cloexec"
  sysopen -w -m 0666 -o "$options" -u fd -- "$path" 2>/dev/null || return 1
  {
    [[ -z "$content" ]] || zcoder_syswrite_all "$fd" "$content" || write_status=$?
  } always {
    exec {fd}>&- || close_status=$?
    (( write_status )) || write_status=$close_status
  }
  return "$write_status"
}

# Debugging must never write through curses. The opt-in logger appends escaped,
# single-line records to a private file so a broken model turn can be inspected
# after the UI returns to Ready.
zcoder_debug_init() {
  [[ -n "$ZCODER_DEBUG_LOG" ]] || return 0
  (( ZCODER_DEBUG_ACTIVE && ZCODER_DEBUG_FD >= 0 )) && return 0
  local requested="$ZCODER_DEBUG_LOG" parent="${ZCODER_DEBUG_LOG:h:A}" old_umask="$(umask)"
  ZCODER_DEBUG_LOG="${parent}/${requested:t}"
  umask 077
  zf_mkdir -p "$parent" 2>/dev/null || { umask "$old_umask"; return 1; }
  if [[ ( ! -e "$ZCODER_DEBUG_LOG" || -O "$ZCODER_DEBUG_LOG" ) && ! -h "$ZCODER_DEBUG_LOG" ]] && \
     sysopen -a -m 0600 -o creat,nofollow,cloexec -u ZCODER_DEBUG_FD -- "$ZCODER_DEBUG_LOG" 2>/dev/null; then
    zf_chmod 600 "$ZCODER_DEBUG_LOG" 2>/dev/null || true
    zcoder_syswrite_all "$ZCODER_DEBUG_FD" "[${EPOCHREALTIME:-0}] pid=$$ debug_start log=${ZCODER_DEBUG_LOG}"$'\n' || {
      exec {ZCODER_DEBUG_FD}>&-
      ZCODER_DEBUG_FD=-1
      umask "$old_umask"
      return 1
    }
    ZCODER_DEBUG_ACTIVE=1
  fi
  umask "$old_umask"
  (( ZCODER_DEBUG_ACTIVE ))
}

zcoder_debug() {
  (( ZCODER_DEBUG_ACTIVE )) || return 0
  local event="${1:-event}" detail="${2:-}"
  detail="${detail//$'\r'/\\r}"
  detail="${detail//$'\n'/\\n}"
  detail="${detail//$'\t'/\\t}"
  if (( ${#detail} > ZCODER_DEBUG_MAX_CHARS )); then
    detail="${detail[1,$ZCODER_DEBUG_MAX_CHARS]}...[debug record truncated]"
  fi
  zcoder_syswrite_all "$ZCODER_DEBUG_FD" "[${EPOCHREALTIME:-0}] pid=$$ ${event} ${detail}"$'\n' || true
}

zcoder_debug_close() {
  (( ZCODER_DEBUG_FD >= 0 )) && exec {ZCODER_DEBUG_FD}>&-
  ZCODER_DEBUG_FD=-1
  ZCODER_DEBUG_ACTIVE=0
}

# Clip to terminal cells without separating a base from its combining marks.
# REPLY retains original text; callers which require padding add it separately.
zcoder_clip() {
  local value="$1" ch=""
  local -i width=${2:-0} cells=0 size=0
  REPLY=""
  (( width >= 0 )) || return 0
  if [[ "$value" != *[^\ -~]* ]]; then REPLY="${value[1,width]}"; return 0; fi
  if (( ${(m)#value} <= width )); then REPLY="$value"; return 0; fi
  for ch in "${(@s::)value}"; do
    size=${(m)#ch}
    (( cells + size <= width )) || break
    REPLY+="$ch"
    (( cells += size ))
  done
  return 0
}

# Shared hard/word wrapper. Output lengths count original characters, while
# limits count display cells. Printable ASCII keeps the arithmetic fast path.
# A glyph wider than the entire window is represented by '?' to make progress
# without overflowing curses; its original character still counts as consumed.
zcoder_hard_wrap() { _zcoder_wrap_cells "$1" "${2:-1}" 0; }
zcoder_wrap() { _zcoder_wrap_cells "$1" "${2:-1}" 1; }

_zcoder_wrap_cells() {
  local text="$1" probe="" prefix="" ch=""
  local -i width=${2:-1} word_wrap=${3:-0} pos=1 total end cells size consumed ascii=0 cut
  local -a chars=()
  ZCODER_WRAPPED=(); ZCODER_WRAPPED_LENGTHS=()
  (( width < 1 )) && width=1
  [[ -z "$text" ]] && { ZCODER_WRAPPED=(""); ZCODER_WRAPPED_LENGTHS=(0); return 0; }
  [[ "$text" != *[^\ -~]* ]] && ascii=1
  chars=("${(@s::)text}"); total=${#chars}
  while (( pos <= total )); do
    if (( ascii )); then
      end=$(( pos + width )); (( end > total + 1 )) && end=$(( total + 1 ))
      probe="${(j::)chars[pos,end-1]}"
    else
      end=$pos; cells=0; probe=""
      while (( end <= total )); do
        ch="${chars[end]}"; size=${(m)#ch}
        if (( cells + size > width )); then
          if (( end == pos )); then probe='?'; (( end++ )); fi
          break
        fi
        probe+="$ch"; (( cells += size, end++ ))
      done
    fi
    if (( word_wrap && end <= total )); then
      prefix="${probe%[[:space:]]*}"
      if [[ "${chars[end]}" == [[:space:]] ]]; then
        while (( end <= total )) && [[ "${chars[end]}" == [[:space:]] ]]; do (( end++ )); done
      elif [[ -n "$prefix" && "$prefix" != "$probe" ]]; then
        cut=${#prefix}; probe="$prefix"; end=$(( pos + cut ))
        while (( end <= total )) && [[ "${chars[end]}" == [[:space:]] ]]; do (( end++ )); done
      fi
    fi
    consumed=$(( end - pos ))
    ZCODER_WRAPPED+=("$probe"); ZCODER_WRAPPED_LENGTHS+=("$consumed")
    pos=$end
  done
  return 0
}

zcoder_pad() {
  local value="$1"
  local -i width=${2:-0} padding=0
  zcoder_clip "$value" "$width"
  padding=$(( width - ${(m)#REPLY} ))
  (( padding > 0 )) && REPLY+="${(pl:padding:: :)}"
  return 0
}

zcoder_time() {
  strftime -s REPLY '%H:%M'
}

zcoder_truncate() {
  local value="$1" limit="${2:-${ZCODER_MAX_TOOL_OUTPUT:-32768}}"
  if (( ${#value} > limit )); then
    REPLY="${value[1,$limit]}"$'\n'"[output truncated at ${limit} characters]"
  else
    REPLY="$value"
  fi
}

# Preserve both the beginning and the diagnostic tail of bounded tool output.
# Commands commonly put the actual failure and summary after voluminous logs.
zcoder_truncate_head_tail() {
  local value="$1" limit="${2:-${ZCODER_MAX_TOOL_OUTPUT:-32768}}" marker=""
  local -i omitted head tail
  if (( ${#value} <= limit )); then
    REPLY="$value"
    return 0
  fi
  omitted=$(( ${#value} - limit ))
  marker=$'\n'"[... ${omitted} characters omitted ...]"$'\n'
  if (( limit <= ${#marker} + 16 )); then
    REPLY="${value[1,$limit]}"
    return 0
  fi
  head=$(( (limit - ${#marker}) * 3 / 5 ))
  tail=$(( limit - ${#marker} - head ))
  REPLY="${value[1,$head]}${marker}${value[-$tail,-1]}"
}
