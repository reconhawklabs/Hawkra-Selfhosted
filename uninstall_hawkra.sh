#!/usr/bin/env bash
# Hawkra Self-Hosted Uninstaller
# Completely removes a Hawkra installation: containers, images, volumes,
# configuration, data, and the /etc/hosts entry.
# Usage: sudo bash uninstall.sh

set -euo pipefail

# ── Constants ────────────────────────────────────────────────────────────────

INSTALL_DIR="/opt/hawkra"
COMPOSE_FILE="docker-compose.selfhosted.yml"

# ── Colors ───────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${BLUE}[*]${NC} $1"; }
success() { echo -e "${GREEN}[+]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
fail()    { echo -e "${RED}[-]${NC} $1"; exit 1; }

# Track what was removed for the summary
REMOVED_CONTAINERS=false
REMOVED_IMAGES=false
REMOVED_VOLUMES=false
REMOVED_HOSTS_ENTRY=false
REMOVED_INSTALL_DIR=false
APP_DOMAIN=""

# ── Pre-flight checks ───────────────────────────────────────────────────────

preflight() {
    # Verify stdin is a terminal
    if [ ! -t 0 ]; then
        fail "This script requires an interactive terminal. Run it directly: sudo bash uninstall.sh"
    fi

    # Root check
    if [ "$(id -u)" -ne 0 ]; then
        fail "This script must be run as root. Use: sudo bash uninstall.sh"
    fi

    # Check if there's anything to uninstall
    local found_something=false

    if [ -d "$INSTALL_DIR" ]; then
        found_something=true
    fi

    if command -v docker &> /dev/null && docker info &> /dev/null; then
        if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^hawkra[-_]"; then
            found_something=true
        fi
        if docker volume ls --format '{{.Name}}' 2>/dev/null | grep -q "^hawkra_"; then
            found_something=true
        fi
    fi

    if [ "$found_something" = false ]; then
        info "No Hawkra installation found. Nothing to uninstall."
        exit 0
    fi
}

# ── Warn the user ────────────────────────────────────────────────────────────

confirm_uninstall() {
    echo ""
    echo -e "${RED}${BOLD}WARNING: This will permanently delete your entire Hawkra installation.${NC}"
    echo ""
    echo "  The following will be destroyed:"
    echo "    - All workspaces, assets, vulnerabilities, and user accounts"
    echo "    - The PostgreSQL database and all stored data"
    echo "    - Uploaded files, credentials, notes, and compliance evidence"
    echo "    - Your uploaded license file"
    echo "    - TLS certificates and configuration"
    echo "    - All Docker containers, images, and volumes for Hawkra"
    echo "    - The /etc/hosts entry added by the installer"
    echo "    - The ${INSTALL_DIR} directory and everything inside it"
    echo ""
    echo -e "  ${BOLD}This action cannot be undone.${NC}"
    echo ""
    read -rp "  Type 'uninstall' to confirm: " confirmation

    if [ "$confirmation" != "uninstall" ]; then
        echo ""
        info "Uninstall cancelled. Your installation is untouched."
        exit 0
    fi

    echo ""
}

# ── Read domain from .env before we delete it ───────────────────────────────

read_domain() {
    if [ -f "$INSTALL_DIR/.env" ]; then
        APP_DOMAIN=$(grep -oP '(?<=^APP_DOMAIN=).+' "$INSTALL_DIR/.env" 2>/dev/null || true)
    fi

    # Fallback: try to extract from compose environment
    if [ -z "$APP_DOMAIN" ] && [ -f "$INSTALL_DIR/$COMPOSE_FILE" ]; then
        APP_DOMAIN=$(grep -oP '(?<=APP_DOMAIN[=:]\s?)\S+' "$INSTALL_DIR/$COMPOSE_FILE" 2>/dev/null | head -1 || true)
    fi

    if [ -n "$APP_DOMAIN" ]; then
        info "Detected domain: $APP_DOMAIN"
    else
        warn "Could not detect APP_DOMAIN. /etc/hosts entry will need manual cleanup if one was added."
    fi
}

# ── Stop and remove containers + volumes via compose ─────────────────────────

remove_containers() {
    info "Stopping and removing containers..."

    # Try compose down first (cleanest approach)
    if [ -f "$INSTALL_DIR/$COMPOSE_FILE" ] && command -v docker &> /dev/null && docker info &> /dev/null; then
        if docker compose -f "$INSTALL_DIR/$COMPOSE_FILE" --project-directory "$INSTALL_DIR" down --volumes --remove-orphans 2>/dev/null; then
            REMOVED_CONTAINERS=true
            REMOVED_VOLUMES=true
            success "Containers and volumes removed via docker compose"
            return
        else
            warn "docker compose down failed — falling back to manual removal"
        fi
    fi

    # Fallback: remove containers manually by name prefix
    if command -v docker &> /dev/null && docker info &> /dev/null; then
        local containers
        containers=$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep "^hawkra[-_]" || true)

        if [ -n "$containers" ]; then
            local removed_any=false
            while read -r container; do
                docker stop "$container" 2>/dev/null || true
                if docker rm -f "$container" 2>/dev/null; then
                    removed_any=true
                fi
            done <<< "$containers"

            if [ "$removed_any" = true ]; then
                REMOVED_CONTAINERS=true
                success "Containers removed manually"
            else
                warn "Could not remove containers — they may need manual cleanup"
            fi
        else
            info "No Hawkra containers found"
        fi
    else
        warn "Docker is not running — skipping container removal"
    fi
}

