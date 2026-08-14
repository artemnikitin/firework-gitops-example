# CI Image Pipeline

The `build-images` workflow runs on every pull request, every push to `main`,
a weekly schedule, and on manual dispatch.
It builds the tenant rootfs images twice, once for `linux/arm64` and once for
`linux/amd64`.

On pushes to `main`, on the weekly schedule, and on manual dispatch (when run
against `main`), each matrix build job publishes its architecture to the
configured S3 bucket and, when configured, authenticates to GCP in the same job
and uploads that architecture to its GCS bucket. Both architectures share one
bucket per cloud: the generated `*-rootfs.ext4` filenames are identical across
architectures, so each is stored under an `<arch>/` key prefix.

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

One bucket per cloud holds every architecture: `S3_IMAGES_BUCKET` and
`GCS_IMAGES_BUCKET`. There are no per-architecture bucket variables. Both matrix
legs upload to the same bucket, under a key prefix taken from the platform they
were built for:

```text
<images-bucket>/
  amd64/tenant-1-kibana-rootfs.ext4
  arm64/tenant-1-kibana-rootfs.ext4
```

The prefix uses the Go architecture vocabulary (`amd64`, `arm64`) that
`TARGET_PLATFORM` already carries — deliberately not the AWS `x86_64` spelling,
which the agent would never look under. `push-images.sh` rejects an
unrecognised `TARGET_PLATFORM` rather than publishing without a prefix.

The Firework agent resolves the prefix from the architecture of the node it runs
on, so a node can only ever fetch images built for itself. Host and guest
architecture must match; before this layout a mismatch surfaced only at microVM
start, as a guest kernel panic.

A missing image fails at sync with an error naming the key — but only on a node
that has no local copy. The agent falls back to a cached image whenever an
object is absent, logging at debug level, so a node that already holds the image
stays quiet. Verify bucket contents directly rather than waiting for nodes to
report a gap.

This also means a mixed-architecture fleet needs no extra configuration: node
configs carry no architecture, so one desired state serves both.

`push-images.sh` takes an explicit `s3` or `gcs` backend argument rather than
inferring one from whichever bucket is set, and `make push-s3` / `make push-gcs`
pass it along with `TARGET_PLATFORM`. Each workflow upload step now exports only
its own provider's bucket, so inference would happen to work — but a local run
or a future step that exports both must not be able to publish to the wrong
object store. Inference is therefore still accepted only when exactly one bucket
variable is set, and errors when both are.
`scripts/test-push-images.sh` covers this and runs in CI.

### Objects from the previous layout

Before this layout, objects sat at the bucket root and both the agent and node
bootstrap read them there. Nothing reads the bucket root now, so any root-level
`*-rootfs.ext4` left over from that layout is inert and can be deleted whenever
convenient:

```bash
aws s3api list-objects-v2 --bucket "$BUCKET" --delimiter / \
  --query 'Contents[].Key' --output text | tr '\t' '\n'
```

`list-objects-v2` with `--delimiter /` returns only root-level keys, without the
`PRE <prefix>/` rows that a plain `aws s3 ls` emits — those rows have no object
name in the column a naive parse would read, which silently produces empty
entries.

Fresh nodes have no local image cache, so they depend on the prefixes being
populated before they boot. Run a `force_rebuild` dispatch after any change to
this pipeline and confirm both prefixes are present before deploying.

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
