#!/usr/bin/env bash
# Hawkra Self-Hosted Installer
# Automates the full deployment on Debian/Ubuntu and Fedora Linux.
# Usage: sudo bash install.sh

set -euo pipefail

# ── Constants ────────────────────────────────────────────────────────────────

INSTALL_DIR="/opt/hawkra"
REPO_TARBALL="https://github.com/reconhawklabs/Hawkra-Selfhosted/archive/refs/heads/main.tar.gz"
COMPOSE_FILE="docker-compose.selfhosted.yml"
BACKEND_HEALTH_TIMEOUT=120  # seconds
TMP_DIR=""

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

# ── Cleanup trap ─────────────────────────────────────────────────────────────

cleanup() {
    local exit_code=$?
    rm -rf "${TMP_DIR:-}"
    if [ $exit_code -ne 0 ]; then
        echo ""
        echo -e "${RED}[-]${NC} Installation failed at step: ${CURRENT_STEP:-unknown}. Check the output above for details."
    fi
}
trap cleanup EXIT
CURRENT_STEP="init"

# ── Pre-flight checks ───────────────────────────────────────────────────────

preflight() {
    CURRENT_STEP="pre-flight checks"
    info "Running pre-flight checks..."

    # Verify stdin is a terminal (not piped)
    if [ ! -t 0 ]; then
        fail "This script requires an interactive terminal. Run it directly: sudo bash install.sh"
    fi

    # Root check
    if [ "$(id -u)" -ne 0 ]; then
        fail "This script must be run as root. Use: sudo bash install.sh"
    fi

    # Architecture check
    local arch
    arch=$(uname -m)
    if [ "$arch" != "x86_64" ] && [ "$arch" != "aarch64" ]; then
        fail "Unsupported architecture: $arch. Hawkra requires x86_64 or aarch64."
    fi

    # Detect distro
    if [ ! -f /etc/os-release ]; then
        fail "Cannot detect Linux distribution. /etc/os-release not found."
    fi

    # shellcheck source=/dev/null
    . /etc/os-release
    DISTRO_ID="${ID:-unknown}"
    DISTRO_VERSION="${VERSION_CODENAME:-}"

    case "$DISTRO_ID" in
        ubuntu|debian)
            PKG_MANAGER="apt"
            # Ensure VERSION_CODENAME is set
            if [ -z "$DISTRO_VERSION" ]; then
                DISTRO_VERSION=$(lsb_release -cs 2>/dev/null || true)
            fi
            if [ -z "$DISTRO_VERSION" ]; then
                fail "Cannot determine distribution codename. Set VERSION_CODENAME in /etc/os-release or install lsb-release."
            fi
            ;;
        fedora)
            PKG_MANAGER="dnf"
            ;;
        *)
            fail "Unsupported distribution: $DISTRO_ID. This installer supports Ubuntu, Debian, and Fedora."
            ;;
    esac

    success "Detected $DISTRO_ID ($PKG_MANAGER) on $arch"

    # Check for existing installation
    EXISTING_INSTALL=false
    if [ -f "$INSTALL_DIR/.env" ]; then
        EXISTING_INSTALL=true
        warn "An existing Hawkra installation was found at $INSTALL_DIR."
        echo ""
        read -rp "    Overwrite configuration? Existing Docker volumes (data) will be preserved. [y/N]: " overwrite
        if [[ ! "$overwrite" =~ ^[Yy]$ ]]; then
            echo ""
            info "Installation cancelled. Your existing installation is untouched."
            exit 0
        fi
        echo ""
    fi
}

# ── Install prerequisites ───────────────────────────────────────────────────

install_prereqs() {
    CURRENT_STEP="installing prerequisites"
    info "Installing prerequisites..."

    case "$PKG_MANAGER" in
        apt)
            apt-get update -qq
            apt-get install -y -qq curl ca-certificates gnupg openssl > /dev/null 2>&1
            ;;
        dnf)
            dnf install -y -q curl ca-certificates gnupg2 openssl > /dev/null 2>&1
            ;;
    esac

    success "Prerequisites installed"
}

# ── Install Docker ───────────────────────────────────────────────────────────

