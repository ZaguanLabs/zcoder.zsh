# Bounded ripgrep collection and presentation, independent of the UI and model.
# The worker owns its coprocess; helpers share only search_worker's local state.

_search_next_record() {
  emulate -L zsh
  setopt nomultibyte
  local delimiter="$1" chunk=''
  local -i received=0 read_status=0
  while [[ "$search_buffer" != *"$delimiter"* ]]; do
    if (( search_bytes >= 2097152 )); then search_limited=1; return 1; fi
    if (( EPOCHREALTIME >= search_deadline )); then search_timed_out=1; return 1; fi
    zselect -r "$search_fd" -t 10 2>/dev/null || continue
    chunk=''; received=0
    sysread -i "$search_fd" -s 8192 -c received chunk 2>/dev/null
    read_status=$?
    (( read_status == 0 || read_status == 5 )) || {
      search_error='Could not read ripgrep output.'; return 1
    }
    if (( received == 0 )); then
      if [[ "$search_buffer" == *': binary file matches ('* ]]; then
        search_error='The requested file contains binary data; search supports text files.'
      elif [[ -n "$search_buffer" ]]; then
        search_error='Incomplete ripgrep output record.'
      fi
      return 1
    fi
    (( search_bytes += received ))
    search_buffer+="$chunk"
  done
  REPLY="${search_buffer%%"$delimiter"*}"
  search_buffer="${search_buffer#*"$delimiter"}"
}

