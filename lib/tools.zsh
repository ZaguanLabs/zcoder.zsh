# Workspace-confined tools exposed to the model.

typeset -g ZCODER_WORKSPACE="${ZCODER_WORKSPACE:-$PWD}"
typeset -g ZCODER_COMMAND_POLICY="${ZCODER_COMMAND_POLICY:-ask}"
typeset -gi ZCODER_MAX_TOOL_OUTPUT="${ZCODER_MAX_TOOL_OUTPUT:-32768}"
typeset -g TOOL_RESULT=""
typeset -gi TOOL_RESULT_OK=0
typeset -g TOOL_SAFETY_REASON=""

tools_schema_json() {
  local output='[
{"type":"function","function":{"name":"list_files","description":"List files and directories below a workspace path while honoring .gitignore even outside a Git repository and excluding common dependency/build trees. Use a narrow path and modest max_entries only when project structure is unknown.","parameters":{"type":"object","properties":{"path":{"type":"string","description":"Narrow workspace-relative directory; defaults to ."},"max_entries":{"type":"integer","description":"Maximum entries; prefer a small limit; defaults to 100"}}}}},
{"type":"function","function":{"name":"read_file","description":"Read a complete UTF-8 text file. Expensive for context: use only for clearly small files or when every line is required; prefer search followed by read_file_range for source code.","parameters":{"type":"object","required":["path"],"properties":{"path":{"type":"string","description":"Workspace-relative path to a small file whose complete contents are needed"}}}}},
{"type":"function","function":{"name":"read_file_range","description":"Read an inclusive line range. This is the preferred file-reading tool after search locates the relevant section; normally request at most 200 lines.","parameters":{"type":"object","required":["path","start_line","end_line"],"properties":{"path":{"type":"string","description":"Workspace-relative file path"},"start_line":{"type":"integer","minimum":1},"end_line":{"type":"integer","minimum":1,"description":"Inclusive end line; normally no more than 200 lines after start_line"}}}}},
{"type":"function","function":{"name":"write_file","description":"Create or completely replace a workspace text file. Prefer apply_patch for focused edits.","parameters":{"type":"object","required":["path","content"],"properties":{"path":{"type":"string"},"content":{"type":"string"}}}}},
{"type":"function","function":{"name":"apply_patch","description":"Apply a complete standard unified diff rooted at the workspace using git apply or patch. Include --- a/path, +++ b/path, and @@ line-range headers. Do not use *** Begin Patch markers.","parameters":{"type":"object","required":["patch"],"properties":{"patch":{"type":"string","description":"Complete unified diff text, for example: --- a/file\n+++ b/file\n@@ -1 +1 @@\n-old\n+new"}}}}},
{"type":"function","function":{"name":"search","description":"First-choice project inspection: search workspace text with ripgrep and return file, line, column, and matching text. After finding a usable location, read its range instead of rephrasing the same search.","parameters":{"type":"object","required":["query"],"properties":{"query":{"type":"string","description":"Focused regular expression"},"path":{"type":"string","description":"Narrow workspace-relative search root; defaults to ."},"max_results":{"type":"integer","description":"Maximum matching lines; defaults to 50"}}}}},
{"type":"function","function":{"name":"run_command","description":"Run a shell command in the workspace after explicit user approval. Use for tests, builds, formatting, git status, and diagnostics.","parameters":{"type":"object","required":["command"],"properties":{"command":{"type":"string"},"cwd":{"type":"string","description":"Workspace-relative working directory; defaults to ."},"timeout_seconds":{"type":"integer","minimum":1,"maximum":3600}}}}}'
  if (( $+functions[skills_tools_schema_json] && ${#SKILL_CATALOG_NAMES} > 0 )); then
    skills_tools_schema_json
    output+=",${REPLY}"
  fi
  output+=',
{"type":"function","function":{"name":"finish","description":"End the current user turn. Call this as the only tool call when the task is complete or genuinely blocked; otherwise call a work tool instead. Put the complete user-facing final answer in response.","parameters":{"type":"object","required":["status","response"],"properties":{"status":{"type":"string","enum":["complete","blocked"]},"response":{"type":"string","description":"Complete user-facing result or exact blocker, in the same language as the user"}}}}}
]'
  REPLY="$output"
}

_tool_fail() {
  TOOL_RESULT_OK=0
  TOOL_RESULT="Error: $1"
  return 1
}

_tool_succeed() {
  TOOL_RESULT_OK=1
  zcoder_truncate "$1" "$ZCODER_MAX_TOOL_OUTPUT"
  TOOL_RESULT="$REPLY"
}

_tool_is_inside_workspace() {
  local resolved="$1" root="${ZCODER_WORKSPACE:A}"
  [[ "$resolved" == "$root" || "$resolved" == "$root"/* ]]
}

_tool_resolve_existing() {
  local requested="${1:-.}" candidate="" resolved=""
  if [[ "$requested" == /* ]]; then
    candidate="$requested"
  else
    candidate="${ZCODER_WORKSPACE}/${requested}"
  fi
  resolved="${candidate:A}"
  _tool_is_inside_workspace "$resolved" || { _tool_fail "path escapes the workspace: $requested"; return 1; }
  [[ -e "$resolved" ]] || { _tool_fail "path does not exist: $requested"; return 1; }
  REPLY="$resolved"
}

_tool_resolve_write_target() {
  local requested="$1" candidate="" parent="" resolved=""
  [[ -n "$requested" ]] || { _tool_fail "path is required"; return 1; }
  if [[ "$requested" == /* ]]; then
    candidate="$requested"
  else
    candidate="${ZCODER_WORKSPACE}/${requested}"
  fi
  parent="${candidate:h:A}"
  _tool_is_inside_workspace "$parent" || { _tool_fail "path escapes the workspace: $requested"; return 1; }
  resolved="${parent}/${candidate:t}"
  if [[ -e "$resolved" ]]; then
    resolved="${resolved:A}"
    _tool_is_inside_workspace "$resolved" || { _tool_fail "path resolves outside the workspace: $requested"; return 1; }
  fi
  REPLY="$resolved"
}

tool_list_files() {
  setopt localoptions extendedglob
  local requested="${1:-.}" max_entries="${2:-100}" base="" base_rel="" rel="" prefix="" line=""
  local out_file="${TMPDIR:-/tmp}/zcoder_list_${$}_${RANDOM}.out" raw=""
  local -a lines=() output=() segments=()
  local -A seen=()
  local -i count=0 truncated=0 exit_code=0 i j
  [[ "$max_entries" == <1-9999> ]] || max_entries=100
  _tool_resolve_existing "$requested" || return 1
  base="$REPLY"
  [[ -d "$base" ]] || { _tool_fail "not a directory: $requested"; return 1; }
  (( $+commands[rg] )) || { _tool_fail "list_files requires ripgrep (rg) to honor ignore files"; return 1; }

  # --no-require-git is the crucial bit: ripgrep otherwise discovers ignore
  # files only inside a repository. Zsh turns the resulting file paths back
  # into the directory-and-file tree expected by the tool contract.
  command rg --files --hidden --no-require-git --sort path \
    --glob '!.git/**' --glob '!.atlas/**' \
    --glob '!**/node_modules/**' --glob '!**/vendor/**' \
    --glob '!**/dist/**' --glob '!**/build/**' --glob '!**/target/**' \
    --glob '!**/coverage/**' --glob '!**/.next/**' \
    --glob '!**/.venv/**' --glob '!**/venv/**' --glob '!**/__pycache__/**' \
    -- "$base" >| "$out_file" 2>&1
  exit_code=$?
  raw="${mapfile[$out_file]}"
  zf_rm -f "$out_file" 2>/dev/null
  (( exit_code == 0 || exit_code == 1 )) || { _tool_fail "ripgrep file listing failed"$'\n'"$raw"; return 1; }
  [[ -n "$raw" ]] || { _tool_succeed "(no entries)"; return 0; }

  base_rel="${base#$ZCODER_WORKSPACE/}"
  [[ "$base" == "${ZCODER_WORKSPACE:A}" ]] && base_rel=""
  lines=("${(@f)raw}")
  for (( i=1; i<=${#lines}; i++ )); do
    line="${lines[i]}"
    rel="${line#$ZCODER_WORKSPACE/}"
    segments=("${(@s:/:)rel}")
    prefix=""
    for (( j=1; j<${#segments}; j++ )); do
      [[ -n "$prefix" ]] && prefix+="/"
      prefix+="${segments[j]}"
      [[ "$prefix" == "$base_rel" ]] && continue
      [[ -n "${seen[${prefix}/]:-}" ]] && continue
      if (( count >= max_entries )); then truncated=1; break 2; fi
      seen[${prefix}/]=1
      output+=("${prefix}/")
      (( count++ ))
    done
    [[ -n "${seen[$rel]:-}" ]] && continue
    if (( count >= max_entries )); then truncated=1; break; fi
    seen[$rel]=1
    output+=("$rel")
    (( count++ ))
  done
  if (( count == 0 )); then
    _tool_succeed "(no entries)"
  else
    _tool_succeed "${(F)output}"
    (( truncated )) && TOOL_RESULT+=$'\n'"[listing limited to ${max_entries} entries]"
  fi
  return 0
}

tool_read_file() {
  local requested="$1" resolved_path="" content=""
  _tool_resolve_existing "$requested" || return 1
  resolved_path="$REPLY"
  [[ -f "$resolved_path" ]] || { _tool_fail "not a regular file: $requested"; return 1; }
  content="${mapfile[$resolved_path]}"
  _tool_succeed "$content"
}

tool_read_file_range() {
  local requested="$1" start="$2" end="$3" resolved_path="" content="" output="" line=""
  local -a lines=()
  local -i i total
  [[ "$start" == <1-> && "$end" == <1-> ]] || { _tool_fail "start_line and end_line must be positive integers"; return 1; }
  (( end >= start )) || { _tool_fail "end_line must be greater than or equal to start_line"; return 1; }
  _tool_resolve_existing "$requested" || return 1
  resolved_path="$REPLY"
  [[ -f "$resolved_path" ]] || { _tool_fail "not a regular file: $requested"; return 1; }
  content="${mapfile[$resolved_path]}"
  lines=("${(@f)content}")
  total=${#lines}
  (( start <= total )) || { _tool_fail "start_line $start is past end of file ($total lines)"; return 1; }
  (( end > total )) && end=$total
  for (( i=start; i<=end; i++ )); do
    line="${lines[i]}"
    output+="${i}: ${line}"
    (( i < end )) && output+=$'\n'
  done
  _tool_succeed "$output"
}

tool_write_file() {
  local requested="$1" content="$2" resolved_path="" parent=""
  _tool_resolve_write_target "$requested" || return 1
  resolved_path="$REPLY"
  parent="${resolved_path:h}"
  zf_mkdir -p "$parent" 2>/dev/null || { _tool_fail "could not create directory: ${parent#$ZCODER_WORKSPACE/}"; return 1; }
  mapfile[$resolved_path]="$content" || { _tool_fail "could not write file: $requested"; return 1; }
  _tool_succeed "Wrote ${#content} characters to ${resolved_path#$ZCODER_WORKSPACE/}"
}

_tool_patch_paths_are_safe() {
  local patch_text="$1" line="" path="" resolved=""
  local -a lines=("${(@f)patch_text}")
  local -i paths=0
  for line in "${lines[@]}"; do
    case "$line" in
      ('--- '*|'+++ '*|'*** '*)
        if [[ ( "$line" == '*** '* && "$line" == *' ****' ) ||
              ( "$line" == '--- '* && "$line" == *' ----' ) ]]; then
          continue
        fi
        path="${line#??? }"
        # Unified/context diff timestamps are tab-separated. Quoted Git paths
        # are left to git apply; patch fallback deliberately rejects them.
        path="${path%%$'\t'*}"
        [[ "$path" == /dev/null ]] && continue
        [[ "$path" == '"'* || "$path" == *'"' ]] && return 1
        [[ "$path" == a/* || "$path" == b/* ]] && path="${path#?/}"
        [[ -n "$path" && "$path" != /* && "$path" != *'../'* && "$path" != ../* && "$path" != */.. && "$path" != .. ]] || return 1
        _tool_resolve_write_target "$path" >/dev/null || return 1
        resolved="$REPLY"
        _tool_is_inside_workspace "$resolved" || return 1
        (( paths++ ))
        ;;
    esac
  done
  (( paths >= 2 ))
}

_tool_patch_strip_level() {
  local patch_text="$1"
  if [[ "$patch_text" == *$'\n--- a/'* || "$patch_text" == '--- a/'* ||
        "$patch_text" == *$'\n+++ b/'* || "$patch_text" == '+++ b/'* ]]; then
    REPLY=1
  else
    REPLY=0
  fi
}

tool_apply_patch() {
  local patch_text="$1" patch_file="${TMPDIR:-/tmp}/zcoder_patch_${$}_${RANDOM}.diff"
  local out_file="${TMPDIR:-/tmp}/zcoder_patch_${$}_${RANDOM}.out"
  local git_error="" patch_error="" output="" engine="" guidance=""
  local -i exit_code=1 strip=0
  [[ -n "$patch_text" ]] || { _tool_fail "patch is empty"; return 1; }
  if [[ "$patch_text" == *'*** Begin Patch'* ]]; then
    _tool_fail $'unsupported patch envelope: send a complete standard unified diff without *** Begin Patch markers\nRequired form:\n--- a/path\n+++ b/path\n@@ -OLD_START,OLD_COUNT +NEW_START,NEW_COUNT @@\n-old line\n+new line'
    return 1
  fi
  (( $+commands[git] || $+commands[patch] )) || { _tool_fail "apply_patch requires git or patch"; return 1; }
  mapfile[$patch_file]="$patch_text"

  if (( $+commands[git] )); then
    command git -C "$ZCODER_WORKSPACE" apply --check --recount --unidiff-zero --whitespace=nowarn "$patch_file" >| "$out_file" 2>&1
    exit_code=$?
    git_error="${mapfile[$out_file]}"
    if (( exit_code == 0 )); then
      command git -C "$ZCODER_WORKSPACE" apply --recount --unidiff-zero --whitespace=nowarn "$patch_file" >| "$out_file" 2>&1
      exit_code=$?
      output="${mapfile[$out_file]}"
      (( exit_code == 0 )) && engine="git apply"
      (( exit_code != 0 )) && git_error+=$'\n'"$output"
    fi
  fi

  if [[ -z "$engine" ]] && (( $+commands[patch] )); then
    if _tool_patch_paths_are_safe "$patch_text"; then
      _tool_patch_strip_level "$patch_text"; strip=$REPLY
      command patch --directory="$ZCODER_WORKSPACE" --strip="$strip" --batch --forward --dry-run --input="$patch_file" >| "$out_file" 2>&1
      exit_code=$?
      patch_error="${mapfile[$out_file]}"
      if (( exit_code == 0 )); then
        command patch --directory="$ZCODER_WORKSPACE" --strip="$strip" --batch --forward --input="$patch_file" >| "$out_file" 2>&1
        exit_code=$?
        output="${mapfile[$out_file]}"
        (( exit_code == 0 )) && engine="patch -p${strip}"
        (( exit_code != 0 )) && patch_error+=$'\n'"$output"
      fi
    else
      patch_error="patch fallback rejected unsafe, ambiguous, or missing file paths"
    fi
  fi

  zf_rm -f "$patch_file" "$out_file" 2>/dev/null
  if [[ -z "$engine" ]]; then
    guidance=$'Send a complete unified diff with ---/+++/@@ headers. Re-read the current file before retrying; do not switch to write_file for a focused edit.'
    _tool_fail "patch rejected"$'\n'"${git_error:+git apply: ${git_error}}"$'\n'"${patch_error:+patch: ${patch_error}}"$'\n'"$guidance"
    return 1
  fi
  _tool_succeed "Patch applied successfully with ${engine}.${output:+$'\n'$output}"
}

tool_search() {
  local query="$1" requested="${2:-.}" max_results="${3:-50}" resolved_path=""
  local out_file="${TMPDIR:-/tmp}/zcoder_search_${$}_${RANDOM}.out" raw="" line=""
  local -a lines=() selected=()
  local -i i limit exit_code
  [[ -n "$query" ]] || { _tool_fail "query is required"; return 1; }
  (( $+commands[rg] )) || { _tool_fail "search requires ripgrep (rg)"; return 1; }
  [[ "$max_results" == <1-9999> ]] || max_results=50
  limit=$max_results
  _tool_resolve_existing "$requested" || return 1
  resolved_path="$REPLY"
  command rg --line-number --column --color never --hidden --no-require-git \
    --glob '!.git/**' --glob '!.atlas/**' \
    --glob '!**/node_modules/**' --glob '!**/vendor/**' \
    --glob '!**/dist/**' --glob '!**/build/**' --glob '!**/target/**' \
    --glob '!**/coverage/**' --glob '!**/.next/**' \
    --glob '!**/.venv/**' --glob '!**/venv/**' --glob '!**/__pycache__/**' \
    -- "$query" "$resolved_path" >| "$out_file" 2>&1
  exit_code=$?
  raw="${mapfile[$out_file]}"
  zf_rm -f "$out_file" 2>/dev/null
  (( exit_code == 0 || exit_code == 1 )) || { _tool_fail "ripgrep failed"$'\n'"$raw"; return 1; }
  [[ -n "$raw" ]] || { _tool_succeed "No matches."; return 0; }
  lines=("${(@f)raw}")
  for (( i=1; i<=${#lines} && i<=limit; i++ )); do
    line="${lines[i]}"
    line="${line#$ZCODER_WORKSPACE/}"
    selected+=("$line")
  done
  _tool_succeed "${(F)selected}"
  (( ${#lines} > limit )) && TOOL_RESULT+=$'\n'"[results limited to ${limit} lines]"
  return 0
}

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

tool_approve_command() {
  local command_text="$1" answer=""
  local -i per_command=0
  [[ "$ZCODER_PROFILE" == sysadmin ]] && per_command=1
  case "$ZCODER_COMMAND_POLICY" in
    allow) (( per_command )) || return 0 ;;
    deny) return 1 ;;
  esac
  if (( $+functions[ui_confirm_command] )); then
    ui_confirm_command "$command_text"
    answer="$REPLY"
  elif [[ -r /dev/tty && -w /dev/tty ]]; then
    print -r -- $'\n'"Command approval requested:" > /dev/tty
    print -r -- "  $command_text" > /dev/tty
    if (( per_command )); then
      print -rn -- "Allow this exact command once? [y/N]: " > /dev/tty
    else
      print -rn -- "Allow? [y] once / [a] session / [N] deny: " > /dev/tty
    fi
    read -r answer < /dev/tty
  else
    answer="n"
  fi
  case "${(L)answer}" in
    y|yes|once) return 0 ;;
    a|always|session)
      (( per_command )) && return 1
      ZCODER_COMMAND_POLICY="allow"
      return 0
      ;;
    *) return 1 ;;
  esac
}

tool_run_command() {
  local command_text="$1" requested="${2:-.}" timeout_seconds="${3:-120}" cwd=""
  local out_file="${TMPDIR:-/tmp}/zcoder_command_${$}_${RANDOM}.out" output="" exit_code=""
  [[ -n "$command_text" ]] || { _tool_fail "command is required"; return 1; }
  [[ "$timeout_seconds" == <1-3600> ]] || timeout_seconds=120
  _tool_resolve_existing "$requested" || return 1
  cwd="$REPLY"
  [[ -d "$cwd" ]] || { _tool_fail "cwd is not a directory: $requested"; return 1; }
  if ! tool_sysadmin_command_guard "$command_text"; then
    _tool_fail "sysadmin safety policy blocked command: $TOOL_SAFETY_REASON"
    return 1
  fi
  if ! tool_approve_command "$command_text"; then
    _tool_fail "user denied command: $command_text"
    return 1
  fi

  if (( $+commands[timeout] )); then
    command timeout --signal=TERM --kill-after=2 "$timeout_seconds" \
      zsh -c "cd ${(q)cwd} && ${command_text}" >| "$out_file" 2>&1
  else
    command zsh -c "cd ${(q)cwd} && ${command_text}" >| "$out_file" 2>&1
  fi
  exit_code=$?
  output="${mapfile[$out_file]}"
  zf_rm -f "$out_file" 2>/dev/null
  zcoder_truncate "$output" "$ZCODER_MAX_TOOL_OUTPUT"; output="$REPLY"
  if (( exit_code == 124 )); then
    _tool_fail "command timed out after ${timeout_seconds}s"$'\n'"$output"
    return 1
  fi
  TOOL_RESULT_OK=$(( exit_code == 0 ))
  TOOL_RESULT="Exit code: ${exit_code}"$'\n'"${output:-\(no output\)}"
  (( exit_code == 0 ))
}

tool_dispatch() {
  local name="$1" args_json="$2"
  if ! json_parse_flat_object "$args_json"; then
    _tool_fail "invalid arguments for $name: ${JSON_ERROR:-parse error}"
    return 1
  fi
  case "$name" in
    list_files) tool_list_files "${JSON_OBJECT[path]:-.}" "${JSON_OBJECT[max_entries]:-100}" ;;
    read_file) tool_read_file "${JSON_OBJECT[path]:-}" ;;
    read_file_range) tool_read_file_range "${JSON_OBJECT[path]:-}" "${JSON_OBJECT[start_line]:-}" "${JSON_OBJECT[end_line]:-}" ;;
    write_file) tool_write_file "${JSON_OBJECT[path]:-}" "${JSON_OBJECT[content]:-}" ;;
    apply_patch) tool_apply_patch "${JSON_OBJECT[patch]:-}" ;;
    search) tool_search "${JSON_OBJECT[query]:-}" "${JSON_OBJECT[path]:-.}" "${JSON_OBJECT[max_results]:-50}" ;;
    run_command) tool_run_command "${JSON_OBJECT[command]:-}" "${JSON_OBJECT[cwd]:-.}" "${JSON_OBJECT[timeout_seconds]:-120}" ;;
    activate_skill) skills_activate "${JSON_OBJECT[name]:-}" ;;
    read_skill_resource) skills_read_resource "${JSON_OBJECT[name]:-}" "${JSON_OBJECT[path]:-}" ;;
    *) _tool_fail "unknown tool: $name" ;;
  esac
}
