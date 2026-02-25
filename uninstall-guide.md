# Hawkra Self-Hosted Uninstallation Guide

This guide walks you through completely removing a Hawkra installation from a Linux server. You can use the automated uninstall script or follow the manual steps below.

---

## Table of Contents

1. [Before You Begin](#1-before-you-begin)
2. [Automated Uninstall (Recommended)](#2-automated-uninstall-recommended)
3. [Manual Uninstall](#3-manual-uninstall)
   - 3.1 [Stop and Remove Containers](#31-stop-and-remove-containers)
   - 3.2 [Remove Docker Volumes](#32-remove-docker-volumes)
   - 3.3 [Remove Docker Images](#33-remove-docker-images)
   - 3.4 [Remove the Hosts Entry](#34-remove-the-hosts-entry)
   - 3.5 [Remove the Installation Directory](#35-remove-the-installation-directory)
4. [Verify Removal](#4-verify-removal)
5. [What Is Not Removed](#5-what-is-not-removed)

---

## 1. Before You Begin

> **Warning:** Uninstalling Hawkra permanently destroys **all** data, including workspaces, assets, vulnerabilities, user accounts, uploaded files, credentials, notes, compliance evidence, your license file, and encryption keys. This action cannot be undone.

If you need to preserve any data, create backups **before** proceeding. See the [Backup section](deployment-guide.md#15-backup) of the deployment guide.

### Export a Database Backup

```bash
cd /opt/hawkra
```

```bash
sudo docker compose -f docker-compose.selfhosted.yml exec postgres \
  pg_dump -U hawkra hawkra > ~/hawkra_db_backup.sql
```

### Export Encryption Keys

```bash
sudo docker run --rm \
  -v hawkra_backend_config:/source:ro \
  -v ~/:/backup \
  alpine tar czf /backup/hawkra_keys_backup.tar.gz -C /source .
```

### Export Uploaded Files

```bash
sudo docker run --rm \
  -v hawkra_file_storage:/source:ro \
  -v ~/:/backup \
  alpine tar czf /backup/hawkra_files_backup.tar.gz -C /source .
```

---

## 2. Automated Uninstall (Recommended)

The `uninstall.sh` script handles the entire removal process. It will ask you to confirm before deleting anything.

```bash
sudo bash uninstall.sh
```

The script will:

1. Detect your existing Hawkra installation.
2. Display a warning listing everything that will be deleted.
3. Require you to type `uninstall` to confirm.
4. Stop and remove all Hawkra Docker containers.
5. Delete all Docker volumes (database, file storage, certificates).
6. Remove Hawkra Docker images.
7. Remove the `/etc/hosts` entry added by the installer.
8. Delete the `/opt/hawkra` directory and all of its contents.
9. Print a summary of what was removed.

> If you no longer have the script, you can download it from the client package repository or follow the manual steps below.

---

## 3. Manual Uninstall

Follow these steps in order if you prefer to uninstall manually or if the automated script is unavailable.

---

### 3.1 Stop and Remove Containers

Stop all running Hawkra containers and remove them along with their associated networks:

```bash
cd /opt/hawkra
```

```bash
sudo docker compose -f docker-compose.selfhosted.yml down
```

Verify no Hawkra containers remain:

```bash
sudo docker ps -a --filter "name=hawkra"
```

If any containers are still listed, remove them manually:

```bash
sudo docker rm -f $(sudo docker ps -a --filter "name=hawkra" -q)
```

---

### 3.2 Remove Docker Volumes

List the Hawkra volumes:

```bash
sudo docker volume ls --filter "name=hawkra_"
```

You should see five volumes:

| Volume | Contents |
|--------|----------|
| `hawkra_postgres_data` | PostgreSQL database (all user data) |
| `hawkra_file_storage` | Uploaded and encrypted files |
| `hawkra_backend_config` | Auto-generated encryption keys |
| `hawkra_caddy_data` | TLS certificates and Caddy state |
| `hawkra_caddy_config` | Caddy configuration cache |

Remove all of them:

```bash
sudo docker volume rm hawkra_postgres_data hawkra_file_storage hawkra_backend_config hawkra_caddy_data hawkra_caddy_config
```

> **If a volume cannot be removed**, it may still be attached to a stopped container. Re-run Step 3.1 to remove the container first, then retry.

---

### 3.3 Remove Docker Images

List the Hawkra images:

```bash
sudo docker images | grep -E "reconhawk|postgres.*16-alpine|redis.*7-alpine|caddy.*2-alpine"
```

Remove them:

```bash
sudo docker rmi ghcr.io/reconhawk/hawkra-backend:latest
```

```bash
sudo docker rmi ghcr.io/reconhawk/hawkra-frontend:latest
```

```bash
sudo docker rmi postgres:16-alpine
```

```bash
sudo docker rmi redis:7-alpine
```

```bash
sudo docker rmi caddy:2-alpine
```

> If you pinned a specific `VERSION` in your `.env` file, replace `latest` with that version tag for the Hawkra images.

> If `postgres`, `redis`, or `caddy` images are used by other projects on this server, skip removing them. Docker will refuse to remove images that are in use by other containers.

---

### 3.4 Remove the Hosts Entry

If the installer (or you) added a hosts entry for the Hawkra domain, remove it now.

First, check the current domain from your `.env` file:

```bash
grep APP_DOMAIN /opt/hawkra/.env
```

Then edit `/etc/hosts`:

```bash
sudo nano /etc/hosts
```

Find and delete the line containing your Hawkra domain. It will look like one of these:

```
192.168.1.100    hawkra.yourcompany.local
127.0.0.1    hawkra.yourcompany.local
0.0.0.0    hawkra.yourcompany.local
```

Save and exit.

> **Do not delete the localhost entry** (`127.0.0.1 localhost`). Removing it will break local networking on your server.

> If other machines on your network also have hosts entries pointing to this server for Hawkra, remove those entries as well.

---

### 3.5 Remove the Installation Directory

Delete the entire `/opt/hawkra` directory:

```bash
sudo rm -rf /opt/hawkra
```

This removes the Docker Compose file, Caddyfile, environment configuration, license file, certificates, and any other files in the installation directory.

---

## 4. Verify Removal

Run the following checks to confirm everything was removed:

```bash
sudo docker ps -a --filter "name=hawkra"
```

```bash
sudo docker volume ls --filter "name=hawkra_"
```

```bash
sudo docker images | grep reconhawk
```

```bash
ls /opt/hawkra 2>/dev/null || echo "Installation directory removed"
```

```bash
grep -i hawkra /etc/hosts || echo "No hosts entry found"
```

All five commands should return empty results or the confirmation messages shown above.

---

## 5. What Is Not Removed

The following are intentionally left in place:

| Item | Reason |
|------|--------|
| Docker Engine | May be used by other applications on this server |
| System packages (`curl`, `openssl`, etc.) | Common utilities that other software depends on |
| Cloned Git repositories outside `/opt/hawkra` | Not part of the installation |
| Backups you created before uninstalling | Stored in the location you chose |

To also remove Docker, see the [Docker documentation](https://docs.docker.com/engine/install/ubuntu/#uninstall-docker-engine) for your distribution.

---

## Support

For assistance, contact your Hawkra account representative or email support at the address provided with your license.