install_docker() {
    CURRENT_STEP="installing Docker"

    # Check if Docker is already installed and running
    if command -v docker &> /dev/null && docker info &> /dev/null; then
        # Verify compose plugin
        if docker compose version &> /dev/null; then
            success "Docker and Docker Compose already installed — skipping"
            return
        else
            info "Docker found but Compose plugin missing — installing..."
        fi
    else
        info "Installing Docker..."
    fi

    case "$PKG_MANAGER" in
        apt)
            install -m 0755 -d /etc/apt/keyrings

            curl -fsSL "https://download.docker.com/linux/${DISTRO_ID}/gpg" \
                | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
            chmod a+r /etc/apt/keyrings/docker.gpg

            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${DISTRO_ID} ${DISTRO_VERSION} stable" \
                | tee /etc/apt/sources.list.d/docker.list > /dev/null

            apt-get update -qq
            apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
                docker-buildx-plugin docker-compose-plugin > /dev/null 2>&1
            ;;
        dnf)
            dnf -y -q install dnf-plugins-core > /dev/null 2>&1

            # Use --add-repo (works on DNF4 and has a compatibility shim in DNF5)
            dnf config-manager --add-repo \
                https://download.docker.com/linux/fedora/docker-ce.repo 2>/dev/null \
                || dnf config-manager addrepo \
                    --from-repofile=https://download.docker.com/linux/fedora/docker-ce.repo 2>/dev/null \
                || fail "Failed to add Docker repository. Check your Fedora version."

            dnf install -y -q docker-ce docker-ce-cli containerd.io \
                docker-buildx-plugin docker-compose-plugin > /dev/null 2>&1
            ;;
    esac

    systemctl enable --now docker > /dev/null 2>&1

    # Verify
    if ! docker compose version &> /dev/null; then
        fail "Docker Compose plugin failed to install. Check your package manager output."
    fi

    success "Docker installed and running"
}

# ── Prompt for domain ────────────────────────────────────────────────────────

prompt_domain() {
    CURRENT_STEP="domain configuration"
    local current_hostname
    current_hostname=$(hostname -f 2>/dev/null || hostname)

    echo ""
    echo -e "${BOLD}Domain Configuration${NC}"
    echo "  Hawkra requires a domain name for TLS certificates."
    echo "  Your server's current hostname is: ${BOLD}${current_hostname}${NC}"
    echo ""
    echo "  1) Use current hostname: $current_hostname"
    echo "  2) Enter a custom domain"
    echo ""
    read -rp "  Choose [1/2] (default: 1): " domain_choice

    case "${domain_choice:-1}" in
        2)
            read -rp "  Enter domain (e.g., hawkra.yourcompany.local): " custom_domain
            if [ -z "$custom_domain" ]; then
                fail "No domain provided."
            fi
            # Validate domain format
            if [[ ! "$custom_domain" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
                fail "Invalid domain format: '$custom_domain'. Use only letters, numbers, dots, and hyphens."
            fi
            APP_DOMAIN="$custom_domain"
            ;;
        *)
            APP_DOMAIN="$current_hostname"
            ;;
    esac

    echo ""
    success "Using domain: $APP_DOMAIN"

    # Add to /etc/hosts if not already present
    ensure_hosts_entry
}

ensure_hosts_entry() {
    # Escape dots in the domain for regex matching
    local escaped_domain
    escaped_domain=$(printf '%s' "$APP_DOMAIN" | sed 's/\./\\./g')

    # Check if the domain already exists in /etc/hosts (as a whole word, not a substring)
    if grep -qE "^\s*[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\s+(\S+\s+)*${escaped_domain}(\s|$)" /etc/hosts 2>/dev/null; then
        success "$APP_DOMAIN already present in /etc/hosts"
        return
    fi

    # Get the server's primary LAN IP
    local lan_ip
    lan_ip=$(hostname -I 2>/dev/null | awk '{print $1}')

    if [ -z "$lan_ip" ]; then
        warn "Could not detect LAN IP. You may need to manually add $APP_DOMAIN to /etc/hosts."
        return
    fi

    echo "$lan_ip    $APP_DOMAIN" >> /etc/hosts
    success "Added $APP_DOMAIN -> $lan_ip to /etc/hosts"
}

# ── Download client package ──────────────────────────────────────────────────

