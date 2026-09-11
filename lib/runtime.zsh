# A private runtime is selected only from this checkout and host. This parameter
# is deliberately not exported: child system shells must select independently.
zcoder_runtime_select() {
  emulate -L zsh
  local entry=${1:A} root=${1:A:h} runtime
  shift
  case ${ZCODER_RUNTIME:-auto} in
    system) return 0 ;;
    auto) ;;
    *) print -ru2 -- 'Error: ZCODER_RUNTIME expects auto or system'; return 1 ;;
  esac
  [[ ${(t)ZCODER_RUNTIME_ACTIVE} == *readonly* &&
     ${ZCODER_RUNTIME_ACTIVE:-} == "$root/.build/native/builds/"*/runtime ]] && return 0
  [[ -r $root/.build/native/current ]] || return 0
  runtime=$(<"$root/.build/native/current")
  [[ $runtime == "$root/.build/native/builds/"*/runtime && $runtime == ${runtime:A} ]] || return 0
  [[ -x $runtime/bin/zsh && -r $runtime/zcoder-host &&
     $(<"$runtime/zcoder-host") == "$MACHTYPE:$OSTYPE:$HOST:$root" ]] || return 0
  exec "$runtime/bin/zsh" -df "$root/scripts/run-native.zsh" "$entry" "$runtime" "$@"
}
