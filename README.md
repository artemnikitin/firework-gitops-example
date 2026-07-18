# firework-gitops-example

> This is an example deployment intended for demonstration and learning purposes only. It is not hardened, audited, etc.

Example GitOps repository for [Firework](https://github.com/artemnikitin/firework), focused on building Firecracker-ready rootfs images and publishing both ARM64 and X86 images to S3 and GCS via architecture-specific buckets.

## Related Repositories

- [firework](https://github.com/artemnikitin/firework) - orchestrator runtime (`firework-agent`, `enricher`, `scheduler`)
- [firework-deployment-example](https://github.com/artemnikitin/firework-deployment-example) - Terraform + Packer deployment on AWS and GCP

## Configuration Docs

Service/config semantics are documented in the main `firework` repository:

- Configuration reference: <https://github.com/artemnikitin/firework/tree/main/docs/configs>
- Architecture details: <https://github.com/artemnikitin/firework/tree/main/docs/architecture>

This repository intentionally keeps only high-level pipeline guidance.

Persistent-volume defaults are present in `defaults.yaml`. The opt-in
`examples/storage-validation.yaml` workload is kept outside `tenants/` so
storage-disabled deployments continue to work; copy it into a tenant only
after the node storage pool is mounted and configured.

## CI Pipeline

CI builds and publishes these images automatically on every push to `main`
(plus pull requests, a weekly schedule, and manual dispatch). See
[`docs/ci-pipeline.md`](docs/ci-pipeline.md) for triggers, incremental-build
behavior, and bucket configuration.
