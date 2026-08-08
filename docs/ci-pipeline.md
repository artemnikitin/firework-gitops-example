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

A missing image now fails at sync with an error naming the key — but only on a
node that has no local copy. The agent falls back to a cached image whenever an
object is absent, logging at debug level, so a node that already holds images
from the previous layout stays quiet. Verify bucket contents directly rather
than waiting for nodes to report a gap.

This also means a mixed-architecture fleet needs no extra configuration: node
configs carry no architecture, so one desired state serves both.

Both bucket variables are exported for every build, so `push-images.sh` takes an
explicit `s3` or `gcs` backend argument rather than inferring one from whichever
bucket is set. `make push-s3` and `make push-gcs` pass it, along with
`TARGET_PLATFORM`. Inference is still accepted when exactly one bucket variable
is set, and errors when both are, so a publish can never silently go to the
wrong object store. `scripts/test-push-images.sh` covers this and runs in CI.

### Migrating from per-architecture buckets

Objects previously sat at the bucket root, and the agent read them there. The
agent change that reads `<arch>/` keys must not ship first: a freshly built node
would find nothing under its prefix and fail. An existing node keeps running on
its cached images, so the damage is uneven and easy to miss — which is why the
verification below is a diff rather than a glance.

1. Merge this repository's change and run `workflow_dispatch` with
   `force_rebuild = true`. Change-aware builds only publish services that
   changed, so without a forced run the new prefixes stay incomplete.
2. Diff the object sets, do not eyeball them. Every flat object must have a
   counterpart under each architecture prefix that has nodes:

   ```bash
   aws s3 ls "s3://$BUCKET/" | awk '{print $4}' | grep -v '/$' | sort > /tmp/flat
   aws s3 ls "s3://$BUCKET/amd64/" | awk '{print $4}' | sort > /tmp/amd64
   comm -23 /tmp/flat /tmp/amd64   # must be empty before step 4
   ```

   A forced rebuild that skipped a service — a build failure, or a service no
   longer in the tenant set — leaves a gap here. Agents will not report it:
   they serve the cached local copy.
3. Roll out agents that resolve arch-prefixed keys.
4. Delete the flat objects at the bucket root, only once step 2 shows no
   difference. Deleting while a gap remains leaves nodes running an image that
   exists nowhere in the bucket, which surfaces at the next node replacement,
   long after the migration.

Un-upgraded agents keep reading the frozen flat objects until they are replaced,
so the intermediate state is safe. Expect one full re-download per node at
cutover: the write-token sidecars survive, but a republished object under a new
key carries a new token. A deployment that publishes kernels to the bucket
rather than baking them into the node image must republish those under `<arch>/`
too.

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
