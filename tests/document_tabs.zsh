#!/usr/bin/env zsh
emulate -R zsh
setopt extendedglob
zmodload zsh/files zsh/mapfile zsh/system zsh/stat zsh/datetime zsh/zselect zsh/zpty
typeset root=${0:A:h:h} base=$(mktemp -d "${TMPDIR:-/tmp}/zcoder-tabs.XXXXXXXX")
typeset server_pid=''
trap 'zpty -d tabs-ui 2>/dev/null; if [[ -n $server_pid ]]; then kill -TERM "$server_pid" 2>/dev/null; wait "$server_pid" 2>/dev/null; fi; zf_rm -rf -- "$base"' EXIT
fail() { print -ru2 -- "FAIL: $*"; exit 1; }
for library in util json input document_files; do source "$root/lib/$library.zsh"; done
typeset ZCODER_WORKSPACE="$base/workspace"
zf_mkdir -p "$ZCODER_WORKSPACE/docs"
typeset content=$'# Reader\n\nA **bold** paragraph with æøå.\n\n| Name | Value |\n| --- | --- |\n| One | Two |\n\n```zsh\nprint hello\n```\n'
for i in {1..60}; do content+="Line $i of the documentation."$'\n\n'; done
print -rn -- "$content" > "$ZCODER_WORKSPACE/docs/first file.md"
print -rn -- '# Second' > "$ZCODER_WORKSPACE/second.md"
print -rn -- '# Third' > "$ZCODER_WORKSPACE/third.md"
print -rn -- '# Fourth' > "$ZCODER_WORKSPACE/fourth.md"
print -rn -- '# Fifth' > "$ZCODER_WORKSPACE/fifth.md"
print -rn -- secret > "$base/outside.md"
zf_ln -s "$base/outside.md" "$ZCODER_WORKSPACE/escape.md"
zf_ln -s 'docs/first file.md' "$ZCODER_WORKSPACE/alias.md"
typeset -a reply
document_read 'docs/first file.md' || fail "$REPLY"
[[ $reply[1] == 'docs/first file.md' && $reply[2] == "$content" ]] || fail 'file content changed'
document_read alias.md || fail "$REPLY"
[[ $reply[1] == 'docs/first file.md' ]] || fail 'canonical file identity'
for invalid in ../outside.md escape.md missing.md docs /dev/null; do
  document_read "$invalid" && fail "accepted $invalid"
done
print -rn -- $'a\0b' > "$ZCODER_WORKSPACE/binary.md"
document_read binary.md && fail 'accepted binary data'
print -rn -- "${(pl:262145::x:)}" > "$ZCODER_WORKSPACE/large.md"
document_read large.md && fail 'accepted oversized document'
print -rn -- '' > "$ZCODER_WORKSPACE/empty.md"
document_read empty.md || fail 'rejected empty document'
[[ $reply[2] == '' ]] || fail 'empty content changed'
for i in 3 4 5 6 7; do
  for sequence in $'\e'"$i" $'\e['"$((48+i));3u" $'\e[27;3;'"$((48+i))~"; do
    input_reset
    for ch in "${(@s::)sequence}"; do input_decode_terminal_event "$ch" ''; done
    [[ $INPUT_EVENT_ACTION == focus_tab && $INPUT_EVENT_TEXT == $i ]] || fail "key decoding $i"
  done
done

# The endpoint uses the same reader, behind the existing authentication gate.
source "$root/lib/http.zsh"
source "$root/lib/remote.zsh"
REMOTE_RUNTIME_DIR="$base/runtime"
zf_mkdir -p "$REMOTE_RUNTIME_DIR"
typeset -i response_status=0
typeset response_body=''
_remote_http_send() { response_status=$2; response_body=$3; }
REMOTE_REQUEST_METHOD=POST; REMOTE_REQUEST_TARGET=/v1/document
REMOTE_REQUEST_BODY='{"path":"alias.md"}'
_remote_server_dispatch_request 0
[[ $response_status == 200 ]] || fail 'remote document endpoint failed'
json_parse_flat_object "$response_body" || fail 'invalid document JSON'
[[ $JSON_OBJECT[path] == 'docs/first file.md' && $JSON_OBJECT[text] == "$content" ]] || fail 'remote content changed'
for requested in '{"path":"escape.md"}' '{"path":"../outside.md"}' '{"path":42}' '{}'; do
  REMOTE_REQUEST_BODY=$requested
  _remote_server_dispatch_request 0
  [[ $response_status == 400 ]] || fail 'remote endpoint accepted invalid path'
