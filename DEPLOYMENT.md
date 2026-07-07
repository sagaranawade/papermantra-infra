# PaperMantra Production Deployment — Manual Steps

Everything the AI **cannot** do from your machine is listed here in order. Code/config in all repos is ready; you finish setup on GitHub, the VPS, and Cloudflare.

> **VPS steps 3–11 (detailed):** see **[VPS-SETUP.md](./VPS-SETUP.md)** — use this after DNS + GitHub secrets + deploy user are ready.

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

## Prod-only mode (current)

**Dev CI/CD deploys are disabled** until you re-enable them. Only production paths are active.

| What runs | Trigger | Where |
|-----------|---------|-------|
| App prod image build + push | Tag `v*.*.*` on any app repo | GitHub Actions → GHCR |
| Infra deploy to VPS | App tag → `repository_dispatch`, or push to infra `main` | `papermantra-infra` workflow |
| Dev deploy jobs | **Disabled** (`if: false` or `workflow_dispatch` only) | See workflow comments |

**Do not configure** any `DEV_*` GitHub secrets or `development` environment for now.

**Re-enable dev later:**

| Repo | File | Change |
|------|------|--------|
| papermantra | `.github/workflows/deploy-dev.yml` | Restore `on.push.branches: [main, develop]` |
| papermantraservices | `.github/workflows/ci-cd.yml` | `deploy-dev` job `if:` → `github.ref == 'refs/heads/development' && github.event_name == 'push'` |
| pdfgenerator | `.github/workflows/ci-cd.yml` | `docker-dev` job — same `if` |
| robofume | `.github/workflows/ci-cd.yml` | `docker-dev` job — same `if` |

PRs and `development` branch pushes still run **build + test** only (no deploy).

---

## Production config — single file on `main`

All production values live in **`papermantra-infra/.env`** (committed on `main`).

- **No** separate `.env` on the VPS  
- **No** `cp .env.example` / `nano .env` on the server  
- To change config: edit `.env` locally → push → `git pull` on VPS → `./scripts/deploy.sh`

> Keep the **papermantra-infra** repository **private** (it contains credentials).


### Two ways to reach the VPS

| Who | How | Credentials live in |
|-----|-----|---------------------|
| **You (manual)** | `ssh deploy@YOUR_VPS_IP` from your laptop | Your `~/.ssh/` key added to VPS `authorized_keys` |
| **GitHub Actions (automated prod deploy)** | `appleboy/ssh-action` in `papermantra-infra/.github/workflows/deploy.yml` | GitHub secrets on **papermantra-infra**: `PROD_SSH_HOST`, `PROD_SSH_USER`, `PROD_SSH_KEY` |

App repos **do not SSH to prod**. They only push images and ping infra via `INFRA_DISPATCH_TOKEN`.

### Directory layout on the VPS (single prod server)

Everything production runs under **`/opt/papermantra-infra`**:

```
/opt/papermantra-infra/
├── .env                    ← production config (committed on main)
├── docker-compose.yml      ← full stack (nginx, portal, website, api, pdf, mongo, redis)
├── nginx/conf.d/           ← reverse proxy for 4 domains
├── certbot/                ← Let's Encrypt certs
├── scripts/
│   ├── deploy.sh           ← pull images + restart (called by GitHub Actions)
│   ├── rollback.sh
│   └── backup-volumes.sh
├── backups/                ← volume backups
└── .deploy-history         ← rollback tags
```

**Docker volumes** (data persists here, not in the repo):

| Volume | Contents |
|--------|----------|
| `mongo_data` | MongoDB databases (`papermantra`, `pdfgenerator`) |
| `redis_data` | Redis cache |
| `api_user_pics`, `api_question_images` | Uploaded files for API |
| `api_logs`, `pdf_logs` | Application logs |

**What is NOT on the VPS:** app source code, per-app `.env` files, or separate dev servers (dev is local-only for now).

### Prod deploy flow (automated)

