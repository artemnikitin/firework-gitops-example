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

This cannot detect a mutable `source_image` tag being re-pushed upstream. The
weekly scheduled run therefore always does a full rebuild and upload. You can
also trigger a full
rebuild+upload immediately via `workflow_dispatch` (`force_rebuild` input,
defaults to `true`) — do this once after merging a change to this
change-detection logic, and any time the buckets need to be forced back in
sync with git history.

Local `make build` runs are unaffected: without `FORCE_REBUILD`/
`COMPARE_BASE_SHA` set, the script always builds every service, same as
before this feature existed.

## Bucket configuration

Both legacy variables mean the amd64 bucket, because both providers default to
x86_64 nodes: `S3_IMAGES_BUCKET` is the amd64 S3 bucket and `GCS_IMAGES_BUCKET`
is the amd64 GCS bucket. The explicit `*_AMD64` names are still supported and
take precedence when set. Publishing the arm64 build requires opting in with
`S3_IMAGES_BUCKET_ARM64` or `GCS_IMAGES_BUCKET_ARM64`; without them the arm64
build still runs but uploads nothing.

Resolved upload targets per build:

| Build | S3 bucket | GCS bucket |
| --- | --- | --- |
| amd64 | `S3_IMAGES_BUCKET_AMD64`, else `S3_IMAGES_BUCKET` | `GCS_IMAGES_BUCKET_AMD64`, else `GCS_IMAGES_BUCKET` |
| arm64 | `S3_IMAGES_BUCKET_ARM64` | `GCS_IMAGES_BUCKET_ARM64` |

Both variables are exported for the amd64 build, so `push-images.sh` takes an
explicit `s3` or `gcs` backend argument rather than inferring one from whichever
bucket is set. `make push-s3` and `make push-gcs` pass it. Inference is still
accepted when exactly one bucket variable is set, and errors when both are, so
a publish can never silently go to the wrong object store.
`scripts/test-push-images.sh` covers this and runs in CI.

Host and guest architecture must match, and a mismatch fails at microVM start
rather than at deploy time. The AWS data plane in
`firework-deployment-example` now defaults to x86_64 nodes using nested
virtualization rather than bare-metal Graviton, so it consumes the amd64 rootfs
images; the GCP data plane has always been x86_64.

`S3_IMAGES_BUCKET` previously meant the arm64 S3 bucket, so an existing
deployment that keeps its value will now receive amd64 images in that same
bucket, replacing the arm64 objects under identical names. That is intended for
the default x86_64 AWS node. A deployment that still runs Graviton nodes
(`node_ami_architecture = "arm64"`) must set `S3_IMAGES_BUCKET_ARM64` and point
`s3_images_bucket_id` at that bucket instead.

## CI config validation

Before building images, the `validate-config` CI job runs Firework's
`cmd/configcheck --require-remote-routing` against this repository's root, using
the exact enricher of the persistent-volume core revision pinned directly in
the workflow. This keeps validation aligned with the control plane and agents
used by this example without requiring a repository variable.

CI image builds compile the bundled `scripts/fc-init/main.go`. This keeps the
guest mount contract in the same GitOps change as the volume workload. Local
builds may still set `FC_INIT_VERSION` explicitly to select a released
Firework `fc-init` artifact.
