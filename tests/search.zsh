# Search exercises real rg and native workers without Ollama or curses.
search_tests() {
  emulate -L zsh
  (( $+commands[rg] )) || return 0
  local fixture="$TEST_TMP/search-tests"
  local ZCODER_WORKSPACE="$fixture/workspace" ZCODER_COMMAND_POLICY=deny
  local ZCODER_MAX_TOOL_OUTPUT=32768 UI_ACTIVE=0 AGENT_TOOL_PHASE=full
  local result='' unusual=$'odd:name\nwith space.zsh' repeated='' sample='' item=''
  local saved_runner="${functions[tool_process_run]:-}" REPLY=''
  local -a result_lines=()
  local -i i=0 saved_runner_exists=${+functions[tool_process_run]}
  zf_mkdir -p -- "$ZCODER_WORKSPACE/src" "$ZCODER_WORKSPACE/tests" "$fixture/outside"
  mapfile[$ZCODER_WORKSPACE/src/a.zsh]=$'before\ncall(foo.bar)\nafter\nneedle one\nneedle two\nend\n'
  mapfile[$ZCODER_WORKSPACE/src/b.py]=$'needle three\n'
  mapfile[$ZCODER_WORKSPACE/tests/test.zsh]=$'needle four\n'
  tool_dispatch search '{"query":"call(foo.bar)","literal":true,"path":"src"}'
  assert_success 'search dispatch supports literal code without regex escaping' $?
  assert_contains "$TOOL_RESULT" '2:1:call(foo.bar)' 'literal search retains match location'
  assert_contains "$TOOL_RESULT" '1-before' 'default context includes the preceding line'
  assert_contains "$TOOL_RESULT" '3-after' 'default context includes the following line'

  tool_dispatch search '{"query":"call(foo.bar)","literal":true,"context_lines":0}'
  assert_not_contains "$TOOL_RESULT" before 'explicit zero context survives dispatch'
  tool_dispatch search '{"query":"needle","mode":"files","glob":"*.zsh"}'
  assert_success 'files mode accepts a file glob' $?
  assert_contains "$TOOL_RESULT" '"src/a.zsh"' 'files mode returns matching paths'
  assert_contains "$TOOL_RESULT" '"tests/test.zsh"' 'glob includes matching files in subdirectories'
  assert_not_contains "$TOOL_RESULT" 'b.py' 'glob excludes other extensions'
  assert_not_contains "$TOOL_RESULT" 'needle' 'files mode omits file contents'
  tool_dispatch search '{"query":"needle","file_type":"py"}'
  assert_contains "$TOOL_RESULT" 'src/b.py' 'file type selects Python sources'
  assert_not_contains "$TOOL_RESULT" 'a.zsh' 'file type excludes other sources'
  tool_dispatch search '{"query":"needle","glob":"!tests/**"}'
  assert_not_contains "$TOOL_RESULT" 'tests/test.zsh' 'negative glob excludes tests'
  tool_dispatch search '{"query":"call(foo.bar)\nneedle three","literal":true,"mode":"files"}'
  assert_success 'newline-separated literal alternatives are searched together' $?
  assert_contains "$TOOL_RESULT" 'src/a.zsh' 'first alternative finds its file'
  assert_contains "$TOOL_RESULT" 'src/b.py' 'second alternative finds its file'
  tool_search 'needle (one|three)' . 50 false files
  assert_contains "$TOOL_RESULT" 'src/a.zsh' 'regex alternatives remain supported'
  assert_contains "$TOOL_RESULT" 'src/b.py' 'regex alternatives search multiple files'

  tool_search needle src/a.zsh 50 false content '' '' 2
  result="$TOOL_RESULT"
  result_lines=("${(@f)result}")
  assert_eq 1 "${#${(@M)result_lines:#3-after}}" 'overlapping context is emitted once'
  assert_eq 1 "${#${(@M)result_lines:#4:1:needle one}}" 'overlapping matching lines are emitted once'
  mapfile[$ZCODER_WORKSPACE/$unusual]=$'specialneedle\n'
  tool_search specialneedle . 50 true content '' '' 0
  assert_contains "$TOOL_RESULT" 'odd:name\nwith space.zsh' 'paths containing colons and newlines are safely framed'
  assert_contains "$TOOL_RESULT" '1:1:specialneedle' 'unusual filenames preserve location parsing'
  mapfile[$ZCODER_WORKSPACE/src/unicode.zsh]=$'før\nnål én\netter\n'
  tool_search nål . 50 true content
  assert_contains "$TOOL_RESULT" '2:1:nål én' 'streamed records preserve UTF-8'

  repeated=''
  for (( i=1; i<=120; i++ )); do repeated+="needle row $i"$'\n'; done
  mapfile[$ZCODER_WORKSPACE/src/noisy.zsh]="$repeated"
  tool_search needle . 4 false content '' '' 0 4096
  assert_contains "$TOOL_RESULT" 'src/noisy.zsh' 'noisy file receives a share of results'
  assert_contains "$TOOL_RESULT" 'src/b.py' 'noisy file cannot crowd out another matching file'
  assert_contains "$TOOL_RESULT" 'next line' 'omitted matches include a continuation line'
  tool_search needle . 50 false content '' '' 5 512
  assert_success 'small output budget remains usable' $?
  assert_success 'search output stays within the requested character budget' $(( ${#TOOL_RESULT} <= 512 ? 0 : 1 ))
  assert_contains "$TOOL_RESULT" 'needle' 'small budget prioritizes actual matching evidence'
  tool_search needle src/a.zsh 50 false content '' '' 2 256
  assert_contains "$TOOL_RESULT" 'needle' 'minimum output budget still returns matching evidence'
  assert_success 'minimum character budget is respected' $(( ${#TOOL_RESULT} <= 256 ? 0 : 1 ))
  tool_search needle src/noisy.zsh 9999 false content '' '' 0 32768
  assert_contains "$TOOL_RESULT" 'Per-file scan capped' 'per-file collection limits cannot masquerade as complete results'

  zf_mkdir -p -- "$ZCODER_WORKSPACE/many"
  for (( i=1; i<=105; i++ )); do mapfile[$ZCODER_WORKSPACE/many/$i]='manyneedle'; done
  tool_search manyneedle many 9999 false files '' '' 0 32768
  assert_contains "$TOOL_RESULT" 'Search collection limited' 'file collection stops at a bounded candidate count'
  tool_search nomatches src 50
  assert_contains "$TOOL_RESULT" 'No text matches.' 'empty searches remain explicit'
  mapfile[$ZCODER_WORKSPACE/src/binary]=$'needle\n\0binary payload\n'
  tool_search needle src 50 false files
  assert_success 'binary files do not break recursive file discovery' $?
  tool_search needle src 50
  assert_success 'binary files do not break recursive content search' $?
  tool_search needle src/binary 50
  assert_failure 'an explicitly requested binary file cannot corrupt text framing' $?
  assert_contains "$TOOL_RESULT" 'binary data' 'explicit binary targets get a useful diagnostic'

  sample="longneedle ${(pl:900::x:)}"
  mapfile[$ZCODER_WORKSPACE/src/long]="$sample"
  tool_search longneedle src/long 50 false content '' '' 0
  assert_contains "$TOOL_RESULT" 'longneedle' 'long-line previews retain matching evidence'
  assert_contains "$TOOL_RESULT" '[...' 'long-line previews retain the truncation marker'
  zf_mkdir -p -- "$ZCODER_WORKSPACE/volume"
  repeated=''; sample="byte-needle ${(pl:470::x:)}"
  for (( i=1; i<=101; i++ )); do repeated+="$sample"$'\n'; done
  for (( i=1; i<=55; i++ )); do mapfile[$ZCODER_WORKSPACE/volume/$i]="$repeated"; done
  tool_search byte-needle volume 9999 false content '' '' 0 512
  assert_success 'high-volume search stops and reaps its ripgrep child' $?
  assert_contains "$TOOL_RESULT" 'Search collection limited' 'raw byte collection is bounded before presentation'
  assert_success 'high-volume output respects the character budget' $(( ${#TOOL_RESULT} <= 512 ? 0 : 1 ))

  # A producer that remains alive after the cap makes ownership observable:
  # returning a partial result must terminate and reap it, not leave it running.
  mapfile[$fixture/producer.zsh]=$'zmodload zsh/system\nprint -r -- "$sysparams[pid]" >| "$1/pid"\nfor i in {1..105}; do print -rn -- "$1/workspace/many/$i"$\'\\0\'; done\nread -r ignored\n'
  command zsh -df "$ZCODER_SEARCH_SCRIPT" "$ZCODER_WORKSPACE" files 9999 0 512 "$fixture/producer.err" 101 \
    zsh -df "$fixture/producer.zsh" "$fixture" >| "$fixture/producer.out"
  assert_success 'bounded collector stops a producer that keeps its pipe open' $?
  result="${mapfile[$fixture/pid]}"
  kill -0 "$result" 2>/dev/null
  assert_failure 'bounded collector leaves no producer process behind' $?

  mapfile[$ZCODER_WORKSPACE/.gitignore]=$'ignored.zsh\n'
  mapfile[$ZCODER_WORKSPACE/ignored.zsh]='ignoredneedle'
  zf_mkdir -p -- "$ZCODER_WORKSPACE/vendor/pkg"
  mapfile[$ZCODER_WORKSPACE/vendor/pkg/secret.zsh]='ignoredneedle'
  tool_search ignoredneedle . 50
  assert_contains "$TOOL_RESULT" 'No text matches.' 'normal searches preserve ignore and dependency exclusions'
  tool_search ignoredneedle . 50 false files '*.zsh'
  assert_contains "$TOOL_RESULT" ignored.zsh 'explicit inclusion globs retain documented ripgrep semantics'
  assert_not_contains "$TOOL_RESULT" vendor 'explicit globs cannot override fixed dependency exclusions'
  mapfile[$fixture/outside/secret]='outsideneedle'
  zf_ln -s -- "$fixture/outside" "$ZCODER_WORKSPACE/escape"
  tool_search outsideneedle . 50 false files '*'
  assert_not_contains "$TOOL_RESULT" secret 'glob search cannot traverse an external symlink'
  tool_search outsideneedle escape 50
  assert_failure 'explicit symlink escape is rejected before launching search' $?
  assert_contains "$TOOL_RESULT" 'escapes the workspace' 'search explains workspace confinement'

  for item in '{"query":"["}' '{"query":"x","file_type":"unknown_zcoder_type"}' \
    '{"query":"x","literal":"true"}' '{"query":"x","context_lines":6}' \
    '{"query":"x","max_chars":255}' '{"query":"x","max_results":1e2}' \
    '{"query":"x","follow":true}' '{"query":"x\n"}' '{"query":"x\u0000"}'; do
    tool_dispatch search "$item"
    assert_failure "search rejects invalid arguments $item" $?
  done
  tool_dispatch search '{"query":"--pre=malicious","literal":true}'
  assert_success 'option-like literal queries remain data' $?
  if (( $+functions[goal_verifier_dispatch_read] )); then
    goal_verifier_dispatch_read search '{"query":"call(foo.bar)","literal":true,"mode":"files"}'
    assert_success 'goal verifier accepts the same search options' $?
    assert_contains "$TOOL_RESULT" 'src/a.zsh' 'verifier literal search locates the file'
    assert_not_contains "$TOOL_RESULT" 'call(foo.bar)' 'verifier files mode omits contents'
    goal_verifier_dispatch_read search '{"query":"x","follow":true}'
    assert_failure 'goal verifier cannot bypass the search argument contract' $?
    goal_verifier_tools_schema_json
    assert_contains "$REPLY" 'context_lines' 'goal verifier advertises the shared search schema'
  fi

  # Exercise exactly the same worker argv through the interactive dispatch path.
  # Process lifetime and terminal interaction have their own real PTY suite.
  tool_search needle src/a.zsh 5 false content '' '' 1
  result="$TOOL_RESULT"
  {
    tool_process_run() {
      shift 2
      TOOL_PROCESS_CANCELLED=0; TOOL_PROCESS_ERROR=''; TOOL_PROCESS_TIMED_OUT=0
      TOOL_PROCESS_OUTPUT=$(command "$@")
    }
    UI_ACTIVE=1
    tool_search needle src/a.zsh 5 false content '' '' 1
    assert_success 'interactive search uses the bounded worker' $?
    assert_eq "$result" "$TOOL_RESULT" 'headless and interactive search produce identical evidence'
    tool_process_run() { TOOL_PROCESS_CANCELLED=1; TOOL_PROCESS_ERROR=''; TOOL_PROCESS_OUTPUT=''; return 130; }
    tool_search needle . 5
    assert_eq 130 "$?" 'interactive cancellation retains its status'
    assert_eq 1 "$TOOL_CANCELLED" 'interactive cancellation reaches the agent'
  } always {
    if (( saved_runner_exists )); then functions[tool_process_run]="$saved_runner"; else unfunction tool_process_run; fi
  }
}
search_tests
unfunction search_tests
