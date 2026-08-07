#!/usr/bin/env bash

# Regression checks for scripts/push-images.sh backend selection.
#
# CI exports both S3_IMAGES_BUCKET and GCS_IMAGES_BUCKET for the amd64 build, so
# `make push-s3` must upload to S3 even though a GCS bucket is also configured.
# An earlier version inferred the backend and preferred GCS, which silently sent
# the AWS images to GCS and left the S3 bucket untouched.
#
# Runs the real Makefile targets with `aws` and `gcloud` stubbed on PATH.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

mkdir -p "$WORKDIR/bin"
printf '#!/bin/sh\necho "aws $*"\n' > "$WORKDIR/bin/aws"
printf '#!/bin/sh\necho "gcloud $*"\n' > "$WORKDIR/bin/gcloud"
chmod +x "$WORKDIR/bin/aws" "$WORKDIR/bin/gcloud"

FAILURES=0

print_indented() {
    while IFS= read -r line; do
        printf '    %s\n' "$line"
    done <<< "$1"
}

# Run a make target from a scratch copy of the repo's pipeline entrypoints so a
# stray *-rootfs.ext4 in the working tree cannot affect the result.
run_case() {
    local desc="$1" target="$2" expected="$3"
    shift 3

    local sandbox="$WORKDIR/case"
    rm -rf "$sandbox"
    mkdir -p "$sandbox/scripts"
    cp "$REPO_ROOT/Makefile" "$sandbox/Makefile"
    cp "$REPO_ROOT/scripts/push-images.sh" "$sandbox/scripts/push-images.sh"
    touch "$sandbox/demo-rootfs.ext4"

    local output status=0
    output="$(cd "$sandbox" && env PATH="$WORKDIR/bin:$PATH" "$@" make "$target" 2>&1)" || status=$?

    if [ "$expected" = "FAIL" ]; then
        if [ "$status" -eq 0 ]; then
            echo "FAIL: $desc — expected a non-zero exit, got 0"
            print_indented "$output"
            FAILURES=$((FAILURES + 1))
        else
            echo "ok: $desc"
        fi
        return
    fi

    if [ "$status" -ne 0 ]; then
        echo "FAIL: $desc — command exited $status"
        print_indented "$output"
        FAILURES=$((FAILURES + 1))
    elif printf '%s\n' "$output" | grep -q "$expected"; then
        echo "ok: $desc"
    else
        echo "FAIL: $desc — expected output matching: $expected"
        print_indented "$output"
        FAILURES=$((FAILURES + 1))
    fi
}

# The regression: both buckets set, as the amd64 CI leg exports them.
run_case "push-s3 uploads to S3 when both buckets are set" \
    push-s3 "aws s3 cp demo-rootfs.ext4 s3://s3-bucket/demo-rootfs.ext4" \
    S3_IMAGES_BUCKET=s3-bucket GCS_IMAGES_BUCKET=gcs-bucket

run_case "push-gcs uploads to GCS when both buckets are set" \
    push-gcs "gcloud storage cp demo-rootfs.ext4 gs://gcs-bucket/demo-rootfs.ext4" \
    S3_IMAGES_BUCKET=s3-bucket GCS_IMAGES_BUCKET=gcs-bucket

run_case "push-s3 uploads to S3 when only the S3 bucket is set" \
    push-s3 "aws s3 cp demo-rootfs.ext4 s3://s3-bucket/demo-rootfs.ext4" \
    S3_IMAGES_BUCKET=s3-bucket

run_case "push-gcs uploads to GCS when only the GCS bucket is set" \
    push-gcs "gcloud storage cp demo-rootfs.ext4 gs://gcs-bucket/demo-rootfs.ext4" \
    GCS_IMAGES_BUCKET=gcs-bucket

run_case "push-s3 fails when the S3 bucket is unset" \
    push-s3 FAIL GCS_IMAGES_BUCKET=gcs-bucket

run_case "push without a backend fails when both buckets are set" \
    push FAIL S3_IMAGES_BUCKET=s3-bucket GCS_IMAGES_BUCKET=gcs-bucket

if [ "$FAILURES" -ne 0 ]; then
    echo "$FAILURES check(s) failed" >&2
    exit 1
fi

echo "All push-images backend checks passed"
