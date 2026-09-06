# Session transcript shared by the terminal UI and headless transports.
# Keep the existing UI_* names for the persistence and rendering interfaces.

typeset -ga UI_ROLES=() UI_CONTENTS=() UI_THINKINGS=() UI_TIMES=() UI_REASONING_OPEN=()

ui_append_message() {
  UI_ROLES+=("$1")
  UI_CONTENTS+=("$2")
  UI_THINKINGS+=("${3:-}")
  zcoder_time; UI_TIMES+=("$REPLY")
  UI_REASONING_OPEN+=(0)
  UI_AUTO_SCROLL=1
}
