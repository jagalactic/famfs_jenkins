#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NODES_FILE="${SCRIPT_DIR}/../configs/nodes.txt"

usage() {
    echo "Usage: $0 [-u user] <command> [args...]"
    echo "  -u user   SSH as specified user (e.g., -u root)"
    echo ""
    echo "Examples:"
    echo "  $0 df -h /"
    echo "  $0 sudo dnf install -y libcurl-devel"
    echo "  $0 -u root journalctl --vacuum-time=5d"
    exit 1
}

if [[ $# -lt 1 ]]; then
    usage
fi

USER_PREFIX=""
if [[ "$1" == "-u" ]]; then
    if [[ -z "$2" ]]; then
        usage
    fi
    USER_PREFIX="${2}@"
    shift 2
fi

if [[ $# -lt 1 ]]; then
    usage
fi

if [[ ! -f "$NODES_FILE" ]]; then
    echo "Error: nodes file not found: $NODES_FILE"
    exit 1
fi

while read -r node; do
    [[ -z "$node" || "$node" =~ ^# ]] && continue
    echo "*******************************************************"
    echo "${USER_PREFIX}${node}:"
    ssh -n "${USER_PREFIX}${node}" "$@"
done < "$NODES_FILE"
