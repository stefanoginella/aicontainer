#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# Runtime path is anchored to this repository.
# shellcheck disable=SC1091
source "$ROOT/template/aic-chown-volumes"

inspect='{
  "Mounts": [
    {"Type":"bind", "Source":"/host/project", "Destination":"/workspace"},
    {"Type":"volume", "Name":"cache", "Destination":"/workspace/.cache-volume"},
    {"Type":"volume", "Name":"nested", "Destination":"/workspace/.cache-volume/nested"},
    {"Type":"volume", "Name":"auth", "Destination":"/home/vscode/.config/aic-auth"},
    {"Type":"bind", "Source":"/var/lib/docker/volumes/deceptive/_data", "Destination":"/workspace/deceptive"},
    {"Type":"volume", "Name":"unsafe-parent", "Destination":"/workspace/unsafe-parent"},
    {"Type":"bind", "Source":"/host/secret", "Destination":"/workspace/unsafe-parent/nested-bind"}
  ]
}'

accepted=(
  /workspace/.cache-volume
  /home/vscode/.config/aic-auth
)

rejected=(
  /workspace
  /workspace/deceptive
  /workspace/unsafe-parent
  /workspace/missing
  /home/vscode/.config
)

for path in "${accepted[@]}"; do
  if ! inspect_has_named_volume_mount "$inspect" "$path"; then
    echo "expected Docker named-volume destination to be accepted: $path" >&2
    exit 1
  fi
done

for path in "${rejected[@]}"; do
  if inspect_has_named_volume_mount "$inspect" "$path"; then
    echo "expected bind/non-mount destination to be rejected: $path" >&2
    exit 1
  fi
done

duplicate='{"Mounts":[
  {"Type":"volume","Destination":"/workspace/duplicate"},
  {"Type":"bind","Destination":"/workspace/duplicate"}
]}'
if inspect_has_named_volume_mount "$duplicate" /workspace/duplicate; then
  echo "expected ambiguous duplicate destination to be rejected" >&2
  exit 1
fi

echo "OK: Docker mount metadata accepts one exact volume and rejects binds, missing, and ambiguous destinations"