download_package() {
    CURRENT_STEP="downloading client package"
    info "Downloading Hawkra client package..."

    # Create install directory structure
    mkdir -p "$INSTALL_DIR"/{license,caddy,certs}

    # Download and extract from GitHub
    local tmp_tar
    tmp_tar=$(mktemp /tmp/hawkra-pkg-XXXXXX.tar.gz)

    if ! curl -fsSL "$REPO_TARBALL" -o "$tmp_tar"; then
        rm -f "$tmp_tar"
        fail "Failed to download client package from GitHub. Check your internet connection."
    fi

    # Extract into a temp directory, then copy files to install dir
    TMP_DIR=$(mktemp -d /tmp/hawkra-extract-XXXXXX)

    tar -xzf "$tmp_tar" -C "$TMP_DIR" --strip-components=1
    rm -f "$tmp_tar"

    # Copy deployment files
    cp -f "$TMP_DIR/$COMPOSE_FILE"              "$INSTALL_DIR/$COMPOSE_FILE"
    cp -f "$TMP_DIR/Caddyfile"                  "$INSTALL_DIR/Caddyfile"
    cp -f "$TMP_DIR/caddy/docker-entrypoint.sh" "$INSTALL_DIR/caddy/docker-entrypoint.sh"

    # Copy trial license if present and no license exists yet
    if [ ! -f "$INSTALL_DIR/license/license.key" ]; then
        if [ -f "$TMP_DIR/license/license.key" ]; then
            cp -f "$TMP_DIR/license/license.key" "$INSTALL_DIR/license/license.key"
            info "Trial license copied. Replace with your production license after setup."
        fi
    fi

    rm -rf "$TMP_DIR"
    TMP_DIR=""
    success "Client package deployed to $INSTALL_DIR"
}

# ── Generate .env ────────────────────────────────────────────────────────────

generate_env() {
    CURRENT_STEP="generating environment file"
    info "Generating .env configuration..."

    # Preserve existing database password on re-install to avoid breaking the database
    local pg_password=""
    if [ "$EXISTING_INSTALL" = true ] && [ -f "$INSTALL_DIR/.env" ]; then
        pg_password=$(grep -oP '(?<=^POSTGRES_PASSWORD=).+' "$INSTALL_DIR/.env" 2>/dev/null || true)
    fi
    if [ -z "$pg_password" ]; then
        pg_password=$(openssl rand -hex 32)
    fi

    cat > "$INSTALL_DIR/.env" <<EOF
# Hawkra Self-Hosted Configuration
# Generated by install.sh on $(date -u +"%Y-%m-%d %H:%M:%S UTC")

# Domain
APP_DOMAIN=${APP_DOMAIN}

# Database
POSTGRES_PASSWORD=${pg_password}

# URLs (derived from APP_DOMAIN)
FRONTEND_URL=https://${APP_DOMAIN}
BACKEND_URL=https://${APP_DOMAIN}
CORS_ALLOWED_ORIGINS=https://${APP_DOMAIN}
COOKIE_DOMAIN=${APP_DOMAIN}
COOKIE_SECURE=true
EOF

    chmod 600 "$INSTALL_DIR/.env"
    success "Environment file created"
}

# ── Fix permissions ──────────────────────────────────────────────────────────

fix_permissions() {
    CURRENT_STEP="setting file permissions"
    info "Setting file permissions..."

    chmod +x  "$INSTALL_DIR/caddy/docker-entrypoint.sh"
    chmod 755 "$INSTALL_DIR/license"

    if [ -f "$INSTALL_DIR/license/license.key" ]; then
        chmod 644 "$INSTALL_DIR/license/license.key"
    fi

    if [ -f "$INSTALL_DIR/certs/cert.pem" ]; then
        chmod 644 "$INSTALL_DIR/certs/cert.pem"
    fi
    if [ -f "$INSTALL_DIR/certs/key.pem" ]; then
        chmod 600 "$INSTALL_DIR/certs/key.pem"
    fi

    # SELinux: relabel bind-mount paths so containers can access them
    if command -v getenforce &> /dev/null && [ "$(getenforce 2>/dev/null)" = "Enforcing" ]; then
        info "SELinux detected — relabelling bind-mount paths..."
        chcon -Rt svirt_sandbox_file_t "$INSTALL_DIR/license"  2>/dev/null || true
        chcon -Rt svirt_sandbox_file_t "$INSTALL_DIR/caddy"    2>/dev/null || true
        chcon -Rt svirt_sandbox_file_t "$INSTALL_DIR/Caddyfile" 2>/dev/null || true
        chcon -Rt svirt_sandbox_file_t "$INSTALL_DIR/certs"    2>/dev/null || true
        success "SELinux labels applied"
    fi

    success "Permissions set"
}

# ── Pull images ──────────────────────────────────────────────────────────────

pull_images() {
    CURRENT_STEP="pulling container images"
    info "Pulling container images (this may take a few minutes)..."

    cd "$INSTALL_DIR"
    docker compose -f "$COMPOSE_FILE" pull

    success "All images pulled"
}

# ── Start containers ─────────────────────────────────────────────────────────

start_containers() {
    CURRENT_STEP="starting containers"
    info "Starting Hawkra..."

    cd "$INSTALL_DIR"
    docker compose -f "$COMPOSE_FILE" up -d

    success "Containers started"
}

