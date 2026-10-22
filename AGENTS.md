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
- `scripts/fc-init/`: bundled `fc-init` source compiled by CI and by local builds unless `FC_INIT_BIN` or `FC_INIT_VERSION` selects another binary.

## Conventions

- Firework runtime config semantics live in the main `firework` repo under `docs/configs/README.md`.
- `source_image` and `rootfs_size_mb` are CI-only fields, not Firework runtime fields.
- Keep service names, tenant IDs, overlay directory names, image filenames, and links aligned.
- Avoid committing generated `*-rootfs.ext4` images, local caches, or credentials.

## Shared contracts

- When changing runtime configuration, check the deployed Firework contract and
  the workflow's pinned validator revision. Update the pin deliberately when the
  runtime contract changes; do not substitute a floating main branch or assume the
  pin discovers the deployed version. See `docs/ci-pipeline.md`.
- When changing guest init or image publication, check the bundled `fc-init`,
  core guest-mount contract, deployment node architecture, and object names/prefixes
  together. Report required companion changes and rollout ordering; unrelated
  changes do not require a cross-repository audit.

## Validation

Run applicable checks from the repository root unless stated otherwise:

- Docs-only changes: check formatting and links; verify changed commands, paths,
  defaults, and behavioral claims against source. No image build is required.
- Runtime YAML changes: run `go run ./cmd/configcheck --require-remote-routing --input-dir /absolute/path/to/firework-gitops-example` from a Firework checkout
  at the exact revision pinned in `.github/workflows/build-images.yaml`. Manual
  schema inspection alone does not reproduce CI validation. This validator checks
  runtime semantics; image-source and overlay changes also need image checks.
- Rootfs conversion changes: run `shellcheck scripts/docker-to-rootfs.sh`.
- `bash scripts/test-push-images.sh` when touching `push-images.sh`, the `push-*` Makefile targets, or the workflow's upload steps. Each workflow upload step exports only its own provider's bucket, but a local run can have both set, so the backend must be selected explicitly rather than inferred. `TARGET_PLATFORM` must also reach the push targets, or images publish under the wrong architecture prefix.
- Build affected rootfs images with an explicit `TARGET_PLATFORM`. Shared builder,
  guest-init, or architecture-selection changes need both `linux/amd64` and
  `linux/arm64` coverage. Use Docker with buildx, `jq`, `mkfs.ext4`, Go for bundled
  `fc-init`, and `yq` as installed by CI for YAML parsing; any supplied
  `FC_INIT_BIN` must match the target platform. Force rebuilding when necessary so
  change detection does not skip the intended images.

CI validation comprises the pinned config check, upload-backend regression check,
and both architecture builds in `.github/workflows/build-images.yaml`. A default
`make build` only builds amd64 and is partial validation. Report unavailable checks
and remaining runtime verification. Cloud validation is a separate, explicitly
authorized step and can be batched across changes. Local validation excludes
`make push`, `make push-s3`, and `make push-gcs`.

Do not upload to S3 or run cloud-mutating commands unless explicitly requested.
