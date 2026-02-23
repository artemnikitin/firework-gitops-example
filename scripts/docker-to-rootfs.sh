#!/usr/bin/env bash
#
# docker-to-rootfs.sh — Convert a Docker image to a Firecracker-bootable ext4 rootfs.
#
# Usage: ./scripts/docker-to-rootfs.sh <docker-image> <output.ext4> [size_mb] [overlay_dir] [fc_init_bin]
#
#   overlay_dir  Optional directory whose contents are copied into the rootfs,
#                mirroring the guest filesystem layout. For example, placing a
#                file at overlay_dir/usr/share/elasticsearch/config/elasticsearch.yml
#                overwrites that path in the rootfs.
#   fc_init_bin  Optional path to a prebuilt linux/arm64 fc-init binary.
#                If omitted, the script tries:
#                  1) FC_INIT_BIN env var
#                  2) ../firework/bin/fc-init
#                  3) build from ../firework/cmd/fc-init (requires Go)
#                  4) fc-init from PATH
#
# Requires: docker, mkfs.ext4 (e2fsprogs), jq
#

set -euo pipefail

IMAGE="${1:?Usage: $0 <docker-image> <output.ext4> [size_mb] [overlay_dir] [fc_init_bin]}"
OUTPUT="${2:?Usage: $0 <docker-image> <output.ext4> [size_mb] [overlay_dir] [fc_init_bin]}"
SIZE_MB="${3:-512}"
OVERLAY_DIR="${4:-}"
FC_INIT_BIN_INPUT="${5:-${FC_INIT_BIN:-}}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

WORKDIR="$(mktemp -d)"
trap 'chmod -R u+rwX "$WORKDIR" 2>/dev/null; rm -rf "$WORKDIR"' EXIT

ROOTFS="$WORKDIR/rootfs"
mkdir -p "$ROOTFS"

resolve_fc_init_bin() {
    local candidate="$FC_INIT_BIN_INPUT"
    local sibling_firework="$REPO_ROOT/../firework"

    if [ -n "$candidate" ]; then
        if [ ! -x "$candidate" ]; then
            echo "ERROR: fc-init binary is not executable: $candidate" >&2
            exit 1
        fi
        echo "$candidate"
        return
    fi

    if [ -x "$sibling_firework/bin/fc-init" ]; then
        echo "$sibling_firework/bin/fc-init"
        return
    fi

    if [ -d "$sibling_firework" ] && command -v go >/dev/null 2>&1; then
        echo "==> Building fc-init from sibling firework repo" >&2
        (
            cd "$sibling_firework"
            GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -ldflags "-s -w" -o "$WORKDIR/fc-init" ./cmd/fc-init/
        )
        echo "$WORKDIR/fc-init"
        return
    fi

    if command -v fc-init >/dev/null 2>&1; then
        echo "$(command -v fc-init)"
        return
    fi

    cat <<'EOF' >&2
ERROR: Could not locate fc-init binary.
Provide it explicitly:
  ./scripts/docker-to-rootfs.sh <image> <output.ext4> [size_mb] [overlay_dir] /path/to/fc-init
or via environment variable:
  FC_INIT_BIN=/path/to/fc-init ./scripts/docker-to-rootfs.sh ...

You can build it from the firework repo with:
  (cd ../firework && make build-fc-init)
EOF
    exit 1
}

validate_fc_init_bin() {
    local bin="$1"

    if ! command -v file >/dev/null 2>&1; then
        return
    fi

    local desc
    desc="$(file -b "$bin" || true)"
    if ! printf '%s' "$desc" | grep -Eiq 'ELF.*(aarch64|ARM64|ARM aarch64|AArch64)'; then
        echo "ERROR: fc-init binary must be linux/arm64 ELF, got: $desc" >&2
        exit 1
    fi
}

FC_INIT_BIN_PATH="$(resolve_fc_init_bin)"
validate_fc_init_bin "$FC_INIT_BIN_PATH"
echo "==> Using fc-init binary: $FC_INIT_BIN_PATH"

echo "==> Pulling image: $IMAGE"
docker pull "$IMAGE"

echo "==> Exporting filesystem"
CONTAINER_ID="$(docker create "$IMAGE")"
docker export "$CONTAINER_ID" | tar -xf - -C "$ROOTFS"
docker rm "$CONTAINER_ID" > /dev/null

# Some images (e.g. Elasticsearch) have restrictive permissions on exported files.
# Make everything writable so we can inject fc-init and apply overlays.
chmod -R u+rwX "$ROOTFS"

