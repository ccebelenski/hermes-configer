# hermes-configer Design Document

## Goal

Create a bash launcher script (`hermes.sh`) that automatically configures and launches Hermes Agent to use a local llama-swap instance as its AI backend -- analogous to how `oc-ls-configer/oc.sh` does this for opencode.

## Architecture

### Single-script design

Like oc-ls-configer, this is a single bash script with no build step. Dependencies are `curl`, `jq`, and `hermes`.

### How Hermes configuration works

Hermes Agent reads its configuration from `$HERMES_HOME/config.yaml` (default: `~/.hermes/config.yaml`). The `HERMES_HOME` environment variable controls the entire home directory, which includes:

- `config.yaml` -- main configuration
- `skills/` -- installed skills
- `memory/` -- persistent memory
- `sessions/` -- session history
- `logs/` -- log files
- `cron/` -- cron jobs
- Other state directories

**Key config fields we need to modify:**
```yaml
model:
  default: <model-name>
  provider: custom
  base_url: <endpoint>/v1
custom_providers:
  - name: <provider-name>
    base_url: <endpoint>/v1
    model: <model-name>
```

### Strategy: symlink HERMES_HOME with modified config

Since `HERMES_HOME` controls the entire home directory (not just config), we can't simply point it at a temp dir with only a config.yaml -- hermes needs access to skills, memory, sessions, etc.

**Approach:** Create a temp directory that mirrors `~/.hermes/` using **symlinks** for all subdirectories/files except `config.yaml`, which gets a modified copy. This way:
- All hermes state (memory, sessions, skills, etc.) is shared with the real home
- Only the config is overridden
- No risk of corrupting the original config
- Cleanup is trivial (remove temp dir with symlinks)

```
/tmp/hermes-XXXXXX/           (temp HERMES_HOME)
  config.yaml                 (modified copy)
  skills -> ~/.hermes/skills  (symlink)
  memory -> ~/.hermes/memory  (symlink)
  sessions -> ...             (symlink)
  ...                         (all other dirs/files symlinked)
```

### Alternative considered: `hermes config set`

Hermes has a `hermes config set <key> <value>` command that modifies the config in place. We could use this instead of temp directories. However:
- It modifies the user's real config permanently
- No automatic cleanup/restore on exit
- Risk of leaving the config in a bad state if the script is killed
- Doesn't match the oc-ls-configer pattern of being ephemeral

**Verdict:** Symlinked temp directory is safer and more consistent.

## Script Flow

```
hermes.sh
  |
  |-- 1. Bootstrap (sourcing detection, abort handler)
  |
  |-- 2. Argument parsing
  |     -r <session-id>    Resume session by ID
  |     -c [name]          Continue most recent (or named) session
  |
  |-- 3. Preflight checks
  |     - Not running as root
  |     - llama-swap health check at $ENDPOINT/health
  |     - hermes is installed
  |     - jq is installed
  |
  |-- 4. Model detection (identical to oc-ls-configer)
  |     - Check LOCAL_MODEL env var
  |     - Query /running for ready models
  |     - Fall back to /v1/models listing
  |
  |-- 5. Generate hermes config
  |     - Create temp directory
  |     - Symlink all contents of ~/.hermes/ into it
  |     - Copy config.yaml and modify model/provider fields with jq/sed
  |     - Set EXIT trap for cleanup
  |
  |-- 6. Launch hermes
  |     - HERMES_HOME=$TEMP_DIR hermes [session args]
```

## Config Modification Details

The script needs to update these fields in `config.yaml`:

| Field | Value |
|---|---|
| `model.default` | Auto-detected model name |
| `model.provider` | `custom` |
| `model.base_url` | `$ENDPOINT/v1` |
| `custom_providers` | Single entry with name, base_url, and model |

Since hermes config is YAML, we need a YAML manipulation tool. Options considered:
1. **`yq`** -- proper YAML processor, preserves comments and formatting
2. **`python3 -c`** with PyYAML/ruamel.yaml -- available since hermes is Python
3. **`sed`** -- fragile but no extra dependencies

**Decision:** Use `yq` (mikefarah/yq). It's a standard Fedora package (`dnf install yq`), keeps the script as pure bash with no Python dependency, and preserves comments and formatting when editing config.yaml. This avoids the PyYAML comment-destruction problem and keeps the dependency model consistent with `jq`.

## Implementation Plan

### Phase 1: Core script (v0.1.0)
1. Create `hermes.sh` with bootstrap, argument parsing, and preflight checks
2. Implement model detection (port from oc-ls-configer)
3. Implement config generation via symlinked temp HERMES_HOME
4. Implement hermes launch with session args

### Phase 2: Polish (v0.2.0)
6. Add `-p/--project-dir` support if hermes supports working directory control
7. Test edge cases (no model loaded, multiple models, missing metadata)
8. Refine error messages and help output

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `LOCAL_ENDPOINT` | `http://localhost:8080` | llama-swap API endpoint |
| `LOCAL_MODEL` | *(auto-detected)* | Model ID override |
| `HERMES_REAL_HOME` | `~/.hermes` | Location of the real hermes home to mirror |

## Differences from oc-ls-configer

| Aspect | oc-ls-configer | hermes-configer |
|---|---|---|
| Target tool | opencode | Hermes Agent |
| Config format | JSON (`opencode.json`) | YAML (`config.yaml`) |
| Config location | `OPENCODE_CONFIG_DIR` (config only) | `HERMES_HOME` (entire home dir) |
| Config strategy | Generate from scratch | Copy + modify existing config |
| YAML tool | jq (JSON) | yq (YAML) |
| Session flags | `-s <id>` | `-r <id>`, `-c [name]` |
| Context/output limits | Detected and set in config | Not needed (hermes auto-detects from provider) |
| State dirs | None (config only) | Must symlink skills, memory, sessions, etc. |

## Resolved Questions

1. **Context length:** Hermes auto-detects context length from the provider via `/v1/models` (including llama.cpp/llama-swap endpoints). It uses a multi-source resolution chain: config overrides -> provider query -> defaults (128k fallback). No need for our script to detect or set context length -- hermes handles it natively. We remove `LOCAL_CONTEXT` from the script's scope. If auto-detection reports the model's theoretical max rather than the configured limit, the user can set it manually via `hermes config set` in their real config.

2. **Lock files / concurrent instances:** We follow hermes's native behavior. The symlink approach means any locks hermes creates in subdirectories resolve to the real `~/.hermes/` -- no special handling needed.

3. **Session storage:** Sessions are shared between the script and normal hermes via symlinks. Sessions created through the script persist in the real `~/.hermes/sessions/` and can be resumed with a normal `hermes -r` later. This is the desired behavior.