```
1. You: git tag v1.0.0 && git push origin v1.0.0   (any app repo)
2. GitHub Actions: build image → push ghcr.io/sagaranawade/<service>:latest
3. GitHub Actions: repository_dispatch → papermantra-infra
4. Infra workflow: SSH to VPS → cd /opt/papermantra-infra → ./scripts/deploy.sh
5. VPS: docker login ghcr.io → docker compose pull → docker compose up -d
6. Infra workflow: smoke tests (papermantra.com, api, pdf, neelmind.com)
```

---

## VPS `.env` — use local values where possible

Copy `papermantra-infra/.env.example` to `/opt/papermantra-infra/.env` on the VPS.
Goal: **same business config as local** (credentials, OAuth, JWT, auth users). Only **hostnames/URLs** change because prod uses public domains and Docker network names.

### Copy from local as-is (same values on VPS)

| VPS `.env` key | Copy from (local) | Local value |
|----------------|-------------------|-------------|
| `JWT_SECRET` | `papermantraservices` `application.properties` → `app.jwt.secret` | `changeit` |
| `JWT_ISSUER` | pdf `application.properties` → `papermantra.security.jwt.issuer` | `papermantra` |
| `JWT_EXPIRATION_MS` | `application.properties` → `app.jwt.expiration-ms` | `2592000000` (30 days) |
| `AUTH_USERNAME` | pdf `application.properties` → `papermantra.auth.username` | `admin@papermantra.com` |
| `AUTH_PASSWORD` | pdf `application.properties` → `papermantra.auth.password` | `neelsa@papermantra.com` |
| `GOOGLE_CLIENT_ID` | `application.properties` → `spring.security.oauth2...google.client-id` | *(your existing client id)* |
| `GOOGLE_CLIENT_SECRET` | same | *(your existing secret)* |
| `GOOGLE_GEN_CLIENT_ID` | `application.properties` → `google.oauth.gen.client-id` | *(your existing client id)* |
| `GOOGLE_GEN_CLIENT_SECRET` | same | *(your existing secret)* |
| `MONGODB_DATABASE` | local | `papermantra` |
| `PDF_MONGODB_DATABASE` | local | `pdfgenerator` |
| `REDIS_PORT` | local | `6379` |
| `REDIS_SSL_ENABLED` | local | `false` |

**DeepSeek API key** is in `application.properties` and ships inside the API Docker image — no VPS `.env` entry needed (same as local).

### Must differ (infrastructure — cannot use localhost)

| VPS `.env` key | Local value | Production value | Why |
|----------------|-------------|------------------|-----|
| `MONGO_ROOT_USER` / `MONGO_ROOT_PASSWORD` | no auth locally | set any password (e.g. `admin` + generated password) | Prod Mongo runs with auth in Docker |
| `MONGODB_URI` | `localhost:27017` | `mongodb://admin:PASSWORD@mongodb:27017/papermantra?authSource=admin` | Docker service name `mongodb`, not localhost |
| `PDF_MONGODB_URI` | `localhost:27017` | same host, db `pdfgenerator` | same |
| `REDIS_HOST` | `localhost` | `redis` | Docker service name |
| `REDIS_PASSWORD` | empty | any strong password | Prod Redis requires `--requirepass` |
| `GOOGLE_GEN_REDIRECT_URI` | `http://localhost:9091/.../oauth2callback` | `https://api.papermantra.com/papermantra/api/v1/googledrive/oauth2callback` | Google OAuth + HTTPS |
| `GOOGLE_GEN_JS_ORIGINS` | `http://localhost:3000,3001` | `https://papermantra.com,https://www.papermantra.com` | Browser origins |
| `AUTH_BASE_URL` | `http://localhost:9091` | `https://api.papermantra.com/papermantra` | PDF → API (internal Docker could use `http://api:9091/papermantra` but public URL works) |
| `QP_BASE_URL` | `http://localhost:9091` | `https://api.papermantra.com/papermantra` | PDF → API |
| `PDF_BASE_URL` | `http://localhost:9092/pdfgenerator` | `https://pdf.papermantra.com/pdfgenerator` | Public PDF URL |
| `CORS_ALLOWED_ORIGINS` | localhost patterns | `https://papermantra.com,https://www.papermantra.com` | Browser CORS |
| `CORS_ALLOWED_PATTERNS` | `http://192.168.*.*:*` | `https://*.papermantra.com` | Browser CORS |
| `IMAGE_*` | local docker build | `ghcr.io/sagaranawade/...:latest` | Pre-built CI images |

