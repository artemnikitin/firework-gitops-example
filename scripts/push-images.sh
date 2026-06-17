#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

if [ -z "${S3_IMAGES_BUCKET:-}" ]; then
    echo "ERROR: S3_IMAGES_BUCKET is required" >&2
    exit 1
fi

for ext4 in *-rootfs.ext4; do
    [ -f "$ext4" ] || continue
    echo "Uploading $ext4 to s3://${S3_IMAGES_BUCKET}/${ext4}"
    aws s3 cp "$ext4" "s3://${S3_IMAGES_BUCKET}/${ext4}"
done
