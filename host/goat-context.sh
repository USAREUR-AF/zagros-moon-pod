#!/usr/bin/env bash

goat_active_context() {
    local profile_dir="$1" context=""
    if [ -n "${GOAT_CONTEXT+x}" ]; then
        if [ -z "$GOAT_CONTEXT" ]; then
            echo "GOAT_CONTEXT is set but empty; unset it or name a context" >&2
            return 1
        fi
        context=$GOAT_CONTEXT
    elif [ -f "$profile_dir/config.toml" ]; then
        context=$(sed -n \
            's/^[[:space:]]*current_context[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
            "$profile_dir/config.toml" | head -1)
    fi
    context=${context:-default}
    case "$context" in
        .|..|*[!A-Za-z0-9._-]*)
            echo "invalid active goat context: $context" >&2
            return 1
            ;;
    esac
    printf '%s\n' "$context"
}
