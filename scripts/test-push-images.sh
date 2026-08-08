#!/usr/bin/env bash

# Regression checks for scripts/push-images.sh backend selection and the
# architecture key prefix.
#
# CI exports both S3_IMAGES_BUCKET and GCS_IMAGES_BUCKET for every build, so
# `make push-s3` must upload to S3 even though a GCS bucket is also configured.
# An earlier version inferred the backend and preferred GCS, which silently sent
# the AWS images to GCS and left the S3 bucket untouched.
#
# One bucket per cloud holds every architecture, so the destination key must
# carry an <arch>/ prefix derived from TARGET_PLATFORM. Publishing to the wrong
# prefix — or to none — is invisible until a node boots a guest built for
# another architecture.
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
    push-s3 "aws s3 cp demo-rootfs.ext4 s3://s3-bucket/amd64/demo-rootfs.ext4" \
    TARGET_PLATFORM=linux/amd64 S3_IMAGES_BUCKET=s3-bucket GCS_IMAGES_BUCKET=gcs-bucket

run_case "push-gcs uploads to GCS when both buckets are set" \
    push-gcs "gcloud storage cp demo-rootfs.ext4 gs://gcs-bucket/amd64/demo-rootfs.ext4" \
    TARGET_PLATFORM=linux/amd64 S3_IMAGES_BUCKET=s3-bucket GCS_IMAGES_BUCKET=gcs-bucket

run_case "push-s3 uploads to S3 when only the S3 bucket is set" \
    push-s3 "aws s3 cp demo-rootfs.ext4 s3://s3-bucket/amd64/demo-rootfs.ext4" \
    TARGET_PLATFORM=linux/amd64 S3_IMAGES_BUCKET=s3-bucket

run_case "push-gcs uploads to GCS when only the GCS bucket is set" \
    push-gcs "gcloud storage cp demo-rootfs.ext4 gs://gcs-bucket/amd64/demo-rootfs.ext4" \
    GCS_IMAGES_BUCKET=gcs-bucket TARGET_PLATFORM=linux/amd64

# The arm64 leg must land under its own prefix; sharing one bucket makes a
# wrong prefix an overwrite of the other architecture.
run_case "push-s3 publishes the arm64 build under the arm64 prefix" \
    push-s3 "aws s3 cp demo-rootfs.ext4 s3://s3-bucket/arm64/demo-rootfs.ext4" \
    TARGET_PLATFORM=linux/arm64 S3_IMAGES_BUCKET=s3-bucket GCS_IMAGES_BUCKET=gcs-bucket

run_case "push-gcs publishes the arm64 build under the arm64 prefix" \
    push-gcs "gcloud storage cp demo-rootfs.ext4 gs://gcs-bucket/arm64/demo-rootfs.ext4" \
    TARGET_PLATFORM=linux/arm64 S3_IMAGES_BUCKET=s3-bucket GCS_IMAGES_BUCKET=gcs-bucket

# An unrecognised platform must fail rather than invent a prefix: the agent
# would look under amd64/ or arm64/ and find nothing.
run_case "push-s3 fails on an unsupported target platform" \
    push-s3 FAIL TARGET_PLATFORM=linux/riscv64 S3_IMAGES_BUCKET=s3-bucket

run_case "push-s3 fails when the S3 bucket is unset" \
    push-s3 FAIL GCS_IMAGES_BUCKET=gcs-bucket

run_case "push without a backend fails when both buckets are set" \
    push FAIL S3_IMAGES_BUCKET=s3-bucket GCS_IMAGES_BUCKET=gcs-bucket

# The cases above prove push-images.sh honours TARGET_PLATFORM, but they run the
# Makefile directly and never see the workflow. Both architectures now publish to
# one bucket under identical object names, so a missing TARGET_PLATFORM on an
# upload step makes the arm64 leg publish to amd64/ and overwrite the amd64
# images — silently, until a node boots a guest built for the wrong architecture.
# Assert the wiring exists.
WORKFLOW="$REPO_ROOT/.github/workflows/build-images.yaml"
for step in push-s3 push-gcs; do
    if awk -v want="make $step" '
        /^      - name:/ { in_step = 1; seen_platform = 0 }
        /TARGET_PLATFORM:/ { if (in_step) seen_platform = 1 }
        $0 ~ ("run: " want) { if (seen_platform) { found = 1 } }
        END { exit !found }
    ' "$WORKFLOW"; then
        echo "ok: workflow passes TARGET_PLATFORM to the $step step"
    else
        echo "FAIL: the workflow step running 'make $step' does not set TARGET_PLATFORM"
        echo "    without it the arm64 build publishes under the amd64 prefix"
        FAILURES=$((FAILURES + 1))
    fi
done

if [ "$FAILURES" -ne 0 ]; then
    echo "$FAILURES check(s) failed" >&2
    exit 1
fi

echo "All push-images backend checks passed"