**Also register** prod OAuth redirect URIs and JS origins in [Google Cloud Console](https://console.cloud.google.com/) (same client IDs, new URLs).

### Frontend build-time URLs (papermantra + robofume)

React/Next bake URLs at **image build** time. These **must** be public HTTPS (not localhost):

| App | Variable | Production value |
|-----|----------|------------------|
| papermantra | `PROD_REACT_APP_API_URL` (GitHub var) | `https://api.papermantra.com/papermantra/api/v1/` |
| papermantra | `PROD_REACT_APP_API_PDF_GENERATOR_URL` | `https://pdf.papermantra.com/pdfgenerator/api/v1/` |
| papermantra | `PROD_REACT_APP_API_KEY` (secret) | `"Production API URL"` (same as `.env.production` today) |
| robofume | `PROD_NEXT_PUBLIC_API_BASE_URL` (optional var) | `https://api.papermantra.com/papermantra/api/v1` |

Local `.env.development` keeps `http://192.168.x.x:9091` — that is correct for local only.

### Should differ later (security — optional for initial launch)

| Item | Local | Recommended prod later |
|------|-------|------------------------|
| `JWT_SECRET` | `changeit` | `openssl rand -base64 48` |
| `MONGO_ROOT_PASSWORD` / `REDIS_PASSWORD` | n/a | strong generated passwords |
| Hardcoded OAuth / DeepSeek in `application.properties` | committed in repo | move to env-only |

For **first prod launch matching local behavior**, using `changeit` and existing OAuth credentials is fine if you accept the security trade-off.

---

## Phase 2 — GitHub: secrets & variables (prod only)

**Skip all `DEV_*` secrets.** Only configure the rows below.

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
./scripts/vps-bootstrap.sh
```

See **[VPS-SETUP.md](./VPS-SETUP.md)** for steps 4–11.

### 3.4 Production `.env`

Comes from the repo on `main` after `git pull`. No manual copy step.

```bash
git pull origin main
./scripts/vps-bootstrap.sh
```

### 3.5 Log in to GHCR on the VPS

```bash
echo YOUR_GITHUB_PAT_WITH_read_packages | docker login ghcr.io -u sagaranawade --password-stdin
```

---

## Phase 4 — DNS (before SSL)

**Current setup:** domains use Hostinger nameservers (`ns1.dns-parking.com`, `ns2.dns-parking.com`).  
Nginx on the VPS already serves both `papermantra.com` and `www.papermantra.com`; the usual failure mode is DNS still pointing the apex at Hostinger parking (`2.57.91.91`) instead of the VPS.

### Hostinger hPanel (DNS Zone Editor)

For **papermantra.com** in [hPanel → Domains → DNS / DNS Zone](https://hpanel.hostinger.com/domains):

| Type | Name | Points to | TTL |
|------|------|-----------|-----|
| A | `@` | `187.127.189.114` | 14400 |
| CNAME | `www` | `papermantra.com` | 14400 |
| A | `api` | `187.127.189.114` | 14400 |
| A | `pdf` | `187.127.189.114` | 14400 |

Repeat `@` + `www` for **neelmind.com** (same VPS IP).

**Symptom:** `papermantra.com` shows a Hostinger “Parked Domain” page while `api.papermantra.com` works — the `@` A record is wrong. Update it to the VPS IP; `www` CNAME will follow automatically.

Verify after 5–15 minutes:

```bash
./scripts/verify-dns.sh
# or manually:
dig +short papermantra.com @ns1.dns-parking.com
dig +short www.papermantra.com @ns1.dns-parking.com
```

### Optional — Cloudflare

If you later move nameservers to Cloudflare, use the same A/CNAME values:

| Type | Name | Content | Proxy |
|------|------|---------|-------|
| A | `@` | VPS_IP | Proxied (orange) |
| CNAME | `www` | `papermantra.com` | Proxied |
| A | `api` | VPS_IP | Proxied |
| A | `pdf` | VPS_IP | Proxied |

### Cloudflare SSL mode (only when using Cloudflare proxy)

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
