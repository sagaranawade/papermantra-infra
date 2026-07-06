# VPS Production Setup — Step by Step

Use this guide **after**:

- [x] VPS created (`deploy` user, Docker, UFW, Fail2Ban)
- [x] GitHub secrets configured
- [x] Cloudflare DNS (6 A records)
- [x] `deploy` user in `docker` group
- [x] GitHub Actions SSH key → `deploy` (`PROD_SSH_*` on papermantra-infra)

**Server path:** `/opt/papermantra-infra`  
**SSH user:** `deploy` (not root)

---

## Overview — remaining steps

| Step | What | Where |
|------|------|--------|
| 3 | Clone infra repo | VPS |
| 4 | Bootstrap + create `.env` | VPS |
| 5 | Validate `.env` | VPS |
| 6 | GHCR login | VPS |
| 7 | Cloudflare SSL mode | Cloudflare UI |
| 8 | SSL certificates (Certbot) | VPS |
| 9 | Push images to GHCR | Your laptop → GitHub |
| 10 | Start production stack | VPS |
| 11 | Verify + enable auto-deploy | VPS + GitHub |

---

## Step 3 — Clone infra repo on VPS

SSH in as **deploy**:

```bash
ssh deploy@YOUR_VPS_IP
```

Clone (first time only):

```bash
sudo mkdir -p /opt
sudo git clone https://github.com/sagaranawade/papermantra-infra.git /opt/papermantra-infra
sudo chown -R deploy:deploy /opt/papermantra-infra
```

**Always work as `deploy` after clone** (not root):

```bash
su - deploy
cd /opt/papermantra-infra
git pull origin main
```

If you see `fatal: detected dubious ownership`:

```bash
# Fix ownership (run once as root):
sudo chown -R deploy:deploy /opt/papermantra-infra

# Then use deploy for all git/docker commands:
su - deploy
cd /opt/papermantra-infra
git pull origin main
```

Do **not** run `git config --global safe.directory` as root unless you must; fixing ownership is the correct fix.

```bash
cd /opt/papermantra-infra
```

**Pull latest** (after you push infra updates from your machine):

```bash
cd /opt/papermantra-infra
git pull origin main
```

---

## Step 4 — Bootstrap and create `.env`

```bash
cd /opt/papermantra-infra
./scripts/vps-bootstrap.sh
```

This will:

- `chmod +x` all scripts
- Copy `.env.production.template` → `.env` (if `.env` does not exist)

Edit `.env` — **only change the 3 passwords**:

```bash
nano .env
```

Generate passwords on the VPS:

```bash
openssl rand -base64 48
```

Run that **twice** and set:

| Key | Action |
|-----|--------|
| `MONGO_ROOT_PASSWORD` | paste generated password #1 |
| `REDIS_PASSWORD` | paste generated password #2 |
| `GRAFANA_ADMIN_PASSWORD` | paste generated password #3 (only if using monitoring) |

**Already filled** (matches your local working config — do not change unless you know why):

- OAuth client IDs/secrets
- `AUTH_USERNAME` / `AUTH_PASSWORD`
- `JWT_SECRET=changeit`
- All prod URLs (`api.papermantra.com`, etc.)
- `CERTBOT_EMAIL=123sagar.anawade@gmail.com`

`MONGODB_URI` and `PDF_MONGODB_URI` use `${MONGO_ROOT_PASSWORD}` — once you set that password, both URIs update automatically.

**Google Cloud Console** (one-time, if not done):

Add to your existing OAuth clients:

- Redirect: `https://api.papermantra.com/papermantra/api/v1/googledrive/oauth2callback`
- JS origins: `https://papermantra.com`, `https://www.papermantra.com`

---

## Step 5 — Validate `.env`

```bash
cd /opt/papermantra-infra
./scripts/validate-env.sh
```

Fix any `FAIL` lines before continuing. `WARN` about `changeit` is OK for first launch.

---

## Step 6 — GHCR login on VPS

Use the same PAT as GitHub secret `GHCR_TOKEN` (`read:packages`):

```bash
cd /opt/papermantra-infra
GHCR_TOKEN=ghp_your_token_here ./scripts/ghcr-login.sh
```

Or interactively:

```bash
./scripts/ghcr-login.sh
```

Test pull (after Step 9 — images must exist first):

```bash
docker pull ghcr.io/sagaranawade/papermantraservices:latest
```

---

## Step 7 — Cloudflare SSL mode

Cloudflare dashboard → **SSL/TLS** → **Overview**:

| Phase | Setting |
|-------|---------|
| **Before** Certbot | **Full** |
| **After** certs work on VPS | **Full (strict)** |

If Certbot fails with proxy on, temporarily set all 6 DNS records to **DNS only** (grey cloud), run Step 8, then turn proxy back on.

---

## Step 8 — SSL certificates (Certbot)

