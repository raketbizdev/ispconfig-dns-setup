#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# Colors for readability
GREEN="\033[1;32m"
RESET="\033[0m"
RED="\033[1;31m"

# Log file for debugging
LOGFILE="/var/log/ispconfig_installation.log"

# Function to log messages
log() {
  echo "$(date +'%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOGFILE"
}

# Function to display informational messages
info() {
  echo -e "${GREEN}[INFO] $1${RESET}"
  log "[INFO] $1"
}

# Function to display error messages
error() {
  echo -e "${RED}[ERROR] $1${RESET}"
  log "[ERROR] $1"
  exit 1
}

# Ensure script is run as root
if [[ $EUID -ne 0 ]]; then
  error "This script must be run as root. Use sudo ./install_ispconfig.sh"
fi

# Variables for ISPConfig installation
ISP_CONFIG_DOWNLOAD_URL="https://www.ispconfig.org/downloads/ISPConfig-3-stable.tar.gz"
ISP_CONFIG_INSTALL_DIR="/tmp/ispconfig3_install"

# Update system and install required packages
install_prerequisites() {
  info "Updating the system and installing required packages..."
  apt update && apt upgrade -y
  apt install -y wget tar php-cli apache2 mysql-server
}

# Download ISPConfig
download_ispconfig() {
  info "Downloading ISPConfig..."
  wget -O /tmp/ispconfig.tar.gz "$ISP_CONFIG_DOWNLOAD_URL"

  info "Extracting ISPConfig installer..."
  mkdir -p "$ISP_CONFIG_INSTALL_DIR"
  tar -xvzf /tmp/ispconfig.tar.gz -C "$ISP_CONFIG_INSTALL_DIR"
}

# Install ISPConfig
install_ispconfig() {
  info "Starting ISPConfig installation..."
  cd "$ISP_CONFIG_INSTALL_DIR/install/"

  # Run ISPConfig installer
  php install.php || error "ISPConfig installation failed. Check the logs for details."

  info "ISPConfig installation completed successfully."
}

# Clean up temporary files
cleanup() {
  info "Cleaning up temporary installation files..."
  rm -rf /tmp/ispconfig.tar.gz "$ISP_CONFIG_INSTALL_DIR"
}

# Final message
final_instructions() {
  info "Installation complete!"
  echo "Access ISPConfig at: https://<your-domain-or-ip>:8080"
  echo "Login using the credentials set during installation."
}

# Main script execution
log "Starting ISPConfig installation script"
install_prerequisites
download_ispconfig
install_ispconfig
cleanup
final_instructions
log "ISPConfig installation script completed successfully"