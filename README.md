# firework-gitops-example

> This is an example deployment intended for demonstration and learning purposes only. It is not hardened, audited, etc.

Example GitOps repository for [Firework](https://github.com/artemnikitin/firework), focused on building Firecracker-ready rootfs images and publishing both ARM64 and amd64 images to S3 and GCS via architecture-specific buckets.

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

On pushes to `main`, each matrix build job publishes its architecture to the
configured S3 bucket and, when configured, authenticates to GCP in the same job
and uploads that architecture to its GCS bucket. Keep the buckets
architecture-specific: the generated `*-rootfs.ext4` filenames are the same
across architectures, so sharing one bucket would cause overwrites.

Legacy variables keep their original meanings: `S3_IMAGES_BUCKET` is the arm64
S3 bucket and `GCS_IMAGES_BUCKET` is the amd64 GCS bucket. Configure
`S3_IMAGES_BUCKET_AMD64` and `GCS_IMAGES_BUCKET_ARM64` to enable the extra
cross-backend uploads.

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
