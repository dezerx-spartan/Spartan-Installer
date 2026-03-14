# Spartan-Installer (Dev)

Official Dev Repo for DezerX Spartan Installer

## Description

The DezerX Spartan Installer is an interactive Bash script designed to automate the deployment of the DezerX Spartan web application. It supports major Linux distributions including Ubuntu, Debian, CentOS, RHEL, AlmaLinux, Rocky, and Fedora.

## Chapters

- [Features](http://192.168.1.66:3000/DezerX/Install-Script#Features)
- [Requirements](http://192.168.1.66:3000/DezerX/Install-Script#Requirements)
- [How to install](http://192.168.1.66:3000/DezerX/Install-Script#How-To-install)
- [Troubleshooting](http://192.168.1.66:3000/DezerX/Install-Script#Troubleshooting)

## Features

- Interactive installation with live output
- Automated setup of PHP, NGINX/Apache, Node.js, Composer, and MySQL/MariaDB
- SSL certificate provisioning via Let's Encrypt (Certbot)
- Secure NGINX configuration with HTTP/2 and recommended headers
- Automatic environment file (.env) setup
- Systemd service for Laravel queue worker
- Cron job setup for scheduled tasks

## Requirements

- Linux server (Ubuntu/Debian/CentOS/RHEL/AlmaLinux/Rocky/Fedora)
- Root privileges
- Internet connectivity

## How To Install

### One line (Recomanded)

1. **Copy & Paste the command**

   ```bash
   sudo bash -c "$(curl -fsSL 'http://192.168.1.66:3000/DezerX/Install-Script/raw/branch/dev/spartan_installer.sh')"
   ```

2. **Follow the interactive prompts to complete the installation.**

### One line - non interactive (advanced)

1. **Copy & Paste the command then remplace placeholders values with your own**
   ```bash
   sudo bash -c "$(curl -fsSL 'http://192.168.1.66:3000/DezerX/Install-Script/raw/branch/dev/spartan_installer.sh') -- --non-interactive --install --license=XXXXXXXXXXXXXXX_XXXXXX --domain dash.example.com --webserver=nginx --ssl-mode=install --db-type=mariadb"
   ```

### Manualy

1. **Clone the repository:**

   ```bash
   git clone -b dev http://192.168.1.66:3000/DezerX/Install-Script.git
   cd Spartan-Installer
   ```

2. **Run the installer as root:**

   ```bash
   sudo bash install.sh
   ```

3. **Follow the interactive prompts to complete the installation.**

## Troubleshooting

- Check the installer log at `/var/log/spartan_installer.log` for details.
- Ensure all required ports (80, 443, database) are open.
- For SSL issues, verify DNS records and domain accessibility.