_search_collect() {
  emulate -L zsh
  setopt extendedglob
  local filename='' record='' number='' resolved='' key=''
  local -i file_id=0 count=0
  while _search_next_record $'\0'; do
    filename="$REPLY"
    resolved="${filename:A}"
    [[ "$resolved" == "$search_root" || "$resolved" == "${search_root%/}/"* ]] || {
      search_error='Search returned a path outside the workspace.'; return 1
    }
    if [[ "$search_mode" == content ]]; then
      _search_next_record $'\n' || break
      record="$REPLY"
      number="${record%%[^0-9]*}"
      [[ "$number" == <1-> && ${#number} -le 9 ]] || {
        search_error='Invalid ripgrep location record.'; return 1
      }
    fi
    file_id=${search_ids[$resolved]:-0}
    if (( ! file_id )); then
      if (( ${#search_paths} >= search_candidates )); then search_limited=1; break; fi
      search_paths+=("$resolved")
      file_id=${#search_paths}
      search_ids[$resolved]=$file_id
    fi
    [[ "$search_mode" == files ]] && continue
    key="$file_id:$number"
    search_rows[$key]="$record"
    if [[ "$record" == "$number:"* ]]; then
      count=$(( ${search_counts[$file_id]:-0} + 1 ))
      search_counts[$file_id]=$count
      search_matches[$file_id:$count]=$number
      (( count < search_per_file )) || search_capped=1
    fi
  done
  return 0
}

_search_render() {
  emulate -L zsh
  local output='' header='' relative='' body='' block='' key='' notice=''
  local -A quotas=() printed=()
  local -i file_id=0 count=0 selected=0 round=0 active=0 total=0
  local -i available=0 quota=0 anchor=0 first=0 last=0 line_no=0 radius=0 share=0 room=0
  local -i shown_files=0 remaining=$(( search_budget - 112 )) clipped=0 next_line=0
  local -a headers=()
  # Reserve headers before sharing the remaining budget. Paths are JSON quoted
  # so colons, newlines and shell metacharacters cannot corrupt result framing.
  for (( file_id=1; file_id<=${#search_paths} && file_id<=search_limit; file_id++ )); do
    relative="${search_paths[file_id]#${search_root%/}/}"
    zjson_quote "$relative"; header="$REPLY"
    [[ "$search_mode" == content ]] && header="File: $header"
    if [[ "$search_mode" == content ]]; then
      # Each file needs room for a matching line and a continuation marker.
      (( remaining - ${#header} - 2 >= (${#headers} + 1) * 123 )) || { clipped=1; break; }
    else
      (( ${#header} + 2 <= remaining )) || { clipped=1; break; }
    fi
    headers+=("$header")
    (( remaining -= ${#header} + 2 ))
  done
  shown_files=${#headers}
  (( shown_files < ${#search_paths} )) && clipped=1
  if [[ "$search_mode" == files ]]; then
    output="${(F)headers}"
  elif (( shown_files )); then
    # Select one match per file per round, so a noisy file cannot spend the
    # entire match budget before another file gets a chance to contribute.
    while (( selected < search_limit )); do
      active=0; (( round++ ))
      for (( file_id=1; file_id<=shown_files && selected<search_limit; file_id++ )); do
        if (( ${search_counts[$file_id]:-0} >= round )); then
          quotas[$file_id]=$round; (( selected++ )); active=1
        fi
      done
      (( active )) || break
    done
    share=$(( remaining / shown_files ))
    for (( file_id=1; file_id<=shown_files; file_id++ )); do
      body=''; printed=(); quota=${quotas[$file_id]:-0}
      available=${search_counts[$file_id]:-0}; count=0
      for (( anchor=1; anchor<=quota; anchor++ )); do
        line_no=${search_matches[$file_id:$anchor]}
        (( ${+printed[$line_no]} )) && { count=$anchor; continue; }
        room=$(( share - ${#body} - 75 ))
        (( room >= 48 )) || break
        radius=$search_context
        # Context is optional; the matching line always takes precedence when
        # a file's share is small. ripgrep has already merged overlapping spans.
        while true; do
          block=''; first=$(( line_no - radius )); last=$(( line_no + radius ))
          (( first > 0 )) || first=1
          for (( total=first; total<=last; total++ )); do
            key="$file_id:$total"
            (( ${+search_rows[$key]} && ! ${+printed[$total]} )) || continue
            block+="${search_rows[$key]}"$'\n'
          done
          (( ${#block} <= room || radius == 0 )) && break
          (( radius-- ))
        done
        if (( ${#block} > room )); then
          block="${block[1,$(( room - 23 ))]} [clipped; read range]"$'\n'
        fi
        body+="$block"
        for (( total=first; total<=last; total++ )); do printed[$total]=1; done
        count=$anchor
      done
      while (( count < available )); do
        next_line=${search_matches[$file_id:$((count + 1))]}
        (( ${+printed[$next_line]} )) || break
        (( count++ ))
      done
      if (( count < available )); then
        next_line=${search_matches[$file_id:$((count + 1))]}
        body+="[more matches; next line $next_line; narrow path or read_file_range]"$'\n'
        clipped=1
      fi
      output+="${headers[file_id]}"$'\n'"$body"$'\n'
    done
  fi
  if (( search_limited )); then
    notice='[Search collection limited; results are partial. Narrow path/glob and search again.]'
  elif (( search_capped )); then
    notice="[Per-file scan capped at $search_per_file matches; results may be partial. Narrow the query or use read_file_range.]"
  elif (( clipped )); then
    notice='[Results limited; narrow path/glob, use mode=files, or increase max_results/max_chars.]'
  fi
  [[ -z "$notice" ]] || output+=$'\n'"$notice"
  if [[ -z "$output" ]]; then
    output='No text matches. search examines file contents, not filenames; use list_files to discover file paths.'
  fi
  while [[ "$output" == *$'\n' ]]; do output="${output%$'\n'}"; done
  print -rn -- "$output"
}

search_worker() {
  emulate -L zsh
  zmodload zsh/system zsh/datetime zsh/zselect || return 1
  local search_root="$1" search_mode="$2" error_file="$6"
  local -i search_limit=$3 search_context=$4 search_budget=$5 search_per_file=$7
  local -i search_candidates=100
  if [[ "$search_mode" == files ]] && (( search_limit < 100 )); then
    search_candidates=$(( search_limit + 1 ))
  fi
  shift 7
  local -a search_paths=()
  local -A search_ids=() search_rows=() search_counts=() search_matches=()
  local search_buffer='' search_error='' search_fd='' diagnostic=''
  local -i search_bytes=0 search_limited=0 search_capped=0 search_timed_out=0 search_pid=0 exit_code=0 error_fd=0
  local -F search_deadline=$(( EPOCHREALTIME + 115.0 ))
  builtin cd -- "$search_root" || return 1
  {
    # stdout is consumed incrementally; the error file also has a kernel-enforced
    # bound. Only this child inherits the file-size limit (16 * 512 bytes).
    coproc { ulimit -f 16; exec "$@" 2>| "$error_file"; }
    search_pid=$!
    exec {search_fd}<&p
    _search_collect
    # Keep PID ownership until wait, including early collection termination.
    if (( search_limited || search_timed_out )) || [[ -n "$search_error" ]]; then
      kill -TERM "$search_pid" 2>/dev/null
    fi
    wait "$search_pid"
    exit_code=$?
    search_pid=0
    if (( search_timed_out )); then print -r -- 'Search timed out; narrow path/glob.'; return 124; fi
    if [[ -n "$search_error" ]] || (( ! search_limited && exit_code > 1 )); then
      sysopen -r -o nofollow,cloexec -u error_fd -- "$error_file" 2>/dev/null && {
        sysread -i "$error_fd" -s 4096 diagnostic 2>/dev/null
        exec {error_fd}<&-
      }
      print -r -- "${search_error:-ripgrep failed (status $exit_code)}"$'\n'"$diagnostic"
      return 1
    fi
    source "${${(%):-%x}:A:h:h}/vendor/zjson/zjson.zsh" || return 1
    _search_render
  } always {
    [[ -z "$search_fd" ]] || exec {search_fd}<&-
    if (( search_pid )); then kill -TERM "$search_pid" 2>/dev/null; wait "$search_pid" 2>/dev/null; fi
  }
}