```bash
cd /opt/papermantra-infra
./certbot/init-letsencrypt.sh
docker compose --profile certbot up -d certbot
```

**Optional staging test** (avoids Let's Encrypt rate limits):

```bash
STAGING=1 ./certbot/init-letsencrypt.sh
```

**Expected:** script creates dummy certs → starts nginx → requests real certs for:

- `papermantra.com` + `www`
- `neelmind.com` + `www`
- `api.papermantra.com`
- `pdf.papermantra.com`

**If it fails:**

```bash
docker compose logs nginx
sudo ufw status
dig +short api.papermantra.com
```

Common fix: grey-cloud DNS records, retry, re-enable orange cloud.

After success → set Cloudflare to **Full (strict)**.

---

## Step 9 — Push Docker images to GHCR (your laptop)

Images **must** exist in GHCR before `deploy.sh` can start the stack.

**Do not** `docker build` on the VPS for production.

### Order (recommended)

```powershell
# 1) API
cd "d:\PaperMantra Projects\Git Hub New Repos\papermantraservices"
git tag v1.0.0
git push origin v1.0.0

# 2) PDF
cd "d:\PaperMantra Projects\Git Hub New Repos\pdfgenerator"
git tag v1.0.0
git push origin v1.0.0

# 3) Portal
cd "d:\PaperMantra Projects\Git Hub New Repos\papermantra"
git tag v1.0.0
git push origin v1.0.0

# 4) Website
cd "d:\PaperMantra Projects\Git Hub New Repos\robofume"
git tag v1.0.0
git push origin v1.0.0
```

Watch **GitHub Actions** in each repo until green.

### Verify packages exist

GitHub → your profile → **Packages** — you should see:

| Package | Tag |
|---------|-----|
| `papermantra-web` | `latest` |
| `papermantraservices` | `latest` |
| `pdf-generator` | `latest` |
| `robofume` | `latest` |

If a package is private, ensure `GHCR_TOKEN` on VPS can pull it.

---

## Step 10 — Start production stack

On VPS:

```bash
cd /opt/papermantra-infra
./scripts/deploy.sh
docker compose ps
```

All services should be `running` / `healthy` (API/PDF may take 60–90s on first boot).

**View logs if something fails:**

```bash
docker compose logs --tail=100 api
docker compose logs --tail=100 pdf
docker compose logs --tail=100 nginx
docker compose logs --tail=100 mongodb
```

---

## Step 11 — Verify production

From your laptop:

```bash
curl -fsS https://papermantra.com/healthz
curl -fsS https://api.papermantra.com/papermantra/actuator/health
curl -fsS https://pdf.papermantra.com/pdfgenerator/actuator/health
curl -fsS -o /dev/null -w "%{http_code}\n" https://www.neelmind.com/
```

Open in browser:

- https://papermantra.com
- https://www.neelmind.com
- Log in on portal → confirm API calls work

### Enable automated deploys

1. Push `papermantra-infra` to `main` (includes this guide + scripts)
2. GitHub → `papermantra-infra` → **Actions** → **Deploy Infrastructure** → **Run workflow**
3. Future releases: `git tag v1.0.1 && git push origin v1.0.1` in any app repo

---

## What NOT to do on VPS (you tested manually — that's OK)

These were **local tests only** — production uses compose:

```bash
# ❌ Not used in prod
docker build -f Dockerfile.prod ...
docker run -p 9091:9091 ...
```

Production = **one** `docker compose up` via `/opt/papermantra-infra`.

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `docker pull` 401 | Re-run `./scripts/ghcr-login.sh` |
| API won't start | `docker compose logs api` — check Mongo/Redis passwords in `.env` |
| PDF won't start | JWT_SECRET must match API; check `AUTH_USERNAME`/`PASSWORD` |
| Nginx 502 | `docker compose ps` — wait for API/PDF health |
| Certbot failed | Grey-cloud DNS, retry; check port 80 open |
| `permission denied` docker | `groups` must include `docker`; re-login SSH |
| `dubious ownership` on git pull | `sudo chown -R deploy:deploy /opt/papermantra-infra` then `su - deploy` |
| Empty database | Expected on first deploy — import/migrate data separately |

---

## Quick command reference (copy-paste)

```bash
# Full path after clone
cd /opt/papermantra-infra
./scripts/vps-bootstrap.sh
nano .env
./scripts/validate-env.sh
./scripts/ghcr-login.sh
./certbot/init-letsencrypt.sh
docker compose --profile certbot up -d certbot
./scripts/deploy.sh
docker compose ps
```

---

## After first successful deploy

1. Change root password if it was ever shared
2. Rotate `JWT_SECRET` / Mongo / Redis passwords when ready
3. Set up backup cron: see `DEPLOYMENT.md` Phase 9
4. Import Mongo data if you need local data on prod
