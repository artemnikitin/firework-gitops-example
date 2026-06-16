#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

CACHE_BIN_DIR="${CACHE_BIN_DIR:-.cache/bin}"
if [[ "$CACHE_BIN_DIR" != /* ]]; then
    CACHE_BIN_DIR="$REPO_ROOT/$CACHE_BIN_DIR"
fi

FC_INIT_BIN="${FC_INIT_BIN:-$CACHE_BIN_DIR/fc-init}"
if [[ "$FC_INIT_BIN" != /* ]]; then
    FC_INIT_BIN="$REPO_ROOT/$FC_INIT_BIN"
fi

configure_tool_paths() {
    if command -v mkfs.ext4 >/dev/null 2>&1; then
        return
    fi

    if command -v brew >/dev/null 2>&1; then
        local e2fsprogs_prefix
        e2fsprogs_prefix="$(brew --prefix e2fsprogs 2>/dev/null || true)"
        if [ -n "$e2fsprogs_prefix" ]; then
            export PATH="${e2fsprogs_prefix}/sbin:${e2fsprogs_prefix}/bin:${PATH}"
        fi
    fi
}

install_fc_init_from_main() {
    local go_path="$REPO_ROOT/.cache/go"
    local installed_bin

    mkdir -p "$go_path" "$(dirname "$FC_INIT_BIN")"

    GOPATH="$go_path" GOOS=linux GOARCH=arm64 CGO_ENABLED=0 \
        go install github.com/artemnikitin/firework/cmd/fc-init@main

    installed_bin="$go_path/bin/fc-init"
    if [ ! -f "$installed_bin" ]; then
        installed_bin="$go_path/bin/linux_arm64/fc-init"
    fi

    if [ ! -f "$installed_bin" ]; then
        echo "ERROR: go install completed, but fc-init was not found in $go_path/bin" >&2
        return 1
    fi

    cp "$installed_bin" "$FC_INIT_BIN"
    chmod +x "$FC_INIT_BIN"
}

resolve_fc_init() {
    mkdir -p "$CACHE_BIN_DIR"

    if [ -n "${FC_INIT_VERSION:-}" ]; then
        local tag
        tag="${FC_INIT_VERSION#v}"
        tag="v${tag}"

        local url
        url="https://github.com/artemnikitin/firework/releases/download/${tag}/fc-init-linux-arm64"
        echo "Downloading fc-init from release ${tag}"
        curl -fsSL "$url" -o "$FC_INIT_BIN"
        chmod +x "$FC_INIT_BIN"
        return
    fi

    echo "FC_INIT_VERSION not set; building fc-init from firework@main"
    if [ -n "${FIREWORK_GITHUB_TOKEN:-}" ]; then
        export GOPRIVATE='github.com/artemnikitin/*'
        export GIT_CONFIG_COUNT=1
        export GIT_CONFIG_KEY_0="url.https://x-access-token:${FIREWORK_GITHUB_TOKEN}@github.com/.insteadOf"
        export GIT_CONFIG_VALUE_0="https://github.com/"
    fi

    if ! install_fc_init_from_main; then
        echo "::warning::Failed to build fc-init from firework@main. Falling back to bundled source."
        GOOS=linux GOARCH=arm64 CGO_ENABLED=0 \
            go build -ldflags "-s -w" -o "$FC_INIT_BIN" ./scripts/fc-init/main.go
    fi
}

overlay_arg_for() {
    local tenant_id="$1"
    local base_name="$2"

    if [ -d "configs/${base_name}" ] && [ -d "configs/${tenant_id}-${base_name}" ]; then
        printf '%s\n' "configs/${base_name}:configs/${tenant_id}-${base_name}"
    elif [ -d "configs/${tenant_id}-${base_name}" ]; then
        printf '%s\n' "configs/${tenant_id}-${base_name}"
    elif [ -d "configs/${base_name}" ]; then
        printf '%s\n' "configs/${base_name}"
    fi
}

yaml_value() {
    local file="$1"
    local key="$2"
    local default_value="$3"

    if command -v yq >/dev/null 2>&1; then
        yq ".${key} // \"${default_value}\"" "$file"
        return
    fi

    if command -v ruby >/dev/null 2>&1; then
        ruby -ryaml -e '
          file, key, default_value = ARGV
          data = YAML.load_file(file) || {}
          value = data[key]
          print(value.nil? ? default_value : value)
        ' "$file" "$key" "$default_value"
        return
    fi

    awk -v key="$key" -v default_value="$default_value" '
      BEGIN { value = default_value }
      $0 ~ "^[[:space:]]*" key ":" {
        sub("^[[:space:]]*" key ":[[:space:]]*", "")
        gsub(/^"|"$/, "")
        value = $0
        exit
      }
      END { print value }
    ' "$file"
}

build_images() {
    for tenant_dir in tenants/*/; do
        [ -d "$tenant_dir" ] || continue
        local tenant_id
        tenant_id="$(basename "$tenant_dir")"
        echo "::group::Tenant: $tenant_id"

        for svc_file in "${tenant_dir}"*.yaml "${tenant_dir}"*.yml; do
            [ -f "$svc_file" ] || continue

            local base_name
            base_name="$(basename "${svc_file%.*}")"

            local source_image
            source_image="$(yaml_value "$svc_file" source_image "")"
            if [ -z "$source_image" ]; then
                echo "Skipping ${tenant_id}-${base_name} - no source_image"
                continue
            fi

            local size_mb
            size_mb="$(yaml_value "$svc_file" rootfs_size_mb 512)"

            local output
            output="${tenant_id}-${base_name}-rootfs.ext4"

            local overlay_arg
            overlay_arg="$(overlay_arg_for "$tenant_id" "$base_name")"

            echo "Building $output from $source_image"
            bash ./scripts/docker-to-rootfs.sh "$source_image" "$output" "$size_mb" \
                "${overlay_arg:-}" "$FC_INIT_BIN"
        done

        echo "::endgroup::"
    done
}

configure_tool_paths
resolve_fc_init
build_images
