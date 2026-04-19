# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This repo contains a single bash script (`hermes.sh`) that launches [Hermes Agent](https://github.com/nousresearch/hermes-agent) configured to use a local [llama-swap](https://github.com/mostlygeek/llama-swap) instance. It auto-detects the currently loaded model from llama-swap's `/running` endpoint, updates the hermes configuration to point at that model/endpoint, and starts hermes.

## Usage

```bash
# Run directly (requires llama-swap running and hermes installed)
./hermes.sh

# Connect to a remote llama-swap instance
./hermes.sh -e http://10.0.0.70:8080

# Override model
LOCAL_MODEL=my-model ./hermes.sh

# Resume a hermes session
./hermes.sh -r <session-id>

# Continue the most recent session
./hermes.sh -c

# Can also be sourced (errors use `return` instead of `exit`)
source hermes.sh
```

## Dependencies

- `curl`, `jq`, `yq` -- used for llama-swap API calls and YAML config editing
- `hermes` -- the Hermes Agent being configured
- A running `llama-swap` instance (default: `http://localhost:8080`)

## How It Works

1. Checks llama-swap health at `$ENDPOINT/health`
2. If `LOCAL_MODEL` is not set, queries `/running` for a single ready model
3. If no model is loaded, lists available models from `/v1/models` and exits
4. Creates a temporary HERMES_HOME directory with symlinks to the user's real hermes home
5. Copies config.yaml and uses `yq` to surgically update model, provider, base_url, and compression model fields
6. Launches `hermes` with `HERMES_HOME` set to the temp directory
7. Cleans up the temp config on exit via `trap`

## Context Length

Hermes auto-detects context length from the provider (including llama-swap's `/v1/models` endpoint). Unlike oc-ls-configer, this script does not need to detect or configure context length -- hermes handles it natively. The script does query llama-swap metadata to display the context length for informational purposes.

## Compression Model

The script sets `auxiliary.compression` to use the same local model and endpoint, avoiding timeout delays that would occur if hermes tried to reach the default external compression model (e.g., `google/gemini-3-flash-preview`) before falling back.

## Argument Pass-through

Any flags not handled by this script (`-r`, `-c`) are passed directly to hermes. This supports `--tui`, `--yolo`, `--skills`, `--worktree`, and any other hermes CLI flags.

## Key Design Decision

Hermes uses `HERMES_HOME` to locate its config directory. The script copies the user's existing `~/.hermes/` to a temp directory, modifies only the model/provider fields in `config.yaml`, and sets `HERMES_HOME` to that temp directory. This preserves all other hermes settings (toolsets, personalities, memory, etc.) while swapping the model configuration.
