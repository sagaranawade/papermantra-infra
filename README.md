# papermantra-infra

Production orchestration for the PaperMantra platform: Docker Compose stack, Nginx reverse proxy, TLS, backups, monitoring, and VPS deployment automation.

> **Manual setup (VPS, GitHub secrets, Cloudflare, SSL):** see **[DEPLOYMENT.md](./DEPLOYMENT.md)** for the full checklist.  
> **VPS steps 3–11 (you are here):** see **[VPS-SETUP.md](./VPS-SETUP.md)**.

## Architecture

```
Internet
   │
   ▼
┌──────────────────────────────────────────────────────────────┐
│  Nginx (80/443) — TLS termination + reverse proxy            │
├──────────────────────────────────────────────────────────────┤
│  papermantra.com / www     →  portal:8080   (React CRA)      │
│  neelmind.com / www        →  website:3000  (Next.js)        │
│  api.papermantra.com       →  api:9091      (/papermantra)   │
│  pdf.papermantra.com       →  pdf:9092      (/pdfgenerator)  │
└──────────────────────────────────────────────────────────────┘
         │
         ▼
┌─────────────────┐     ┌─────────────────┐
│  MongoDB 7      │     │  Redis 7        │
│  (persistent)   │     │  (persistent)   │
└─────────────────┘     └─────────────────┘
```

Application images are built and pushed by each app repo's CI pipeline (GHCR). This repo only **pulls** pre-built images and wires them together.

| Service | Image (default) | App repo |
|---------|-----------------|----------|
| Portal | `ghcr.io/sagaranawade/papermantra-web:latest` | papermantra |
| Website | `ghcr.io/sagaranawade/robofume:latest` | robofume |
| API | `ghcr.io/sagaranawade/papermantraservices:latest` | papermantraservices |
| PDF | `ghcr.io/sagaranawade/pdf-generator:latest` | pdfgenerator |

## Repository layout

```
papermantra-infra/
├── docker-compose.yml              # Core production stack
├── docker-compose.monitoring.yml   # Optional Prometheus + Grafana overlay
├── .env                            # Production config (committed on main)
├── nginx/
│   ├── nginx.conf
│   └── conf.d/                     # Per-domain reverse proxy configs
├── certbot/
│   ├── init-letsencrypt.sh         # First-time SSL bootstrap
│   └── renew.sh                    # Manual renewal
├── scripts/
│   ├── deploy.sh                   # Pull images + restart + health checks
│   ├── rollback.sh                 # Revert to previous IMAGE_* tags
│   └── backup-volumes.sh           # MongoDB + Redis + media backup
├── monitoring/                     # Optional observability configs
└── .github/workflows/deploy.yml    # SSH deploy to VPS on push to main
```

## VPS prerequisites

1. **Ubuntu 22.04+** (or any Linux with Docker Engine 24+ and Docker Compose v2)
2. **DNS** (Cloudflare or other) — A records pointing to the VPS:
   - `papermantra.com`, `www.papermantra.com`
   - `neelmind.com`, `www.neelmind.com`
   - `api.papermantra.com`
   - `pdf.papermantra.com`
3. **Firewall** — allow inbound `80`, `443`; restrict `9090`/`3001` (monitoring) to localhost or VPN
4. **GHCR access** on the VPS (`docker login ghcr.io`) so private images can be pulled

## First-time setup

### 1. Install Docker on the VPS

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker "$USER"
newgrp docker
```

### 2. Clone this repo

```bash
sudo mkdir -p /opt
sudo git clone https://github.com/sagaranawade/papermantra-infra.git /opt/papermantra-infra
sudo chown -R "$USER:$USER" /opt/papermantra-infra
cd /opt/papermantra-infra
```

### 3. Configure environment

```bash
cp .env is not needed — `.env` is on `main`. After clone:

