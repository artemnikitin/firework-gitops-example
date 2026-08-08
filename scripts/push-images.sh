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
# One bucket per cloud holds every architecture. Objects are uploaded under an
# <arch>/ prefix, and the Firework agent reads the prefix matching the node it
# runs on. The prefix uses the Go architecture vocabulary (amd64, arm64) that
# TARGET_PLATFORM already carries — not the AWS x86_64 spelling, which would be
# a silent 404 on the agent side.
#
# Environment:
#   S3_IMAGES_BUCKET   destination bucket for the s3 backend
#   GCS_IMAGES_BUCKET  destination bucket for the gcs backend
#   TARGET_PLATFORM    platform the images were built for; sets the key prefix

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

BACKEND="${1:-}"

# Deliberately no default. `make build-arm64` sets TARGET_PLATFORM inside its
# own recipe, so a defaulted push would let `make build-arm64 && make push-s3`
# publish arm64 images under amd64/ and overwrite them in the now-shared bucket.
# CI always sets it explicitly, so requiring it costs nothing.
if [ -z "${TARGET_PLATFORM:-}" ]; then
    echo "ERROR: TARGET_PLATFORM must be set; it selects the <arch>/ key prefix" >&2
    echo "Pass the platform the images were built for, e.g.:" >&2
    echo "  TARGET_PLATFORM=linux/arm64 make push-s3" >&2
    exit 1
fi

case "$TARGET_PLATFORM" in
    linux/amd64 | linux/arm64)
        TARGET_ARCH="${TARGET_PLATFORM##*/}"
        ;;
    *)
        echo "ERROR: unsupported target platform: $TARGET_PLATFORM" >&2
        echo "Supported platforms: linux/amd64, linux/arm64" >&2
        exit 1
        ;;
esac

push_s3() {
    if [ -z "${S3_IMAGES_BUCKET:-}" ]; then
        echo "ERROR: S3_IMAGES_BUCKET must be set for the s3 backend" >&2
        exit 1
    fi
    for ext4 in *-rootfs.ext4; do
        [ -f "$ext4" ] || continue
        echo "Uploading $ext4 to s3://${S3_IMAGES_BUCKET}/${TARGET_ARCH}/${ext4}"
        aws s3 cp "$ext4" "s3://${S3_IMAGES_BUCKET}/${TARGET_ARCH}/${ext4}"
    done
}

push_gcs() {
    if [ -z "${GCS_IMAGES_BUCKET:-}" ]; then
        echo "ERROR: GCS_IMAGES_BUCKET must be set for the gcs backend" >&2
        exit 1
    fi
    for ext4 in *-rootfs.ext4; do
        [ -f "$ext4" ] || continue
        echo "Uploading $ext4 to gs://${GCS_IMAGES_BUCKET}/${TARGET_ARCH}/${ext4}"
        gcloud storage cp "$ext4" "gs://${GCS_IMAGES_BUCKET}/${TARGET_ARCH}/${ext4}"
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
