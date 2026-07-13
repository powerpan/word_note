#!/usr/bin/env bash

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
KEY_PATH="$PROJECT_ROOT/.local_secrets/ssh/word_note_tencent_cloud_ed25519"
KNOWN_HOSTS_PATH="$PROJECT_ROOT/.local_secrets/ssh/known_hosts"
REMOTE_HOST="ubuntu@134.175.182.221"

if [[ ! -f "$KEY_PATH" ]]; then
  printf 'Missing SSH private key: %s\n' "$KEY_PATH" >&2
  exit 1
fi

exec ssh \
  -i "$KEY_PATH" \
  -o IdentitiesOnly=yes \
  -o StrictHostKeyChecking=accept-new \
  -o UserKnownHostsFile="$KNOWN_HOSTS_PATH" \
  "$REMOTE_HOST" \
  "$@"
