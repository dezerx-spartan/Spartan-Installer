#!/usr/bin/env bash
# DezerX Spartan – Interactive Installer (Live Output, SSL-ready NGINX, no Redis)
# Distros: Ubuntu/Debian, CentOS/RHEL/Alma/Rocky, Fedora

set -euo pipefail

TITLE="DezerX Spartan Installer"
LOG="/var/log/dezerx_installer.log"
APP_DIR="/var/www/spartan"            # Default; wird interaktiv abgefragt
APP_USER_DEFAULT="www-data"
APP_GROUP_DEFAULT="www-data"

mkdir -p "$(dirname "$LOG")"
exec > >(tee -a "$LOG") 2>&1

# -------- Pretty output helpers --------
ts() { date +"%Y-%m-%d %H:%M:%S"; }
hr() { printf -- "---------------------------------------------------------------------\n"; }
section() { hr; echo "[$(ts)] >>> $*"; hr; }
cmdshow() { printf "\n$ %s\n\n" "$*"; }
run() { local desc="$1"; shift; section "$desc"; cmdshow "$*"; "$@"; }

need_root(){ [[ $EUID -eq 0 ]] || { echo "Run as root (sudo)."; exit 1; }; }
have(){ command -v "$1" >/dev/null 2>&1; }
die(){ echo; hr; echo "ERROR: $*" >&2; echo "See log: $LOG"; hr; exit 1; }

detect_os(){ source /etc/os-release || true; DISTRO_ID="${ID:-unknown}"; DISTRO_VER="${VERSION_ID:-}"; section "Detected OS: ${DISTRO_ID} ${DISTRO_VER}"; }

install_whiptail(){
  if have whiptail; then return; fi
  case "$DISTRO_ID" in
    debian|ubuntu) run "Install whiptail" apt-get update -y; run "Install whiptail" apt-get install -y whiptail ;;
    centos|rhel|almalinux|rocky) if have dnf; then run "Install newt (whiptail)" dnf -y install newt; else run "Install newt (whiptail)" yum -y install newt; fi ;;
    fedora) run "Install newt (whiptail)" dnf -y install newt ;;
    *) die "Cannot install whiptail/newt automatically on $DISTRO_ID" ;;
  esac
}

# ---------------- Menüs ----------------
main_menu(){ whiptail --title "$TITLE" --yesno "Welcome to the DezerX Spartan installer.\n\nProceed with installation?" 12 70; }

ask_domain(){
  while :; do
    DOMAIN=$(whiptail --title "$TITLE" --inputbox "Enter your primary domain (e.g. example.com)\nThis will be used for vHost, APP_URL and SSL." 10 70 "" 3>&1 1>&2 2>&3) || exit 1
    [[ -n "$DOMAIN" ]] && break
    whiptail --title "$TITLE" --msgbox "Domain is required." 8 50
  done
  section "Domain set to: ${DOMAIN}"
}

ask_app_dir(){
  local default_dir="$APP_DIR"
  APP_DIR=$(whiptail --title "$TITLE" --inputbox "Application directory (DocumentRoot = APP_DIR/public)\n\nEdit if needed:" 12 70 "$default_dir" 3>&1 1>&2 2>&3) || exit 1
  section "APP_DIR set to: ${APP_DIR}"
}

choose_webserver(){
  WEB=$(whiptail --title "$TITLE" --radiolist "Select your web server" 15 70 2 \
    "nginx"  "Nginx + PHP-FPM (+ Node.js LTS)" ON \
    "apache" "Apache + PHP-FPM (+ Node.js LTS)" OFF \
    3>&1 1>&2 2>&3) || exit 1
  section "Web server: ${WEB}"
}

choose_ioncube(){
  IONCUBE=$(whiptail --title "$TITLE" --radiolist "ionCube Loader" 12 70 2 \
    "install" "Install ionCube Loader (recommended)" ON \
    "skip"    "Skip (you will install it yourself)" OFF \
    3>&1 1>&2 2>&3) || exit 1
  section "ionCube selection: ${IONCUBE}"
}

choose_db_engine(){
  DB_ENGINE=$(whiptail --title "$TITLE" --radiolist "Choose database server" 12 70 2 \
    "mariadb" "MariaDB Server" ON \
    "mysql"   "MySQL Server" OFF \
    3>&1 1>&2 2>&3) || exit 1
  section "DB engine: ${DB_ENGINE}"
}

