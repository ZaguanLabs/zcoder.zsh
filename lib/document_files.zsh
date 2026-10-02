# Shared, bounded file reader for local tabs and the authenticated remote API.
# Success publishes (canonical workspace-relative path, literal text) in reply.
# Failure publishes a human-readable error in REPLY, without touching tool state.
document_read() {
  emulate -L zsh
  local LC_ALL=C
  local requested=$1 root=${ZCODER_WORKSPACE:A} candidate resolved chunk content=''
  local -i fd=-1 result=0 remaining=0
  local -A metadata
  reply=(); REPLY=''
  [[ -n $requested && $requested != *$'\0'* ]] || { REPLY='A Markdown filename is required.'; return 1; }
  [[ $requested == /* ]] && candidate=$requested || candidate="$root/$requested"
  resolved=${candidate:A}
  [[ $resolved == "${root%/}/"* ]] || { REPLY='Document path escapes the workspace.'; return 1; }
  [[ ${resolved:e:l} == (md|markdown) ]] || { REPLY='Open a .md or .markdown file.'; return 1; }
  [[ -f $resolved && -r $resolved ]] || { REPLY='Document is not a readable regular file.'; return 1; }
  zmodload -F zsh/stat b:zstat || return 1
  zmodload zsh/system || return 1
  sysopen -r -o nofollow,nonblock,cloexec -u fd -- "$resolved" 2>/dev/null || { REPLY='Could not open document.'; return 1; }
  {
    if ! zstat -H metadata -f "$fd" || (( (metadata[mode] & 8#170000) != 8#100000 )); then
      REPLY='Document is not a regular file.'; return 1
    fi
    (( metadata[size] <= 262144 )) || { REPLY='Document exceeds the 256 KiB reader limit.'; return 1; }
    # Read one extra byte to detect growth without allocating an unbounded file.
    while (( ${#content} <= 262144 )); do
      remaining=$(( 262145 - ${#content} ))
      (( remaining > 32768 )) && remaining=32768
      sysread -i "$fd" -s "$remaining" chunk 2>/dev/null
      result=$?
      (( result == 5 )) && break
      (( result == 0 )) || { REPLY='Could not read document.'; return 1; }
      content+=$chunk
    done
    (( ${#content} <= 262144 )) || { REPLY='Document exceeds the 256 KiB reader limit.'; return 1; }
    [[ $content != *$'\0'* ]] || { REPLY='Document contains binary data.'; return 1; }
    reply=("${resolved#${root%/}/}" "$content")
    return 0
  } always {
    exec {fd}<&-
  }
}
