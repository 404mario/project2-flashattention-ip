#!/usr/bin/env bash

resolve_python() {
    if [[ -n "${PYTHON:-}" ]]; then
        PYTHON_BIN="$PYTHON"
        return 0
    fi

    for cand in python python3; do
        if command -v "$cand" >/dev/null 2>&1; then
            PYTHON_BIN="$cand"
            return 0
        fi
    done

    for user_name in "${USERNAME:-}" "${USER:-}" 15783; do
        if [[ -z "$user_name" ]]; then
            continue
        fi
        local bundled_python_dir="/c/Users/$user_name/.cache/codex-runtimes/codex-primary-runtime/dependencies/python"
        if [[ -x "$bundled_python_dir/python.exe" ]]; then
            export PATH="$bundled_python_dir:$PATH"
            PYTHON_BIN=python.exe
            return 0
        fi
    done

    for user_name in "${USERNAME:-}" "${USER:-}" 15783; do
        if [[ -z "$user_name" ]]; then
            continue
        fi
        local win_python_dir="/c/Users/$user_name/AppData/Local/Programs/Python/Python310"
        if [[ -x "$win_python_dir/python.exe" ]]; then
            export PATH="$win_python_dir:$PATH"
            PYTHON_BIN=python.exe
            return 0
        fi
    done

    if command -v py >/dev/null 2>&1; then
        PYTHON_BIN=py
        return 0
    fi

    echo "ERROR: Python interpreter not found. Set PYTHON=/path/to/python and rerun." >&2
    return 1
}

PYTHON_BIN=""
resolve_python
