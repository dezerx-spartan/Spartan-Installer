# Spartan-Installer

Official Repo for DezerX Spartan Installer

## Overview

The DezerX Spartan Installer is an interactive Bash script designed to automate the deployment of the DezerX Spartan web application. It supports major Linux distributions including Ubuntu, Debian, CentOS, RHEL, AlmaLinux, Rocky, and Fedora.

## Features

- Interactive installation with live output
- Automated setup of PHP, NGINX/Apache, Node.js, Composer, and MySQL/MariaDB
- SSL certificate provisioning via Let's Encrypt (Certbot)
- Secure NGINX configuration with HTTP/2 and recommended headers
- Automatic environment file (.env) setup
- Systemd service for Laravel queue worker
- Cron job setup for scheduled tasks

## Usage

1. **Clone the repository:**

   ```bash
   git clone https://github.com/your-org/Spartan-Installer.git
   cd Spartan-Installer
   ```

2. **Run the installer as root:**

   ```bash
   sudo bash install.sh
   ```

3. **Follow the interactive prompts to complete the installation.**

## Requirements

- Linux server (Ubuntu/Debian/CentOS/RHEL/AlmaLinux/Rocky/Fedora)
- Root privileges
- Internet connectivity

## Troubleshooting

- Check the installer log at `/var/log/dezerx_installer.log` for details.
- Ensure all required ports (80, 443, database) are open.
- For SSL issues, verify DNS records and domain accessibility.
