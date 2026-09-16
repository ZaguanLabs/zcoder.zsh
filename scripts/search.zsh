#!/usr/bin/env zsh
# Trusted argv only: this worker never evaluates model-provided shell source.
emulate -R zsh
source "${0:A:h:h}/lib/search.zsh" || exit 1
search_worker "$@"
