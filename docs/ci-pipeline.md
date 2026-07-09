# CI Image Pipeline

The `build-images` workflow runs on every pull request, every push to `main`,
a weekly schedule, and on manual dispatch.
It builds the tenant rootfs images twice, once for `linux/arm64` and once for
`linux/amd64`.

On pushes to `main`, on the weekly schedule, and on manual dispatch (when run
against `main`), each matrix build job publishes its architecture to the
configured S3 bucket and, when configured, authenticates to GCP in the same job
and uploads that architecture to its GCS bucket. Keep the buckets
architecture-specific: the generated `*-rootfs.ext4` filenames are the same
across architectures, so sharing one bucket would cause overwrites.

## Change-aware builds

To avoid rebuilding every tenant image on every run, `scripts/build-images.sh`
skips a tenant service when its YAML file and overlay directories
(`configs/<service>/`, `configs/<tenant>-<service>/`) haven't changed since a
comparison commit (the PR's base commit, or the previous commit on `push`). A
change to any shared pipeline input (`scripts/docker-to-rootfs.sh`,
`scripts/build-images.sh`, `scripts/fc-init/`, `Makefile`, or the workflow
file itself) forces a full rebuild of every service, since those affect every
image.

This can't detect two kinds of change: a mutable `source_image` tag being
re-pushed upstream, and a bump to the `FC_INIT_VERSION` repo variable (no
associated file diff). Both are covered by the weekly scheduled run, which
always does a full rebuild and upload. You can also trigger a full
rebuild+upload immediately via `workflow_dispatch` (`force_rebuild` input,
defaults to `true`) — do this once after merging a change to this
change-detection logic, and any time the buckets need to be forced back in
sync with git history.

Local `make build` runs are unaffected: without `FORCE_REBUILD`/
`COMPARE_BASE_SHA` set, the script always builds every service, same as
before this feature existed.

## Bucket configuration

Legacy variables keep their original meanings: `S3_IMAGES_BUCKET` is the arm64
S3 bucket and `GCS_IMAGES_BUCKET` is the amd64 GCS bucket. Configure
`S3_IMAGES_BUCKET_AMD64` and `GCS_IMAGES_BUCKET_ARM64` to enable the extra
cross-backend uploads.

## CI config validation

Before building images, the `validate-config` CI job runs Firework's
`cmd/configcheck --require-remote-routing` against this repository's root, using
the exact enricher of a pinned core version.
