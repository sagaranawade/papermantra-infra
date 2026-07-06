# VPS Production Setup — Step by Step

**Single source of truth:** all production config is in **`.env` on the `main` branch**.  
No separate `.env` on the server. Change config → edit `.env` in repo → push → `git pull` on VPS.

---

## Already done

- [x] VPS (`deploy` user, Docker, UFW)
- [x] GitHub secrets
- [x] Cloudflare DNS
- [x] GitHub Actions SSH key

---

## Step 1 — Get latest infra (VPS, as `deploy`)

```bash
ssh deploy@YOUR_VPS_IP
cd /opt/papermantra-infra
git pull origin main
```

If `dubious ownership`:

```bash
sudo chown -R deploy:deploy /opt/papermantra-infra
```

---

## Step 2 — Bootstrap (no nano, no copy)

```bash
cd /opt/papermantra-infra
./scripts/vps-bootstrap.sh
```

Uses `.env` from the repo. Validates automatically.

---

## Step 3 — GHCR login

```bash
./scripts/ghcr-login.sh
```

---

## Step 4 — SSL (Cloudflare = **Full** first)

```bash
./certbot/init-letsencrypt.sh
docker compose --profile certbot up -d certbot
```

Then Cloudflare → **Full (strict)**.

---

## Step 5 — Push images (laptop)

Tag `v1.0.0` in all 4 app repos. Wait for GitHub Actions.

---

## Step 6 — Deploy

```bash
cd /opt/papermantra-infra
./scripts/deploy.sh
docker compose ps
```

---

## Step 7 — Verify

```bash
curl -fsS https://papermantra.com/healthz
curl -fsS https://api.papermantra.com/papermantra/actuator/health
curl -fsS https://pdf.papermantra.com/pdfgenerator/actuator/health
```

---

## Changing config later

1. Edit `.env` in `papermantra-infra` on your laptop  
2. `git commit && git push origin main`  
3. On VPS: `git pull origin main && ./scripts/deploy.sh`  

No server-side file editing.

---

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Old `.env` on VPS from manual copy | `git checkout -- .env` or `git pull` after push |
| `dubious ownership` | `sudo chown -R deploy:deploy /opt/papermantra-infra` |
| `docker pull` 401 | `./scripts/ghcr-login.sh` |
