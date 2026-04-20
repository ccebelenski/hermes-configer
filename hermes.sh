#!/bin/bash
# Copyright (c) 2026 Chris Cebelenski
# Licensed under the MIT License. See LICENSE file in the project root.

# Detect if script is being sourced
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    _HC_SOURCED=1
else
    _HC_SOURCED=0
fi

# --- Helper functions ---

hc_abort() {
    local status="${1:-1}"
    if (( _HC_SOURCED )); then
        return "$status"
    else
        exit "$status"
    fi
}

_hc_restore_config() {
    [ -f "$TEMP_HERMES_HOME/config.yaml" ] || return 0

    local _cfg="$TEMP_HERMES_HOME/config.yaml"

    if [ "$HC_STICKY" != true ]; then
        local _changed=false

        # For each field we modified, restore the original only if hermes did not change it
        local _paths=(
            ".model.default"
            ".model.provider"
            ".model.base_url"
            ".auxiliary.compression.model"
            ".auxiliary.compression.provider"
            ".auxiliary.compression.base_url"
        )
        local _set_vals=(
            "$SET_MODEL_DEFAULT"
            "$SET_MODEL_PROVIDER"
            "$SET_MODEL_BASE_URL"
            "$SET_COMP_MODEL"
            "$SET_COMP_PROVIDER"
            "$SET_COMP_BASE_URL"
        )
        local _orig_vals=(
            "$ORIG_MODEL_DEFAULT"
            "$ORIG_MODEL_PROVIDER"
            "$ORIG_MODEL_BASE_URL"
            "$ORIG_COMP_MODEL"
            "$ORIG_COMP_PROVIDER"
            "$ORIG_COMP_BASE_URL"
        )

        local _i _cur_val
        for _i in "${!_paths[@]}"; do
            _cur_val=$(yq "${_paths[$_i]}" "$_cfg")
            if [ "$_cur_val" = "${_set_vals[$_i]}" ]; then
                if [ -z "${_orig_vals[$_i]}" ] || [ "${_orig_vals[$_i]}" = "null" ]; then
                    yq -i "del(${_paths[$_i]})" "$_cfg"
                else
                    export _HC_RESTORE_VAL="${_orig_vals[$_i]}"
                    yq -i "${_paths[$_i]} = env(_HC_RESTORE_VAL)" "$_cfg"
                    unset _HC_RESTORE_VAL
                fi
            else
                _changed=true
            fi
        done

        # custom_providers: compare as JSON
        local _cur_cp
        _cur_cp=$(yq -o=json '.custom_providers' "$_cfg")
        if [ "$_cur_cp" = "$SET_CUSTOM_PROVIDERS" ]; then
            if [ -z "$ORIG_CUSTOM_PROVIDERS" ] || [ "$ORIG_CUSTOM_PROVIDERS" = "null" ]; then
                yq -i 'del(.custom_providers)' "$_cfg"
            else
                export _HC_RESTORE_VAL="$ORIG_CUSTOM_PROVIDERS"
                yq -i '.custom_providers = env(_HC_RESTORE_VAL)' "$_cfg"
                unset _HC_RESTORE_VAL
            fi
        else
            _changed=true
        fi

        if [ "$_changed" = true ]; then
            echo "Note: hermes modified model/provider config; those changes have been preserved." >&2
        fi
    fi

    cp "$_cfg" "${HERMES_REAL_HOME}/config.yaml"
}

