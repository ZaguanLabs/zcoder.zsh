# A file barrier holds the child between reads and explicit frame presentation.
if [[ $terminal_has_norefresh == 1 ]]; then
  typeset presentation_base="$TEST_TMP/presentation" presentation_output='' presentation_chunk=''
  presentation_run() {
    trap - EXIT INT TERM
    exec zsh -df "$TEST_DIR/fixtures/presentation_ui.zsh" "$PROJECT_DIR" "$presentation_base"
  }
  presentation_wait() {
    local -F deadline=$(( EPOCHREALTIME + 8 ))
    while (( EPOCHREALTIME < deadline )); do
      while zpty -r presentation-ui presentation_chunk 2>/dev/null; do presentation_output+="$presentation_chunk"; done
      if [[ ${mapfile[$presentation_base.step]:-} == $1 ]]; then
        # The child is blocked: drain writes preceding its report before QA.
        while zpty -r presentation-ui presentation_chunk 2>/dev/null; do presentation_output+="$presentation_chunk"; done
        return 0
      fi
      zselect -t 1
    done
    return 1
  }
  TERM=xterm-256color zpty -b presentation-ui presentation_run
  for presentation_step in ready hidden stillhidden resized presented done; do
    presentation_wait "$presentation_step"
    assert_success "application input presentation reaches $presentation_step" $?
    case $presentation_step in
      ready) assert_contains "$presentation_output" BEFORE 'explicit refresh presents the initial frame' ;;
      hidden|stillhidden|resized)
        assert_not_contains "$presentation_output" SECRETFRAME "$presentation_step input does not present the dirty parent window"
        assert_not_contains "$presentation_output" HIDDENCHILD "$presentation_step input does not present the dirty child window"
        ;;
      presented)
        assert_contains "$presentation_output" SECRETFRAME 'terminal_refresh presents the deferred parent frame'
        assert_contains "$presentation_output" HIDDENCHILD 'terminal_refresh presents the deferred child frame'
        ;;
    esac
    [[ $presentation_step == hidden ]] && zpty -w -n presentation-ui $'X\eOA'
    mapfile[$presentation_base.continue]=$presentation_step
  done
  zpty -d presentation-ui
  unfunction presentation_run presentation_wait
fi
