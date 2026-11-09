# Specifications

External specifications zmachine relies on.

## Collected

| Title | Source | Why it applies |
| --- | --- | --- |
| [The Z-Machine Standards Document 1.1](z-machine-1.1/index.html) | <https://www.inform-fiction.org/zmachine/standards/z1point1/> | The virtual machine in `src/vm`: memory, instructions, text, objects, screen model, and the header. |
| [Quetzal 1.4: portable save files](quetzal/index.html) | <https://www.inform-fiction.org/zmachine/standards/quetzal/> | `save` and `restore` (`src/vm/quetzal.zig`). |
| [MCP 2025-06-18: transports](mcp/transports.md) | <https://modelcontextprotocol.io/specification/2025-06-18/basic/transports> | Streamable HTTP at `POST /mcp`, sessions and `DELETE`. |
| [MCP 2025-06-18: lifecycle](mcp/lifecycle.md) | <https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle> | `initialize`, protocol version, and capabilities. |
| [MCP 2025-06-18: tools](mcp/tools.md) | <https://modelcontextprotocol.io/specification/2025-06-18/server/tools> | `tools/list` and `tools/call` for both profiles. |
| [RFC 6265: HTTP State Management (cookies)](rfc6265.txt) | <https://www.rfc-editor.org/rfc/rfc6265> | The remote player's HttpOnly, SameSite session cookie. |

## Not collected

| Title | Source | Why it applies |
| --- | --- | --- |
| RFC 9110: HTTP Semantics | <https://www.rfc-editor.org/rfc/rfc9110> | Status codes, `Host`, `Origin`, and long-polling replies in `src/web`. |
| JSON-RPC 2.0 | <https://www.jsonrpc.org/specification> | The message format MCP uses. |
| EFF short word list 1 | <https://www.eff.org/dice> | The generated password's words; kept as `src/poly/eff_short_wordlist_1.txt` (CC BY 3.0). |