# ── Wait for backend to be healthy ───────────────────────────────────────────

wait_for_backend() {
    CURRENT_STEP="waiting for backend"
    info "Waiting for backend to become ready (up to ${BACKEND_HEALTH_TIMEOUT}s)..."

    local elapsed=0
    local interval=5

    cd "$INSTALL_DIR"
    while [ $elapsed -lt $BACKEND_HEALTH_TIMEOUT ]; do
        # Check if the backend has produced the admin user creation log
        if docker compose -f "$COMPOSE_FILE" logs --tail=100 backend 2>/dev/null | grep -qi "admin.*password\|password.*admin"; then
            success "Backend is ready"
            return
        fi

        # Check if the container has exited/crashed
        local state
        state=$(docker compose -f "$COMPOSE_FILE" ps backend --format '{{.State}}' 2>/dev/null || true)

        if [ "$state" = "exited" ] || [ "$state" = "dead" ]; then
            echo ""
            warn "Backend container exited unexpectedly. Logs:"
            docker compose -f "$COMPOSE_FILE" logs --tail=30 backend
            fail "Backend failed to start. See logs above."
        fi

        sleep $interval
        elapsed=$((elapsed + interval))
        printf "\r    ... %ds elapsed" "$elapsed"
    done

    echo ""
    warn "Backend did not produce credentials within ${BACKEND_HEALTH_TIMEOUT}s."
    warn "It may still be starting. Check logs with:"
    echo "    cd $INSTALL_DIR && docker compose -f $COMPOSE_FILE logs -f backend"
    ADMIN_PASSWORD=""
}

# ── Extract admin password ───────────────────────────────────────────────────

extract_password() {
    CURRENT_STEP="extracting admin credentials"

    cd "$INSTALL_DIR"

    # Try Perl-compatible regex first (grep -P)
    ADMIN_PASSWORD=$(docker compose -f "$COMPOSE_FILE" logs backend 2>/dev/null \
        | grep -i "password" | head -1 \
        | grep -oP '(?<=password:\s).+' 2>/dev/null || true)

    # Fallback: sed-based extraction
    if [ -z "$ADMIN_PASSWORD" ]; then
        ADMIN_PASSWORD=$(docker compose -f "$COMPOSE_FILE" logs backend 2>/dev/null \
            | grep -i "password" | head -1 \
            | sed 's/.*[Pp]assword[: ]*//' | xargs 2>/dev/null || true)
    fi

    if [ -z "$ADMIN_PASSWORD" ]; then
        ADMIN_PASSWORD=""
    fi
}

# ── Print summary ────────────────────────────────────────────────────────────

print_summary() {
    local url="https://${APP_DOMAIN}"

    echo ""
    echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}${BOLD}  Hawkra installation complete!${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${BOLD}URL:${NC}        $url/login"
    echo -e "  ${BOLD}Admin:${NC}      admin@hawkra.local"

    if [ -n "$ADMIN_PASSWORD" ]; then
        echo -e "  ${BOLD}Password:${NC}   $ADMIN_PASSWORD"
    else
        echo -e "  ${BOLD}Password:${NC}   Run the following command to retrieve it:"
        echo "              docker compose -f $INSTALL_DIR/$COMPOSE_FILE logs backend | grep -i password"
    fi

    echo ""
    echo -e "  ${BOLD}Next steps:${NC}"
    echo "    1. Open the URL above in your browser"
    echo "    2. Accept the self-signed certificate warning (if applicable)"
    echo "    3. Log in with the admin credentials above"
    echo "    4. Upload your license file when prompted"
    echo "    5. Click \"Complete Setup\""
    echo "    6. Change the default admin password in Account Settings"
    echo ""
    echo -e "  ${BOLD}Installation directory:${NC} $INSTALL_DIR"
    echo -e "  ${BOLD}View logs:${NC}             cd $INSTALL_DIR && docker compose -f $COMPOSE_FILE logs -f"
    echo ""
    echo -e "  See the deployment guide for SMTP, AI, and MFA configuration."
    echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
    echo ""
    echo -e "${BOLD}╔═══════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║       Hawkra Self-Hosted Installer        ║${NC}"
    echo -e "${BOLD}╚═══════════════════════════════════════════╝${NC}"
    echo ""

    preflight
    install_prereqs
    install_docker
    prompt_domain
    download_package
    generate_env
    fix_permissions
    pull_images
    start_containers
    wait_for_backend
    extract_password
    print_summary
}

main "$@"
