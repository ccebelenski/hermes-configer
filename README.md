# hermes-configer

A bash script that automatically configures [Hermes Agent](https://github.com/nousresearch/hermes-agent) to use a local [llama-swap](https://github.com/mostlygeek/llama-swap) or [llama.cpp](https://github.com/ggml-org/llama.cpp) instance. It detects the currently running model, configures hermes to use it, and launches.

## Features

- Auto-detects the active model from llama-swap's `/running` endpoint or any OpenAI-compatible `/v1/models` endpoint
- Works with llama-swap, llama.cpp, and other OpenAI-compatible backends
- Preserves your existing hermes config (toolsets, personalities, memory, etc.) while swapping the model
- Points compression model at the local endpoint to avoid external API timeouts
- Persists any config changes hermes makes during the session while restoring model fields on exit
- Generates a temporary `HERMES_HOME` with updated config
- Can be sourced (`source hermes.sh`) or executed directly (`./hermes.sh`)

## Prerequisites

- An OpenAI-compatible endpoint running locally or remotely ([llama-swap](https://github.com/mostlygeek/llama-swap), [llama.cpp](https://github.com/ggml-org/llama.cpp), etc.)
- [Hermes Agent](https://github.com/nousresearch/hermes-agent) installed and in `PATH`
- `curl`, `jq`, and [`yq`](https://github.com/mikefarah/yq) (`dnf install yq` on Fedora)

## Usage

```bash
# Basic usage (auto-detects model from llama-swap)
./hermes.sh

# Connect to a remote endpoint
./hermes.sh -e http://10.0.0.70:8080

# Use a local llama.cpp instance
./hermes.sh -e http://localhost:8081

# Specify a model explicitly
LOCAL_MODEL=my-model ./hermes.sh

# Resume an existing hermes session
./hermes.sh -r <session-id>

# Continue the most recent session
./hermes.sh -c

# Continue a named session
./hermes.sh -c "my project"

# Make the model/provider config permanent (don't revert on exit)
./hermes.sh --sticky

# Pass extra flags through to hermes
./hermes.sh --tui --yolo
./hermes.sh -c --skills coding

# Can also be sourced (errors use `return` instead of `exit`)
source hermes.sh
```

## Options

| Flag | Description |
|---|---|
| `-e, --endpoint <url>` | llama-swap endpoint (default: `http://localhost:8080`) |
| `-r <session-id>` | Resume an existing hermes session by ID |
| `-c [name]` | Continue the most recent session, or a named session |
| `--sticky` | Persist the model/provider config changes permanently |
| `-h, --help` | Show help message |
| `--` | All arguments after `--` are passed directly to hermes |

Any flags not recognized by this script (e.g., `--tui`, `--yolo`, `--skills`) are passed through to hermes automatically.

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `LOCAL_ENDPOINT` | `http://localhost:8080` | API endpoint (alternative to `-e` flag) |
| `LOCAL_MODEL` | *(auto-detected)* | Model ID to use |

## Context Length

Hermes auto-detects context length from the provider (including llama-swap's `/v1/models` endpoint). No manual context configuration is needed in this script.

## Contributing

Contributions are welcome! Feel free to open an issue or submit a pull request.

## License

[MIT](LICENSE)
