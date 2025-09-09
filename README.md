# Spartan-Installer

Official Repo for DezerX Spartan Installer

## Description

The DezerX Spartan Installer is an interactive Bash script designed to automate the deployment of the DezerX Spartan web application. It supports major Linux distributions including Ubuntu, Debian, CentOS, RHEL, AlmaLinux, Rocky, and Fedora.

## Chapters

- [Features](https://github.com/DezerX-Brand-of-Bauer-Kuke-EDV-GBR/Spartan-Installer#Features)
- [Requirements](https://github.com/DezerX-Brand-of-Bauer-Kuke-EDV-GBR/Spartan-Installer#Requirements)
- [How to install](https://github.com/DezerX-Brand-of-Bauer-Kuke-EDV-GBR/Spartan-Installer#How-To-install)
- [Troubleshooting](https://github.com/DezerX-Brand-of-Bauer-Kuke-EDV-GBR/Spartan-Installer#Troubleshooting)

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
   curl -fsSL https://github.com/DezerX-Brand-of-Bauer-Kuke-EDV-GBR/Spartan-Installer/releases/latest/download/spartan_installer.sh | sudo bash
   ```

2. **Follow the interactive prompts to complete the installation.**


### Manualy

1. **Clone the repository:**

   ```bash
   git clone https://github.com/DezerX-Brand-of-Bauer-Kuke-EDV-GBR/Spartan-Installer.git
   cd Spartan-Installer
   ```

2. **Run the installer as root:**

   ```bash
   sudo bash install.sh
   ```

3. **Follow the interactive prompts to complete the installation.**


## Troubleshooting

- Check the installer log at `/var/log/dezerx_installer.log` for details.
- Ensure all required ports (80, 443, database) are open.
- For SSL issues, verify DNS records and domain accessibility.
