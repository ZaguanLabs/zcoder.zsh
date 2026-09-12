#!/usr/bin/env zsh
# Source-only dependency: headless builds need neither a compiler nor ncurses.
emulate -R zsh
setopt errexit nounset pipefail
typeset project_root=${0:A:h:h} dependency=${0:A:h:h}/vendor/zjson
typeset source_file exclude excludes=''
typeset -a sources=(zjson.zsh lib/utf8.zsh lib/zjson.zsh lib/pointer.zsh lib/context.zsh)
typeset -i complete=1
for source_file in "${sources[@]}"; do
  [[ -r $dependency/$source_file ]] || complete=0
done
if (( ! complete )); then
  (( ${+commands[git]} )) || {
    print -ru2 -- 'Missing zjson dependency. Install Git and run make json.'
    exit 1
  }
  if [[ -f $dependency/.git ]] && [[ -n $(git -C "$dependency" status --porcelain --untracked-files=no) ]]; then
    print -ru2 -- 'vendor/zjson has local edits. Save them before initializing the dependency.'
    exit 1
  fi
  git -C "$project_root" submodule sync -- vendor/zjson
  git -C "$project_root" submodule update --init --recursive -- vendor/zjson
  for source_file in "${sources[@]}"; do
    [[ -r $dependency/$source_file ]] || {
      print -ru2 -- 'Incomplete zjson dependency. Run git submodule update --init --recursive.'
      exit 1
    }
  done
fi
# Keep optional wordcode out of the submodule's local status without modifying
# upstream source. Source archives and deployed copies need no Git metadata.
if [[ -f $dependency/.git ]]; then
  exclude=$(git -C "$dependency" rev-parse --git-path info/exclude)
  [[ $exclude == /* ]] || exclude=$dependency/$exclude
  [[ ! -r $exclude ]] || excludes=$(<"$exclude")
  if [[ $'\n'$excludes$'\n' != *$'\n*.zwc\n'* ]]; then
    zmodload zsh/files
    zf_mkdir -p "${exclude:h}"
    print -r -- $'\n# Local zcoder wordcode from make compile\n*.zwc' >> "$exclude"
  fi
fi
