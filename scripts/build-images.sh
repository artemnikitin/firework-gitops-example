#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

CACHE_BIN_DIR="${CACHE_BIN_DIR:-.cache/bin}"
if [[ "$CACHE_BIN_DIR" != /* ]]; then
    CACHE_BIN_DIR="$REPO_ROOT/$CACHE_BIN_DIR"
fi

TARGET_PLATFORM="${TARGET_PLATFORM:-linux/arm64}"
FC_INIT_BIN_INPUT="${FC_INIT_BIN:-}"
if [[ -n "$FC_INIT_BIN_INPUT" && "$FC_INIT_BIN_INPUT" != /* ]]; then
    FC_INIT_BIN_INPUT="$REPO_ROOT/$FC_INIT_BIN_INPUT"
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

platform_arch() {
    local platform="$1"

    case "$platform" in
        linux/amd64)
            printf '%s\n' "amd64"
            ;;
        linux/arm64)
            printf '%s\n' "arm64"
            ;;
        *)
            echo "ERROR: unsupported target platform: $platform" >&2
            echo "Supported platforms: linux/amd64, linux/arm64" >&2
            exit 1
            ;;
    esac
}

install_fc_init_from_ref() {
    local ref="$1"
    local goarch="$2"
    local output="$3"
    local go_path="$REPO_ROOT/.cache/go"
    local installed_bin

    mkdir -p "$go_path" "$(dirname "$output")"

    GOPATH="$go_path" GOOS=linux GOARCH="$goarch" CGO_ENABLED=0 \
        go install "github.com/artemnikitin/firework/cmd/fc-init@${ref}"

    installed_bin="$go_path/bin/fc-init"
    if [ ! -f "$installed_bin" ]; then
        installed_bin="$go_path/bin/linux_${goarch}/fc-init"
    fi

    if [ ! -f "$installed_bin" ]; then
        echo "ERROR: go install completed, but fc-init was not found in $go_path/bin" >&2
        return 1
    fi

    cp "$installed_bin" "$output"
    chmod +x "$output"
}

configure_firework_github_access() {
    if [ -n "${FIREWORK_GITHUB_TOKEN:-}" ]; then
        export GOPRIVATE='github.com/artemnikitin/*'
        export GIT_CONFIG_COUNT=1
        export GIT_CONFIG_KEY_0="url.https://x-access-token:${FIREWORK_GITHUB_TOKEN}@github.com/.insteadOf"
        export GIT_CONFIG_VALUE_0="https://github.com/"
    fi
}

resolve_fc_init() {
    local platform="$1"
    local output="$2"
    local goarch
    goarch="$(platform_arch "$platform")"

    mkdir -p "$CACHE_BIN_DIR"

    if [ -n "$FC_INIT_BIN_INPUT" ]; then
        if [ ! -x "$FC_INIT_BIN_INPUT" ]; then
            echo "ERROR: FC_INIT_BIN is not executable: $FC_INIT_BIN_INPUT" >&2
            exit 1
        fi
        return
    fi

    configure_firework_github_access

    if [ -n "${FC_INIT_VERSION:-}" ]; then
        local tag
        tag="${FC_INIT_VERSION#v}"
        tag="v${tag}"

        local url
        url="https://github.com/artemnikitin/firework/releases/download/${tag}/fc-init-linux-${goarch}"
        echo "Downloading fc-init for ${platform} from release ${tag}"
        if curl -fsSL "$url" -o "$output"; then
            chmod +x "$output"
            return
        fi

        echo "::warning::Release asset fc-init-linux-${goarch} was not found for ${tag}. Building fc-init from source tag ${tag}."
        install_fc_init_from_ref "$tag" "$goarch" "$output"
        return
    fi

    echo "FC_INIT_VERSION not set; building fc-init for ${platform} from firework@main"

    if ! install_fc_init_from_ref "main" "$goarch" "$output"; then
        echo "::warning::Failed to build fc-init from firework@main. Falling back to bundled source."
        GOOS=linux GOARCH="$goarch" CGO_ENABLED=0 \
            go build -ldflags "-s -w" -o "$output" ./scripts/fc-init/main.go
    fi
}

GLOBAL_PIPELINE_PATHS=(
    "scripts/docker-to-rootfs.sh"
    "scripts/build-images.sh"
    "scripts/fc-init"
    "Makefile"
    ".github/workflows/build-images.yaml"
)

# A usable comparison SHA lets us skip per-service builds when nothing
# relevant changed. Any failure here (no git repo, bad/missing SHA, forced
# rebuild) must fall back to building everything - that's today's behavior
# and is always correct, just not optimized.
diff_base_usable() {
    [ "${FORCE_REBUILD:-false}" != "true" ] || return 1
    [ -n "${COMPARE_BASE_SHA:-}" ] || return 1
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
    git cat-file -e "${COMPARE_BASE_SHA}^{commit}" 2>/dev/null || return 1
    return 0
}

# Returns success (0) when it is safe to consider skipping unchanged
# per-service builds, i.e. none of the shared pipeline inputs changed.
skip_eligible() {
    diff_base_usable || return 1
    git diff --quiet "$COMPARE_BASE_SHA" -- "${GLOBAL_PIPELINE_PATHS[@]}" 2>/dev/null
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
    local platform="$1"
    local fc_init_bin="$2"

    for tenant_dir in tenants/*/; do
        [ -d "$tenant_dir" ] || continue
        local tenant_id
        tenant_id="$(basename "$tenant_dir")"
        echo "::group::Tenant: $tenant_id ($platform)"

        for svc_file in "${tenant_dir}"*.yaml "${tenant_dir}"*.yml; do
            [ -f "$svc_file" ] || continue

            local base_name
            base_name="$(basename "${svc_file%.*}")"

            if [ "$SKIP_ELIGIBLE" = "true" ]; then
                # Always pass both overlay paths, even if absent on disk right now:
                # a deleted overlay dir must still show up in the diff, or its
                # removal would be invisible to the skip check.
                local svc_paths=("$svc_file" "configs/${base_name}" "configs/${tenant_id}-${base_name}")

                if git diff --quiet "$COMPARE_BASE_SHA" -- "${svc_paths[@]}" 2>/dev/null; then
                    echo "Skipping ${tenant_id}-${base_name} ($platform) - no changes since $COMPARE_BASE_SHA"
                    continue
                fi
            fi

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
                "${overlay_arg:-}" "$fc_init_bin" "$platform"
        done

        echo "::endgroup::"
    done
}

configure_tool_paths
TARGET_ARCH="$(platform_arch "$TARGET_PLATFORM")"
FC_INIT_BIN_FOR_PLATFORM="${FC_INIT_BIN_INPUT:-$CACHE_BIN_DIR/fc-init-linux-$TARGET_ARCH}"
resolve_fc_init "$TARGET_PLATFORM" "$FC_INIT_BIN_FOR_PLATFORM"

SKIP_ELIGIBLE=false
if skip_eligible; then
    SKIP_ELIGIBLE=true
elif diff_base_usable; then
    echo "Shared pipeline inputs changed since $COMPARE_BASE_SHA; building every image."
fi

build_images "$TARGET_PLATFORM" "$FC_INIT_BIN_FOR_PLATFORM"