# ---------------- DB Wizard ----------------
DB_HOST="127.0.0.1"; DB_PORT="3306"; DB_NAME="dezerx"; DB_USER="dezer"; DB_PASS=""
db_collect(){
  DB_HOST=$(whiptail --title "$TITLE" --inputbox "Database Host" 10 70 "${DB_HOST}" 3>&1 1>&2 2>&3) || exit 1
  DB_PORT=$(whiptail --title "$TITLE" --inputbox "Database Port" 10 70 "${DB_PORT}" 3>&1 1>&2 2>&3) || exit 1
  DB_NAME=$(whiptail --title "$TITLE" --inputbox "Database Name" 10 70 "${DB_NAME}" 3>&1 1>&2 2>&3) || exit 1
  DB_USER=$(whiptail --title "$TITLE" --inputbox "Database User" 10 70 "${DB_USER}" 3>&1 1>&2 2>&3) || exit 1
  while :; do
    DB_PASS=$(whiptail --title "$TITLE" --passwordbox "Database Password\n\nUse a strong unique password." 12 70 3>&1 1>&2 2>&3) || exit 1
    DB_PASS2=$(whiptail --title "$TITLE" --passwordbox "Confirm Password" 12 70 3>&1 1>&2 2>&3) || exit 1
    [[ "$DB_PASS" == "$DB_PASS2" ]] && break
    whiptail --title "$TITLE" --msgbox "Passwords do not match. Please try again." 10 60
  done
  whiptail --title "$TITLE" --yesno "Database configuration:\n\nHost: ${DB_HOST}\nPort: ${DB_PORT}\nName: ${DB_NAME}\nUser: ${DB_USER}\n\nProceed to create database and user?" 14 70 || exit 1
  section "DB config confirmed: ${DB_USER}@${DB_HOST}:${DB_PORT}/${DB_NAME}"
}

mysql_exec(){
  local SQL="$1"
  if mysql --protocol=socket -uroot -e "SELECT 1;" >/dev/null 2>&1; then mysql --protocol=socket -uroot -e "$SQL"; return $?; fi
  if mysql -uroot -e "SELECT 1;" >/dev/null 2>&1; then mysql -uroot -e "$SQL"; return $?; fi
  local ROOTPW; ROOTPW=$(whiptail --title "$TITLE" --passwordbox "Enter MySQL/MariaDB root password" 10 70 3>&1 1>&2 2>&3) || return 1
  mysql -uroot -p"${ROOTPW}" -e "$SQL"
}

