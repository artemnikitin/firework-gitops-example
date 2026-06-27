# firework-gitops-example

> This is an example deployment intended for demonstration and learning purposes only. It is not hardened, audited, etc.

Example GitOps repository for [Firework](https://github.com/artemnikitin/firework), focused on building Firecracker-ready rootfs images and publishing ARM64 images to S3 and amd64 images to GCS.

## Related Repositories

- [firework](https://github.com/artemnikitin/firework) - orchestrator runtime (`firework-agent`, `enricher`, `scheduler`)
- [firework-deployment-example](https://github.com/artemnikitin/firework-deployment-example) - Terraform + Packer deployment on AWS and GCP

## Configuration Docs

Service/config semantics are documented in the main `firework` repository:

- Configuration reference: <https://github.com/artemnikitin/firework/tree/main/docs/configs>
- Architecture details: <https://github.com/artemnikitin/firework/tree/main/docs/architecture>

This repository intentionally keeps only high-level pipeline guidance.

## CI Image Pipeline

The `build-images` workflow runs on every pull request and every push to `main`.
It builds the tenant rootfs images twice, once for `linux/arm64` and once for
`linux/amd64`.

### CI config validation

Before building images, the `validate-config` CI job runs Firework's
`cmd/configcheck --require-remote-routing` against this repository's root, using
the exact enricher of a pinned core version. 

Local platform-specific builds:

```bash
make build-arm64
make build-amd64
TARGET_PLATFORM=linux/amd64 make build
```

Local builds require Docker with buildx, `jq`, and `mkfs.ext4`.
