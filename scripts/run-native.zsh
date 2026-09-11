# Entered by the application's launcher in the matched private shell.
emulate -R zsh
typeset native_entry=${1:A}
typeset native_runtime=${2:A}
shift 2
unset ZCODER_RUNTIME_ACTIVE
typeset -gr ZCODER_RUNTIME_ACTIVE=${native_runtime:A}
0=$native_entry
source "$native_entry" "$@"
