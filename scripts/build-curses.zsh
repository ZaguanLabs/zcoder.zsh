#!/usr/bin/env zsh
# Explicit development build; normal startup and `make compile` need no C tools.
emulate -R zsh
setopt errexit nounset pipefail
typeset project_root=${0:A:h:h}
typeset dependency=$project_root/vendor/zcurses
[[ -f $dependency/Makefile ]] || {
  print -u2 -r -- 'Initialize the dependency: git submodule update --init --recursive'
  exit 1
}
typeset source_root=${ZSH_BUILD_ROOT:?Set ZSH_BUILD_ROOT to a matching configured, built Zsh source tree}
typeset signature="$ZSH_VERSION:$ZSH_PATCHLEVEL:$MACHTYPE:$OSTYPE:$HOST" built_signature
built_signature=$("$source_root/Src/zsh" -dfc 'print -r -- "$ZSH_VERSION:$ZSH_PATCHLEVEL:$MACHTYPE:$OSTYPE:$HOST"')
[[ $built_signature == "$signature" ]] || {
  print -u2 -r -- 'ZSH_BUILD_ROOT does not match the running Zsh version and platform.'
  exit 1
}
# Invalidate before rebuilding: a failed build must not retain an enabled stamp.
zmodload zsh/files
zf_rm -f -- "$dependency/.build/zcoder-abi"
make -C "$dependency" build
# Verify the module loads in this shell ABI, isolated from the build process.
zsh -dfc 'module_path=("$1" $module_path); zmodload zsh/curses' \
  zcoder-curses "$dependency/.build/modules"
print -r -- "$signature" >| "$dependency/.build/zcoder-abi"
print -r -- 'Local zcurses enabled. Run make test to exercise both resize backends.'
