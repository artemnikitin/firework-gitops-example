#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

if [ -n "${GCS_IMAGES_BUCKET:-}" ]; then
    for ext4 in *-rootfs.ext4; do
        [ -f "$ext4" ] || continue
        echo "Uploading $ext4 to gs://${GCS_IMAGES_BUCKET}/${ext4}"
        gcloud storage cp "$ext4" "gs://${GCS_IMAGES_BUCKET}/${ext4}"
    done
elif [ -n "${S3_IMAGES_BUCKET:-}" ]; then
    for ext4 in *-rootfs.ext4; do
        [ -f "$ext4" ] || continue
        echo "Uploading $ext4 to s3://${S3_IMAGES_BUCKET}/${ext4}"
        aws s3 cp "$ext4" "s3://${S3_IMAGES_BUCKET}/${ext4}"
    done
else
    echo "ERROR: S3_IMAGES_BUCKET or GCS_IMAGES_BUCKET must be set" >&2
    exit 1
fi
