# Hawkra Self-Hosted Deployment Guide

This guide walks you through deploying Hawkra on a Linux server using Docker.

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Install Docker](#2-install-docker)
3. [Deploy the Client Package](#3-deploy-the-client-package)
4. [Configure DNS / Hostname](#4-configure-dns--hostname)
5. [TLS Certificates (Optional)](#5-tls-certificates-optional)
6. [Create the Environment File](#6-create-the-environment-file)
7. [Fix File Permissions](#7-fix-file-permissions)
8. [Pull Container Images](#8-pull-container-images)
9. [Start Hawkra](#9-start-hawkra)
10. [First Login & License Setup](#10-first-login--license-setup)
11. [Configure AI API Keys](#11-configure-ai-api-keys)
12. [Configure SMTP (Email)](#12-configure-smtp-email)
13. [Configure Multi-Factor Authentication](#13-configure-multi-factor-authentication)
14. [Updating Hawkra](#14-updating-hawkra)
15. [Backup](#15-backup)
16. [Troubleshooting](#16-troubleshooting)

---

## 1. Prerequisites

A Linux server with at least **4 GB of RAM** and **20 GB of disk space**. You will need `curl` and root or sudo access.

### Debian / Ubuntu

```bash
sudo apt update && sudo apt install -y curl ca-certificates gnupg
```

### Fedora

```bash
sudo dnf install -y curl ca-certificates gnupg2
```

---

## 2. Install Docker

### Debian / Ubuntu

```bash
sudo install -m 0755 -d /etc/apt/keyrings
```

```bash
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
```

```bash
sudo chmod a+r /etc/apt/keyrings/docker.gpg
```

```bash
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
```

> **Debian users:** Replace `ubuntu` with `debian` in both URLs above.

```bash
sudo apt update
```

```bash
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

### Fedora

```bash
sudo dnf -y install dnf-plugins-core
```

```bash
sudo dnf config-manager addrepo --from-repofile=https://download.docker.com/linux/fedora/docker-ce.repo
```

```bash
sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

### Enable and Verify (All Distros)

```bash
sudo systemctl enable --now docker
```

```bash
sudo docker run --rm hello-world
```

Optionally add your user to the `docker` group to run commands without `sudo`:

```bash
sudo usermod -aG docker $USER && newgrp docker
```

---

## 3. Deploy the Client Package

Create the installation directory:

```bash
sudo mkdir -p /opt/hawkra/{license,caddy,certs}
```

Copy the files provided to you into the installation directory:

```bash
sudo cp docker-compose.selfhosted.yml /opt/hawkra/
```

```bash
sudo cp Caddyfile /opt/hawkra/
```

```bash
sudo cp caddy/docker-entrypoint.sh /opt/hawkra/caddy/
```

Copy the license file provided to you:

```bash
sudo cp your-license.key /opt/hawkra/license/license.key
```

Your directory should look like this:

```
/opt/hawkra/
  docker-compose.selfhosted.yml
  Caddyfile
  caddy/
    docker-entrypoint.sh
  certs/            (empty unless using custom certificates)
  license/
    license.key
```

---

## 4. Configure DNS / Hostname

Hawkra requires a domain name for TLS certificates. Even on a private network, you must assign a hostname.

If you do **not** have a real DNS record pointing to this server, add an entry to `/etc/hosts` on the server **and** on every machine that will access Hawkra.

```bash
sudo nano /etc/hosts
```

Add a line mapping your server's LAN IP to your chosen domain:

```
192.168.1.100   hawkra.yourcompany.local
```

Replace `192.168.1.100` with the server's actual IP and `hawkra.yourcompany.local` with your chosen domain.

> **This must be done before starting the containers.** Caddy generates TLS certificates at startup using the configured domain.

---

## 5. TLS Certificates (Optional)

By default, Caddy generates **self-signed certificates** automatically. No action is needed for internal or test deployments.

### Option A: Self-Signed (Default)

No configuration required. Browsers will show a certificate warning that you can accept.

### Option B: Custom Certificates

If you have certificates from a corporate CA or a commercial provider:

```bash
sudo cp /path/to/your/cert.pem /opt/hawkra/certs/cert.pem
```

```bash
sudo cp /path/to/your/key.pem /opt/hawkra/certs/key.pem
```

The entrypoint script detects these files automatically at startup.

### Option C: Let's Encrypt

For public-facing servers with a real DNS record pointing to the server, add `LETS_ENCRYPT=true` to your `.env` file (see next section). Ports **80** and **443** must be reachable from the internet.

---

## 6. Create the Environment File

Generate a strong random password for the database:

```bash
cd /opt/hawkra
```

```bash
POSTGRES_PW=$(openssl rand -base64 24)
```

```bash
echo "Save this password somewhere safe: $POSTGRES_PW"
```

Create the `.env` file. Replace `hawkra.yourcompany.local` with the domain you configured in Step 4:

```bash
sudo tee /opt/hawkra/.env > /dev/null <<EOF
# Domain (REQUIRED - must match your DNS/hosts entry)
APP_DOMAIN=hawkra.yourcompany.local

# Database
POSTGRES_PASSWORD=$POSTGRES_PW

# URLs (replace domain to match APP_DOMAIN)
FRONTEND_URL=https://hawkra.yourcompany.local
BACKEND_URL=https://hawkra.yourcompany.local
CORS_ALLOWED_ORIGINS=https://hawkra.yourcompany.local
COOKIE_DOMAIN=hawkra.yourcompany.local
COOKIE_SECURE=true

# Uncomment for Let's Encrypt (public-facing servers only)
# LETS_ENCRYPT=true

# Pin to a specific version (optional, defaults to latest)
# VERSION=1.0.0
EOF
```

Restrict the file permissions:

```bash
sudo chmod 600 /opt/hawkra/.env
```

---

## 7. Fix File Permissions

The Caddy entrypoint script must be executable:

```bash
sudo chmod +x /opt/hawkra/caddy/docker-entrypoint.sh
```

The license directory must be writable by the backend container so that license files can be uploaded through the web interface during setup. The backend container runs as root, so ensure the directory and any existing files are accessible:

```bash
sudo chmod 755 /opt/hawkra/license
```

If you pre-placed a license file:

```bash
sudo chmod 644 /opt/hawkra/license/license.key
```

If using custom certificates:

```bash
sudo chmod 644 /opt/hawkra/certs/cert.pem
```

```bash
sudo chmod 600 /opt/hawkra/certs/key.pem
```

---

## 8. Pull Container Images

```bash
cd /opt/hawkra
```

```bash
sudo docker compose -f docker-compose.selfhosted.yml pull
```

This downloads the backend, frontend, PostgreSQL, Redis, and Caddy images.

---

## 9. Start Hawkra

```bash
cd /opt/hawkra
```

```bash
sudo docker compose -f docker-compose.selfhosted.yml up -d
```

Wait approximately 30 seconds for all services to start, then verify:

```bash
sudo docker compose -f docker-compose.selfhosted.yml ps
```

All services should show a status of **Up** or **Up (healthy)**.

---

## 10. First Login & License Setup

### Find the Default Admin Password

On first boot, the backend generates a random password for the default admin account. Retrieve it from the logs:

```bash
sudo docker compose -f docker-compose.selfhosted.yml logs backend | grep -i "password"
```

The default admin account is: **`admin@hawkra.local`**

### Complete Setup

1. Open **https://your-domain/login** in your browser.
2. If using self-signed certificates, accept the browser security warning.
3. Log in with `admin@hawkra.local` and the password from the logs.
4. You will be redirected to the **License Setup** page.
5. Upload the license file provided to you.
6. Click **Complete Setup**.
7. The platform is now live.

> If you pre-placed the license file at `./license/license.key` in Step 3, it will be detected automatically and you can skip the upload.

> If the upload fails, verify that the `./license` directory is writable (see Step 7).

> Change the default admin password immediately after login under **Account Settings**.

---

## 11. Configure AI API Keys

Hawkra's AI assistant requires an API key from a supported LLM provider. This is configured through the web interface.

### Get a Gemini API Key

1. Go to [https://aistudio.google.com/apikey](https://aistudio.google.com/apikey).
2. Create a new API key and copy it.

### Apply the Key

1. In Hawkra, navigate to **Admin > Settings**.
2. Under **AI Configuration**, set:
   - **gemini_api_key** — paste your Gemini API key
   - **gemini_model** — leave as default (`gemini-2.0-flash`) or set your preferred model
   - **llm_mode** — set to `cloud`
3. Save.

### Local LLM (Alternative)

To use a local LLM server (Ollama, llama.cpp, etc.) instead:

1. Under **AI Configuration**, set:
   - **llm_mode** — set to `local`
   - **local_llm_server** — your server URL (e.g., `http://localhost:11434`)

> API keys can alternatively be set as environment variables in the `.env` file (`GEMINI_API_KEY`, `GEMINI_MODEL`, `LLM_MODE`, `LOCAL_LLM_SERVER`). Environment variables take priority over settings configured in the admin UI.

---

## 12. Configure SMTP (Email)

SMTP enables email verification, password resets, email-based MFA, and user invitations. It is optional but recommended.

Append the following to your `.env` file, replacing the values with your SMTP provider's details:

```bash
sudo tee -a /opt/hawkra/.env > /dev/null <<'EOF'

# SMTP
SMTP_HOST=smtp.yourprovider.com
SMTP_PORT=465
SMTP_ENCRYPTION=ssl
SMTP_USERNAME=your-username
SMTP_PASSWORD=your-password
SMTP_FROM_ADDRESS=hawkra@yourcompany.com
EOF
```

Restart the backend for SMTP to take effect:

```bash
cd /opt/hawkra && sudo docker compose -f docker-compose.selfhosted.yml restart backend
```

### Common SMTP Providers

| Provider | Host | Port | Encryption |
|----------|------|------|------------|
| Gmail | smtp.gmail.com | 465 | ssl |
| Outlook / O365 | smtp.office365.com | 587 | starttls |
| Amazon SES | email-smtp.us-east-1.amazonaws.com | 465 | ssl |

> SMTP settings can also be configured in **Admin > Settings** under **Email (SMTP)**, but a container restart is still required after changes.

---

## 13. Configure Multi-Factor Authentication

MFA is optional in self-hosted deployments. Each user configures it from their own account.

### TOTP (Authenticator App)

1. Log in and go to **Account Settings**.
2. Under **Security**, click **Add Authenticator**.
3. Enter your account password when prompted.
4. Scan the QR code with your authenticator app (Google Authenticator, Authy, Microsoft Authenticator, etc.).
5. Enter the 6-digit code from the app to confirm.
6. **Save the recovery codes** displayed after setup. Store them securely — they are your only backup if you lose access to the authenticator app.

### Email MFA

Requires SMTP to be configured first (see Section 12).

1. Go to **Account Settings > Security**.
2. Click **Add Email MFA**.
3. Enter your password, then enter the verification code sent to your email.

---

## 14. Updating Hawkra

```bash
cd /opt/hawkra
```

```bash
sudo docker compose -f docker-compose.selfhosted.yml pull
```

```bash
sudo docker compose -f docker-compose.selfhosted.yml up -d
```

To pin a specific version, set `VERSION` in your `.env` file:

```
VERSION=1.2.0
```

Then pull and restart as shown above.

---

## 15. Backup

### Encryption Keys (Critical)

The `backend_config` volume contains auto-generated encryption keys. **If this volume is lost, all encrypted data is permanently unrecoverable.**

```bash
sudo docker run --rm \
  -v hawkra_backend_config:/source:ro \
  -v /opt/hawkra:/backup \
  alpine tar czf /backup/backend_config_backup.tar.gz -C /source .
```

### Database

```bash
sudo docker compose -f docker-compose.selfhosted.yml exec postgres \
  pg_dump -U hawkra hawkra > /opt/hawkra/hawkra_db_backup.sql
```

### File Storage

```bash
sudo docker run --rm \
  -v hawkra_file_storage:/source:ro \
  -v /opt/hawkra:/backup \
  alpine tar czf /backup/file_storage_backup.tar.gz -C /source .
```

---

## 16. Troubleshooting

### View Logs

```bash
sudo docker compose -f docker-compose.selfhosted.yml logs -f
```

```bash
sudo docker compose -f docker-compose.selfhosted.yml logs -f backend
```

```bash
sudo docker compose -f docker-compose.selfhosted.yml logs -f caddy
```

### Common Issues

| Issue | Solution |
|-------|---------|
| Browser shows "connection refused" | Verify containers are running: `docker compose ps` |
| Certificate warning in browser | Expected with self-signed certs. Accept the warning, or install custom certificates. |
| Caddy fails to start | Check that `APP_DOMAIN` is set in `.env` and `caddy/docker-entrypoint.sh` is executable (`chmod +x`). |
| 503 on all pages | Setup is not complete. Log in as admin and complete the license setup flow. |
| Admin password not in logs | The password is only printed on first boot. If the database volume already exists from a previous start, it was logged during that initial start. |
| Backend can't connect to database | Ensure `POSTGRES_PASSWORD` in `.env` is correct. Check: `docker compose logs postgres` |
| CORS errors in browser | Verify `CORS_ALLOWED_ORIGINS` in `.env` exactly matches the URL in your browser address bar, including `https://`. |
| License upload fails | The `./license` directory must be writable by the container. Run `sudo chmod 755 /opt/hawkra/license` and restart. |
| Email not sending | Verify all six `SMTP_*` variables are set in `.env`. Restart the backend after changes. Check `docker compose logs backend` for SMTP errors. |
| Domain not resolving | Confirm the `/etc/hosts` entry exists on both the server and the client machine accessing the UI. |

### Restart All Services

```bash
cd /opt/hawkra
```

```bash
sudo docker compose -f docker-compose.selfhosted.yml down
```

```bash
sudo docker compose -f docker-compose.selfhosted.yml up -d
```

### Full Reset (Destroys All Data)

```bash
cd /opt/hawkra
```

```bash
sudo docker compose -f docker-compose.selfhosted.yml down -v
```

```bash
sudo docker compose -f docker-compose.selfhosted.yml up -d
```

> **Warning:** The `-v` flag removes all Docker volumes including the database and encryption keys. All data will be permanently lost.

---

## Support

For assistance, contact your Hawkra account representative or email support at the address provided with your license.
