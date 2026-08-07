#!/usr/bin/env bash
#
# docker-to-rootfs.sh — Convert a Docker image to a Firecracker-bootable ext4 rootfs.
#
# Usage: ./scripts/docker-to-rootfs.sh <docker-image> <output.ext4> [size_mb] [overlay_dir] [fc_init_bin] [target_platform]
#
#   overlay_dir  Optional colon-separated list of directories whose contents are
#                copied into the rootfs in order, mirroring the guest filesystem
#                layout. Later directories override earlier ones, so pass the shared
#                baseline first and tenant-specific overlay second. For example:
#                  configs/elasticsearch:configs/tenant-1-elasticsearch
#   fc_init_bin  Optional path to a prebuilt fc-init binary for target_platform.
#                If omitted, the script tries:
#                  1) FC_INIT_BIN env var
#                  2) ../firework/bin/fc-init-linux-<arch>
#                  3) ../firework/bin/fc-init (linux/arm64 compatibility alias)
#                  4) build from ../firework/cmd/fc-init (requires Go)
#                  5) fc-init from PATH
#   target_platform Optional Docker platform to export. Defaults to
#                   TARGET_PLATFORM env var, then linux/amd64.
#
# Requires: docker with buildx, mkfs.ext4 (e2fsprogs), jq
#

set -euo pipefail

IMAGE="${1:?Usage: $0 <docker-image> <output.ext4> [size_mb] [overlay_dir] [fc_init_bin] [target_platform]}"
OUTPUT="${2:?Usage: $0 <docker-image> <output.ext4> [size_mb] [overlay_dir] [fc_init_bin] [target_platform]}"
SIZE_MB="${3:-512}"
OVERLAY_DIR="${4:-}"
FC_INIT_BIN_INPUT="${5:-${FC_INIT_BIN:-}}"
TARGET_PLATFORM="${6:-${TARGET_PLATFORM:-linux/amd64}}"
TARGET_ARCH="${TARGET_PLATFORM##*/}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

WORKDIR="$(mktemp -d)"
CONTAINER_ID=""
cleanup() {
    if [ -n "$CONTAINER_ID" ]; then
        docker rm "$CONTAINER_ID" > /dev/null 2>&1 || true
    fi
    chmod -R u+rwX "$WORKDIR" 2>/dev/null
    rm -rf "$WORKDIR"
}
trap cleanup EXIT

ROOTFS="$WORKDIR/rootfs"
mkdir -p "$ROOTFS"

case "$TARGET_PLATFORM" in
    linux/amd64 | linux/arm64)
        ;;
    *)
        echo "ERROR: unsupported target platform: $TARGET_PLATFORM" >&2
        echo "Supported platforms: linux/amd64, linux/arm64" >&2
        exit 1
        ;;
esac

resolve_fc_init_bin() {
    local candidate="$FC_INIT_BIN_INPUT"
    local sibling_firework="$REPO_ROOT/../firework"
    local arch_candidate="$sibling_firework/bin/fc-init-linux-$TARGET_ARCH"

    if [ -n "$candidate" ]; then
        if [ ! -x "$candidate" ]; then
            echo "ERROR: fc-init binary is not executable: $candidate" >&2
            exit 1
        fi
        echo "$candidate"
        return
    fi

    if [ -x "$arch_candidate" ]; then
        echo "$arch_candidate"
        return
    fi

    if [ "$TARGET_ARCH" = "arm64" ] && [ -x "$sibling_firework/bin/fc-init" ]; then
        echo "$sibling_firework/bin/fc-init"
        return
    fi

    if [ -d "$sibling_firework" ] && command -v go >/dev/null 2>&1; then
        echo "==> Building fc-init for $TARGET_PLATFORM from sibling firework repo" >&2
        (
            cd "$sibling_firework"
            GOOS=linux GOARCH="$TARGET_ARCH" CGO_ENABLED=0 go build -ldflags "-s -w" -o "$WORKDIR/fc-init" ./cmd/fc-init/
        )
        echo "$WORKDIR/fc-init"
        return
    fi

    if command -v fc-init >/dev/null 2>&1; then
        command -v fc-init
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
    local pattern

    if ! command -v file >/dev/null 2>&1; then
        return
    fi

    local desc
    desc="$(file -b "$bin" || true)"

    case "$TARGET_ARCH" in
        amd64)
            pattern='ELF.*(x86-64|x86_64|AMD64)'
            ;;
        arm64)
            pattern='ELF.*(aarch64|ARM64|ARM aarch64|AArch64)'
            ;;
    esac

    if ! printf '%s' "$desc" | grep -Eiq "$pattern"; then
        echo "ERROR: fc-init binary must match $TARGET_PLATFORM, got: $desc" >&2
        exit 1
    fi
}

image_repo_for_digest() {
    local image="$1"
    local last_component

    if [[ "$image" == *@* ]]; then
        printf '%s\n' "${image%@*}"
        return
    fi

    last_component="${image##*/}"
    if [[ "$last_component" == *:* ]]; then
        printf '%s\n' "${image%:*}"
        return
    fi

    printf '%s\n' "$image"
}

