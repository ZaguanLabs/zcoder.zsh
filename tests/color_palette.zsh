#!/usr/bin/env zsh
# Exercise allocation failures and session snapshots without curses or Ollama.
emulate -R zsh
source "${0:A:h:h}/lib/drawing.zsh" || exit 1
fail() { print -ru2 -- "FAIL: $*"; exit 1; }
typeset ZCODER_CURSES_COMMAND=zcurses ZCODER_COLOR=auto NO_COLOR=''
typeset -i ZCURSES_COLORS=256 fail_rich=0 fail_basic=0
typeset -A zdraw_ui_theme
zcoder_curses_features() { reply=(); return 1; }
zcoder_curses() {
  [[ $1 == attr ]] || return 1
  (( fail_rich )) && [[ $UI_COLOR_MODE == 256 ]] && return 1
  # Reject a later basic role: testing only the text pair misses this failure.
  (( fail_basic )) && [[ $UI_COLOR_MODE == basic && "$*" == *'3/0'* ]] && return 1
  return 0
}
ui_theme_init
[[ $UI_COLOR_MODE == 256 && $UI_THEME_COLORS[surface] == 235 &&
   $UI_THEME_COLORS[error] == 131 ]] || fail 'stock RGB-to-indexed palette'
typeset REPLY
ui_style 'bold red/black'
[[ $REPLY == 'bold 131/235' ]] || fail 'semantic transcript colors'
NO_COLOR=1 ui_theme_init
ui_style 'bold red/black'
[[ $UI_COLOR_MODE == mono && $REPLY == bold ]] || fail 'NO_COLOR or stale style cache'
ZCODER_COLOR=basic NO_COLOR=1 ui_theme_init
[[ $UI_COLOR_MODE == basic && $UI_THEME_COLORS[success] == 2 &&
   $UI_THEME_COLORS[warning] == 3 && $UI_THEME_COLORS[error] == 1 ]] || fail 'explicit basic override'
fail_rich=1
ui_theme_init
ui_widget_theme
[[ $UI_COLOR_MODE == basic && $zdraw_ui_theme[color-profile] == 16 &&
   $zdraw_ui_theme[error] == 1 ]] || fail 'rich allocation fallback snapshot'
fail_basic=1
ui_theme_init
ui_widget_theme
[[ $UI_COLOR_MODE == mono && $zdraw_ui_theme[color-profile] == mono &&
   $zdraw_ui_theme[error] == default ]] || fail 'basic allocation fallback snapshot'
fail_rich=0 fail_basic=0
ui_theme_init
[[ $UI_COLOR_MODE == 256 ]] || fail 'new session retained degraded profile'
# Only initialization converts colors; redraws reuse their resolved palette.
zdraw-color() { fail 'conversion during drawing'; }
ui_style 'underline warning/surface'
ui_widget_theme
[[ $REPLY == 'underline 186/235' ]] || fail 'resolved palette reuse'
print -r -- 'PASS: palette conversion, policy, allocation fallback, cache and session reset'