_hc_main() {

    # --- Configuration ---

    local ENDPOINT="${LOCAL_ENDPOINT:-http://localhost:8080}"
    local CURL_OPTS=(-sf --max-time 5)
    # Global so the EXIT trap can see it after _hc_main returns
    HERMES_REAL_HOME="${HERMES_REAL_HOME:-${HOME}/.hermes}"

    HC_STICKY=false
    local SESSION_ARGS=()
    local HERMES_EXTRA_ARGS=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                cat <<'HELPEOF'
Usage: hermes.sh [options] [-- hermes-args...]

Options:
  -e, --endpoint URL   llama-swap endpoint (default: http://localhost:8080)
  -r SESSION_ID        Resume a hermes session by ID
  -c [SESSION_ID]      Continue the most recent session, or a specific one
  --sticky             Persist model/provider config changes to the real config
  -h, --help           Show this help message
  --                   Pass remaining arguments directly to hermes

Environment variables:
  LOCAL_MODEL          Override model name (skip auto-detection from llama-swap)
  HERMES_REAL_HOME     Override hermes home directory (default: ~/.hermes)

All unrecognized options are passed through to hermes (e.g. --tui, --yolo).
HELPEOF
                return 0
                ;;
            --sticky)
                HC_STICKY=true
                shift
                ;;
            -e|--endpoint)
                if [ -z "${2:-}" ]; then
                    echo "Error: -e/--endpoint requires a URL" >&2
                    hc_abort 1; return $?
                fi
                ENDPOINT="$2"
                shift 2
                ;;
            -r)
                if [ -z "${2:-}" ]; then
                    echo "Error: -r requires a session ID" >&2
                    hc_abort 1; return $?
                fi
                SESSION_ARGS=(-r "$2")
                shift 2
                ;;
            -c)
                if [ -n "${2:-}" ] && [[ "${2}" != -* ]]; then
                    SESSION_ARGS=(-c "$2")
                    shift 2
                else
                    SESSION_ARGS=(-c)
                    shift
                fi
                ;;
            --)
                shift
                HERMES_EXTRA_ARGS+=("$@")
                break
                ;;
            *)
                HERMES_EXTRA_ARGS+=("$1")
                shift
                ;;
        esac
    done

    # --- Preflight checks ---

    if [ "$(id -u)" -eq 0 ]; then
        echo "Error: do not run this script as root" >&2
        hc_abort 1; return $?
    fi

    if ! curl "${CURL_OPTS[@]}" "${ENDPOINT}/health" > /dev/null 2>&1; then
        echo "Error: llama-swap does not appear to be running at ${ENDPOINT}" >&2
        echo "Start it with: llama-swap --config your-config.yaml" >&2
        hc_abort 1; return $?
    fi

    if ! command -v hermes > /dev/null 2>&1; then
        echo "Error: hermes is not installed or not in PATH" >&2
        hc_abort 1; return $?
    fi

    if ! command -v jq > /dev/null 2>&1; then
        echo "Error: jq is not installed or not in PATH" >&2
        hc_abort 1; return $?
    fi

    if ! command -v yq > /dev/null 2>&1; then
        echo "Error: yq is not installed or not in PATH" >&2
        echo "Install with: dnf install yq (Fedora) or see https://github.com/mikefarah/yq" >&2
        hc_abort 1; return $?
    fi

    if [ ! -d "$HERMES_REAL_HOME" ]; then
        echo "Error: hermes home directory not found at ${HERMES_REAL_HOME}" >&2
        echo "Run 'hermes setup' first, or set HERMES_REAL_HOME" >&2
        hc_abort 1; return $?
    fi

    if [ ! -f "${HERMES_REAL_HOME}/config.yaml" ]; then
        echo "Error: config.yaml not found in ${HERMES_REAL_HOME}" >&2
        echo "Run 'hermes setup' first" >&2
        hc_abort 1; return $?
    fi

    # --- Model detection ---
    # Resolution chain: LOCAL_MODEL env var -> /running (llama-swap) -> /v1/models (universal)

    local MODEL="${LOCAL_MODEL:-}"

    # Try llama-swap's /running endpoint first (not all endpoints support this)
    if [ -z "$MODEL" ]; then
        local RUNNING_JSON
        RUNNING_JSON=$(curl "${CURL_OPTS[@]}" "${ENDPOINT}/running" 2>/dev/null)
        if printf '%s\n' "$RUNNING_JSON" | jq -e '.running' > /dev/null 2>&1; then
            local READY_MODELS
            READY_MODELS=$(printf '%s\n' "$RUNNING_JSON" | jq -r '.running[] | select(.state == "ready") | .model' 2>/dev/null)
            local READY_COUNT
            READY_COUNT=$(printf '%s\n' "$READY_MODELS" | grep -c . 2>/dev/null || echo 0)

            if [ "$READY_COUNT" -gt 1 ]; then
                echo "Multiple models ready. Specify one with LOCAL_MODEL=<model> $(basename "${BASH_SOURCE[0]}"):"
                printf '%s\n' "$READY_MODELS"
                hc_abort 1; return $?
            fi

            MODEL=$(printf '%s\n' "$READY_MODELS" | head -n 1)
        fi
    fi

    # Fall back to /v1/models (works with any OpenAI-compatible endpoint)
    if [ -z "$MODEL" ]; then
        local MODELS_JSON
        MODELS_JSON=$(curl "${CURL_OPTS[@]}" "${ENDPOINT}/v1/models" 2>/dev/null)
        if ! printf '%s\n' "$MODELS_JSON" | jq -e '.data' > /dev/null 2>&1; then
            echo "Error: could not detect models from ${ENDPOINT}" >&2
            echo "Specify one with: LOCAL_MODEL=<model> $(basename "${BASH_SOURCE[0]}")" >&2
            hc_abort 1; return $?
        fi

        local AVAILABLE_MODELS
        AVAILABLE_MODELS=$(printf '%s\n' "$MODELS_JSON" | jq -r '.data[].id' 2>/dev/null)
        local AVAILABLE_COUNT
        AVAILABLE_COUNT=$(printf '%s\n' "$AVAILABLE_MODELS" | grep -c . 2>/dev/null || echo 0)

        if [ "$AVAILABLE_COUNT" -eq 1 ]; then
            MODEL=$(printf '%s\n' "$AVAILABLE_MODELS" | head -n 1)
        elif [ "$AVAILABLE_COUNT" -gt 1 ]; then
            echo "Multiple models available. Specify one with LOCAL_MODEL=<model> $(basename "${BASH_SOURCE[0]}"):"
            printf '%s\n' "$AVAILABLE_MODELS"
            hc_abort 1; return $?
        else
            echo "No models available at ${ENDPOINT}" >&2
            hc_abort 1; return $?
        fi
    fi

    echo "Detected model: ${MODEL}"

    # --- Generate hermes config via symlinked temp HERMES_HOME ---

    # Global so the EXIT trap can see it after _hc_main returns
    TEMP_HERMES_HOME=$(mktemp -d /tmp/hermes-XXXXXX)
    # Note: when sourced, this trap replaces any existing EXIT trap in the caller's shell
    trap '_hc_restore_config; rm -rf "$TEMP_HERMES_HOME"' EXIT

    # Symlink everything from the real hermes home into the temp directory
    local item name
    local _old_nullglob
    _old_nullglob=$(shopt -p nullglob)
    shopt -s nullglob

    for item in "${HERMES_REAL_HOME}"/*; do
        name=$(basename "$item")
        if [ "$name" = "config.yaml" ]; then
            continue
        fi
        ln -s "$(readlink -f "$item")" "${TEMP_HERMES_HOME}/${name}"
    done

    # Also symlink dotfiles/hidden files if any exist
    for item in "${HERMES_REAL_HOME}"/.*; do
        name=$(basename "$item")
        [[ "$name" == "." || "$name" == ".." ]] && continue
        ln -s "$(readlink -f "$item")" "${TEMP_HERMES_HOME}/${name}"
    done

    $_old_nullglob

    # Copy config.yaml and save original model/provider values for restore on exit
    cp "${HERMES_REAL_HOME}/config.yaml" "${TEMP_HERMES_HOME}/config.yaml"

    ORIG_MODEL_DEFAULT=$(yq '.model.default' "${HERMES_REAL_HOME}/config.yaml")
    ORIG_MODEL_PROVIDER=$(yq '.model.provider' "${HERMES_REAL_HOME}/config.yaml")
    ORIG_MODEL_BASE_URL=$(yq '.model.base_url' "${HERMES_REAL_HOME}/config.yaml")
    ORIG_COMP_MODEL=$(yq '.auxiliary.compression.model' "${HERMES_REAL_HOME}/config.yaml")
    ORIG_COMP_PROVIDER=$(yq '.auxiliary.compression.provider' "${HERMES_REAL_HOME}/config.yaml")
    ORIG_COMP_BASE_URL=$(yq '.auxiliary.compression.base_url' "${HERMES_REAL_HOME}/config.yaml")
    ORIG_CUSTOM_PROVIDERS=$(yq -o=json '.custom_providers' "${HERMES_REAL_HOME}/config.yaml")

    local BASE_URL="${ENDPOINT}/v1"
    local PROVIDER_NAME="${ENDPOINT#http://}"
    PROVIDER_NAME="${PROVIDER_NAME#https://}"

    # Values passed via env vars to avoid shell injection in the yq expression
    MODEL="$MODEL" \
    BASE_URL="$BASE_URL" \
    PROVIDER_NAME="$PROVIDER_NAME" \
    yq -i '
        .model.default = env(MODEL) |
        .model.provider = "custom" |
        .model.base_url = env(BASE_URL) |
        .auxiliary.compression.model = env(MODEL) |
        .auxiliary.compression.provider = "custom" |
        .auxiliary.compression.base_url = env(BASE_URL) |
        (.custom_providers // []) as $existing |
        .custom_providers = ([$existing[] | select(.name != env(PROVIDER_NAME))] + [{
            "name": env(PROVIDER_NAME),
            "base_url": env(BASE_URL),
            "model": env(MODEL)
        }])
    ' "${TEMP_HERMES_HOME}/config.yaml"

    # Save the values we set so the exit trap can detect if hermes changed them
    SET_MODEL_DEFAULT="$MODEL"
    SET_MODEL_PROVIDER="custom"
    SET_MODEL_BASE_URL="$BASE_URL"
    SET_COMP_MODEL="$MODEL"
    SET_COMP_PROVIDER="custom"
    SET_COMP_BASE_URL="$BASE_URL"
    SET_CUSTOM_PROVIDERS=$(yq -o=json '.custom_providers' "${TEMP_HERMES_HOME}/config.yaml")

    if [ ! -s "${TEMP_HERMES_HOME}/config.yaml" ]; then
        echo "Error: failed to generate hermes config" >&2
        hc_abort 1; return $?
    fi

    # --- Status summary ---

    echo "Configured provider: ${ENDPOINT}"
    echo "Compression model:   ${MODEL} (local)"

    # Query context length from llama-swap metadata if available
    local CONTEXT_INFO=""
    local MODELS_META
    MODELS_META=$(curl "${CURL_OPTS[@]}" "${ENDPOINT}/v1/models" 2>/dev/null)
    if printf '%s\n' "$MODELS_META" | jq -e . > /dev/null 2>&1; then
        CONTEXT_INFO=$(printf '%s\n' "$MODELS_META" | jq -r --arg m "$MODEL" \
            '.data[] | select(.id == $m) | .meta.llamaswap.context_length // empty' 2>/dev/null)
    fi
    if [ -n "$CONTEXT_INFO" ]; then
        echo "Context length:      ${CONTEXT_INFO} tokens (from llama-swap metadata)"
    else
        echo "Context length:      (hermes will auto-detect from provider)"
    fi

    # --- Launch hermes ---

    HERMES_HOME="$TEMP_HERMES_HOME" hermes "${SESSION_ARGS[@]}" "${HERMES_EXTRA_ARGS[@]}"
}

_hc_main "$@"
