emulate -R zsh
setopt errexit
zmodload zsh/datetime zsh/files zsh/mapfile zsh/net/tcp zsh/system zsh/zselect zsh/terminfo zsh/zpty
zmodload zdraw zmdown
typeset -A native_contract native_document
zdraw textpolicy native_contract unicode-17.0.0-egc-wcwidth-sum-attach-zero
[[ $native_contract[grapheme_compiled] == 1 ]] || {
  print -ru2 -- 'zdraw requires wide-character ncurses development headers/libraries.'
  exit 1
}
zmdown --spans native_document --width 20 --width-policy wcwidth-sum --cluster-styles first-base --text '**ready**'
[[ $native_document[schema] == 1 && $native_document[width_policy_name] == wcwidth-sum &&
   $native_document[cluster_styles] == first-base ]] || exit 1