```bash
cd /opt/papermantra-infra
./scripts/vps-bootstrap.sh
```
```

Generate strong secrets:

```bash
openssl rand -base64 48   # JWT_SECRET, REDIS_PASSWORD, MONGO_ROOT_PASSWORD
```

### 4. Log in to GHCR

```bash
echo "<GITHUB_PAT_with_read:packages>" | docker login ghcr.io -u YOUR_GITHUB_USER --password-stdin
```

### 5. Bootstrap SSL certificates

Ensure DNS has propagated, then:

```bash
chmod +x certbot/*.sh scripts/*.sh
./certbot/init-letsencrypt.sh
docker compose --profile certbot up -d certbot   # auto-renewal sidecar
```

Use staging first if testing: `STAGING=1 ./certbot/init-letsencrypt.sh`

### 6. Start the full stack

```bash
./scripts/deploy.sh
```

Verify:

```bash
docker compose ps
curl -fsS https://papermantra.com/healthz
curl -fsS https://api.papermantra.com/papermantra/actuator/health
```

## Day-to-day operations

### Deploy latest images

After app repos push new `:latest` (or tagged) images to GHCR:

```bash
cd /opt/papermantra-infra
./scripts/deploy.sh
```

Or push infra changes to `main` — GitHub Actions runs the same script over SSH.

### Pin a specific version

Edit `.env`:

```env
IMAGE_SERVICES=ghcr.io/sagaranawade/papermantraservices:v1.4.0
IMAGE_PDF=ghcr.io/sagaranawade/pdf-generator:v1.4.0
```

Then `./scripts/deploy.sh`.

### Rollback

If a deployment fails health checks (with `--rollback-on-failure`) or you need to revert manually:

```bash
./scripts/rollback.sh
```

The script restores the previous `IMAGE_*` tags recorded in `.deploy-history`.

### Backups

```bash
./scripts/backup-volumes.sh
# or specify destination:
./scripts/backup-volumes.sh /opt/backups/papermantra
```

Schedule daily via cron:

```cron
0 2 * * * /opt/papermantra-infra/scripts/backup-volumes.sh >> /var/log/papermantra-backup.log 2>&1
```

Backups include:

- MongoDB (`mongodump` archive)
- Redis RDB snapshot
- API uploaded media volumes (user pics, question images)

Retention defaults to 14 days (`BACKUP_RETENTION_DAYS` in `.env`).

### Restore MongoDB from backup

```bash
gunzip -c backups/20260101T020000Z/mongodb.archive.gz | \
  docker compose exec -T mongodb mongorestore \
    --username="$MONGO_ROOT_USER" --password="$MONGO_ROOT_PASSWORD" \
    --authenticationDatabase=admin --archive --gzip --drop
```

## Monitoring (optional)

```bash
docker compose -f docker-compose.yml -f docker-compose.monitoring.yml --profile monitoring up -d
```

- Prometheus: `http://127.0.0.1:9090` (localhost only)
- Grafana: `http://127.0.0.1:3001` (default creds from `.env`)

Expose Grafana through an SSH tunnel or VPN — do not publish it publicly without auth hardening.

> **Note:** Spring Boot apps must expose the Prometheus actuator endpoint for scrape targets to work. Add `prometheus` to `management.endpoints.web.exposure.include` in each app's prod profile if needed.

## GitHub Actions (infra repo)

Workflow: `.github/workflows/deploy.yml`

**Secrets required** (Settings → Secrets → Actions):

| Secret | Purpose |
|--------|---------|
| `PROD_SSH_HOST` | VPS IP or hostname |
| `PROD_SSH_USER` | SSH user (must have Docker access) |
| `PROD_SSH_KEY` | Private SSH key (PEM) |
| `GHCR_TOKEN` | PAT with `read:packages` for VPS docker pull |

**Optional variable:** `INFRA_DEPLOY_PATH` (default `/opt/papermantra-infra`)

App repos can trigger an infra redeploy after pushing images:

```yaml
# In an app repo workflow (after docker push):
- uses: peter-evans/repository-dispatch@v3
  with:
    token: ${{ secrets.INFRA_DISPATCH_TOKEN }}
    repository: sagaranawade/papermantra-infra
    event-type: deploy-infra
    client-payload: '{"tag":"v1.2.3"}'
```

## App repo responsibilities

Each application repo owns **code + Dockerfile.prod + CI/CD**. This repo owns **orchestration only**. Prod releases trigger infra deploy via `INFRA_DISPATCH_TOKEN`.

## Cloudflare DNS

**Full migration guide:** **[CLOUDFLARE-MIGRATION.md](./CLOUDFLARE-MIGRATION.md)**

BIND zone templates for import: `cloudflare/papermantra.com.zone`, `cloudflare/neelmind.com.zone`

After migration:

```bash
./scripts/verify-cloudflare-ns.sh
./scripts/verify-dns.sh
```

Before running Certbot (if certs not yet issued):

1. Create A records for all domains → VPS public IP (DNS only / grey cloud)
2. Set SSL/TLS mode to **Full (strict)** after certificates are issued
3. Optional: enable proxy (orange cloud) for DDoS protection after DNS is stable

## Troubleshooting

| Symptom | Check |
|---------|-------|
| Nginx 502 | `docker compose logs api pdf portal website` |
| SSL errors | `./certbot/renew.sh`; verify `certbot/conf/live/` paths match nginx configs |
| API won't start | Mongo/Redis credentials in `.env`; `docker compose logs mongodb redis api` |
| Image pull 401 | Re-run `docker login ghcr.io` on VPS |
| Health check timeout | Spring Boot cold start can take 60–90s on first boot |

View all logs:

```bash
docker compose logs -f --tail=100
```

## Security notes

- Never commit `.env.local` — optional overrides only. Production `.env` is committed on `main` for this single-VPS setup.
- MongoDB and Redis are **not** published to the host; only Nginx exposes ports 80/443
- Rotate `JWT_SECRET`, `MONGO_ROOT_PASSWORD`, and `REDIS_PASSWORD` on a schedule
- Keep base images updated: `docker compose pull && docker compose up -d`
