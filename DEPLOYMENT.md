# PaperMantra Production Deployment — Manual Steps

Everything the AI **cannot** do from your machine is listed here in order. Code/config in all repos is ready; you finish setup on GitHub, the VPS, and Cloudflare.

---

## What is already done (in code)

| Item | Location |
|------|----------|
| Production Docker Compose stack | `papermantra-infra/docker-compose.yml` |
| Nginx reverse proxy (4 domains) | `papermantra-infra/nginx/conf.d/` |
| SSL bootstrap scripts | `papermantra-infra/certbot/` |
| Deploy / rollback / backup scripts | `papermantra-infra/scripts/` |
| Infra GitHub Actions deploy | `papermantra-infra/.github/workflows/deploy.yml` |
| robofume CI/CD | `robofume/.github/workflows/ci-cd.yml` |
| App → infra deploy trigger | All 4 app repos (on prod tag push) |

---

## Phase 1 — GitHub: container registry

All images use **GHCR** (`ghcr.io/sagaranawade/...`).

### 1.1 Make packages visible (or keep private)

For each repo (`papermantra`, `robofume`, `papermantraservices`, `pdfgenerator`):

1. GitHub → repo → **Packages** (after first CI push)
2. Open each package → **Package settings**
3. Set visibility or link package to repo

### 1.2 Image names (must match VPS `.env`)

| Service | Image |
|---------|-------|
| Portal | `ghcr.io/sagaranawade/papermantra-web:latest` |
| Website | `ghcr.io/sagaranawade/robofume:latest` |
| API | `ghcr.io/sagaranawade/papermantraservices:latest` |
| PDF | `ghcr.io/sagaranawade/pdf-generator:latest` |

**papermantra** `deploy-prod.yml` uses `REGISTRY_HOST` / `REGISTRY_NAMESPACE` secrets. Set them to:

- `REGISTRY_HOST` = `ghcr.io`
- `REGISTRY_NAMESPACE` = `sagaranawade`

So pushed images match the infra `.env` paths above.

---

## Phase 2 — GitHub: secrets & variables

### 2.1 `papermantra-infra` repo secrets

Settings → Secrets and variables → Actions → **Secrets**:

| Secret | Value |
|--------|-------|
| `PROD_SSH_HOST` | VPS public IP or hostname |
| `PROD_SSH_USER` | SSH user (e.g. `ubuntu`, `deploy`) |
| `PROD_SSH_KEY` | Full private key (PEM), including `-----BEGIN...` |
| `GHCR_TOKEN` | GitHub PAT with `read:packages` (for VPS `docker pull`) |

Optional **variable**: `INFRA_DEPLOY_PATH` = `/opt/papermantra-infra` (default)

Create **environment** `production` (optional approval gate).

### 2.2 Each app repo — shared secret

Add to **all four** app repos (`papermantra`, `robofume`, `papermantraservices`, `pdfgenerator`):

| Secret | How to create |
|--------|----------------|
| `INFRA_DISPATCH_TOKEN` | GitHub → Settings → Developer settings → **Fine-grained PAT** or classic PAT with `repo` scope on `papermantra-infra` |

This lets app CI trigger infra deploy after pushing images.

### 2.3 `papermantra` repo — additional secrets/vars

**Secrets:** `REGISTRY_HOST`, `REGISTRY_USERNAME`, `REGISTRY_PASSWORD`, `PROD_REACT_APP_API_KEY`  
**Variables:**

- `PROD_REACT_APP_API_URL` = `https://api.papermantra.com/papermantra/api/v1/`
- `PROD_REACT_APP_API_PDF_GENERATOR_URL` = `https://pdf.papermantra.com/pdfgenerator/api/v1/`
- `PROD_APP_URL` = `https://papermantra.com`

### 2.4 `robofume` optional variable

- `PROD_NEXT_PUBLIC_API_BASE_URL` = `https://api.papermantra.com/papermantra/api/v1`

---

## Phase 3 — VPS: initial server setup

Use Ubuntu 22.04+ (2 vCPU, 4 GB RAM minimum recommended).

### 3.1 SSH in and install Docker

```bash
ssh deploy@YOUR_VPS_IP

curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
newgrp docker
docker compose version   # must show v2.x
```

### 3.2 Firewall

```bash
sudo ufw allow OpenSSH
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw enable
sudo ufw status
```

Do **not** expose MongoDB (27017) or Redis (6379) publicly.

### 3.3 Clone infra repo

```bash
sudo mkdir -p /opt
sudo git clone https://github.com/sagaranawade/papermantra-infra.git /opt/papermantra-infra
sudo chown -R $USER:$USER /opt/papermantra-infra
cd /opt/papermantra-infra
```

### 3.4 Create production `.env`

```bash
cp .env.example .env
nano .env
```

**Must change** (generate with `openssl rand -base64 48`):

- `MONGO_ROOT_PASSWORD`
- `REDIS_PASSWORD`
- `JWT_SECRET`
- `GRAFANA_ADMIN_PASSWORD` (if using monitoring)

**Must fill** (from Google Cloud Console):

- `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`
- `GOOGLE_GEN_CLIENT_ID`, `GOOGLE_GEN_CLIENT_SECRET`

**Must fill** (PDF service auth to API):

- `AUTH_USERNAME`, `AUTH_PASSWORD`

Verify `MONGODB_URI` and `PDF_MONGODB_URI` use the same `MONGO_ROOT_USER` / `MONGO_ROOT_PASSWORD` you set.

### 3.5 Log in to GHCR on the VPS

```bash
echo YOUR_GITHUB_PAT_WITH_read_packages | docker login ghcr.io -u sagaranawade --password-stdin
```

---

## Phase 4 — Cloudflare DNS (before SSL)

