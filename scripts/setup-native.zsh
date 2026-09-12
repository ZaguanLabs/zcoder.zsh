#!/usr/bin/env zsh
# Build a private shell and its modules together; never guess a system-shell ABI.
emulate -R zsh
setopt errexit nounset pipefail
zmodload zsh/files zsh/system
typeset project_root=${0:A:h:h} make_command=${MAKE:-make}
typeset cache=$project_root/.build/native
typeset release=5.9.2
# https://www.zsh.org/pub/SHA256SUM
typeset archive_sha=36fa734374b44783582cec09bcd67822e2f992c779ec1624ab5596df078d2f81
typeset host_stamp="$MACHTYPE:$OSTYPE:$HOST:$project_root"
typeset tool dependency revision draw_revision markdown_revision digest build_id
typeset -a missing=() hasher=()
for tool in git "$make_command"; do
  whence -p -- "$tool" > /dev/null || missing+=("$tool")
done
(( ${#missing} == 0 )) || { print -ru2 -- "Missing build tools: ${(j:, :)missing}"; exit 1; }
if (( ${+commands[sha256sum]} )); then hasher=(sha256sum)
elif (( ${+commands[shasum]} )); then hasher=(shasum -a 256)
else print -ru2 -- 'Install sha256sum or shasum to verify the Zsh source archive.'; exit 1
fi
# Configuration and makefiles in upstream Zsh cannot represent these paths.
[[ $project_root != *[[:space:]]* && $project_root != *[\#\$\`\\]* ]] || {
  print -ru2 -- 'Build in a checkout path without whitespace, #, $, backticks or backslashes.'
  exit 1
}
zf_mkdir -p "$cache"
typeset -i lock_fd
: >> "$cache/lock"
zsystem flock -t 0 -f lock_fd "$cache/lock" 2>/dev/null || {
  print -ru2 -- 'Another native build is running in this checkout. Wait for it to finish.'
  exit 1
}
TRAPZERR() { print -ru2 -- "Native setup failed. Details: $cache/build.log"; }
print -r -- "Preparing zdraw and zmdown (build log: $cache/build.log)"
# Update to the parent's pinned revisions; never overwrite edits in a dependency.
for dependency in zdraw zmdown zjson; do
  if [[ -f $project_root/vendor/$dependency/.git ]]; then
    [[ -z $(git -C "$project_root/vendor/$dependency" status --porcelain --untracked-files=no) ]] || {
      print -ru2 -- "vendor/$dependency has local edits. Commit or save them before setup."
      exit 1
    }
  fi
done
git -C "$project_root" submodule sync --recursive
git -C "$project_root" submodule update --init --recursive
draw_revision=$(git -C "$project_root/vendor/zdraw" rev-parse HEAD)
markdown_revision=$(git -C "$project_root/vendor/zmdown" rev-parse HEAD)
digest=$("${hasher[@]}" "$0"); digest=${digest%% *}
build_id=$(print -r -- "$host_stamp:$archive_sha:$draw_revision:$markdown_revision:$digest:${CC:-cc}:${CPPFLAGS:-}:${CFLAGS:-}:${LDFLAGS:-}:$make_command" | "${hasher[@]}")
build_id=${build_id%% *}
typeset current=''
[[ ! -L $cache/current && ! -d $cache/current ]] || { print -ru2 -- 'Native runtime pointer must be a regular file.'; exit 1; }
[[ ! -r $cache/current ]] || current=$(<"$cache/current")
if [[ $current == "$cache/builds/"*/runtime && $current == ${current:A} &&
      -r $current/zcoder-build && $(<"$current/zcoder-build") == "$build_id" &&
      -r $current/zcoder-host && $(<"$current/zcoder-host") == "$host_stamp" &&
      -x $current/bin/zsh ]]; then
  "$current/bin/zsh" -df "$project_root/scripts/verify-native.zsh"
  print -r -- 'Private Zsh, zdraw and zmdown are up to date.'
  exit 0
fi
for tool in "${CC:-cc}" autoconf autoheader m4 patch awk sed tar xz cp cmp install; do
  whence -p -- "$tool" > /dev/null || missing+=("$tool")
done
if (( ${#missing} )); then
  print -ru2 -- "Missing build tools: ${(j:, :)missing}"
  print -ru2 -- 'Install a C toolchain, Autoconf and ncurses development headers; see docs/getting-started.md.'
  exit 1
fi
typeset archive=$cache/zsh-$release.tar.xz
if [[ ! -f $archive ]]; then
  (( ${+commands[curl]} )) || { print -ru2 -- 'Install curl to download the pinned Zsh release.'; exit 1; }
  curl --fail --location --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 300 \
    "https://www.zsh.org/pub/zsh-$release.tar.xz" -o "$archive.part"
  digest=$("${hasher[@]}" "$archive.part"); digest=${digest%% *}
  [[ $digest == "$archive_sha" ]] || { print -ru2 -- 'Zsh archive checksum mismatch; download was not used.'; exit 1; }
  zf_mv -f "$archive.part" "$archive"
fi
digest=$("${hasher[@]}" "$archive"); digest=${digest%% *}
[[ $digest == "$archive_sha" ]] || {
  print -ru2 -- "Zsh archive checksum mismatch. Remove $archive and retry."
  exit 1
}
# Each build has its own prefix. A failed replacement leaves current usable.
typeset build_root=$cache/builds/$build_id-$$
typeset source_root=$build_root/source/zsh-$release
typeset draw_root=$build_root/zdraw markdown_root=$build_root/zmdown
typeset runtime=$build_root/runtime
zf_mkdir -p "$build_root/source" "$draw_root" "$markdown_root"
build_native() {
  tar -xJf "$archive" -C "$build_root/source"
  git -C "$project_root/vendor/zdraw" archive "$draw_revision" | tar -xf - -C "$draw_root"
  git -C "$project_root/vendor/zmdown" archive "$markdown_revision" | tar -xf - -C "$markdown_root"
  (cd "$source_root"; ./configure --prefix="$runtime" --enable-dynamic --with-tcsetpgrp)
  "$make_command" -C "$source_root/Src"
  ZSH_BUILD_ROOT="$source_root" ZDRAW_MAKE="$make_command" zsh -df "$draw_root/scripts/build.zsh"
  # Inherit the same configuration and zdraw sources for the final shell build.
  ZSH_BUILD_ROOT="$draw_root/.build/zsh" ZMDOWN_BUILD_NAME= MAKE="$make_command" zsh -df "$markdown_root/scripts/build.zsh"
  "$make_command" -C "$markdown_root/.build/zsh" install.bin install.modules
  "$runtime/bin/zsh" -df "$project_root/scripts/verify-native.zsh"
  print -r -- "$host_stamp" > "$runtime/zcoder-host"
  print -r -- "$build_id" > "$runtime/zcoder-build"
}
build_native > "$cache/build.log" 2>&1
# Publish a data pointer atomically; keep running and previous builds intact.
print -r -- "$runtime" > "$cache/current.new"
zf_mv -f "$cache/current.new" "$cache/current"
print -r -- 'Built private Zsh with zdraw and zmdown. Launch ./zcoder.zsh as usual.'
