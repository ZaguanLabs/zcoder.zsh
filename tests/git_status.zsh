# Repository display metadata requires neither the Git executable nor curses.
git_status_test() {
  local root="$TEST_TMP/git-status" REPLY=''
  local ZCODER_WORKSPACE="$TEST_TMP/git-status/project"
  local REMOTE_MODE=local REMOTE_GIT_STATUS='Git: server-branch'
  local UI_GIT_DISPLAY='' UI_GIT_WORKSPACE=''
  local -F UI_NEXT_GIT_CHECK=0
  zf_mkdir -p "$root/project/src" "$root/plain" "$root/metadata" "$root/linked"
  zcoder_git_status "$root/plain"
  assert_eq 'No Git' "$REPLY" 'ordinary projects have an explicit non-Git state'
  zf_mkdir "$root/project/.git"
  print -r -- 'ref: refs/heads/main' > "$root/project/.git/HEAD"
  zcoder_git_status "$root/project/src"
  assert_eq 'Git: main' "$REPLY" 'nested workspaces find their branch before the first commit'
  ui_git_update
  assert_eq 'Git: main' "$UI_GIT_DISPLAY" 'the header reads the workspace branch'
  print -r -- 'ref: refs/heads/feature/new-ui' > "$root/project/.git/HEAD"
  UI_NEXT_GIT_CHECK=0
  ui_git_update
  assert_eq 'Git: feature/new-ui' "$UI_GIT_DISPLAY" 'branch switches refresh without restarting the UI'
  ZCODER_WORKSPACE="$root/plain"
  ui_git_update
  assert_eq 'No Git' "$UI_GIT_DISPLAY" 'workspace changes immediately clear the previous branch'
  print -r -- 'gitdir: ../metadata' > "$root/linked/.git"
  print -r -- 'ref: refs/heads/worktree' > "$root/metadata/HEAD"
  zcoder_git_status "$root/linked"
  assert_eq 'Git: worktree' "$REPLY" 'relative gitfiles identify linked worktrees and submodules'
  print -r -- "gitdir: $root/metadata" > "$root/linked/.git"
  zcoder_git_status "$root/linked"
  assert_eq 'Git: worktree' "$REPLY" 'absolute gitfiles identify linked worktrees'
  print -r -- '0123456789abcdef0123456789abcdef01234567' > "$root/metadata/HEAD"
  zcoder_git_status "$root/linked"
  assert_eq 'Git: detached 01234567' "$REPLY" 'detached HEAD is explicit and includes a short commit ID'
  print -r -- 'broken metadata' > "$root/metadata/HEAD"
  zcoder_git_status "$root/linked"
  assert_eq 'Git: unavailable' "$REPLY" 'invalid metadata never masquerades as a branch'
  zf_ln -s "$root/project/src" "$root/alias"
  zcoder_git_status "$root/alias"
  assert_eq 'Git: feature/new-ui' "$REPLY" 'workspace symlinks resolve to the actual repository'
  REMOTE_MODE=client
  ZCODER_WORKSPACE="$root/project"
  ui_git_update
  assert_eq 'Git: server-branch' "$UI_GIT_DISPLAY" 'remote sessions use server metadata even when the path exists locally'
  REMOTE_GIT_STATUS=''
  ui_git_update
  assert_eq 'Git: unavailable' "$UI_GIT_DISPLAY" 'legacy servers never fall back to a local branch'
  local HTTP_BODY='' REMOTE_MODEL_STATUS=ready REMOTE_MODEL_ERROR=''
  _remote_server_model_status_json
  HTTP_BODY="$REPLY"
  _remote_client_parse_model_status
  assert_success 'server Git metadata round-trips through model status JSON' $?
  assert_eq 'Git: feature/new-ui' "$REMOTE_GIT_STATUS" 'remote polling reads the current server branch'

  local -i UI_ACTIVE=1 UI_MODAL_ACTIVE=0 SCREEN_W=80
  local ZCODER_NAME=zcoder ZCODER_VERSION=test ZCODER_MODEL=model OLLAMA_HOST=host REMOTE_MODE=local
  local UI_STATUS_DISPLAY=Ready UI_STATUS_ATTR='bold green/black'
  local -a MOCK_ZCURSES_CALLS=()
  UI_GIT_DISPLAY=$'Git: feature/\e[31m\nvery-long-branch-name'
  _ui_paint_header 1
  local call='' branch_text='' row=-1
  for call in "${MOCK_ZCURSES_CALLS[@]}"; do
    [[ "$call" == 'move top_win '* ]] && row=-1
    [[ "$call" == 'string top_win project' ]] && row=0
    [[ "$call" == 'string top_win '* && "$row" == 0 ]] && branch_text+="${call#string top_win }"
  done
  assert_contains "$branch_text" '…' 'long branch names visibly truncate on narrow terminals'
  assert_not_contains "$branch_text" $'\e' 'branch names cannot inject terminal escapes'
  assert_not_contains "$branch_text" $'\n' 'branch names cannot create terminal rows'
  assert_success 'branch labels fit inside the header border' $(( ${(m)#branch_text} <= SCREEN_W - 4 ? 0 : 1 ))
  assert_contains "$branch_text" 'project^feature/' 'the header joins workspace and branch with a caret'
  assert_contains "${(F)MOCK_ZCURSES_CALLS}" $'attr top_win -bold -dim bold red/black\nstring top_win ^' 'the branch separator is red'
  assert_contains "${(F)MOCK_ZCURSES_CALLS}" $'attr top_win -bold -dim bold yellow/black\nstring top_win feature/' 'the branch name is yellow'
  for UI_GIT_DISPLAY in 'No Git' 'Git: unavailable' 'Git: detached 01234567' ''; do
    MOCK_ZCURSES_CALLS=()
    _ui_paint_header 1
    branch_text=''; row=-1
    for call in "${MOCK_ZCURSES_CALLS[@]}"; do
      [[ "$call" == 'move top_win '* ]] && row=-1
      [[ "$call" == 'string top_win project' ]] && row=0
      [[ "$call" == 'string top_win '* && "$row" == 0 ]] && branch_text+="${call#string top_win }"
    done
    assert_eq project "$branch_text" "the workspace omits branchless Git state: $UI_GIT_DISPLAY"
    assert_not_contains "${(F)MOCK_ZCURSES_CALLS}" 'move top_win 2 2' 'the header no longer writes a separate Git label'
  done

  local -A saved_functions=()
  local function_name=''
  for function_name in http_async_start http_async_ready http_async_collect agent_set_status; do
    saved_functions[$function_name]="$functions[$function_name]"
  done
  local REMOTE_IDLE_PID='' REMOTE_IDLE_BASE='' REMOTE_IDLE_ENDPOINT='' REMOTE_ENDPOINT=fixture
  local REMOTE_ERROR='' observed_status='untouched' poll_body=''
  local -i REMOTE_GIT_SUPPORTED=1 poll_failed=0
  local -F REMOTE_CLIENT_NEXT_MODEL_POLL=0 REMOTE_IDLE_DEADLINE=0
  {
    http_async_start() { HTTP_ASYNC_PID=fixture; return 0; }
    http_async_ready() { return 0; }
    http_async_collect() { HTTP_ASYNC_PID=''; HTTP_BODY="$poll_body"; return "$poll_failed"; }
    agent_set_status() { observed_status="$1"; }
    poll_body='{"model_status":"ready","git_status":"Git: switched-remotely"}'
    remote_client_idle_poll
    remote_client_idle_poll
    assert_eq 'Git: switched-remotely' "$REMOTE_GIT_STATUS" 'idle remote sessions refresh branches after model warm-up ends'
    assert_eq untouched "$observed_status" 'remote branch polling preserves foreground status'
    REMOTE_CLIENT_NEXT_MODEL_POLL=0
    poll_failed=1
    remote_client_idle_poll
    remote_client_idle_poll
    assert_eq 'Git: unavailable' "$REMOTE_GIT_STATUS" 'failed remote polls clear stale branch information'
    assert_eq ready "$REMOTE_MODEL_STATUS" 'branch polling failures do not become model warm-up failures'
    assert_eq untouched "$observed_status" 'branch polling failures preserve foreground status'
  } always {
    for function_name in "${(@k)saved_functions}"; do
      functions[$function_name]="$saved_functions[$function_name]"
    done
  }
}
git_status_test
unfunction git_status_test
