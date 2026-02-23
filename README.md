# firework-gitops-example

Example GitOps configuration repository for [Firework](https://github.com/artemnikitin/firework). Demonstrates how to go from Docker images to Firecracker-bootable ext4 rootfs images in CI, and how to structure service definitions for the enricher.

## Related repositories

- [firework](https://github.com/artemnikitin/firework) — The orchestrator itself (agent + enricher)
- [firework-deployment-example](https://github.com/artemnikitin/firework-deployment-example) — Terraform + Packer setup for deploying on AWS

## Structure

```
defaults.yaml          # Global defaults (kernel, resources, health checks)
services/
  kibana.yaml          # Kibana — analytics and visualization UI (v9.3.0)
  elasticsearch.yaml   # Elasticsearch — search and analytics engine (v9.3.0)
configs/
  elasticsearch/       # Config overlay for Elasticsearch (mirrors guest fs layout)
    usr/share/elasticsearch/config/elasticsearch.yml
  kibana/              # Config overlay for Kibana
    usr/share/kibana/config/kibana.yml
scripts/
  docker-to-rootfs.sh  # Docker image → ext4 rootfs converter (with overlay support)
.github/workflows/
  build-images.yaml    # CI pipeline: build rootfs + upload to S3 (ARM)
```

## How the image pipeline works

1. You push a change to `services/`, `configs/`, or `scripts/` on `main`.
2. The CI workflow (runs on ARM) reads each `services/*.yaml` file and extracts the `source_image` field.
3. For each service, `scripts/docker-to-rootfs.sh` converts the Docker image to an ext4 rootfs:
   - `docker create` + `docker export` to extract the filesystem
   - `docker inspect` to read ENTRYPOINT/CMD, ENV, USER, and WORKDIR
   - If a `configs/<service>/` directory exists, its contents are overlaid into the rootfs (mirroring the guest filesystem layout)
   - Resolves `fc-init` in CI:
     - if `FC_INIT_VERSION` is set -> downloads `fc-init-linux-arm64` from `https://github.com/artemnikitin/firework/releases`
     - if `FC_INIT_VERSION` is empty -> tries `github.com/artemnikitin/firework/cmd/fc-init@main` (uses `FIREWORK_GITHUB_TOKEN` when needed for private access)
     - if `@main` build fails (for example, missing private repo access) -> falls back to bundled `scripts/fc-init/main.go`
   - Installs the compiled `/sbin/fc-init` binary into the guest image
   - Writes `/etc/firework/runtime.json` with image env/workdir/user metadata and writable path hints
   - Generates `/sbin/init` wrapper from Docker ENTRYPOINT/CMD + ENV metadata for compatibility
   - `mkfs.ext4 -d` to build the ext4 image (no sudo or mount needed)
4. The ext4 images are uploaded to S3.

## Config overlays

Application-specific configuration files live in `configs/<service-name>/`. The directory structure mirrors the guest filesystem. For example:

```
configs/elasticsearch/usr/share/elasticsearch/config/elasticsearch.yml
```

This file overwrites `/usr/share/elasticsearch/config/elasticsearch.yml` inside the rootfs at build time. This is how we configure:

- **Elasticsearch**: single-node discovery, listen on all interfaces, security disabled for MVP
- **Kibana**: listen on all interfaces, connect to Elasticsearch via the `${ELASTICSEARCH_HOSTS}` environment variable (injected at runtime by the agent via service links)

Config overlays handle static, per-application settings that don't change between deployments. For dynamic, per-deployment settings (like service endpoints), use service links or environment variables instead.

## Service links

Services can declare dependencies on other services. The firework agent resolves these at runtime — no hardcoded IPs are needed in config files.

For example, Kibana declares a link to Elasticsearch:

```yaml
# services/kibana.yaml (excerpt)
links:
  - service: "elasticsearch"
    env: "ELASTICSEARCH_HOSTS"
    port: 9200
```

At boot time, the agent:
1. Assigns deterministic guest IPs to all services (alphabetically by name, starting at `.2`)
2. Resolves each link to a concrete URL (e.g. `http://172.16.0.2:9200`)
3. Injects it as a kernel boot argument (`firework.env.ELASTICSEARCH_HOSTS=http://172.16.0.2:9200`)
4. The guest's `fc-init` exports it as an environment variable

Kibana's config overlay uses this variable:

```yaml
# configs/kibana/usr/share/kibana/config/kibana.yml
elasticsearch.hosts: ["${ELASTICSEARCH_HOSTS}"]
```

This way, if IPs change (e.g. services are reordered), no config files need updating.

## Runtime environment variables

In addition to build-time config overlays, the firework-agent can inject environment variables at runtime via kernel boot arguments. Service definitions can include an `env` map:

```yaml
env:
  SERVER_HOST: "0.0.0.0"
```

The agent appends these as `firework.env.KEY=VALUE` entries to the kernel command line. The guest's `/sbin/fc-init` parses `/proc/cmdline` and exports them before launching the application. This is useful for settings that vary per deployment without rebuilding images.

Environment variables from service links are automatically merged into the env map.

## Service definitions

Each file in `services/` defines a Firecracker microVM service:

```yaml
name: "my-service"
source_image: "myorg/myapp:latest"              # Docker image to convert (used by CI)
image: "/var/lib/images/my-service-rootfs.ext4"  # Path on the host (used by agent)
rootfs_size_mb: 1024                             # Rootfs image size (used by CI, default: 512)
node_type: "web"                                 # Which node group to run on
vcpus: 2
memory_mb: 512
network: true
links:                                           # Inter-service dependencies
  - service: "other-service"
    env: "OTHER_SERVICE_URL"
    port: 8080
port_forwards:                                   # Expose ports to the host
  - host_port: 80
    vm_port: 8080
health_check:
  type: "http"
  port: 8080
  path: "/healthz"
metadata:
  version: "1.0.0"
```

| Field | Required | Description |
|---|---|---|
| `name` | yes | Unique service name |
| `source_image` | no | Docker image for CI rootfs build |
| `image` | yes | Path to the rootfs image on the host |
| `rootfs_size_mb` | no | Rootfs image size in MB (default: 512, used by CI) |
| `node_type` | yes | Determines which node group runs this service |
| `vcpus` | no | Virtual CPUs (falls back to `defaults.yaml`) |
| `memory_mb` | no | Memory in MB (falls back to `defaults.yaml`) |
| `network` | no | Whether the service needs networking |
| `links` | no | Dependencies on other services (resolved by agent at runtime) |
| `port_forwards` | no | Host-to-VM port mappings for external access |
| `env` | no | Runtime environment variables |
| `health_check` | no | Health check configuration |
| `metadata` | no | Arbitrary key-value pairs |

Only `name`, `image`, and `node_type` are required. Everything else falls back to `defaults.yaml`.

## How it connects to Firework

```
                    ┌──────────────┐
   git push ──────► │  CI Workflow  │──── ext4 images ────► S3
                    └──────────────┘
                                                            │
   git push ──────► Enricher Lambda ── node configs ──► S3  │
                                                        │   │
                    ┌──────────────┐                     ▼   ▼
                    │ Firework     │◄─── polls S3 for configs + images
                    │ Agent        │
                    └──────────────┘
```

1. **CI pipeline** builds ext4 rootfs images from Docker images (with config overlays) and uploads them to S3.
2. **Enricher Lambda** (triggered by webhook on push) reads service definitions, applies defaults, and writes enriched per-node configs to S3.
3. **Firework agents** on each node poll S3 for both configs and images, resolve service links, and converge to the desired state.

## Local testing

Test the conversion script locally:

```bash
# Build fc-init once (from sibling firework repo)
(cd ../firework && make build-fc-init)

# Without config overlay:
./scripts/docker-to-rootfs.sh docker.elastic.co/kibana/kibana:9.3.0 /tmp/kibana.ext4 2048 "" ../firework/bin/fc-init

# With config overlay:
./scripts/docker-to-rootfs.sh docker.elastic.co/kibana/kibana:9.3.0 /tmp/kibana.ext4 2048 configs/kibana ../firework/bin/fc-init

file /tmp/kibana.ext4  # should show "Linux rev 1.0 ext4 filesystem data"
```