resolve_platform_image() {
    local image="$1"
    local manifest_json
    local has_manifests
    local digest
    local repo

    if ! command -v docker >/dev/null 2>&1 || ! docker buildx version >/dev/null 2>&1; then
        echo "ERROR: docker buildx is required to resolve platform-specific image digests" >&2
        exit 1
    fi

    manifest_json="$(docker buildx imagetools inspect --raw "$image")"
    has_manifests="$(printf '%s\n' "$manifest_json" | jq -r 'has("manifests")')"
    if [ "$has_manifests" != "true" ]; then
        printf '%s\n' "$image"
        return
    fi

    digest="$(printf '%s\n' "$manifest_json" | jq -r \
        --arg os "linux" \
        --arg arch "$TARGET_ARCH" \
        'first(.manifests[]? | select(.platform.os == $os and .platform.architecture == $arch) | .digest) // ""')"
    if [ -z "$digest" ]; then
        echo "ERROR: image $image does not publish a $TARGET_PLATFORM manifest" >&2
        exit 1
    fi

    repo="$(image_repo_for_digest "$image")"
    printf '%s@%s\n' "$repo" "$digest"
}

FC_INIT_BIN_PATH="$(resolve_fc_init_bin)"
validate_fc_init_bin "$FC_INIT_BIN_PATH"
echo "==> Using fc-init binary: $FC_INIT_BIN_PATH"

PLATFORM_IMAGE="$(resolve_platform_image "$IMAGE")"

echo "==> Pulling image: $IMAGE ($TARGET_PLATFORM)"
docker pull --platform "$TARGET_PLATFORM" "$PLATFORM_IMAGE"

echo "==> Creating container for $TARGET_PLATFORM"
CONTAINER_ID="$(docker create --platform "$TARGET_PLATFORM" "$PLATFORM_IMAGE")"

# Read metadata from the exact image ID Docker selected for the container.
# Inspecting a multi-arch tag can report a different locally cached platform.
CONTAINER_INSPECT_JSON="$(docker inspect "$CONTAINER_ID")"
IMAGE_ID="$(echo "$CONTAINER_INSPECT_JSON" | jq -r '.[0].Image')"
INSPECT_JSON="$(docker inspect "$IMAGE_ID")"

IMAGE_ARCH="$(echo "$INSPECT_JSON" | jq -r '.[0].Architecture // ""')"
if [ "$IMAGE_ARCH" != "$TARGET_ARCH" ]; then
    echo "ERROR: pulled image architecture mismatch: expected $TARGET_ARCH, got ${IMAGE_ARCH:-unknown}" >&2
    exit 1
fi

echo "==> Exporting filesystem"
docker export "$CONTAINER_ID" | tar -xf - -C "$ROOTFS"
docker rm "$CONTAINER_ID" > /dev/null
CONTAINER_ID=""

# Some images (e.g. Elasticsearch) have restrictive permissions on exported files.
# Make everything writable so we can inject fc-init and apply overlays.
chmod -R u+rwX "$ROOTFS"

# Extract ENTRYPOINT and CMD from the image config.
echo "==> Reading ENTRYPOINT/CMD from image"
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

# Apply config overlays in order. OVERLAY_DIR may be a colon-separated list;
# later entries override earlier ones (shared baseline first, tenant-specific second).
if [ -n "$OVERLAY_DIR" ]; then
    IFS=: read -ra overlay_dirs <<< "$OVERLAY_DIR"
    for dir in "${overlay_dirs[@]}"; do
        [ -n "$dir" ] || continue
        [ -d "$dir" ] || continue
        echo "==> Applying config overlay from $dir"
        cp -r "$dir/." "$ROOTFS/"
    done
fi

# Some upstream images carry runtime-generated files that should not be baked
# into a reusable base rootfs.
if [ -f "$ROOTFS/usr/share/kibana/data/uuid" ]; then
    echo "==> Removing stale Kibana UUID file from rootfs"
    rm -f "$ROOTFS/usr/share/kibana/data/uuid"
fi
if [ -f "$ROOTFS/usr/share/elasticsearch/config/elasticsearch.keystore" ]; then
    echo "==> Removing Elasticsearch keystore from rootfs (recreated at boot)"
    rm -f "$ROOTFS/usr/share/elasticsearch/config/elasticsearch.keystore"
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
rm -f "$ROOTFS/sbin/fc-init"
cp "$FC_INIT_BIN_PATH" "$ROOTFS/sbin/fc-init"
chmod 755 "$ROOTFS/sbin/fc-init"

# Generate /sbin/init wrapper from Docker metadata so services still boot
# correctly when kernel args only specify "init=/sbin/fc-init".
echo "==> Generating /sbin/init wrapper from Docker metadata"
rm -f "$ROOTFS/sbin/init"
cat > "$ROOTFS/sbin/init" <<INIT_EOF
#!/bin/sh

# Environment from Docker image
$ENV_LINES

${APP_WORKDIR:+cd "$APP_WORKDIR"}

exec $APP_CMD
INIT_EOF
chmod 755 "$ROOTFS/sbin/init"

# Ensure essential directories exist in the rootfs.
mkdir -p "$ROOTFS"/{proc,sys,dev,tmp,var}

echo "==> Building ext4 image (${SIZE_MB}M)"
dd if=/dev/zero of="$OUTPUT" bs=1M count="$SIZE_MB" status=none
mkfs.ext4 -F -d "$ROOTFS" "$OUTPUT" > /dev/null 2>&1

echo "==> Done: $OUTPUT ($(du -h "$OUTPUT" | cut -f1))"
