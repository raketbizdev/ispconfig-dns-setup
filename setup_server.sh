#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# Colors for readability
GREEN="\033[1;32m"
RESET="\033[0m"

# Function to display informational messages
info() {
  echo -e "${GREEN}[INFO] $1${RESET}"
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

# Load configuration from a file
load_config() {
  if [[ -f "setup_config.conf" ]]; then
    source setup_config.conf
    info "Loaded configuration from setup_config.conf"
  else
    info "No configuration file found. Proceeding with dynamic inputs."
    dynamic_inputs
  fi
}

# Get dynamic inputs
dynamic_inputs() {
  read -p "Enter your domain name (e.g., raketeros.com): " DOMAIN
  read -p "Enter your hostname (e.g., mail.raketeros.com): " HOSTNAME
  read -p "Enter your server IP address: " SERVER_IP
  read -p "Enter your MySQL root password: " MYSQL_ROOT_PASSWORD
  read -p "Enter the ISPConfig database name (default: dbispconfig): " ISP_DB_NAME
  ISP_DB_NAME=${ISP_DB_NAME:-dbispconfig}
  read -p "Enter the ISPConfig database username (default: ispconfig_user): " ISP_DB_USER
  ISP_DB_USER=${ISP_DB_USER:-ispconfig_user}
  read -p "Enter the ISPConfig database password: " ISP_DB_PASSWORD
  read -p "Would you like to install SSL using Let's Encrypt? (yes/no): " INSTALL_SSL
}

# Install prerequisites
install_prerequisites() {
  info "Updating and upgrading the system..."
  sudo apt update && sudo apt upgrade -y

  info "Installing necessary packages..."
  sudo apt install -y apache2 mysql-server php-cli php-mysql php-mbstring php-xml php-curl mailutils unzip wget opendkim opendkim-tools net-tools bind9 bind9utils bind9-doc certbot python3-certbot-apache
}

# Set hostname
set_hostname() {
  info "Setting hostname to $HOSTNAME..."
  sudo hostnamectl set-hostname "$HOSTNAME"
  sudo tee /etc/hosts <<EOF > /dev/null
127.0.0.1 localhost
127.0.0.1 $HOSTNAME
$SERVER_IP $HOSTNAME
EOF
}

# Configure MySQL
configure_mysql() {
  info "Configuring MySQL..."
  sudo mysql -e "CREATE DATABASE IF NOT EXISTS $ISP_DB_NAME;"
  sudo mysql -e "CREATE USER IF NOT EXISTS '$ISP_DB_USER'@'localhost' IDENTIFIED BY '$ISP_DB_PASSWORD';"
  sudo mysql -e "GRANT ALL PRIVILEGES ON $ISP_DB_NAME.* TO '$ISP_DB_USER'@'localhost';"
  sudo mysql -e "FLUSH PRIVILEGES;"
}

# Install ISPConfig
install_ispconfig() {
  info "Installing ISPConfig..."
  cd /tmp
  wget -O ispconfig.tar.gz https://www.ispconfig.org/downloads/ISPConfig-3-stable.tar.gz
  tar -xzvf ispconfig.tar.gz
  cd ispconfig3_install/install/
  sudo php -q install.php
}

# Configure Postfix
configure_postfix() {
  info "Configuring Postfix..."
  sudo debconf-set-selections <<< "postfix postfix/mailname string $DOMAIN"
  sudo debconf-set-selections <<< "postfix postfix/main_mailer_type string 'Internet Site'"
  sudo systemctl restart postfix
}

# Configure OpenDKIM
configure_opendkim() {
  info "Setting up OpenDKIM..."
  ensure_directory "/etc/opendkim/keys/$DOMAIN"
  cd "/etc/opendkim/keys/$DOMAIN"

  if [[ ! -f "mail.private" ]]; then
    info "Generating DKIM keys..."
    sudo opendkim-genkey -s mail -d "$DOMAIN"
  fi

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
AutoRestartRate 10/1h
UMask 002
PidFile /var/run/opendkim/opendkim.pid
TrustAnchorFile /etc/ssl/certs/ca-certificates.crt
EOF

  sudo tee /etc/opendkim/TrustedHosts <<EOF > /dev/null
127.0.0.1
localhost
$SERVER_IP
$DOMAIN
EOF

  sudo systemctl restart opendkim postfix
}

# Configure Bind9 for Name Servers
configure_bind9() {
  info "Configuring Bind9 for ns1 and ns2..."
  sudo tee /etc/bind/named.conf.local <<EOF > /dev/null
zone "$DOMAIN" {
    type master;
    file "/etc/bind/db.$DOMAIN";
};
EOF

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
mail    IN      A       $SERVER_IP
@       IN      MX      10 mail.$DOMAIN.
EOF

  sudo systemctl restart bind9
}

# Install SSL
install_ssl() {
  if [[ "$INSTALL_SSL" == "yes" ]]; then
    info "Installing SSL with Let's Encrypt..."
    sudo certbot --apache -d "$HOSTNAME" -d "$DOMAIN"
  fi
}

# Menu for selective task execution
show_menu() {
  echo "Select an option:"
  select option in "Install Prerequisites" "Set Hostname" "Configure MySQL" "Install ISPConfig" "Configure Postfix" "Configure OpenDKIM" "Configure Bind9" "Install SSL" "Exit"; do
    case $REPLY in
      1) install_prerequisites ;;
      2) set_hostname ;;
      3) configure_mysql ;;
      4) install_ispconfig ;;
      5) configure_postfix ;;
      6) configure_opendkim ;;
      7) configure_bind9 ;;
      8) install_ssl ;;
      9) exit ;;
      *) echo "Invalid option." ;;
    esac
  done
}

# Main execution
load_config
show_menu