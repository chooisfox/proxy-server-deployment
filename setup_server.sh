#!/bin/bash

# ==============================================================================
# AUTOMATED VPN SERVER SETUP (Nginx + Xray/3x-ui + Fail2Ban + SSL)
# Supported OS: Debian/Ubuntu, Rocky/Alma/CentOS, Arch Linux
# ==============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

XRAY_INTERNAL_PORT=3000
XRAY_PATH="/vless-stream"

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root. Use 'sudo -i' or 'sudo ./script.sh'"
        exit 1
    fi
}

get_public_ip() {
    curl -s https://api.ipify.org || curl -s https://ifconfig.me
}

install_packages() {
    log_info "Detecting OS and installing dependencies..."

    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
    else
        log_error "Cannot detect OS. Exiting."
        exit 1
    fi

    case $OS in
        ubuntu|debian)
            log_info "Detected Debian/Ubuntu..."
            apt-get update -y
            apt-get install -y vim nginx fail2ban certbot python3-certbot-nginx curl socat git tar
            ;;
        rocky|almalinux|centos|rhel)
            log_info "Detected RHEL-based..."
            dnf install -y epel-release
            dnf update -y
            dnf install -y vim nginx fail2ban certbot python3-certbot-nginx curl socat git tar
            ;;
        arch)
            log_info "Detected Arch Linux..."
            pacman -Syu --noconfirm
            pacman -S --noconfirm vim nginx fail2ban certbot certbot-nginx curl socat git
            ;;
        *)
            log_error "Unsupported Distribution: $OS"
            exit 1
            ;;
    esac

    systemctl enable nginx fail2ban
    systemctl start nginx
}

setup_domain_ssl() {
    log_info "Configuration Setup..."

    SERVER_IP=$(get_public_ip)
    echo -e "Detected Public IP: ${GREEN}$SERVER_IP${NC}"

    echo -e "${YELLOW}Enter your Domain Name (e.g., vpn.example.com). Leave blank to SKIP SSL setup.${NC}"
    read -p "Domain: " DOMAIN_NAME

    if [[ -z "$DOMAIN_NAME" ]]; then
        log_warn "No domain provided. Skipping SSL and HTTPS setup."
        SKIP_SSL=true
    else
        SKIP_SSL=false

        log_info "Preparing Nginx for Certbot verification..."

        systemctl start nginx

        mkdir -p /var/www/html

        log_info "Requesting SSL Certificate for $DOMAIN_NAME..."
        certbot certonly --webroot -w /var/www/html \
            --agree-tos --register-unsafely-without-email \
            --non-interactive \
            -d "$DOMAIN_NAME"

        if [[ $? -eq 0 ]]; then
            log_success "Certificate generated successfully."
        else
            log_error "Certbot failed. Please check your DNS records point to $SERVER_IP."
            SKIP_SSL=true
        fi
    fi
}

configure_nginx() {
    log_info "Generating Modern Nginx Configuration..."

    mv /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak 2>/dev/null

    cat > /etc/nginx/nginx.conf <<EOF
user nginx; # Check user (sometimes www-data on debian)
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 2048;
    multi_accept on;
}

http {
    include       mime.types;
    default_type  application/octet-stream;

    # Logging
    access_log off; # Disable access log for privacy/performance
    error_log /var/log/nginx/error.log warn;

    # Optimization
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 4096;
    client_max_body_size 16M;

    # Gzip
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css text/xml application/json application/javascript application/rss+xml application/atom+xml image/svg+xml;

    # SSL Global Settings (Modern Mozilla Profile)
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off; # Let client decide is better for compatibility if protocols are restricted

    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
EOF

    if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
        sed -i 's/user nginx;/user www-data;/' /etc/nginx/nginx.conf
    fi

    mkdir -p /etc/nginx/sites-enabled
    mkdir -p /etc/nginx/sites-available

    if [[ "$SKIP_SSL" == "true" ]]; then
        cat > /etc/nginx/sites-enabled/default.conf <<EOF
server {
    listen 80;
    server_name _;
    root /var/www/html;
    index index.html;
}
EOF
    else
        cat > /etc/nginx/sites-enabled/${DOMAIN_NAME}.conf <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN_NAME;

    # Redirect all HTTP to HTTPS
    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $DOMAIN_NAME;

    root /var/www/html;
    index index.html;

    # --- SSL Configuration (Mozilla Intermediate) ---
    ssl_certificate /etc/letsencrypt/live/${DOMAIN_NAME}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN_NAME}/privkey.pem;

    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:50m;
    ssl_session_tickets off;

    # Modern Ciphers
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;

    # HSTS (Strict Security)
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "DENY" always;

    # --- 1. Camouflage Website (Root) ---
    location / {
        try_files \$uri \$uri/ =404;
    }

    # --- 2. VLESS WebSocket/gRPC Proxy ---
    # In 3x-ui, set your inbound to listen on 127.0.0.1:${XRAY_INTERNAL_PORT}
    # and Path to ${XRAY_PATH}

    location ${XRAY_PATH} {
        if (\$http_upgrade != "websocket") {
            return 404;
        }
        proxy_redirect off;
        proxy_pass http://127.0.0.1:${XRAY_INTERNAL_PORT};

        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;

        # Real IP Forwarding
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF
    fi

    echo "<h1>Welcome to $DOMAIN_NAME</h1><p>System Operational.</p>" > /var/www/html/index.html

    log_info "Reloading Nginx..."
    systemctl restart nginx
    if [[ $? -eq 0 ]]; then
        log_success "Nginx configured and running."
    else
        log_error "Nginx failed to start. Check 'systemctl status nginx' or config syntax."
    fi
}


configure_fail2ban() {
    log_info "Configuring Fail2Ban..."

    cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 1d
findtime = 1d
maxretry = 5
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled = true
mode = aggressive
port = ssh
EOF

    systemctl restart fail2ban
    log_success "Fail2Ban active. Check status with: fail2ban-client status sshd"
}


install_3xui() {
    log_info "Installing 3x-ui Panel..."
    log_warn "The 3x-ui installer will now run. Please follow its interactive prompts."
    log_warn "If it asks for a port, use a random one (e.g., 2053) for the PANEL."

    bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
}

main() {
    clear
    echo -e "${GREEN}==========================================${NC}"
    echo -e "${GREEN}   Advanced VPN Server Setup Script       ${NC}"
    echo -e "${GREEN}==========================================${NC}"

    check_root
    install_packages
    setup_domain_ssl
    configure_nginx
    configure_fail2ban
    install_3xui

    echo -e "${GREEN}==========================================${NC}"
    echo -e "${GREEN}   INSTALLATION COMPLETE                  ${NC}"
    echo -e "${GREEN}==========================================${NC}"

    if [[ "$SKIP_SSL" == "false" ]]; then
        echo -e "Your Website:     https://${DOMAIN_NAME}"
        echo -e "VLESS Path:       ${XRAY_PATH}"
        echo -e "VLESS Internal:   127.0.0.1:${XRAY_INTERNAL_PORT}"
        echo -e "${YELLOW}IMPORTANT: In 3x-ui, create a VLESS inbound with:${NC}"
        echo -e "  - Port: ${XRAY_INTERNAL_PORT}"
        echo -e "  - Listen IP: 127.0.0.1"
        echo -e "  - Transport: WebSocket"
        echo -e "  - Path: ${XRAY_PATH}"
        echo -e "  - Security: None (Nginx handles SSL)"
    fi
}

main