# ── Remove Docker volumes ────────────────────────────────────────────────────

remove_volumes() {
    # Skip if compose down already handled volumes
    if [ "$REMOVED_VOLUMES" = true ]; then
        return
    fi

    if ! command -v docker &> /dev/null || ! docker info &> /dev/null; then
        warn "Docker is not running — skipping volume removal"
        return
    fi

    info "Removing Docker volumes..."

    local volumes
    volumes=$(docker volume ls --format '{{.Name}}' 2>/dev/null | grep "^hawkra_" || true)

    if [ -n "$volumes" ]; then
        local removed_any=false
        while read -r volume; do
            if docker volume rm "$volume" 2>/dev/null; then
                removed_any=true
            else
                warn "Could not remove volume: $volume (may be in use)"
            fi
        done <<< "$volumes"

        if [ "$removed_any" = true ]; then
            REMOVED_VOLUMES=true
            success "Docker volumes removed"
        fi
    else
        info "No Hawkra volumes found"
    fi
}

# ── Remove Docker images ─────────────────────────────────────────────────────

remove_images() {
    if ! command -v docker &> /dev/null || ! docker info &> /dev/null; then
        warn "Docker is not running — skipping image removal"
        return
    fi

    info "Removing Docker images..."

    local removed_count=0

    # Remove Hawkra-specific images
    local hawkra_images
    hawkra_images=$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
        | grep -E "ghcr\.io/reconhawk/" || true)

    if [ -n "$hawkra_images" ]; then
        while read -r image; do
            if docker rmi "$image" 2>/dev/null; then
                removed_count=$((removed_count + 1))
            fi
        done <<< "$hawkra_images"
    fi

    # Remove the specific infrastructure images used by the compose file.
    # docker rmi will refuse to remove images still in use by other containers.
    local infra_images=("postgres:16-alpine" "redis:7-alpine" "caddy:2-alpine")
    for image in "${infra_images[@]}"; do
        if docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -qx "$image"; then
            if docker rmi "$image" 2>/dev/null; then
                removed_count=$((removed_count + 1))
            else
                info "Kept $image (in use by another container)"
            fi
        fi
    done

    if [ "$removed_count" -gt 0 ]; then
        REMOVED_IMAGES=true
        success "Removed $removed_count Docker image(s)"
    else
        info "No Hawkra images found"
    fi
}

# ── Remove /etc/hosts entry ──────────────────────────────────────────────────

