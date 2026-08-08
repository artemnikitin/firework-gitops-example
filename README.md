# firework-gitops-example

> This is an example deployment intended for demonstration and learning purposes only. It is not hardened, audited, etc.

Example GitOps repository for [Firework](https://github.com/artemnikitin/firework), focused on building Firecracker-ready rootfs images and publishing them to S3 and GCS via architecture-specific buckets. Both X86 and ARM64 images are built; X86 is published by default, because both the AWS and GCP data planes run x86_64 nodes, and ARM64 publishing is opt-in.

## Related Repositories

- [firework](https://github.com/artemnikitin/firework) - orchestrator runtime (`firework-agent`, `enricher`, `scheduler`)
- [firework-deployment-example](https://github.com/artemnikitin/firework-deployment-example) - Terraform + Packer deployment on AWS and GCP

## Configuration Docs

Service/config semantics are documented in the main `firework` repository:

- Configuration reference: <https://github.com/artemnikitin/firework/tree/main/docs/configs>
- Architecture details: <https://github.com/artemnikitin/firework/tree/main/docs/architecture>

This repository intentionally keeps only high-level pipeline guidance.

Persistent-volume defaults are present in `defaults.yaml`.
`tenants/tenant-1/elasticsearch.yaml` mounts its data directory from a local
persistent volume. Tenant-1 Kibana and all tenant-2 and tenant-3 services
remain stateless. Enable and verify the local storage pool on every AWS and
GCP node before merging this configuration.

## CI Pipeline

CI builds and publishes these images automatically on every push to `main`
(plus pull requests, a weekly schedule, and manual dispatch). See
[`docs/ci-pipeline.md`](docs/ci-pipeline.md) for triggers, incremental-build
behavior, and bucket configuration.
