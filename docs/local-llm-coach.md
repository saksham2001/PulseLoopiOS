---
title: Local / self-hosted AI Coach
description: Connect PulseLoop to Ollama, LM Studio, llama.cpp, vLLM, SGLang, or another OpenAI-compatible server.
---

# Use a local model with AI Coach

PulseLoop can run AI Coach conversations through an OpenAI-compatible server
you control. The server can run on a Mac, PC, NAS, or another computer on your
network, and most setups do not need an API key.

!!! important "Use the server's network address"
    If the model runs on another computer, do **not** enter `localhost` or
    `127.0.0.1` in PulseLoop. On your iPhone, those addresses mean the iPhone
    itself. Use the computer's LAN address instead, such as
    `http://192.168.1.50:11434`.

## Quick start

1. Start one of the [supported servers](#supported-servers), load a chat model,
   and make the server reachable from your local network. Keep the iPhone and
   server on the same network for the first setup.
2. In PulseLoop, open **Settings → AI Coach** and turn on **Enable AI Coach**.
3. Set **Provider** to **Local / self-hosted**.
4. Enter the server's base address, for example
   `http://192.168.1.50:11434`. You do not need to add `/v1`. Add an API key
   only if your server requires one.
5. Tap **Detect server & configure**. PulseLoop checks the connection, lists
   available models, and tests tool calling and structured output. Choose a
   model if the server offers more than one.
6. Open the Coach and try a question such as **“How was my sleep last night?”**
   Allow Local Network access if iOS asks.

!!! tip "Model size and context"
    Tool-capable instruct models work best. A context window of at least 8K is
    a good starting point; very small contexts can truncate PulseLoop's health
    context and tool definitions.

## Supported servers

PulseLoop uses the OpenAI-compatible Chat Completions API. These engines are
supported directly:

| Engine | Typical address from the iPhone | API key | Setup notes |
|---|---|---|---|
| [Ollama](https://docs.ollama.com/api/openai-compatibility) | `http://<server-ip>:11434` | Usually none | Tool use depends on the model. Ollama listens only on the server itself by default; enable LAN access with `OLLAMA_HOST=0.0.0.0:11434`. |
| [LM Studio](https://lmstudio.ai/docs/developer/openai-compat) | `http://<server-ip>:1234` | Optional | Start the local server and enable **Serve on Local Network**. Authentication is off by default. |
| [llama.cpp](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md) (`llama-server`) | `http://<server-ip>:8080` | Optional | Use `--host 0.0.0.0` for LAN access. `--jinja` is recommended for tool-capable models. |
| [vLLM](https://docs.vllm.ai/en/latest/features/tool_calling/) | `http://<server-ip>:8000` | Optional | Automatic tool calling needs `--enable-auto-tool-choice` and the parser required by the model. |
| [SGLang](https://docs.sglang.io/basic_usage/openai_api_completions.html) | `http://<server-ip>:30000` | Optional | Tool and structured-output support depends on the model and server configuration. |
| Other OpenAI-compatible servers | Your server's base address | Varies | The server must provide `GET /v1/models` and `POST /v1/chat/completions`. |

The port can be different if you changed the server configuration. PulseLoop
also accepts a full `/v1` or `/v1/chat/completions` URL and normalizes it to the
base address.

## Recommended settings

- **Detect server & configure:** Run this first and again after changing the
  server, model, or launch options.
- **Tool calling:** Keep this on for questions that need detailed PulseLoop
  data. It also powers goals, workout logging, meal logging, and other actions
  when **AI actions** is enabled. Turn it off if the server or model does not
  support tools reliably.
- **Response format:** The detected setting is usually best. **Off** is the
  broadest-compatibility fallback if a server returns schema or JSON errors.
- **Max tokens:** Leave this blank unless the server needs an explicit limit.
- **Timeout:** The 180-second default suits most local models. Increase it for
  a large model running on a CPU; use a smaller model if every response times
  out.
- **API key:** Leave it blank unless authentication is enabled on your server.
  Saved keys are stored in the iOS Keychain.

Local servers can use PulseLoop's health-data and action tools. Image input also
works when the selected model supports images. Provider-hosted web search is not
available in local mode.

## Troubleshooting

| Problem | What to check |
|---|---|
| **Server not reachable** | Use the server computer's LAN IP, not `localhost`. Confirm both devices are on the same network and allow PulseLoop's iOS Local Network permission. |
| **Connection refused** | Make sure the server listens on `0.0.0.0` or its LAN interface, and allow its port through the computer's firewall. |
| **No models found** | Load a model, then open `<base-address>/v1/models` from another device on the same network. It should return JSON. |
| **Coach answers but cannot read or change data** | Enable **Tool calling**, use a tool-capable model, and check the engine-specific launch options in the table. Enable **AI actions** for writes. |
| **JSON or schema errors** | Set **Response format** to **Off**, then run detection again. |
| **Empty, truncated, or timed-out answers** | Use at least an 8K context window, leave **Max tokens** blank, increase the timeout, or choose a smaller model. |
| **401 / unauthorized** | Save the same API key or token configured on the server. |

## Privacy and network access

The local provider sends your question and the health context needed to answer
it to the server you configure. Use a server and network you trust.

PulseLoop accepts plain `http://` addresses for local/private destinations and
requires `https://` for public hosts. Redirects are not followed, and an optional
API key is stored in the iOS Keychain. Do not expose an unauthenticated local
model server directly to the public internet.