In Cloudflare for **papermantra.com** and **neelmind.com**:

| Type | Name | Content | Proxy |
|------|------|---------|-------|
| A | `@` | VPS_IP | Proxied (orange) |
| A | `www` | VPS_IP | Proxied |
| A | `api` | VPS_IP | Proxied |
| A | `pdf` | VPS_IP | Proxied |

Repeat for **neelmind.com** (`@` and `www`).

Wait 5–15 minutes for DNS propagation, then verify:

```bash
dig +short papermantra.com
dig +short api.papermantra.com
```

### Cloudflare SSL mode

1. SSL/TLS → Overview → set **Full (strict)** *after* Let's Encrypt certs exist  
2. For first Certbot run, temporarily use **Full** or **DNS only** (grey cloud) if HTTP-01 fails behind proxy

---

## Phase 5 — SSL certificates

On the VPS:

```bash
cd /opt/papermantra-infra
chmod +x certbot/*.sh scripts/*.sh

# Optional: test with staging first (avoids rate limits)
# STAGING=1 ./certbot/init-letsencrypt.sh

./certbot/init-letsencrypt.sh
docker compose --profile certbot up -d certbot
```

If Certbot fails behind Cloudflare proxy, set DNS records to **DNS only** (grey cloud), run the script again, then re-enable proxy.

---

## Phase 6 — First image push (build containers)

Images must exist in GHCR before the stack can start. Push a tag from each repo (or run workflows manually):

```bash
# Example from each repo locally:
git tag v1.0.0
git push origin v1.0.0
```

Or use **Actions → Run workflow** where available.

Order does not matter much; all four images should be in GHCR before full deploy.

---

## Phase 7 — Start the stack

```bash
cd /opt/papermantra-infra
./scripts/deploy.sh
docker compose ps
```

Verify locally on VPS:

```bash
curl -fsS http://127.0.0.1/healthz          # via nginx
curl -fsS https://papermantra.com/healthz   # public
curl -fsS https://api.papermantra.com/papermantra/actuator/health
curl -fsS https://pdf.papermantra.com/pdfgenerator/actuator/health
```

---

## Phase 8 — Enable automated deploys

1. Push `papermantra-infra` to `main` (commit all infra files)
2. Confirm **Actions → Deploy Infrastructure** runs successfully
3. Future prod releases: tag any app `v1.0.1` → CI pushes image → triggers infra → VPS pulls `:latest`

### Manual redeploy

GitHub → `papermantra-infra` → Actions → **Deploy Infrastructure** → Run workflow

Or on VPS:

```bash
cd /opt/papermantra-infra && ./scripts/deploy.sh
```

---

## Phase 9 — Backups (cron)

```bash
crontab -e
```

Add:

```cron
0 2 * * * /opt/papermantra-infra/scripts/backup-volumes.sh >> /var/log/papermantra-backup.log 2>&1
```

Test once manually:

```bash
/opt/papermantra-infra/scripts/backup-volumes.sh
ls -la /opt/papermantra-infra/backups/
```

---

## Phase 10 — Optional monitoring

```bash
cd /opt/papermantra-infra
docker compose -f docker-compose.yml -f docker-compose.monitoring.yml --profile monitoring up -d
```

Access via SSH tunnel only:

```bash
ssh -L 3001:127.0.0.1:3001 -L 9090:127.0.0.1:9090 deploy@YOUR_VPS_IP
# Grafana: http://localhost:3001
# Prometheus: http://localhost:9090
```

---

## Rollback procedure

If a deploy breaks production:

```bash
cd /opt/papermantra-infra
./scripts/rollback.sh
```

Or pin one service:

```bash
./scripts/update-image-tag.sh IMAGE_SERVICES v1.0.0
./scripts/deploy.sh
```

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `INFRA_DISPATCH_TOKEN` missing | Add PAT to app repo secrets |
| Image pull 401 on VPS | Re-run `docker login ghcr.io` |
| Nginx SSL error on start | Run `./certbot/init-letsencrypt.sh` |
| API unhealthy | Check `docker compose logs api mongodb redis` |
| `.env is missing` in Actions | Create `/opt/papermantra-infra/.env` on VPS |
| Smoke tests fail in Actions | DNS/SSL not ready; complete Phases 4–7 first |
| OAuth redirect errors | Update Google Console redirect URIs to prod URLs in `.env` |

---

## Commit & push checklist

Push these repos when ready:

```bash
# papermantra-infra
cd papermantra-infra && git add -A && git commit -m "Add production infra stack" && git push

# robofume (new CI)
cd ../robofume && git add .github && git commit -m "Add CI/CD workflow" && git push

# Updated deploy triggers
cd ../papermantra && git add .github && git commit -m "Trigger infra deploy on prod release" && git push
cd ../papermantraservices && git add .github && git commit -m "Trigger infra deploy on prod release" && git push
cd ../pdfgenerator && git add .github && git commit -m "Align image name and trigger infra deploy" && git push
```

*(Run commits only when you are ready — the commands above are for your reference.)*

---

## Summary: your action items

1. Create GitHub secrets (`PROD_SSH_*`, `GHCR_TOKEN`, `INFRA_DISPATCH_TOKEN` in all repos)
2. Set papermantra registry secrets to `ghcr.io` / `sagaranawade`
3. Provision VPS + install Docker
4. Create `/opt/papermantra-infra/.env` with real secrets
5. Configure Cloudflare DNS
6. Run Certbot init on VPS
7. Tag & push v1.0.0 on each app to populate GHCR
8. Run `./scripts/deploy.sh` on VPS
9. Push all repos to GitHub
10. Schedule backups cron

After that, production deploys are: **tag release → CI builds image → infra auto-deploys on VPS**.
