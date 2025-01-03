#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# Colors for readability
GREEN="\033[1;32m"
RESET="\033[0m"

# Log file for debugging
LOGFILE="/var/log/setup_server.log"

# Function to log messages
log() {
  echo "$(date +'%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOGFILE"
}

# Function to display informational messages
info() {
  echo -e "${GREEN}[INFO] $1${RESET}"
  log "[INFO] $1"
}

# Function to check and create directory
ensure_directory() {
  local dir=$1
  if [[ ! -d $dir ]]; then
    info "Creating directory: $dir"
    sudo mkdir -p "$dir"
  else
    info "Directory already exists: $dir"
  fi
}

# Function to check and create file
ensure_file() {
  local file=$1
  if [[ ! -f $file ]]; then
    info "Creating file: $file"
    sudo touch "$file"
  else
    info "File already exists: $file"
  fi
}

# Perform system update and install prerequisites
install_prerequisites() {
  info "Updating and upgrading the system..."
  sudo apt update && sudo apt upgrade -y

  info "Installing necessary packages..."
  sudo apt install -y apache2 mysql-server php-cli php-mysql php-mbstring php-xml php-curl mailutils unzip wget opendkim opendkim-tools net-tools bind9 bind9utils bind9-doc certbot python3-certbot-apache
}

# Get dynamic inputs
read_inputs() {
  read -p "Enter your primary domain name (e.g., raketeros.com): " DOMAIN
  read -p "Enter your server IP address (e.g., 68.183.238.52): " SERVER_IP
  read -p "Enter your MySQL root password: " MYSQL_ROOT_PASSWORD
  read -p "Enter the ISPConfig database name (default: dbispconfig): " ISP_DB_NAME
  ISP_DB_NAME=${ISP_DB_NAME:-dbispconfig}
  read -p "Enter the ISPConfig database username (default: ispconfig_user): " ISP_DB_USER
  ISP_DB_USER=${ISP_DB_USER:-ispconfig_user}
  read -p "Enter the ISPConfig database password: " ISP_DB_PASSWORD
  read -p "Would you like to install SSL using Let's Encrypt? (yes/no): " INSTALL_SSL
}

# Set hostname
set_hostname() {
  info "Setting hostname to server.$DOMAIN..."
  sudo hostnamectl set-hostname "server.$DOMAIN"
  sudo tee /etc/hosts <<EOF > /dev/null
127.0.0.1 localhost
127.0.0.1 server.$DOMAIN
$SERVER_IP server.$DOMAIN
EOF
}

# Configure Bind9 for NS and DNS Zones
configure_bind9() {
  info "Configuring Bind9 for ns1 and ns2..."
  sudo tee /etc/bind/named.conf.local <<EOF > /dev/null
zone "$DOMAIN" {
    type master;
    file "/etc/bind/db.$DOMAIN";
};

zone "mail.$DOMAIN" {
    type master;
    file "/etc/bind/db.mail.$DOMAIN";
};
EOF

  # Main domain zone file
  sudo tee /etc/bind/db.$DOMAIN <<EOF > /dev/null
\$TTL    604800
@       IN      SOA     ns1.$DOMAIN. admin.$DOMAIN. (
                              2         ; Serial
                         604800         ; Refresh
                          86400         ; Retry
                        2419200         ; Expire
                         604800 )       ; Negative Cache TTL
;
@       IN      NS      ns1.$DOMAIN.
@       IN      NS      ns2.$DOMAIN.
@       IN      A       $SERVER_IP
ns1     IN      A       $SERVER_IP
ns2     IN      A       $SERVER_IP
server  IN      A       $SERVER_IP
mail    IN      A       $SERVER_IP
@       IN      MX      10 mail.$DOMAIN.
EOF

  # Mail-specific zone file
  sudo tee /etc/bind/db.mail.$DOMAIN <<EOF > /dev/null
\$TTL    604800
@       IN      SOA     ns1.$DOMAIN. admin.$DOMAIN. (
                              2         ; Serial
                         604800         ; Refresh
                          86400         ; Retry
                        2419200         ; Expire
                         604800 )       ; Negative Cache TTL
;
@       IN      NS      ns1.$DOMAIN.
@       IN      NS      ns2.$DOMAIN.
@       IN      A       $SERVER_IP
EOF

  sudo systemctl restart bind9
}

# Configure Postfix and DKIM
configure_postfix_dkim() {
  info "Setting up Postfix and OpenDKIM..."
  sudo apt install -y opendkim opendkim-tools
  ensure_directory "/etc/opendkim/keys/$DOMAIN"
  cd "/etc/opendkim/keys/$DOMAIN"
  sudo opendkim-genkey -s mail -d "$DOMAIN"
  sudo chown -R opendkim:opendkim /etc/opendkim

  sudo tee /etc/opendkim.conf <<EOF > /dev/null
Syslog yes
LogWhy yes
Domain $DOMAIN
KeyFile /etc/opendkim/keys/$DOMAIN/mail.private
Selector mail
Socket local:/var/spool/postfix/opendkim/opendkim.sock
Canonicalization relaxed/simple
OversignHeaders From
AutoRestart Yes
EOF

  sudo tee /etc/opendkim/TrustedHosts <<EOF > /dev/null
127.0.0.1
localhost
$SERVER_IP
$DOMAIN
EOF

  sudo systemctl restart opendkim postfix
}

# Install SSL
install_ssl() {
  if [[ "$INSTALL_SSL" == "yes" ]]; then
    info "Installing SSL with Let's Encrypt..."
    sudo certbot --apache -d "server.$DOMAIN" -d "$DOMAIN" -d "mail.$DOMAIN"
  fi
}

# Final instructions
final_instructions() {
  info "Installation complete!"
  echo "Primary domain is accessible at: https://server.$DOMAIN"
  echo "Mail MX record points to: mail.$DOMAIN"
  echo "Update your domain provider's nameservers to:"
  echo "ns1.$DOMAIN - $SERVER_IP"
  echo "ns2.$DOMAIN - $SERVER_IP"
}

# Main Execution
log "Starting server setup script"
install_prerequisites
read_inputs
set_hostname
configure_bind9
configure_postfix_dkim
install_ssl
final_instructions
log "Server setup script completed successfully"