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

# Set hostname and update /etc/hosts
set_hostname() {
  local hostname="server.$DOMAIN"
  info "Setting hostname to $hostname..."
  sudo hostnamectl set-hostname "$hostname"

  info "Updating /etc/hosts..."
  sudo tee /etc/hosts <<EOF > /dev/null
127.0.0.1 localhost
127.0.1.1 $hostname
$SERVER_IP $hostname
EOF

  # Test hostname resolution
  if ! ping -c 1 "$hostname" &>/dev/null; then
    log "Hostname resolution failed for $hostname. Check /etc/hosts configuration."
    echo "Error: Hostname resolution failed for $hostname. Ensure /etc/hosts is correct."
    exit 1
  fi

  info "Hostname and /etc/hosts updated successfully."
}


# Configure Bind9 for NS and DNS Zones
configure_bind9() {
  info "Configuring Bind9 for ns1 and ns2..."

  # Write named.conf.local
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
                              $(date +%Y%m%d%H) ; Serial
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
                              $(date +%Y%m%d%H) ; Serial
                         604800         ; Refresh
                          86400         ; Retry
                        2419200         ; Expire
                         604800 )       ; Negative Cache TTL
;
@       IN      NS      ns1.$DOMAIN.
@       IN      NS      ns2.$DOMAIN.
@       IN      A       $SERVER_IP
EOF

  # Validate Bind9 configuration
  if ! sudo named-checkconf &>/dev/null; then
    log "Bind9 configuration validation failed. Check named.conf.local."
    echo "Error: Bind9 configuration validation failed. Run 'sudo named-checkconf'."
    exit 1
  fi

  # Validate each zone file
  if ! sudo named-checkzone "$DOMAIN" /etc/bind/db."$DOMAIN" &>/dev/null; then
    log "Zone validation failed for $DOMAIN. Check /etc/bind/db.$DOMAIN."
    echo "Error: Zone validation failed for $DOMAIN. Run 'sudo named-checkzone'."
    exit 1
  fi

  if ! sudo named-checkzone "mail.$DOMAIN" /etc/bind/db.mail."$DOMAIN" &>/dev/null; then
    log "Zone validation failed for mail.$DOMAIN. Check /etc/bind/db.mail.$DOMAIN."
    echo "Error: Zone validation failed for mail.$DOMAIN. Run 'sudo named-checkzone'."
    exit 1
  fi

  # Restart Bind9
  info "Restarting Bind9 service..."
  sudo systemctl restart bind9

  # Check Bind9 status
  if systemctl is-active --quiet bind9; then
    info "Bind9 restarted successfully."
  else
    log "Bind9 failed to restart. Check /var/log/syslog for details."
    echo "Error: Bind9 failed to restart. Use 'journalctl -xeu bind9.service' to debug."
    exit 1
  fi
}

configure_postfix_dkim() {
  info "Setting up Postfix and OpenDKIM..."
  
  # Install OpenDKIM
  sudo apt install -y opendkim opendkim-tools

  # Create necessary directories
  ensure_directory "/etc/opendkim/keys/$DOMAIN"

  # Generate DKIM keys
  cd "/etc/opendkim/keys/$DOMAIN"
  sudo opendkim-genkey -s mail -d "$DOMAIN"
  sudo chown -R opendkim:opendkim /etc/opendkim
  sudo chmod -R 700 /etc/opendkim

  # Configure OpenDKIM
  sudo tee /etc/opendkim.conf <<EOF > /dev/null
Syslog                  yes
LogWhy                  yes
UMask                   002
Domain                  $DOMAIN
KeyTable                /etc/opendkim/key.table
SigningTable            /etc/opendkim/signing.table
ExternalIgnoreList      /etc/opendkim/trusted.hosts
InternalHosts           /etc/opendkim/trusted.hosts
Socket                  local:/var/spool/postfix/opendkim/opendkim.sock
Canonicalization        relaxed/simple
OversignHeaders         From
AutoRestart             yes
PidFile                 /var/run/opendkim/opendkim.pid
EOF

  # Configure key table, signing table, and trusted hosts
  sudo tee /etc/opendkim/key.table <<EOF > /dev/null
mail._domainkey.$DOMAIN $DOMAIN:mail:/etc/opendkim/keys/$DOMAIN/mail.private
EOF

  sudo tee /etc/opendkim/signing.table <<EOF > /dev/null
*@${DOMAIN} mail._domainkey.$DOMAIN
EOF

  sudo tee /etc/opendkim/trusted.hosts <<EOF > /dev/null
127.0.0.1
localhost
$SERVER_IP
$DOMAIN
EOF

  # Restart OpenDKIM and Postfix
  sudo systemctl restart opendkim || {
    log "OpenDKIM failed to restart. Check /var/log/syslog for details."
    echo "Error: OpenDKIM failed to restart. Run 'sudo journalctl -xeu opendkim.service' to debug."
    exit 1
  }

  sudo systemctl restart postfix || {
    log "Postfix failed to restart. Check /var/log/mail.log for details."
    echo "Error: Postfix failed to restart. Run 'sudo journalctl -xeu postfix.service' to debug."
    exit 1
  }

  info "Postfix and OpenDKIM configured successfully."
}

# Install SSL
install_ssl() {
  if [[ "$INSTALL_SSL" == "yes" ]]; then
    info "Checking DNS records for $DOMAIN and mail.$DOMAIN..."

    local dns_errors=false

    # Check DNS A record for the primary domain
    if ! dig +short "$DOMAIN" | grep -q "$SERVER_IP"; then
      log "DNS record for $DOMAIN is not pointing to $SERVER_IP."
      echo "Warning: DNS record for $DOMAIN is missing or incorrect."
      echo "Instructions to fix:"
      echo "  1. Log in to your domain registrar's DNS management panel."
      echo "  2. Add or update an A record for $DOMAIN:"
      echo "     - Name: @"
      echo "     - Type: A"
      echo "     - Value: $SERVER_IP"
      echo "  3. Wait for DNS propagation (can take up to 24 hours)."
      echo "  4. Verify the DNS record with:"
      echo "     dig +short $DOMAIN"
      dns_errors=true
    fi

    # Check DNS A record for the mail subdomain
    if ! dig +short "mail.$DOMAIN" | grep -q "$SERVER_IP"; then
      log "DNS record for mail.$DOMAIN is not pointing to $SERVER_IP."
      echo "Warning: DNS record for mail.$DOMAIN is missing or incorrect."
      echo "Instructions to fix:"
      echo "  1. Log in to your domain registrar's DNS management panel."
      echo "  2. Add or update an A record for mail.$DOMAIN:"
      echo "     - Name: mail"
      echo "     - Type: A"
      echo "     - Value: $SERVER_IP"
      echo "  3. Wait for DNS propagation (can take up to 24 hours)."
      echo "  4. Verify the DNS record with:"
      echo "     dig +short mail.$DOMAIN"
      dns_errors=true
    fi

    # If there are DNS errors, skip SSL installation
    if [[ "$dns_errors" == true ]]; then
      log "Skipping SSL installation due to DNS errors."
      echo "Note: SSL installation has been skipped. Resolve the DNS issues above and re-run the script to install SSL."
      return
    fi

    # Proceed with SSL installation
    info "DNS records verified. Proceeding with SSL installation..."
    sudo certbot --apache -d "server.$DOMAIN" -d "$DOMAIN" -d "mail.$DOMAIN" || {
      log "Certbot failed to issue certificates. Check /var/log/letsencrypt/letsencrypt.log for details."
      echo "Error: Certbot failed. Verify DNS records and retry."
    }

    info "SSL certificates installed successfully."
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