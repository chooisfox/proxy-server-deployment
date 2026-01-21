#!/bin/bash

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
        log_error "This script must be run as root."
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
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -y
            apt-get install -y vim nginx fail2ban certbot python3-certbot-nginx curl socat git tar
            ;;
        rocky|almalinux|centos|rhel)
            dnf install -y epel-release
            dnf update -y
            dnf install -y vim nginx fail2ban certbot python3-certbot-nginx curl socat git tar
            ;;
        arch)
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
        log_warn "No domain provided. Skipping SSL, Hostname, and HTTPS setup."
        SKIP_SSL=true
    else
        SKIP_SSL=false

        log_info "Setting system hostname to $DOMAIN_NAME..."
        if command -v hostnamectl &> /dev/null; then
            hostnamectl set-hostname "$DOMAIN_NAME"
        else
            echo "$DOMAIN_NAME" > /etc/hostname
            hostname "$DOMAIN_NAME"
        fi

        if ! grep -q "$DOMAIN_NAME" /etc/hosts; then
            echo "127.0.0.1 $DOMAIN_NAME" >> /etc/hosts
        fi

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

    if [[ "$OS" == "arch" ]]; then
        NGINX_USER="http"
    elif [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
        NGINX_USER="www-data"
    else
        NGINX_USER="nginx"
    fi

    log_info "Configuring Nginx to run as user: $NGINX_USER"

    mkdir -p /var/www/html
    chown -R $NGINX_USER:$NGINX_USER /var/www/html
    chmod -R 755 /var/www/html

    mv /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak 2>/dev/null

    mkdir -p /etc/nginx/conf.d

    cat > /etc/nginx/nginx.conf <<EOF
user $NGINX_USER;
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

    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 4096;
    client_max_body_size 16M;

    server_tokens off;
    access_log off;
    error_log /var/log/nginx/error.log warn;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;

    include /etc/nginx/conf.d/*.conf;
}
EOF

    rm -f /etc/nginx/conf.d/default.conf
    rm -f /etc/nginx/sites-enabled/* 2>/dev/null

    CONFIG_FILE="/etc/nginx/conf.d/${DOMAIN_NAME}.conf"

    if [[ "$SKIP_SSL" == "true" ]]; then
        cat > $CONFIG_FILE <<EOF
server {
    listen 80;
    server_name _;
    root /var/www/html;
    index index.html;
}
EOF
    else
        cat > $CONFIG_FILE <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN_NAME;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $DOMAIN_NAME;

    root /var/www/html;
    index index.html;

    ssl_certificate /etc/letsencrypt/live/${DOMAIN_NAME}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN_NAME}/privkey.pem;

    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:10m;
    ssl_session_tickets off;

    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "DENY" always;

    location / {
        try_files \$uri \$uri/ =404;
    }

    location ${XRAY_PATH} {
        if (\$http_upgrade != "websocket") { return 404; }
        proxy_pass http://127.0.0.1:${XRAY_INTERNAL_PORT};
        proxy_redirect off;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF
    fi

    echo "<h1>System Operational</h1><p>Verified: $DOMAIN_NAME</p>" > /var/www/html/index.html
    chown $NGINX_USER:$NGINX_USER /var/www/html/index.html

    log_info "Reloading Nginx..."
    systemctl enable nginx
    systemctl restart nginx
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

    systemctl enable fail2ban
    systemctl restart fail2ban
    log_success "Fail2Ban active."
}

install_3xui() {
    log_info "Installing 3x-ui Panel..."
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
        echo -e "Hostname set to:  ${GREEN}$DOMAIN_NAME${NC}"
        echo -e "Web Camouflage:   https://${DOMAIN_NAME}"
        echo -e "VLESS Path:       ${YELLOW}${XRAY_PATH}${NC}"
        echo -e "VLESS Internal:   ${YELLOW}127.0.0.1:${XRAY_INTERNAL_PORT}${NC}"
        echo -e ""
        echo -e "${BLUE}INSTRUCTIONS FOR 3x-ui:${NC}"
        echo -e "1. Create a new Inbound"
        echo -e "2. Protocol: VLESS"
        echo -e "3. Port: ${XRAY_INTERNAL_PORT}"
        echo -e "4. Listen: 127.0.0.1"
        echo -e "5. Transport: WebSocket -> Path: ${XRAY_PATH}"
        echo -e "6. Security: None (Nginx handles SSL on 443)"
    fi
}

main
