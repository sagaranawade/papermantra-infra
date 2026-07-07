# Cloudflare DNS migration — papermantra.com + neelmind.com

Move both domains off Hostinger `dns-parking.com` nameservers to Cloudflare. This fixes the intermittent Hostinger parking page (`2.57.91.91`) without touching the VPS or app deploys.

**VPS IP:** `187.127.189.114`

**Time:** ~30–60 minutes of setup, then up to 24 hours for global propagation (usually 15–30 minutes).

---

## Before you start

1. Create a free [Cloudflare account](https://dash.cloudflare.com/sign-up) (if you do not have one).
2. In Hostinger hPanel, **export** the current DNS zone for **neelmind.com** (Domains → DNS → Export). You need email records (MX, SPF, DKIM).
3. Leave Hostinger nameservers unchanged until Cloudflare shows all records and gives you new nameservers.

---

## Part A — papermantra.com

### A1. Add site in Cloudflare

1. Cloudflare dashboard → **Add a site** → enter `papermantra.com` → **Free** plan.
2. Cloudflare scans existing DNS. Review the list; delete any record pointing to `2.57.91.91`.
3. Set these records (**Proxy status = DNS only**, grey cloud, for the first migration):

| Type  | Name | Content              | TTL  | Proxy      |
|-------|------|----------------------|------|------------|
| A     | `@`  | `187.127.189.114`    | Auto | DNS only   |
| CNAME | `www`| `papermantra.com`    | Auto | DNS only   |
| A     | `api`| `187.127.189.114`    | Auto | DNS only   |
| A     | `pdf`| `187.127.189.114`    | Auto | DNS only   |

4. Remove duplicate `@` A records or any Hostinger parking records Cloudflare imported.
5. Continue. Cloudflare shows two nameservers, e.g.:
   - `ada.ns.cloudflare.com`
   - `bob.ns.cloudflare.com`
   (Your assigned pair may differ — use exactly what Cloudflare shows.)

### A2. Change nameservers in Hostinger

1. [hPanel → Domains → Domain portfolio](https://hpanel.hostinger.com/domains) → **Manage** `papermantra.com`.
2. **DNS / Nameservers** → **Change nameservers** → **Custom DNS**.
3. Replace `ns1.dns-parking.com` / `ns2.dns-parking.com` with the two Cloudflare nameservers.
4. Save.

### A3. Activate in Cloudflare

1. Back in Cloudflare → wait for the site status to become **Active** (refresh every few minutes).
2. **SSL/TLS → Overview** → set **Full (strict)** (Let's Encrypt certs already exist on the VPS).
3. Do **not** enable orange-cloud proxy yet unless you have verified HTTPS works end-to-end.

---

## Part B — neelmind.com

### B1. Add site in Cloudflare

1. **Add a site** → `neelmind.com` → **Free** plan.
2. Import or add records below. **Keep all email records** if you use Hostinger Mail on this domain.

**Website (VPS):**

| Type  | Name | Content              | TTL  | Proxy      |
|-------|------|----------------------|------|------------|
| A     | `@`  | `187.127.189.114`    | Auto | DNS only   |
| CNAME | `www`| `neelmind.com`       | Auto | DNS only   |

**Email (Hostinger Mail — copy from hPanel export if values differ):**

| Type | Name                         | Content                                              | Priority |
|------|------------------------------|------------------------------------------------------|----------|
| MX   | `@`                          | `mx1.hostinger.com`                                  | 5        |
| MX   | `@`                          | `mx2.hostinger.com`                                  | 10       |
| TXT  | `@`                          | `v=spf1 include:_spf.mail.hostinger.com ~all`        | —        |
| TXT  | `_dmarc`                     | `v=DMARC1; p=none`                                   | —        |
| TXT  | `hostingermail-a._domainkey` | *(paste full DKIM value from Hostinger DNS export)*  | —        |

> If Hostinger shows additional DKIM rows (`hostingermail-b`, `hostingermail-c`), add those too.  
> After migration, send a test email from `@neelmind.com` to confirm delivery.

3. Delete any `@` A record pointing to `75.2.60.5`, `2.57.91.91`, or other non-VPS IPs.
4. Note the two Cloudflare nameservers for this site (may differ from papermantra.com).

### B2. Change nameservers in Hostinger

Same as Part A2, but for **neelmind.com** → use **this site's** Cloudflare nameservers.

### B3. Activate and SSL

Same as Part A3 for `neelmind.com`.

---

## Part C — Verify

### From your laptop (PowerShell)

```powershell
nslookup papermantra.com 1.1.1.1
nslookup neelmind.com 1.1.1.1
```

Both must return **only** `187.127.189.114`. Run each command 3–4 times — no flip to `2.57.91.91`.

### From the VPS

```bash
cd /opt/papermantra-infra
git pull origin main
./scripts/verify-dns.sh
./scripts/verify-cloudflare-ns.sh
```

### HTTPS smoke test

```bash
curl -sI https://papermantra.com | head -3
curl -sI https://www.neelmind.com | head -3
curl -sI https://api.papermantra.com/papermantra/actuator/health | head -3
```

---

## Part D — Optional: enable Cloudflare proxy (orange cloud)

Only after DNS is stable for 24 hours:

1. Set **A** / **CNAME** web records to **Proxied** (orange cloud).
2. **SSL/TLS** must stay **Full (strict)**.
3. If Certbot renewal fails later, temporarily set affected records to **DNS only**, run `./certbot/renew.sh`, then re-enable proxy.

Web records safe to proxy: `@`, `www`, `api`, `pdf`.  
**Never proxy MX records.**

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Cloudflare stuck on "Pending nameservers" | Confirm custom NS saved in Hostinger; wait up to 24h |
| Site still shows Hostinger page | `ipconfig /flushdns` (Windows); verify NS are Cloudflare: `nslookup -type=NS papermantra.com` |
| `neelmind.com` email stops working | Re-check MX + SPF + DKIM in Cloudflare match Hostinger export |
| SSL errors after enabling proxy | Cloudflare → SSL/TLS → **Full (strict)**; confirm LE certs on VPS |
| Certbot HTTP-01 fails | Set records to DNS only (grey cloud), renew, then re-proxy |

---

## Checklist

**papermantra.com**

- [ ] Site added in Cloudflare (Free)
- [ ] A `@`, CNAME `www`, A `api`, A `pdf` → `187.127.189.114` (DNS only)
- [ ] No record pointing to `2.57.91.91`
- [ ] Nameservers changed in Hostinger to Cloudflare
- [ ] Cloudflare status = Active
- [ ] `verify-dns.sh` passes

**neelmind.com**

- [ ] Site added in Cloudflare (Free)
- [ ] A `@`, CNAME `www` → VPS (DNS only)
- [ ] MX, SPF, DKIM, DMARC copied from Hostinger
- [ ] Nameservers changed in Hostinger to Cloudflare
- [ ] Cloudflare status = Active
- [ ] Test email sent/received
- [ ] `verify-dns.sh` passes
