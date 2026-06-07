# AGENTS.md

## Project

This is the example GitOps input repo for Firework. It defines tenant service YAML and config overlays used to build Firecracker-ready rootfs images and publish them to S3.

## Layout

- `defaults.yaml`: global service defaults consumed by Firework enricher.
- `tenants/<tenant>/<service>.yaml`: tenant service specs.
- `configs/<service>/` and `configs/<tenant>-<service>/`: rootfs overlays; tenant-specific overlays take precedence.
- `scripts/docker-to-rootfs.sh`: converts Docker images into ext4 rootfs images.
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
- A targeted local rootfs build when Docker, `jq`, `mkfs.ext4`, and a linux/arm64 `fc-init` are available.

Do not upload to S3 or run cloud-mutating commands unless explicitly requested.
