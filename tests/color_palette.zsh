#!/usr/bin/env zsh
# Exercise allocation failures and session snapshots without curses or Ollama.
emulate -R zsh
source "${0:A:h:h}/lib/drawing.zsh" || exit 1
fail() { print -ru2 -- "FAIL: $*"; exit 1; }
typeset ZCODER_CURSES_COMMAND=zcurses ZCODER_COLOR=auto NO_COLOR='' REMOTE_MODE=local
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
typeset -A local_palette=("${(@kv)UI_THEME_COLORS}")
REMOTE_MODE=client
ui_theme_init
ui_widget_theme
[[ $UI_THEME_COLORS[surface] != $local_palette[surface] &&
   $UI_THEME_COLORS[accent] != $local_palette[accent] &&
   $zdraw_ui_theme[accent] == $UI_THEME_COLORS[accent] ]] || fail 'remote tint or widget palette'
[[ $UI_THEME_COLORS[header] == 108 ]] || fail 'remote header retains green in 256 colors'
for role in success warning error syntax info; do
  [[ $UI_THEME_COLORS[$role] == $local_palette[$role] ]] || fail "remote changed $role meaning"
done
ZCODER_COLOR=basic ui_theme_init
[[ $UI_THEME_COLORS[accent] == 5 && $UI_THEME_COLORS[border] == 5 &&
   $UI_THEME_COLORS[header] == 2 &&
   $UI_THEME_COLORS[success] == 2 && $UI_THEME_COLORS[warning] == 3 &&
   $UI_THEME_COLORS[error] == 1 ]] || fail 'remote basic colors'
NO_COLOR=1 ui_theme_init
ui_widget_theme
[[ $UI_COLOR_MODE == mono && $zdraw_ui_theme[accent] == default ]] || fail 'remote NO_COLOR'
REMOTE_MODE=local
ui_theme_init
for role in ${(k)local_palette}; do
  [[ $UI_THEME_COLORS[$role] == $local_palette[$role] ]] || fail 'remote palette leaked into local session'
done
# Only initialization converts colors; redraws reuse their resolved palette.
zdraw-color() { fail 'conversion during drawing'; }
ui_style 'underline warning/surface'
ui_widget_theme
[[ $REPLY == 'underline 186/235' ]] || fail 'resolved palette reuse'
print -r -- 'PASS: palette conversion, policy, allocation fallback, cache and session reset'