# Extract ENTRYPOINT and CMD from the image config.
echo "==> Reading ENTRYPOINT/CMD from image"
INSPECT_JSON="$(docker inspect "$IMAGE")"
ENTRYPOINT="$(echo "$INSPECT_JSON" | jq -r '.[0].Config.Entrypoint // [] | join(" ")')"
CMD="$(echo "$INSPECT_JSON" | jq -r '.[0].Config.Cmd // [] | join(" ")')"
APP_USER="$(echo "$INSPECT_JSON" | jq -r '.[0].Config.User // ""')"
VOLUME_PATHS_JSON="$(echo "$INSPECT_JSON" | jq -c '.[0].Config.Volumes // {} | keys')"

# Build the command the init process will exec.
# Docker semantics: ENTRYPOINT + CMD are concatenated.
if [ -n "$ENTRYPOINT" ] && [ -n "$CMD" ]; then
    APP_CMD="$ENTRYPOINT $CMD"
elif [ -n "$ENTRYPOINT" ]; then
    APP_CMD="$ENTRYPOINT"
elif [ -n "$CMD" ]; then
    APP_CMD="$CMD"
else
    echo "ERROR: Image has no ENTRYPOINT or CMD" >&2
    exit 1
fi

echo "    App command: $APP_CMD"

# Extract ENV from the image config for the init script.
ENV_LINES="$(echo "$INSPECT_JSON" | jq -r '.[0].Config.Env // [] | .[]' | while IFS= read -r line; do
    echo "export $line"
done)"
RUNTIME_ENV_JSON="$(echo "$INSPECT_JSON" | jq -c '.[0].Config.Env // [] | map(split("=") | { (.[0]): (.[1:] | join("=")) }) | add // {}')"

# Extract WORKDIR from the image config.
APP_WORKDIR="$(echo "$INSPECT_JSON" | jq -r '.[0].Config.WorkingDir // ""')"
RUNTIME_WRITABLE_PATHS_JSON="$(jq -cn \
  --arg workdir "$APP_WORKDIR" \
  --argjson volumes "$VOLUME_PATHS_JSON" \
  '
  (
    [
      "/tmp",
      "/var/tmp",
      "/run",
      "/usr/share/kibana/data",
      "/usr/share/elasticsearch/config",
      "/usr/share/elasticsearch/data",
      "/usr/share/elasticsearch/logs"
    ]
    + (if $workdir != "" then [$workdir] else [] end)
    + $volumes
  )
  | map(select(type == "string" and length > 0))
  | unique
  ')"

# Apply config overlay if provided.
if [ -n "$OVERLAY_DIR" ] && [ -d "$OVERLAY_DIR" ]; then
    echo "==> Applying config overlay from $OVERLAY_DIR"
    cp -r "$OVERLAY_DIR/." "$ROOTFS/"
fi

# Some upstream images carry runtime-generated files that should not be baked
# into a reusable base rootfs.
if [ -f "$ROOTFS/usr/share/kibana/data/uuid" ]; then
    echo "==> Removing stale Kibana UUID file from rootfs"
    rm -f "$ROOTFS/usr/share/kibana/data/uuid"
fi

# Write Docker-derived runtime metadata consumed by /sbin/fc-init.
echo "==> Writing /etc/firework/runtime.json"
mkdir -p "$ROOTFS/etc/firework"
jq -n \
  --arg user "$APP_USER" \
  --arg workdir "$APP_WORKDIR" \
  --argjson env "$RUNTIME_ENV_JSON" \
  --argjson writable_paths "$RUNTIME_WRITABLE_PATHS_JSON" \
  '{user: $user, workdir: $workdir, env: $env, writable_paths: $writable_paths}' > "$ROOTFS/etc/firework/runtime.json"

# Install /sbin/fc-init compiled binary from the firework repo.
echo "==> Installing /sbin/fc-init"
mkdir -p "$ROOTFS/sbin"
cp "$FC_INIT_BIN_PATH" "$ROOTFS/sbin/fc-init"
chmod 755 "$ROOTFS/sbin/fc-init"

# Generate /sbin/init wrapper from Docker metadata so services still boot
# correctly when kernel args only specify "init=/sbin/fc-init".
echo "==> Generating /sbin/init wrapper from Docker metadata"
cat > "$ROOTFS/sbin/init" <<INIT_EOF
#!/bin/sh

# Environment from Docker image
$ENV_LINES

${APP_WORKDIR:+cd "$APP_WORKDIR"}

exec $APP_CMD
INIT_EOF
chmod 755 "$ROOTFS/sbin/init"

# Ensure essential directories exist in the rootfs.
mkdir -p "$ROOTFS"/{proc,sys,dev,tmp,var/run}

echo "==> Building ext4 image (${SIZE_MB}M)"
dd if=/dev/zero of="$OUTPUT" bs=1M count="$SIZE_MB" status=none
mkfs.ext4 -F -d "$ROOTFS" "$OUTPUT" > /dev/null 2>&1

echo "==> Done: $OUTPUT ($(du -h "$OUTPUT" | cut -f1))"