db_create(){
  local SQL="
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`;
CREATE USER IF NOT EXISTS '${DB_USER}'@'${DB_HOST}' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'${DB_HOST}' WITH GRANT OPTION;
FLUSH PRIVILEGES;"
  section "Create database & user"
  echo "$SQL"
  mysql_exec "$SQL" || die "Failed to create database/user. Check root access."
}

# ---------------- Package Ops ----------------
pm_update_upgrade(){
  local full="$1"
  case "$DISTRO_ID" in
    debian|ubuntu) export DEBIAN_FRONTEND=noninteractive; run "apt update" apt-get update -y; if ((full)); then run "apt dist-upgrade" apt-get -y dist-upgrade; fi ;;
    centos|rhel|almalinux|rocky) if have dnf; then run "dnf makecache" dnf -y makecache; if ((full)); then run "dnf upgrade" dnf -y upgrade; fi; else run "yum makecache" yum -y makecache; if ((full)); then run "yum update" yum -y update; fi; fi ;;
    fedora) run "dnf makecache" dnf -y makecache; if ((full)); then run "dnf upgrade" dnf -y upgrade; fi ;;
  esac
}

pm_install(){
  case "$DISTRO_ID" in
    debian|ubuntu) run "Install: $*" apt-get install -y "$@" ;;
    centos|rhel|almalinux|rocky) if have dnf; then run "Install: $*" dnf -y install "$@"; else run "Install: $*" yum -y install "$@"; fi ;;
    fedora) run "Install: $*" dnf -y install "$@" ;;
    *) die "Unsupported distro for package install: $DISTRO_ID" ;;
  esac
}

enable_php_repo_and_update(){
  case "$DISTRO_ID" in
    debian|ubuntu)
      pm_install software-properties-common curl apt-transport-https ca-certificates gnupg lsb-release
      if [[ "$DISTRO_ID" == "ubuntu" ]]; then run "Add PPA ondrej/php" add-apt-repository -y ppa:ondrej/php; fi
      run "apt update after PHP repo" apt-get update -y
      ;;
    fedora)
      pm_install dnf-plugins-core
      run "dnf module reset php" bash -lc "dnf -y module reset php || true"
      run "dnf module enable php (latest stream available)" bash -lc "dnf -y module enable php || true"
      ;;
    centos|rhel|almalinux|rocky)
      pm_install dnf-plugins-core || true
      if have dnf; then
        run "Install Remi repo" bash -lc "dnf -y install https://rpms.remirepo.net/enterprise/remi-release-\$(rpm -E %rhel).rpm || true"
        run "dnf module reset php" bash -lc "dnf -y module reset php || true"
        run "dnf module enable php (remi default)" bash -lc "dnf -y module enable php:remi || true"
      else
        run "Install Remi repo (yum)" bash -lc "yum -y install https://rpms.remirepo.net/enterprise/remi-release-\$(rpm -E %rhel).rpm || true"
      fi
      ;;
  esac
}

install_php_stack(){
  case "$DISTRO_ID" in
    debian|ubuntu)
      if ! apt-get install -y php php-cli php-fpm php-gd php-mysql php-mbstring php-bcmath php-xml php-curl php-zip; then
        section "Base repos didn't have PHP meta packages — enabling PHP repo and retrying…"
        enable_php_repo_and_update
        pm_install php php-cli php-fpm php-gd php-mysql php-mbstring php-bcmath php-xml php-curl php-zip
      fi
      ;;
    fedora|centos|rhel|almalinux|rocky)
      if have dnf; then
        if ! dnf -y install php php-cli php-fpm php-gd php-mysqlnd php-mbstring php-bcmath php-xml php-curl php-zip; then
          section "Enabling module/repo for newer PHP and retrying…"
          enable_php_repo_and_update
          pm_install php php-cli php-fpm php-gd php-mysqlnd php-mbstring php-bcmath php-xml php-curl php-zip
        fi
      else
        pm_install php php-cli php-fpm php-gd php-mysqlnd php-mbstring php-bcmath php-xml php-curl php-zip || true
      fi
      ;;
  esac
}

install_nodejs_lts(){
  case "$DISTRO_ID" in
    debian|ubuntu)
      run "Setup NodeSource LTS" bash -lc "curl -fsSL https://deb.nodesource.com/setup_lts.x -o /tmp/nodesource.sh && bash /tmp/nodesource.sh"
      pm_install nodejs
      ;;
    fedora)
      run "Setup NodeSource LTS (RPM)" bash -lc "curl -fsSL https://rpm.nodesource.com/setup_lts.x | bash - || true"
      pm_install nodejs || { run "Enable nodejs:lts module" dnf -y module enable nodejs:lts; pm_install nodejs; } || true
      ;;
    centos|rhel|almalinux|rocky)
      run "Setup NodeSource LTS (RPM)" bash -lc "curl -fsSL https://rpm.nodesource.com/setup_lts.x | bash - || true"
      if have dnf; then pm_install nodejs || { run "Enable nodejs:18" dnf -y module enable nodejs:18; pm_install nodejs; } || true
      else pm_install nodejs || true; fi
      ;;
    *) pm_install nodejs || true ;;
  esac
  have npm || pm_install npm || true
}

install_webserver(){
  if [[ "$WEB" == "nginx" ]]; then
    pm_install nginx
  else
    case "$DISTRO_ID" in
      debian|ubuntu) pm_install apache2 ;;
      fedora|centos|rhel|almalinux|rocky) pm_install httpd ;;
    esac
    if [[ -d /etc/apache2 ]]; then
      run "Enable Apache modules" bash -lc "a2enmod proxy proxy_fcgi setenvif rewrite headers expires || true"
      run "Restart Apache" systemctl restart apache2
    fi
  fi
}

install_db_engine(){
  if [[ "$DB_ENGINE" == "mariadb" ]]; then
    case "$DISTRO_ID" in
      debian|ubuntu|fedora|centos|rhel|almalinux|rocky) pm_install mariadb-server mariadb-client || pm_install mariadb-server ;;
    esac
    run "Enable/start MariaDB" bash -lc "systemctl enable --now mariadb || systemctl enable --now mariadb.service || true"
  else
    case "$DISTRO_ID" in
      debian|ubuntu) pm_install mysql-server mysql-client; run "Enable/start MySQL" systemctl enable --now mysql || true ;;
      fedora) pm_install @mysql || pm_install community-mysql-server || pm_install mysql-server || true; run "Enable/start mysqld" systemctl enable --now mysqld || true ;;
      centos|rhel|almalinux|rocky) pm_install @mysql:8.0 || pm_install community-mysql-server || pm_install mysql-server || true; run "Enable/start mysqld" systemctl enable --now mysqld || true ;;
    esac
  fi
  have mysql || pm_install mariadb-client || pm_install mysql-client || true
}

install_composer(){ run "Install Composer" bash -lc "curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer"; }

# ---------------- PHP-FPM helpers ----------------
find_php_fpm_service(){ systemctl list-unit-files --type=service | awk '/php.*-fpm\.service/ {print $1}' | sort -r | head -n1; }
start_php_fpm(){
  local svc; svc="$(find_php_fpm_service)"
  if [[ -n "$svc" ]]; then run "Enable/start ${svc}" systemctl enable --now "$svc"; else run "Enable/start php-fpm (generic)" systemctl enable --now php-fpm || true; fi
}
restart_php_fpm(){
  local svc; svc="$(find_php_fpm_service)"
  if [[ -n "$svc" ]]; then run "Restart ${svc}" systemctl restart "$svc" || true; else run "Restart php-fpm (generic)" systemctl restart php-fpm || true; fi
}
php_fpm_socket(){
  for s in /run/php/php*-fpm.sock /var/run/php/php*-fpm.sock /run/php/php-fpm.sock /var/run/php/php-fpm.sock /run/php-fpm/www.sock; do
    [[ -S "$s" ]] && { echo "unix:$s"; return; }
  done
  echo "unix:/run/php/php-fpm.sock"
}

# ---------------- ionCube ----------------
php_minor(){ php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || echo "8.2"; }
install_ioncube(){
  local PHPV ARCH URL TMP TAR SO
  PHPV="$(php_minor)"
  case "$(uname -m)" in
    x86_64) ARCH="x86-64" ;;
    aarch64|arm64) ARCH="aarch64" ;;
    *) die "ionCube: unsupported architecture $(uname -m)" ;;
  esac
  URL="https://downloads.ioncube.com/loader_downloads/ioncube_loaders_lin_${ARCH}.tar.gz"
  TMP="$(mktemp -d)"; TAR="$TMP/ioncube.tar.gz"
  run "Download ionCube" curl -fsSL "$URL" -o "$TAR"
  run "Extract ionCube" tar -xzf "$TAR" -C "$TMP"
  SO="$TMP/ioncube/ioncube_loader_lin_${PHPV}.so"
  [[ -f "$SO" ]] || die "ionCube loader for PHP ${PHPV} not found."
  run "Install ionCube to /usr/local/ioncube" bash -lc "install -d /usr/local/ioncube && install -m 0644 '$SO' /usr/local/ioncube/"
  local INI="zend_extension=/usr/local/ioncube/ioncube_loader_lin_${PHPV}.so"
  if [[ -d "/etc/php/${PHPV}/cli/conf.d" ]]; then
    run "Write ionCube ini (CLI)" bash -lc "echo '$INI' > /etc/php/${PHPV}/cli/conf.d/00-ioncube.ini"
    [[ -d "/etc/php/${PHPV}/fpm/conf.d" ]] && run "Write ionCube ini (FPM)" bash -lc "echo '$INI' > /etc/php/${PHPV}/fpm/conf.d/00-ioncube.ini"
    [[ -d "/etc/php/${PHPV}/apache2/conf.d" ]] && run "Write ionCube ini (Apache)" bash -lc "echo '$INI' > /etc/php/${PHPV}/apache2/conf.d/00-ioncube.ini"
  elif [[ -d "/etc/php.d" ]]; then
    run "Write ionCube ini (/etc/php.d)" bash -lc "echo '$INI' > /etc/php.d/00-ioncube.ini"
  fi
  restart_php_fpm
}

# ---------------- NGINX layout & config ----------------
nginx_layout_detect(){
  NGINX_AVAIL="/etc/nginx/sites-available"
  NGINX_ENABLED="/etc/nginx/sites-enabled"
  if [[ -d "$NGINX_AVAIL" && -d "$NGINX_ENABLED" ]]; then
    NGINX_MODE="debian"
    NGINX_CONF_PATH="$NGINX_AVAIL/dezerx.conf"
  else
    NGINX_MODE="rhel"
    NGINX_CONF_PATH="/etc/nginx/conf.d/dezerx.conf"
  fi
  section "NGINX layout: ${NGINX_MODE} (conf: ${NGINX_CONF_PATH})"
}

nginx_remove_defaults(){
  [[ -f /etc/nginx/sites-available/default ]] && run "Remove default NGINX (sites-available)" rm -f /etc/nginx/sites-available/default
  [[ -f /etc/nginx/sites-enabled/default   ]] && run "Remove default NGINX (sites-enabled)"   rm -f /etc/nginx/sites-enabled/default
  [[ -f /etc/nginx/conf.d/default.conf     ]] && run "Remove default NGINX (conf.d/default.conf)" rm -f /etc/nginx/conf.d/default.conf
}

nginx_enable_site(){
  if [[ "$NGINX_MODE" == "debian" ]]; then
    ln -sf "$NGINX_CONF_PATH" "$NGINX_ENABLED/dezerx.conf"
  fi
}

configure_nginx_http_only(){
  local sock; sock="$(php_fpm_socket)"
  nginx_layout_detect
  nginx_remove_defaults
  run "Write NGINX HTTP-only vHost for ${DOMAIN}" bash -lc "cat >'$NGINX_CONF_PATH' <<EOF
server {
    listen 80;
    server_name ${DOMAIN};

    root ${APP_DIR}/public;
    index index.php index.html;

    access_log /var/log/nginx/dezerx.app-access.log;
    error_log  /var/log/nginx/dezerx.app-error.log error;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        fastcgi_pass ${sock};
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param HTTP_PROXY \"\";
        fastcgi_intercept_errors off;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
        fastcgi_connect_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_read_timeout 300;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF"
  [[ "$NGINX_MODE" == "debian" ]] && run "Enable site (symlink)" nginx_enable_site
  start_php_fpm
  run "Test nginx configuration" nginx -t
  run "Enable/start nginx" systemctl enable --now nginx
  run "Restart nginx" systemctl restart nginx
}

configure_nginx_ssl(){
  local sock; sock="$(php_fpm_socket)"
  nginx_layout_detect
  nginx_remove_defaults
  run "Write NGINX SSL vHost for ${DOMAIN}" bash -lc "cat >'$NGINX_CONF_PATH' <<EOF
server {
    listen 80;
    server_name ${DOMAIN};
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name ${DOMAIN};

    root ${APP_DIR}/public;
    index index.php index.html;

    access_log /var/log/nginx/dezerx.app-access.log;
    error_log  /var/log/nginx/dezerx.app-error.log error;

    client_max_body_size 100m;
    client_body_timeout 120s;

    sendfile off;

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_session_cache shared:SSL:10m;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384";
    ssl_prefer_server_ciphers on;

    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";
    add_header X-Robots-Tag none;
    add_header Content-Security-Policy "frame-ancestors 'self'";
    add_header X-Frame-Options DENY;
    add_header Referrer-Policy same-origin;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        fastcgi_pass ${sock};
        fastcgi_index index.php;
        fastcgi_param PHP_VALUE "upload_max_filesize = 100M \n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
        fastcgi_intercept_errors off;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
        fastcgi_connect_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_read_timeout 300;
        include /etc/nginx/fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF"
  [[ "$NGINX_MODE" == "debian" ]] && run "Enable site (symlink)" nginx_enable_site
  start_php_fpm
  run "Test nginx configuration" nginx -t
  run "Restart nginx" systemctl restart nginx
}

# ---------------- APP bootstrap (.env, composer, npm, artisan) ----------------
ensure_app_dir(){ run "Ensure app directory ${APP_DIR}" bash -lc "mkdir -p '${APP_DIR}/public'"; }

env_write_value(){
  local key="$1" val="$2"
  if grep -qE "^${key}=" "${APP_DIR}/.env" 2>/dev/null; then
    run "Update .env ${key}" sed -i "s|^${key}=.*|${key}=${val}|g" "${APP_DIR}/.env"
  else
    run "Append .env ${key}" echo "${key}=${val}" >> "${APP_DIR}/.env"
  fi
}

detect_web_user_group(){
  APP_USER="$APP_USER_DEFAULT"; APP_GROUP="$APP_GROUP_DEFAULT"
  if [[ "$WEB" == "nginx" ]]; then
    id nginx >/dev/null 2>&1 && { APP_USER="nginx"; APP_GROUP="nginx"; } || \
    id www-data >/dev/null 2>&1 && { APP_USER="www-data"; APP_GROUP="www-data"; }
  else
    id apache >/dev/null 2>&1 && { APP_USER="apache"; APP_GROUP="apache"; } || \
    id www-data >/dev/null 2>&1 && { APP_USER="www-data"; APP_GROUP="www-data"; }
  fi
  section "Using web user/group: ${APP_USER}:${APP_GROUP}"
}

app_env_setup(){
  if [[ ! -f "${APP_DIR}/.env" && -f "${APP_DIR}/.env.example" ]]; then
    run "Copy .env.example -> .env" cp "${APP_DIR}/.env.example" "${APP_DIR}/.env"
  elif [[ ! -f "${APP_DIR}/.env" ]]; then
    run "Create empty .env" touch "${APP_DIR}/.env"
  fi
  env_write_value "APP_NAME" "\"DezerX Spartan\""
  env_write_value "APP_ENV" "production"
  env_write_value "APP_KEY" ""
  env_write_value "APP_DEBUG" "false"
  env_write_value "APP_URL" "http://${DOMAIN}"
  env_write_value "DB_CONNECTION" "mysql"
  env_write_value "DB_HOST" "${DB_HOST}"
  env_write_value "DB_PORT" "${DB_PORT}"
  env_write_value "DB_DATABASE" "${DB_NAME}"
  env_write_value "DB_USERNAME" "${DB_USER}"
  env_write_value "DB_PASSWORD" "${DB_PASS}"
}

app_install_steps(){
  [[ -f "${APP_DIR}/composer.json" ]] && run "composer install" bash -lc "cd '${APP_DIR}' && COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader -n --prefer-dist"
  [[ -f "${APP_DIR}/package.json"  ]] && run "npm install" bash -lc "cd '${APP_DIR}' && npm install"
  [[ -f "${APP_DIR}/package.json"  ]] && run "npm run build" bash -lc "cd '${APP_DIR}' && npm run build || true"
  run "artisan key:generate" bash -lc "cd '${APP_DIR}' && php artisan key:generate --force || true"
  run "artisan migrate --seed" bash -lc "cd '${APP_DIR}' && php artisan migrate --seed --force || true"
}

apply_permissions(){
  detect_web_user_group
  run "Set ownership to ${APP_USER}:${APP_GROUP}" chown -R "${APP_USER}:${APP_GROUP}" "${APP_DIR}"
  run "Set permissions 755" chmod -R 755 "${APP_DIR}"
  [[ -d "${APP_DIR}/storage" ]] && run "storage perms" chmod -R ug+rwX "${APP_DIR}/storage" || true
  [[ -d "${APP_DIR}/bootstrap/cache" ]] && run "bootstrap/cache perms" chmod -R ug+rwX "${APP_DIR}/bootstrap/cache" || true
}

setup_cron(){
  local cron_line="* * * * * cd ${APP_DIR} && php artisan schedule:run >> /dev/null 2>&1"
  run "Install cron for scheduler" bash -lc "(crontab -l 2>/dev/null | grep -v -F \"${cron_line}\"; echo \"${cron_line}\") | crontab -"
}

setup_systemd_queue(){
  detect_web_user_group
  local svc="/etc/systemd/system/dezerx.service"
  run "Create systemd service dezerx.service" bash -lc "cat >'$svc' <<EOF
[Unit]
Description=Laravel Queue Worker for DezerX
After=network.target

[Service]
User=${APP_USER}
Group=${APP_GROUP}
WorkingDirectory=${APP_DIR}
ExecStart=/usr/bin/php ${APP_DIR}/artisan queue:work --queue=critical,high,medium,default,low --sleep=3 --tries=3
Restart=always
RestartSec=5
StartLimitBurst=3
StartLimitIntervalSec=60
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=dezerx-worker

[Install]
WantedBy=multi-user.target
EOF"
  run "Enable & start dezerx.service" bash -lc "systemctl daemon-reload && systemctl enable dezerx.service && systemctl start dezerx.service || true"
}

# ---------------- Certbot ----------------
ask_certbot(){ whiptail --title "$TITLE" --yesno "Install SSL with Certbot for ${DOMAIN} now?" 10 70; }

install_certbot_pkgs(){
  case "$DISTRO_ID" in
    debian|ubuntu)
      if [[ "$WEB" == "nginx" ]]; then 
        pm_install certbot python3-certbot-nginx
      else 
        pm_install certbot python3-certbot-apache
      fi
      ;;
    fedora|centos|rhel|almalinux|rocky)
      if [[ "$WEB" == "nginx" ]]; then 
        pm_install certbot python3-certbot-nginx || pm_install certbot || true
      else 
        pm_install certbot python3-certbot-apache || pm_install certbot || true
      fi
      ;;
  esac
}

run_certbot_webroot(){
  run "Obtain certificate for ${DOMAIN} (webroot: ${APP_DIR}/public)" \
    bash -lc "certbot certonly --non-interactive --agree-tos -m admin@${DOMAIN} --webroot -w '${APP_DIR}/public' -d '${DOMAIN}' || true"
}

# ---------------- License & Download ----------------
LICENSE_KEY=""
ask_license_key(){
  while :; do
    LICENSE_KEY=$(whiptail --title "$TITLE" --passwordbox "Enter your DezerX Spartan license key" 10 70 3>&1 1>&2 2>&3) || exit 1
    [[ -n "$LICENSE_KEY" ]] || { whiptail --title "$TITLE" --msgbox "License key is required." 8 50; continue; }
    local masked="${LICENSE_KEY:0:4}****${LICENSE_KEY: -4}"
    whiptail --title "$TITLE" --yesno "Use this license key?\n\n${masked}\n\nDomain: ${DOMAIN}\nProduct ID: 1" 12 70 && break
  done
  section "License key captured (masked)."
}

install_download_tools(){
  case "$DISTRO_ID" in
    debian|ubuntu) pm_install curl jq unzip rsync tar file ;;
    fedora|centos|rhel|almalinux|rocky) pm_install curl jq unzip rsync tar file ;;
    *) pm_install curl jq unzip rsync tar file || true ;;
  esac
}

license_verify(){
  local API="https://market.dezerx.com/api/license/verify"
  local TMP; TMP="$(mktemp)"
  section "Verify license (GET)"
  cmdshow "curl -fsS -H 'Authorization: Bearer ***' -H 'X-Domain: ${DOMAIN}' -H 'X-Product-ID: 1' ${API}"
  local CODE
  CODE=$(curl -sS -X GET "$API" \
      -H "Authorization: Bearer ${LICENSE_KEY}" \
      -H "X-Domain: ${DOMAIN}" \
      -H "X-Product-ID: 1" \
      -H "Content-Type: application/json" \
      -o "$TMP" -w '%{http_code}') || CODE=0

  [[ "$CODE" =~ ^2 ]] || { echo "API response:"; cat "$TMP" 2>/dev/null || true; die "Verify API returned HTTP ${CODE}."; }

  local SUCCESS IS_ACTIVE PNAME PDID PDOMAIN MSG
  SUCCESS=$(jq -r '.success // false' "$TMP") || SUCCESS=false
  IS_ACTIVE=$(jq -r '.data.is_active // false' "$TMP") || IS_ACTIVE=false
  PNAME=$(jq -r '.data.product_name // empty' "$TMP")
  PDID=$(jq -r '.data.product_id // empty' "$TMP")
  PDOMAIN=$(jq -r '.data.domain // empty' "$TMP")
  MSG=$(jq -r '.message // empty' "$TMP")

  [[ "$SUCCESS" == "true" && "$IS_ACTIVE" == "true" ]] || { echo "API response:"; cat "$TMP"; die "License not active/valid: ${MSG:-Unknown}"; }

  echo "License OK: ${PNAME:-DezerX Spartan} (product_id=${PDID:-?})"
  [[ -n "$PDOMAIN" ]] && echo "Registered domain: $PDOMAIN"
}

license_download_and_extract(){
  local API="https://market.dezerx.com/api/license/download"
  local TMPDIR; TMPDIR="$(mktemp -d)"
  local RESP_FILE="$TMPDIR/resp.json"

  section "Request one-time download link (POST)"
  cmdshow "curl -fsS -X POST '${API}' -H 'Authorization: Bearer ***' -H 'X-Domain: ${DOMAIN}' -H 'X-Product-ID: 1'"

  local CODE
  CODE=$(curl -sS -X POST "$API" \
      -H "Authorization: Bearer ${LICENSE_KEY}" \
      -H "X-Domain: ${DOMAIN}" \
      -H "X-Product-ID: 1" \
      -H "Content-Type: application/json" \
      -o "$RESP_FILE" -w '%{http_code}') || CODE=0

  [[ "$CODE" =~ ^2 ]] || { echo "API response:"; cat "$RESP_FILE" 2>/dev/null || true; die "Download-token API returned HTTP ${CODE}."; }

  local SUCCESS URL EXPIRES NAME SIZE MSG
  SUCCESS=$(jq -r '.success // false' "$RESP_FILE") || SUCCESS=false
  MSG=$(jq -r '.message // empty' "$RESP_FILE")
  URL=$(jq -r '.data.download_url // empty' "$RESP_FILE")
  EXPIRES=$(jq -r '.data.expires_at // empty' "$RESP_FILE")
  NAME=$(jq -r '.data.product_name // empty' "$RESP_FILE")
  SIZE=$(jq -r '.data.file_size // empty' "$RESP_FILE")

  [[ "$SUCCESS" == "true" && -n "$URL" ]] || { echo "API response:"; cat "$RESP_FILE"; die "No valid download_url in response: ${MSG:-Unknown}"; }

  section "License OK – downloading ${NAME:-payload}"
  echo "Download URL (one-time): $URL"
  [[ -n "$EXPIRES" ]] && echo "Expires at: $EXPIRES"
  [[ -n "$SIZE" ]] && echo "File size: $SIZE bytes"

  local OUT="$TMPDIR/app"
  mkdir -p "$OUT"
  local FILE="$OUT/payload"
  curl -fL "$URL" -o "${FILE}" || die "Failed to download application payload."

  local TYPE
  if file -b "${FILE}" | grep -qi "zip"; then
    TYPE="zip"
  elif file -b "${FILE}" | grep -Eiq "gzip|tar"; then
    TYPE="targz"
  else
    case "$URL" in
      *.zip) TYPE="zip" ;;
      *.tar.gz|*.tgz) TYPE="targz" ;;
      *) die "Unknown archive type (expected zip or tar.gz)." ;;
    esac
  fi

  section "Extract application archive (${TYPE})"
  local EXTRACT="$OUT/extract"
  mkdir -p "$EXTRACT"
  if [[ "$TYPE" == "zip" ]]; then
    unzip -q "${FILE}" -d "$EXTRACT"
  else
    tar -xzf "${FILE}" -C "$EXTRACT"
  fi

  local SRC="$EXTRACT"
  local TOP_COUNT
  TOP_COUNT="$(find "$EXTRACT" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
  if [[ "$TOP_COUNT" -eq 1 ]]; then
    SRC="$(find "$EXTRACT" -mindepth 1 -maxdepth 1 -type d | head -n1)"
  fi

  ensure_app_dir
  section "Sync application to ${APP_DIR}"
  rsync -a --delete "$SRC"/ "${APP_DIR}/"/

  [[ -f "${APP_DIR}/composer.json" ]] || die "composer.json missing after extraction; invalid payload?"
  echo "App synced to ${APP_DIR}"
}

# ---- HTTPS flip after certbot ----
flip_app_url_to_https(){
  if [[ -f "${APP_DIR}/.env" ]]; then
    section "Flip APP_URL to https://${DOMAIN}"
    sed -i "s|^APP_URL=.*|APP_URL=https://${DOMAIN}|g" "${APP_DIR}/.env" || true
    if [[ -f "${APP_DIR}/artisan" ]]; then
      run "artisan config:clear" bash -lc "cd '${APP_DIR}' && php artisan config:clear || true"
      run "artisan config:cache" bash -lc "cd '${APP_DIR}' && php artisan config:cache || true"
    fi
  fi
}

# ---------------- Flow ----------------
need_root
detect_os
install_whiptail

main_menu || { echo "Installation cancelled."; exit 0; }
ask_domain
ask_app_dir
choose_webserver
choose_ioncube
choose_db_engine
db_collect

whiptail --title "$TITLE" --yesno "Summary:\n
Domain: ${DOMAIN}
App dir: ${APP_DIR}
Web server: ${WEB}
ionCube: ${IONCUBE}
Database engine: ${DB_ENGINE}

DB Host: ${DB_HOST}
DB Port: ${DB_PORT}
DB Name: ${DB_NAME}
DB User: ${DB_USER}

Proceed with installation (live output)?" 20 72 || exit 1

# Update caches early and ensure download tooling
pm_update_upgrade 0
install_download_tools

# License: verify -> download -> extract to APP_DIR
ask_license_key
license_verify
license_download_and_extract

# Now install system stack & app deps
install_php_stack
install_webserver
install_nodejs_lts
install_db_engine
db_create
install_composer
[[ "$IONCUBE" == "install" ]] && install_ioncube || section "Skipping ionCube (user choice)"

# App setup & build
app_env_setup
app_install_steps
apply_permissions
setup_cron
setup_systemd_queue

if [[ "$WEB" == "nginx" ]]; then
  configure_nginx_http_only
  if ask_certbot; then
    install_certbot_pkgs
    run_certbot_webroot
    configure_nginx_ssl
    flip_app_url_to_https
  fi
else
  if ask_certbot; then
    install_certbot_pkgs
    run "Certbot (apache)" certbot --apache -d "${DOMAIN}" || true
    flip_app_url_to_https
  fi
fi

section "All done!"
echo "Domain:       ${DOMAIN}"
echo "App Path:     ${APP_DIR}"
echo "DocumentRoot: ${APP_DIR}/public"
echo "Web server:   ${WEB}"
echo "DB engine:    ${DB_ENGINE}"
php -v | grep -qi ioncube && echo "ionCube:     enabled" || echo "ionCube:     not detected"
echo "DB:           ${DB_USER}@${DB_HOST}:${DB_PORT}/${DB_NAME}"
echo "DB pass in:   ${APP_DIR}/.env"
echo "Log:          ${LOG}"
hr
echo "Useful:"
echo " systemctl status dezerx.service"
echo " crontab -l"
[[ "$WEB" == "nginx" ]] && echo " nginx logs: /var/log/nginx/" || echo " apache logs: /var/log/apache2/ or /var/log/httpd/"
echo " SSL (if enabled): /etc/letsencrypt/live/${DOMAIN}/"
hr
exit 0

