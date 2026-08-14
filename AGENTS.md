# AGENTS.md

## Project

This is the example GitOps input repo for Firework. It defines tenant service YAML and config overlays used to build Firecracker-ready rootfs images and publish them to S3 and GCS. Both amd64 and ARM64 are built and published, to one bucket per cloud, under an `<arch>/` key prefix; the agent resolves the prefix from the node it runs on. Public routing is provider-neutral via `metadata.subdomain`; there is no provider-specific runtime config tree.

## Layout

- `defaults.yaml`: global service defaults consumed by Firework enricher; changes here affect every service on the next enricher run.
- `docs/ci-pipeline.md`: CI trigger/incremental-build/publishing details for the image pipeline.
- `Makefile`: image pipeline entrypoints used by CI (`build` and `push`).
- `tenants/<tenant>/<service>.yaml`: tenant service specs.
- `configs/<service>/` and `configs/<tenant>-<service>/`: rootfs overlays; tenant-specific overlays take precedence.
- `scripts/build-images.sh`: resolves `fc-init` and builds tenant rootfs images. Skips a tenant service when its inputs (own YAML, shared/tenant overlays) are unchanged since `COMPARE_BASE_SHA`, unless `FORCE_REBUILD=true` or a shared pipeline file changed (see workflow for how these are set in CI).
- `scripts/docker-to-rootfs.sh`: converts Docker images into ext4 rootfs images.
- `scripts/push-images.sh`: uploads generated rootfs images to the object store named by its `s3`/`gcs` backend argument, under an `<arch>/` key prefix derived from `TARGET_PLATFORM`.
- `scripts/test-push-images.sh`: regression checks for that backend selection and the architecture prefix.
- `scripts/fc-init/`: fallback bundled `fc-init` source for CI.

## Conventions

- Firework runtime config semantics live in the main `firework` repo under `docs/configs/README.md`.
- `source_image` and `rootfs_size_mb` are CI-only fields, not Firework runtime fields.
- Keep service names, tenant IDs, overlay directory names, image filenames, and links aligned.
- Avoid committing generated `*-rootfs.ext4` images, local caches, or credentials.

## Validation

For YAML-only changes, inspect schema consistency against the main repo docs.
For image pipeline changes, validate:

- `shellcheck scripts/docker-to-rootfs.sh`
- `bash scripts/test-push-images.sh` when touching `push-images.sh`, the `push-*` Makefile targets, or the workflow's upload steps. Each workflow upload step exports only its own provider's bucket, but a local run can have both set, so the backend must be selected explicitly rather than inferred. `TARGET_PLATFORM` must also reach the push targets, or images publish under the wrong architecture prefix.
- A targeted local rootfs build when Docker, `jq`, `mkfs.ext4`, and a linux/amd64 `fc-init` are available.

For CI-equivalent validation, run `make build`, but skip `make push`.

Do not upload to S3 or run cloud-mutating commands unless explicitly requested.
