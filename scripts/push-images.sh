#!/usr/bin/env bash

# Usage: ./scripts/push-images.sh [backend]
#
#   backend  Optional object store to upload to: "s3" or "gcs". When given, the
#            matching bucket variable is required and the other is ignored.
#            When omitted the backend is inferred from whichever single bucket
#            variable is set, and having both set is an error rather than a
#            silent preference — CI exports both, so inference cannot
#            distinguish "push to S3" from "push to GCS" on its own.
#
# Environment:
#   S3_IMAGES_BUCKET   destination bucket for the s3 backend
#   GCS_IMAGES_BUCKET  destination bucket for the gcs backend

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

BACKEND="${1:-}"

push_s3() {
    if [ -z "${S3_IMAGES_BUCKET:-}" ]; then
        echo "ERROR: S3_IMAGES_BUCKET must be set for the s3 backend" >&2
        exit 1
    fi
    for ext4 in *-rootfs.ext4; do
        [ -f "$ext4" ] || continue
        echo "Uploading $ext4 to s3://${S3_IMAGES_BUCKET}/${ext4}"
        aws s3 cp "$ext4" "s3://${S3_IMAGES_BUCKET}/${ext4}"
    done
}

push_gcs() {
    if [ -z "${GCS_IMAGES_BUCKET:-}" ]; then
        echo "ERROR: GCS_IMAGES_BUCKET must be set for the gcs backend" >&2
        exit 1
    fi
    for ext4 in *-rootfs.ext4; do
        [ -f "$ext4" ] || continue
        echo "Uploading $ext4 to gs://${GCS_IMAGES_BUCKET}/${ext4}"
        gcloud storage cp "$ext4" "gs://${GCS_IMAGES_BUCKET}/${ext4}"
    done
}

case "$BACKEND" in
    s3)
        push_s3
        ;;
    gcs)
        push_gcs
        ;;
    "")
        if [ -n "${S3_IMAGES_BUCKET:-}" ] && [ -n "${GCS_IMAGES_BUCKET:-}" ]; then
            echo "ERROR: S3_IMAGES_BUCKET and GCS_IMAGES_BUCKET are both set; pass an explicit backend (s3 or gcs)" >&2
            exit 1
        elif [ -n "${GCS_IMAGES_BUCKET:-}" ]; then
            push_gcs
        elif [ -n "${S3_IMAGES_BUCKET:-}" ]; then
            push_s3
        else
            echo "ERROR: S3_IMAGES_BUCKET or GCS_IMAGES_BUCKET must be set" >&2
            exit 1
        fi
        ;;
    *)
        echo "ERROR: unknown backend: $BACKEND (expected s3 or gcs)" >&2
        exit 1
        ;;
esac