remove_hosts_entry() {
    if [ -z "$APP_DOMAIN" ]; then
        return
    fi

    local escaped_domain
    escaped_domain=$(printf '%s' "$APP_DOMAIN" | sed 's/\./\\./g')

    # Check if the entry exists — match the exact format the installer writes:
    # "{ip}    {domain}" where the domain is the only hostname on the line
    if ! grep -qE "^\s*[0-9.]+\s+${escaped_domain}\s*$" /etc/hosts 2>/dev/null; then
        info "No /etc/hosts entry found for $APP_DOMAIN"
        return
    fi

    info "Removing /etc/hosts entry for $APP_DOMAIN..."

    # Create a backup before modifying
    cp /etc/hosts /etc/hosts.hawkra-backup

    # Remove only lines where this domain is the sole mapped hostname
    local tmp_hosts
    tmp_hosts=$(mktemp /tmp/hawkra-hosts-XXXXXX)

    grep -vE "^\s*[0-9.]+\s+${escaped_domain}\s*$" /etc/hosts > "$tmp_hosts" 2>/dev/null || true

    # Verify the temp file is valid (not empty — /etc/hosts should always have content)
    if [ ! -s "$tmp_hosts" ]; then
        warn "Hosts file modification produced an empty file — restoring backup"
        rm -f "$tmp_hosts"
        cp /etc/hosts.hawkra-backup /etc/hosts
        rm -f /etc/hosts.hawkra-backup
        return
    fi

    # Verify localhost entry is still present (sanity check)
    if ! grep -qE "^\s*127\.0\.0\.1\s" "$tmp_hosts" 2>/dev/null; then
        warn "Modified hosts file is missing localhost — restoring backup"
        rm -f "$tmp_hosts"
        cp /etc/hosts.hawkra-backup /etc/hosts
        rm -f /etc/hosts.hawkra-backup
        return
    fi

    # Atomic replacement with verification
    if ! cp "$tmp_hosts" /etc/hosts; then
        warn "Failed to write new /etc/hosts — restoring backup"
        cp /etc/hosts.hawkra-backup /etc/hosts
        rm -f "$tmp_hosts"
        return
    fi

    rm -f "$tmp_hosts"

    # Verify the write succeeded before removing backup
    if grep -qE "^\s*127\.0\.0\.1\s" /etc/hosts 2>/dev/null; then
        rm -f /etc/hosts.hawkra-backup
    else
        warn "Post-write verification failed — backup preserved at /etc/hosts.hawkra-backup"
    fi

    REMOVED_HOSTS_ENTRY=true
    success "Removed $APP_DOMAIN from /etc/hosts"
}

# ── Remove install directory ─────────────────────────────────────────────────

remove_install_dir() {
    if [ ! -d "$INSTALL_DIR" ]; then
        info "$INSTALL_DIR does not exist — skipping"
        return
    fi

    info "Removing $INSTALL_DIR..."
    rm -rf "$INSTALL_DIR"

    if [ -d "$INSTALL_DIR" ]; then
        warn "Could not fully remove $INSTALL_DIR — check permissions"
    else
        REMOVED_INSTALL_DIR=true
        success "Removed $INSTALL_DIR"
    fi
}

# ── Print summary ────────────────────────────────────────────────────────────

print_summary() {
    echo ""
    echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}${BOLD}  Hawkra uninstall complete${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${BOLD}Removal summary:${NC}"

    if [ "$REMOVED_CONTAINERS" = true ]; then
        echo -e "    ${GREEN}+${NC} Docker containers stopped and removed"
    else
        echo -e "    ${YELLOW}-${NC} No containers were removed"
    fi

    if [ "$REMOVED_VOLUMES" = true ]; then
        echo -e "    ${GREEN}+${NC} Docker volumes deleted (database, file storage, certs)"
    else
        echo -e "    ${YELLOW}-${NC} No volumes were removed"
    fi

    if [ "$REMOVED_IMAGES" = true ]; then
        echo -e "    ${GREEN}+${NC} Docker images removed (hawkra, postgres, redis, caddy)"
    else
        echo -e "    ${YELLOW}-${NC} No images were removed"
    fi

    if [ "$REMOVED_HOSTS_ENTRY" = true ]; then
        echo -e "    ${GREEN}+${NC} /etc/hosts entry removed ($APP_DOMAIN)"
    elif [ -n "$APP_DOMAIN" ]; then
        echo -e "    ${YELLOW}-${NC} No /etc/hosts entry was found for $APP_DOMAIN"
    else
        echo -e "    ${YELLOW}-${NC} Could not determine domain — check /etc/hosts manually"
    fi

    if [ "$REMOVED_INSTALL_DIR" = true ]; then
        echo -e "    ${GREEN}+${NC} $INSTALL_DIR deleted"
    else
        echo -e "    ${YELLOW}-${NC} $INSTALL_DIR was not removed"
    fi

    echo ""
    echo -e "  ${BOLD}Not removed:${NC}"
    echo "    - Docker itself (still installed)"
    echo "    - System packages installed by the installer (curl, openssl, etc.)"
    echo ""
    echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
    echo ""
    echo -e "${BOLD}╔═══════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║      Hawkra Self-Hosted Uninstaller       ║${NC}"
    echo -e "${BOLD}╚═══════════════════════════════════════════╝${NC}"
    echo ""

    preflight
    confirm_uninstall
    read_domain
    remove_containers
    remove_volumes
    remove_images
    remove_hosts_entry
    remove_install_dir
    print_summary
}

main "$@"
