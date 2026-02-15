#!/bin/bash

# Shared config loader for YAML-based config

CONFIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$CONFIG_DIR/config.yaml"
CONFIG_PARSER="$CONFIG_DIR/read_config.py"

load_config() {
    local node_id="$1"

    if [ ! -f "$CONFIG_FILE" ]; then
        echo "[ERROR] config.yaml 不存在: $CONFIG_FILE" >&2
        return 1
    fi
    if [ ! -f "$CONFIG_PARSER" ]; then
        echo "[ERROR] read_config.py 不存在: $CONFIG_PARSER" >&2
        return 1
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        echo "[ERROR] 未找到 python3，无法解析 config.yaml" >&2
        return 1
    fi

    local output
    if [ -n "$node_id" ]; then
        output=$(python3 "$CONFIG_PARSER" --file "$CONFIG_FILE" --node "$node_id")
    else
        output=$(python3 "$CONFIG_PARSER" --file "$CONFIG_FILE")
    fi
    if [ $? -ne 0 ]; then
        echo "$output" >&2
        return 1
    fi

    eval "$output"
}
