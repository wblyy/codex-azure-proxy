# codex-azure-proxy

Run [OpenAI Codex CLI](https://github.com/openai/codex) against Azure OpenAI with zero code changes.

A local MITM proxy intercepts Codex's requests to `api.openai.com`, translates the Responses API to Azure Chat Completions, and converts the response back.

```
Codex CLI → ClashX → MITM Proxy (127.0.0.1:8765) → Azure OpenAI
```

## Why This Exists

Codex speaks OpenAI's Responses API. Azure speaks Chat Completions. They're similar but not identical. This proxy bridges the gap and handles all the edge cases (parallel tool calls, sandwiched text messages, null content assistant messages) that cause Azure to return 400 errors.

## Quick Start

```bash
# 1. Clone
git clone https://github.com/wblyy/codex-azure-proxy
cd codex-azure-proxy

# 2. Set Azure credentials
export AZURE_BASE_URL=https://YOUR_RESOURCE.services.ai.azure.com/openai
export OPENAI_API_KEY=YOUR_AZURE_KEY
export AZURE_API_VERSION=2025-04-01-preview   # optional

# 3. Run setup (generates cert, trusts it, installs LaunchAgent)
bash setup.sh

# 4. Configure ClashX (see below)
# 5. Run Codex normally — it hits Azure automatically
codex "write a hello world script"
```

## Prerequisites

- macOS with [ClashX](https://github.com/yichengchen/clashX) installed
- Node.js >= 16
- Azure OpenAI resource with a deployment (e.g. `gpt-4o`, `gpt-5.5`)

## ClashX Configuration

Add to `~/.config/clash/config.yaml`:

```yaml
proxies:
  - name: codex-mitm
    type: http
    server: 127.0.0.1
    port: 8765

rules:
  - DOMAIN,api.openai.com,codex-mitm
  # ... your other rules
```

Reload ClashX config after saving.

## Model Names

Azure deployment names map 1:1 to what Codex passes. Create your Azure deployments with names that match:

| Codex model arg | Azure deployment name |
|-----------------|-----------------------|
| `gpt-4o`        | `gpt-4o`              |
| `gpt-5.5`       | `gpt-5.5`             |
| `gpt-4.1`       | `gpt-4.1`             |

Use `codex --model gpt-4o` or set `OPENAI_MODEL=gpt-4o`.

## Verify

```bash
curl -sk --proxy http://127.0.0.1:8765 https://api.openai.com/health
# → {"ok":true,"proxy":"codex-azure-mitm"}
```

## Test

```bash
python3 tests/test_proxy.py gpt-4o
# Runs 8 scenarios: single turn, single tool, parallel tools,
# text+tool, sandwiched text, sequential, mixed 3-round, null content regression
```

## How It Works

Codex sends requests to `api.openai.com/v1/responses` using the Responses API format. ClashX routes these through the proxy. The proxy:

1. Intercepts the CONNECT tunnel to `api.openai.com` (fake TLS cert)
2. Parses the Responses API request body (`input[]` array + `instructions`)
3. Converts `input[]` to Azure Chat Completions `messages[]`
4. Streams the Azure response back as Codex SSE events

### The Tricky Part: Message Conversion

Codex's `input[]` array can contain these patterns (all discovered from real logs):

| Pattern | Example | Challenge |
|---------|---------|-----------|
| Single tool | `[fc, fco]` | Simple |
| Parallel tools | `[fc1, fc2, fco1, fco2]` | Must merge into ONE assistant message |
| Text + tool | `[text_msg, fc, fco]` | Text must be in same assistant message as tool_calls |
| **Sandwiched text** | `[fc, text_msg, fco]` | Text between fc and fco must merge into fc's assistant message |
| Sequential | `[fc1, fco1, text, fc2, fco2]` | Each round is separate |
| Null content | `[msg(content:[])]` | Azure rejects `content:null` on text-only messages |

Azure's rules are strict:
- `content: null` is only allowed when `tool_calls` is present
- All parallel tool_calls from one turn MUST be in ONE `role: "assistant"` message
- `role: "tool"` messages must immediately follow the assistant with matching `tool_call_id`

## Logs

```bash
tail -f /tmp/codex-azure-proxy.log
```

Each request logs its input item types and generated message structure, making it easy to debug conversion issues:

```
[proxy] input-items[7]: 0:user 1:function_call(shell) 2:message 3:function_call_output 4:function_call(shell) 5:function_call_output 6:user
[proxy] messages[6]: system -> user -> assistant(tc:1) -> tool -> assistant(tc:1) -> tool -> user
```

## Manual LaunchAgent Control

```bash
# Restart
launchctl unload ~/Library/LaunchAgents/com.codex.azure-proxy.plist
launchctl load ~/Library/LaunchAgents/com.codex.azure-proxy.plist

# Stop
launchctl unload ~/Library/LaunchAgents/com.codex.azure-proxy.plist

# Check running
ps aux | grep proxy.js
```

## License

MIT