done
_remote_http_parse_headers $'POST /v1/document HTTP/1.1\r\nContent-Length: 0' 'Bearer test-token'
[[ $? == 3 ]] || fail 'document endpoint missing-auth admission'

typeset output='' chunk='' backend ptybase
wait_state() {
  local expected=$1
  local -F deadline=$(( EPOCHREALTIME+20 ))
  while (( EPOCHREALTIME < deadline )); do
    while zpty -r tabs-ui chunk 2>/dev/null; do output+=$chunk; done
    [[ ${mapfile[$ptybase.state]:-} == "$expected" || ( $expected == document: && ${mapfile[$ptybase.state]:-} == document:* ) ]] && return 0
    zselect -t 1
  done
  fail "$backend state $expected; notice=${mapfile[$ptybase.notice]:-}; server=${mapfile[$base/server.log]:-}; got ${mapfile[$ptybase.state]:-}; ${(V)output[-1200,-1]}"
}
run_fixture() {
  trap - EXIT INT TERM
  export TERM=xterm-256color ZCODER_SYNC_OUTPUT=false
  exec zsh -df "$root/tests/fixtures/document_tabs_ui.zsh" "$root" "$ptybase" "$backend" "$ZCODER_WORKSPACE"
}
zsh -df "$root/tests/fixtures/document_tabs_server.zsh" "$root" "$base" "$ZCODER_WORKSPACE" > "$base/server.log" 2>&1 &
server_pid=$!
typeset -F server_deadline=$(( EPOCHREALTIME+10 ))
while [[ ! -s $base/endpoint ]] && (( EPOCHREALTIME<server_deadline )); do zselect -t 1; done
[[ -s $base/endpoint ]] || fail 'remote server startup'
for backend in stock auto remote; do
  ptybase="$base/$backend"; output=''
  zpty -b tabs-ui run_fixture || fail 'PTY startup'
  wait_state 'input:3:0:'
  [[ ${mapfile[$ptybase.header]:-} != *'[3 Coding]'* ]] || fail 'empty reader shows Coding tab'
  zpty -w -n tabs-ui $'/open "docs/first file.md"\r'
  wait_state 'document:4:0:'
  if [[ ${mapfile[$ptybase.renderer]} == zdraw:* ]]; then
    [[ ${mapfile[$ptybase.header]} == *'[3 Coding] [4 first file.md]'* ]] || fail 'document tab is not adjacent to Coding'
  fi
  [[ ${mapfile[$ptybase.lines]} == *Reader* && ${mapfile[$ptybase.lines]} == *'Line 60'* ]] || fail 'rendered document incomplete'
  [[ ${mapfile[$ptybase.renderer]} != zdraw:* || ${mapfile[$ptybase.renderer]} == zdraw:zmdown ]] || fail 'native reader did not use zmdown'
  command stty rows 18 cols 45 < "${mapfile[$ptybase.tty]}"
  local -F resize_deadline=$(( EPOCHREALTIME+10 ))
  while [[ ${mapfile[$ptybase.geometry]:-} != 45:18 ]] && (( EPOCHREALTIME<resize_deadline )); do zselect -t 1; done
  [[ ${mapfile[$ptybase.geometry]:-} == 45:18 ]] || fail 'reader resize failed'
  command stty rows 24 cols 100 < "${mapfile[$ptybase.tty]}"
  resize_deadline=$(( EPOCHREALTIME+10 ))
  while [[ ${mapfile[$ptybase.geometry]:-} != 100:24 ]] && (( EPOCHREALTIME<resize_deadline )); do zselect -t 1; done
  [[ ${mapfile[$ptybase.geometry]:-} == 100:24 ]] || fail 'reader resize restoration failed'
  zpty -w -n tabs-ui j
  wait_state 'document:4:1:'
  zpty -w -n tabs-ui $'\e2unfinished draft\e4'
  wait_state 'document:4:1:unfinished draft'
  zpty -w -n tabs-ui $'\e3'
  wait_state 'input:3:0:unfinished draft'
  zpty -w -n tabs-ui $'\e4'
  wait_state 'document:4:1:unfinished draft'
  zpty -w -n tabs-ui x
  wait_state 'input:3:0:unfinished draft'
  [[ ${mapfile[$ptybase.header]:-} != *'[3 Coding]'* ]] || fail 'last document close leaves Coding tab visible'
  zpty -w -n tabs-ui '!'
  wait_state 'input:3:0:unfinished draft!'
  zpty -w -n tabs-ui $'\x15/open second.md\r'
  wait_state 'document:4:0:'
  zpty -w -n tabs-ui $'\e2/open third.md\r'
  wait_state 'document:5:0:'
  zpty -w -n tabs-ui $'\e2/open fourth.md\r'
  wait_state 'document:6:0:'
  zpty -w -n tabs-ui $'\e2/open fifth.md\r'
  wait_state 'document:7:0:'
  zpty -w -n tabs-ui $'\e2/open second.md\r'
  wait_state 'document:4:0:'
  zpty -w -n tabs-ui $'\e2/open empty.md\r'
  wait_state 'input:3:0:'
  local -F limit_deadline=$(( EPOCHREALTIME+10 ))
  while (( EPOCHREALTIME<limit_deadline )); do
    [[ ${mapfile[$ptybase.notice]:-} == 'Four documents'* && ${mapfile[$ptybase.loading]:-1} == 0 ]] && break
    zselect -t 1
  done
  [[ ${mapfile[$ptybase.notice]:-} == 'Four documents'* && ${mapfile[$ptybase.count]} == 4 ]] || fail 'document limit not enforced'
  zpty -w -n tabs-ui $'\e5x\e7'
  wait_state 'document:7:0:'
  zpty -w -n tabs-ui $'\e2/open empty.md\r'
  wait_state 'document:5:0:'
  print -rn -- '# Reloaded' > "$ZCODER_WORKSPACE/empty.md"
  zpty -w -n tabs-ui r
  wait_state 'document:5:0:'
  # A barrier on rendered text avoids mistaking the prior state for completion.
  local -F deadline=$(( EPOCHREALTIME+10 ))
  while [[ ${mapfile[$ptybase.lines]} != *Reloaded* ]] && (( EPOCHREALTIME<deadline )); do zselect -t 1; done
  [[ ${mapfile[$ptybase.lines]} == *Reloaded* ]] || fail 'reload did not update'
  zf_rm "$ZCODER_WORKSPACE/empty.md"
  zpty -w -n tabs-ui r
  zselect -t 10
  [[ ${mapfile[$ptybase.lines]} == *Reloaded* ]] || fail 'failed reload discarded content'
  print -rn -- '' > "$ZCODER_WORKSPACE/empty.md"
  # Fixture switches to the real activity input dispatcher and opens approval.
  print -rn -- 1 > "$ptybase.activity"
  zpty -w -n tabs-ui $'\e2draft while running\e4j'
  wait_state 'document:4:0:draft while running'
  zpty -w -n tabs-ui $'x\e2\x15/open alias.md\r'
  wait_state 'document:4:0:'
  zpty -w -n tabs-ui $'\e2draft while running\e4'
  wait_state 'document:4:0:draft while running'
  print -rn -- 1 > "$ptybase.approval"
  wait_state 'approval:'
  zpty -w -n tabs-ui n
  wait_state 'document:'
  [[ ${mapfile[$ptybase.decision]} == n ]] || fail 'approval policy was bypassed'
  [[ ${mapfile[$ptybase.transcript]} == 'Original conversation' ]] || fail 'reader changed transcript'
  [[ ${mapfile[$ptybase.draft]} == 'draft while running' ]] || fail 'reader changed draft'
  print -rn -- 1 > "$ptybase.stop"
  zpty -w -n tabs-ui $'\e2'
  wait_state done
  zpty -d tabs-ui
  [[ ! -e $ptybase.turn ]] || fail '/open submitted model work'
  if [[ $backend == auto ]]; then
    zf_mkdir -p "$root/.build/document-visuals/tabs"
    for capture in "$ptybase".capture-*(N.); do
      print -rn -- "$(<"$capture")" > "$root/.build/document-visuals/tabs/${capture:t}.json" || fail 'capture publication'
    done
  fi
done
print -r -- 'PASS: read-only document files, remote endpoint, tab controls, rendering, activity and approvals'
