#!/usr/bin/env zsh
zmodload zsh/zselect
IFS= read -r request || exit 1
print -rn -- '{"jsonrpc":"2.0","id":'
while true; do zselect -t 10; done
