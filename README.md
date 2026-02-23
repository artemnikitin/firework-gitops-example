# firework-gitops-example

Example GitOps repository for [Firework](https://github.com/artemnikitin/firework), focused on building Firecracker-ready rootfs images from Docker images and publishing them to S3.

## Related Repositories

- [firework](https://github.com/artemnikitin/firework) - orchestrator runtime (`firework-agent`, `enricher`, `scheduler`)
- [firework-deployment-example](https://github.com/artemnikitin/firework-deployment-example) - Terraform + Packer deployment on AWS

## Configuration Docs (Source of Truth)

Service/config semantics are documented in the main `firework` repository:

- Configuration reference: <https://github.com/artemnikitin/firework/tree/main/docs/configs>
- Architecture details: <https://github.com/artemnikitin/firework/tree/main/docs/architecture>

This repository intentionally keeps only high-level pipeline guidance.

## Repository Layout

```text
defaults.yaml                    # global defaults consumed by enricher
tenants/<tenant-id>/*.yaml       # tenant service definitions/overrides
configs/<service>/...            # optional filesystem overlays copied into rootfs
scripts/docker-to-rootfs.sh      # Docker image -> ext4 conversion script
scripts/fc-init/main.go          # bundled fallback source for fc-init
.github/workflows/build-images.yaml
```

## CI Image Pipeline

The `build-images` workflow does the following on relevant pushes:

1. Resolves `fc-init` (release asset, `go install`, or bundled fallback build).
2. Iterates over `tenants/*/*.yaml`.
3. Reads `source_image` and optional `rootfs_size_mb` from each tenant file.
4. Builds `<tenant>-<service>-rootfs.ext4` via `scripts/docker-to-rootfs.sh`.
5. Applies config overlays with precedence:
   - `configs/<tenant>-<service>/` (tenant-specific)
   - then `configs/<service>/` (shared)
6. Uploads resulting `*-rootfs.ext4` artifacts to S3.

## GitHub Actions Inputs

Workflow expects:

- Secrets:
  - `AWS_ACCESS_KEY_ID`
  - `AWS_SECRET_ACCESS_KEY`
  - `FIREWORK_GITHUB_TOKEN` (optional, for private `firework` source access)
- Variables:
  - `AWS_REGION`
  - `S3_IMAGES_BUCKET`
  - `FC_INIT_VERSION` (optional)

## Local Build Example

Build one rootfs locally:

```bash
./scripts/docker-to-rootfs.sh \
  docker.elastic.co/kibana/kibana:9.3.0 \
  tenant-1-kibana-rootfs.ext4 \
  2048 \
  configs/kibana
```

Then upload manually if needed:

```bash
aws s3 cp tenant-1-kibana-rootfs.ext4 s3://<images-bucket>/
```

## End-to-End Flow

```text
git push -> GitHub Actions builds ext4 images -> uploads to S3 (images bucket)
git push -> enricher (from firework deployment) -> writes nodes/*.yaml to S3 (configs bucket)
firework-agent nodes poll both buckets and reconcile VMs
```
