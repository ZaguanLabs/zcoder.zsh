#!/usr/bin/env zsh

# Deterministic stdio MCP server used by the client tests. It deliberately
# avoids sharing zcoder's JSON code so the fixture can catch wire mistakes.

setopt NO_UNSET
typeset mode="${1:-modern}" line="" id="" method="" log="${MCP_FIXTURE_LOG:-}"
typeset id_pattern='"id":([0-9]+)' method_pattern='"method":"([^\"]+)"'

while IFS= read -r line; do
  [[ -n "$log" ]] && print -r -- "$line" >> "$log"
  id=""; method=""
  [[ "$line" =~ "$id_pattern" ]] && id="${match[1]}"
  [[ "$line" =~ "$method_pattern" ]] && method="${match[1]}"

  case "$method" in
    server/discover)
      if [[ "$mode" == modern ]]; then
        [[ "$line" == *'"io.modelcontextprotocol/protocolVersion":"2026-07-28"'* ]] || {
          print -r -- "{\"jsonrpc\":\"2.0\",\"id\":${id},\"error\":{\"code\":-32602,\"message\":\"missing modern metadata\"}}"
          continue
        }
        print -r -- "{\"jsonrpc\":\"2.0\",\"id\":${id},\"result\":{\"resultType\":\"complete\",\"supportedVersions\":[\"2026-07-28\"],\"capabilities\":{\"tools\":{}},\"_meta\":{\"io.modelcontextprotocol/serverInfo\":{\"name\":\"fixture-modern\",\"version\":\"1\"}}}}"
      else
        print -r -- "{\"jsonrpc\":\"2.0\",\"id\":${id},\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}"
      fi
      ;;
    initialize)
      if [[ "$mode" == legacy && "$line" == *'"protocolVersion":"2025-11-25"'* ]]; then
        print -r -- "{\"jsonrpc\":\"2.0\",\"id\":${id},\"result\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":\"fixture-legacy\",\"version\":\"1\"}}}"
      else
        print -r -- "{\"jsonrpc\":\"2.0\",\"id\":${id},\"error\":{\"code\":-32602,\"message\":\"Unsupported protocol version\"}}"
      fi
      ;;
    notifications/initialized)
      ;;
    tools/list)
      if [[ "$mode" == modern && "$line" != *'"io.modelcontextprotocol/clientCapabilities"'* ]]; then
        print -r -- "{\"jsonrpc\":\"2.0\",\"id\":${id},\"error\":{\"code\":-32602,\"message\":\"missing request metadata\"}}"
      elif [[ "$mode" == modern && "$line" != *'"cursor":"page-2"'* ]]; then
        print -r -- "{\"jsonrpc\":\"2.0\",\"id\":${id},\"result\":{\"tools\":[{\"name\":\"find-symbol\",\"description\":\"Find a symbol without reading whole files\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\"}},\"required\":[\"query\"]}}],\"nextCursor\":\"page-2\"}}"
      else
        print -r -- "{\"jsonrpc\":\"2.0\",\"id\":${id},\"result\":{\"tools\":[{\"name\":\"echo.data\",\"description\":\"Echo structured arguments\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"payload\":{\"type\":\"object\"}}}}]}}"
      fi
      ;;
    tools/call)
      if [[ "$mode" == modern && "$line" != *'"io.modelcontextprotocol/protocolVersion":"2026-07-28"'* ]]; then
        print -r -- "{\"jsonrpc\":\"2.0\",\"id\":${id},\"error\":{\"code\":-32602,\"message\":\"missing call metadata\"}}"
      else
        print -r -- "{\"jsonrpc\":\"2.0\",\"id\":${id},\"result\":{\"resultType\":\"complete\",\"content\":[{\"type\":\"text\",\"text\":\"fixture call completed\"}],\"structuredContent\":{\"received\":true},\"isError\":false}}"
      fi
      ;;
    *)
      [[ -n "$id" ]] && print -r -- "{\"jsonrpc\":\"2.0\",\"id\":${id},\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}"
      ;;
  esac
done
