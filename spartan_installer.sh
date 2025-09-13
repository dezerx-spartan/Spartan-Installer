#!/usr/bin/env bash
# DezerX Spartan – Interactive Installer (Live Output, SSL-ready NGINX, no Redis)
# Distros: Ubuntu/Debian, CentOS/RHEL/Alma/Rocky, Fedora

set -euo pipefail
trap 'echo "[ERR] An error occured at line ${LINENO} while executing: ${BASH_COMMAND}" | tee /dev/tty >&2' ERR

TITLE="DezerX Spartan Installer"
LOG="/var/log/spartan_installer.log"
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
run(){
    local first="$1"
    local desc cmdstr
    shift
    if have "$first" >/dev/null 2>&1; then
        cmdstr="$first"
        [[ $# -gt 0 ]] && cmdstr="$cmdstr $*"
        desc="Running: $cmdstr"
    else
        desc="$first"
        cmdstr="$*"
    fi
    
    section "$desc"
    cmdshow "$*"
    "$@"
}

need_root(){ [[ $EUID -eq 0 ]] || { echo "Run as root (sudo)."; exit 1; }; }
have(){ command -v "$1" >/dev/null 2>&1; }
die(){ echo; hr; echo "ERROR: $*" >&2; echo "See log: $LOG"; hr; exit 1; }

detect_os(){ source /etc/os-release || true; DISTRO_ID="${ID:-unknown}"; DISTRO_VER="${VERSION_ID:-}"; section "Detected OS: ${DISTRO_ID} ${DISTRO_VER}"; }

pm_install(){
    local desc
    if [[ "$1" =~ [[:space:]:] ]]; then
        desc="$1"
        shift
    else
        desc="Installing: $*"
    fi
    
    case "$DISTRO_ID" in
        debian|ubuntu) run "${desc}" apt-get install -y "$@" ;;
        centos|rhel|almalinux|rocky) if have dnf; then run "${desc}" dnf -y --setopt=install_weak_deps=False install "$@"; else run "${desc}" yum -y install "$@"; fi ;;
        fedora) run "${desc}" dnf -y install "$@" ;;
        *) die "Unsupported distro for package install: $DISTRO_ID" ;;
    esac
}

pm_update_upgrade(){
    local full="$1"
    case "$DISTRO_ID" in
        debian|ubuntu)
            export DEBIAN_FRONTEND=noninteractive
            run "Updating apt repositories" apt-get update
            run "Upgrading apt repositories" apt-get upgrade -y
            if ((full)); then
                run "apt dist-upgrade" apt-get -y dist-upgrade;
            fi
        ;;
        centos|rhel|almalinux|rocky)
            if have dnf; then
                run "dnf makecache" dnf -y makecache
                run "dnf upgrade" dnf -y upgrade
                if ((full)); then
                    run "dnf dist-upgrade" dnf -y distro-sync
                fi
            else
                run "yum makecache" yum -y makecache
                run "yum makecache" yum -y upgrade
            fi
        ;;
        fedora)
            run "dnf makecache" dnf -y makecache
            run "dnf upgrade" dnf -y upgrade
            if ((full)); then
                run "dnf dist-upgrade" dnf -y distro-sync
            fi
        ;;
    esac
}

install_essentials(){
    local pkgs=()
    
    case "$DISTRO_ID" in
        debian|ubuntu)
            pkgs=(curl apt-transport-https ca-certificates gnupg lsb-release jq unzip rsync tar file openssl procps)
        ;;
        fedora|centos|rhel|almalinux|rocky)
            pkgs=(curl ca-certificates gnupg jq unzip rsync tar file openssl procps cronie)
        ;;
        *) die "Distro not supported $DISTRO_ID" ;;
    esac
    
    if ! have whiptail; then
        case "$DISTRO_ID" in
            debian|ubuntu) pkgs+=(whiptail) ;;
            fedora|centos|rhel|almalinux|rocky) pkgs+=(newt) ;;
            *) die "Distro not supported $DISTRO_ID" ;;
        esac
    fi
    
    pm_install "Installing essential dependencies" "${pkgs[@]}"
}

is_systemd() {
    [[ -d /run/systemd/system ]] && return 0
    local p1
    p1="$(ps -p 1 -o comm= 2>/dev/null || true)"
    [[ "$p1" = "systemd" ]] && return 0
    return 1
}

start_service(){
    local svc="$1"
    
    if is_systemd && have systemctl >/dev/null 2>&1; then
        section "Attempting to start ${svc} via systemctl"
        if systemctl enable --now "$svc" >/dev/null 2>&1 || systemctl start "$svc" >/dev/null 2>&1; then
            return 0
        fi
    fi
    
    if have rc-service >/dev/null 2>&1; then
        section "Attempting to start ${svc} via rc-servic"
        if rc-service "$svc" start >/dev/null 2>&1; then
            return 0
        fi
    fi
    
    if have service >/dev/null 2>&1; then
        section "Attempting to start ${svc} via service"
        if service "$svc" start >/dev/null 2>&1; then
            return 0
        fi
    fi
    
    return 1
}

# ---------------- Menüs ----------------
main_menu(){
    CHOICE=$(whiptail --title "$TITLE" --menu "Welcome to the DezerX Spartan installer.\n\nChoose an option:" 15 70 2 \
        "install" "Install DezerX Spartan" \
    "update" "Update DezerX Spartan" 3>&1 1>&2 2>&3) || { echo "Operation cancelled."; exit 0; }
}

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
        DB_PASS=$(whiptail --title "$TITLE" --passwordbox "Database Password\n\nUse a strong unique password.\n\nLeave empty to auto-generate one." 12 70 3>&1 1>&2 2>&3) || exit 1
        
        if [[ -z "$DB_PASS" ]]; then
            DB_PASS=$(openssl rand -hex 16)
            whiptail --title "$TITLE" --msgbox "No password entered, a secure password was generated for you:\n\n${DB_PASS}\n\nSave it somewhere safe. (it will be written to the .env file)" 14 70
            break
        fi
        
        DB_PASS2=$(whiptail --title "$TITLE" --passwordbox "Confirm Password" 12 70 3>&1 1>&2 2>&3) || exit 1
        
        if [[ "$DB_PASS" == "$DB_PASS2" ]]; then
            break
        fi
        
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
            enable_php_repo_and_update
            run "Install PHP stack (latest available)" apt-get install --no-install-recommends -y php php-cli php-fpm php-gd php-mysql php-mbstring php-bcmath php-xml php-curl php-zip
        ;;
        fedora|centos|rhel|almalinux|rocky)
            if have dnf; then
                enable_php_repo_and_update
                run "Install PHP stack (latest available)" dnf -y install php php-cli php-fpm php-gd php-mysqlnd php-mbstring php-bcmath php-xml php-curl php-zip
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
        run "Starting nginx" systemctl start nginx || true
        elif [[ "$WEB" == "apache" ]]; then
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

install_composer(){
    if have composer >/dev/null 2>&1; then
        section "Composer already installed. $(command -v composer)"
        return 0
    fi
    
    run "Install composer" bash -lc "curl -fsSL https://getcomposer.org/composer-stable.phar -o /usr/local/bin/composer"
    run "Making composer executable" bash -lc "chmod +x /usr/local/bin/composer || true"
    
    if [[ ! -e "/usr/bin/composer" ]]; then
        run "Creating a symlink from /usr/local/bin/composer -> /usr/bin/composer" ln -sf /usr/local/bin/composer /usr/bin/composer || true
    fi
    
    if have composer >/dev/null 2>&1; then
        section "Composer installed. $(command -v composer)"
        return 0
    fi
    
    # Falback to the installer
    local temp_installer
    temp_installer="$(mktemp)"
    
    run "Downloading composer installer." bash -lc "curl -fsSL https://getcomposer.org/installer -o '${temp_installer}'"
    run "Running composer installer" bash -lc "php '${temp_installer}' --install-dir=/usr/local/bin --filename=composer"
    
    rm -f "${temp_installer}" || true
    
    if have composer >/dev/null 2>&1; then
        section "Composer installed. $(command -v composer)"
        return 0
    fi
    
    echo -e "Failed to install composer."
    return 1
}

# ---------------- License & Download ----------------
LICENSE_KEY=""
PRODUCT_ID=""
PRODUCT_NAME=""

ask_license_key(){
    while :; do
        LICENSE_KEY=$(whiptail --title "$TITLE" --passwordbox "Enter your DezerX Spartan license key" 10 70 3>&1 1>&2 2>&3) || exit 1
        if [[ -z "$LICENSE_KEY" ]]; then
            whiptail --title "$TITLE" --msgbox "License key is required." 8 50
            continue
        fi
        
        if [[ "$LICENSE_KEY" == SPARTANSTARTER_* ]]; then
            PRODUCT_ID="1"
            PRODUCT_NAME="Spartan Starter"
            elif [[ "$LICENSE_KEY" == SPARTANPROFESSIONAL_* ]]; then
            PRODUCT_ID="5"
            PRODUCT_NAME="Spartan Professional"
            elif [[ "$LICENSE_KEY" == SPARTANULTIMATE_* ]]; then
            PRODUCT_ID="6"
            PRODUCT_NAME="Spartan Ultimate"
        else
            whiptail --title "$TITLE" --msgbox "Invalid license key. Please try again." 8 50
            continue
        fi
        
        local masked="${LICENSE_KEY:0:4}****${LICENSE_KEY: -4}"
        whiptail --title "$TITLE" --yesno "Use this license key?\n\n${masked}\n\nDomain: ${DOMAIN}" 12 70 && break
    done
    section "License key captured (masked)."
}

license_verify(){
    local API="https://market.dezerx.com/api/license/verify"
    local TMP; TMP="$(mktemp)"
    section "Verify license (GET)"
    cmdshow "curl -fsS -H 'Authorization: Bearer ***' -H 'X-Domain: ${DOMAIN}' -H 'X-Product-ID: ${PRODUCT_ID}' ${API}"
    local CODE
    CODE=$(curl -sS -X GET "$API" \
        -H "Authorization: Bearer ${LICENSE_KEY}" \
        -H "X-Domain: ${DOMAIN}" \
        -H "X-Product-ID: ${PRODUCT_ID}" \
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
    
    echo "License OK: ${PNAME:-${PRODUCT_NAME}} (product_id=${PDID:-${PRODUCT_ID}})"
    [[ -n "$PDOMAIN" ]] && echo "Registered domain: $PDOMAIN"
}

license_download_and_extract(){
    local API="https://market.dezerx.com/api/license/download"
    local TMPDIR; TMPDIR="$(mktemp -d)"
    local RESP_FILE="$TMPDIR/resp.json"
    
    section "Request one-time download link (POST)"
    cmdshow "curl -fsS -X POST '${API}' -H 'Authorization: Bearer ***' -H 'X-Domain: ${DOMAIN}' -H 'X-Product-ID: ${PRODUCT_ID}'"
    
    local CODE
    CODE=$(curl -sS -X POST "$API" \
        -H "Authorization: Bearer ${LICENSE_KEY}" \
        -H "X-Domain: ${DOMAIN}" \
        -H "X-Product-ID: ${PRODUCT_ID}" \
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

# ---------------- PHP-FPM helpers ----------------
find_php_fpm_service(){ systemctl list-unit-files --type=service | awk '/php.*-fpm\.service/ {print $1}' | sort -r | head -n1; }
php_minor(){ php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || echo "8.2"; }
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
        [[ -S "$s" ]] && { echo "unix:$s"; return 0; }
    done
    echo "unix:/run/php/php-fpm.sock"
}
php_fpm_conf(){
    local candidates=()
    
    case "$DISTRO_ID" in
        debian|ubuntu)
            candidates+=("/etc/php/*/fpm/pool.d/www.conf")
            candidates+=("/etc/php/$(php_minor)/fpm/pool.d/www.conf")
        ;;
        fedora|centos|rhel|almalinux|rocky)
            candidates+=("/etc/php-fpm.d/www.conf")
        ;;
    esac
    
    for cf in "${candidates[@]}"; do
        [[ -f "$cf" ]] && { echo "$cf"; return 0; }
    done
    
    return 1
}


# ---------------- ionCube ----------------
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
    local avail="/etc/nginx/sites-available/default"
    local enabled="/etc/nginx/sites-enabled/default"
    local confd="/etc/nginx/conf.d/default.conf"
    
    for f in "$avail" "$enabled" "$confd"; do
        if [[ -e "$f" || -L "$f" ]]; then
            run "Removed default NGINX conf ($f)" rm -f "$f"
        fi
    done
}

nginx_enable_site(){
    if [[ "$NGINX_MODE" == "debian" ]]; then
        run "Enable site (symlink)" ln -sf "$NGINX_CONF_PATH" "$NGINX_ENABLED/dezerx.conf"
    fi
}

configure_nginx_http_only(){
    local sock; sock="$(php_fpm_socket)"
    nginx_layout_detect
    nginx_remove_defaults
    
  run "Write NGINX HTTP-only vHost for ${DOMAIN}" bash -lc "cat >'$NGINX_CONF_PATH' <<'EOF'
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
    nginx_enable_site
    start_php_fpm
    run "Test nginx configuration" nginx -t
    run "Enable/start nginx" systemctl enable --now nginx
    run "Restart nginx" systemctl restart nginx
}

configure_nginx_ssl(){
    local sock; sock="$(php_fpm_socket)"
    nginx_layout_detect
    nginx_remove_defaults
  run "Write NGINX SSL vHost for ${DOMAIN}" bash -lc "cat >'$NGINX_CONF_PATH' <<'EOF'
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
    add_header X-XSS-Protection \"1; mode=block\";
    add_header X-Robots-Tag none;
    add_header Content-Security-Policy \"frame-ancestors 'self'\";
    add_header X-Frame-Options DENY;
    add_header Referrer-Policy same-origin;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        fastcgi_pass ${sock};
        fastcgi_index index.php;
        fastcgi_param PHP_VALUE \"upload_max_filesize=100M \\n post_max_size=100M \\n max_execution_time=300\";
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param HTTP_PROXY \"\";
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

detect_web_user_group(){
    local user="" group="" proc_user pid candidates detection_method=""
    APP_USER="$APP_USER_DEFAULT"; APP_GROUP="$APP_GROUP_DEFAULT"
    
    if [[ "$WEB" == "nginx" ]]; then
        candidates=(nginx www-data www)
    else
        candidates=(apache2 httpd apache)
    fi
    
    # tbh those two functions are pretty much the same but why not
    # Get user from pid using systemctl and group using id
    if command -v systemctl >/dev/null 2>&1; then
        for svc in "${candidates[@]}"; do
            if systemctl is-active --quiet "$svc" >/dev/null 2>&1; then
                if ! systemctl list-unit-files --type=service --all | grep -qw "${svc}.service"; then
                    continue
                fi
                
                pid="$(systemctl show -p MainPID --value "$svc" 2>/dev/null || true)"
                if [[ -n "$pid" && "$pid" -gt 0 ]]; then
                    user="$(ps -o user= -p "$pid" 2>/dev/null | awk '{print $1}' || true)"
                fi
                
                if [[ "$user" == "root" || -z "$user" ]]; then
                    if command -v pgrep >/dev/null 2>&1 && pgrep -x "$svc" >/dev/null 2>&1; then
                        proc_user="$(ps -o user= -C "$svc" 2>/dev/null | awk '{print $1}' | grep -v "^root$" | head -n1 || true)"
                        [[ -n $proc_user ]] && user="$proc_user"
                    fi
                fi
                
                if [[ -n "$user" ]]; then
                    group="$(id -gn "$user" 2>/dev/null || echo "$user")"
                    detection_method="candidates + systemctl"
                    break
                fi
            fi
        done
    fi
    
    # falback to id if systemctl isn't active/installed
    if [[ -z "${user}" || -z "${group}" ]]; then
        for u in "${candidates[@]}"; do
            if id "$u" >/dev/null 2>&1; then
                user="$u"
                group="$(id -gn "$user" 2>/dev/null || echo "$user")"
                detection_method="candidates + id"
                break
            fi
        done
    fi
    
    # last falback to the defaults
    if [[ -z "${user}" || -z "${group}" ]]; then
        user="${$APP_USER_DEFAULT}"
        group="${$APP_USER_DEFAULT}"
        detection_method="defaults"
    fi
    
    APP_USER="${user}"
    APP_GROUP="${group}"
    
    section "Using web user/group: ${APP_USER}:${APP_GROUP} (method=${detection_method})"
}

config_php_fpm(){
    local sock; sock="$(php_fpm_conf)"
    run "Updating user to ${APP_USER} in: ${sock}" sed -i "s|^user = .*|user = ${APP_USER}|" "${sock}"
    run "Updating user to ${APP_GROUP} in: ${sock}" sed -i "s|^group = .*|group = ${APP_GROUP}|" "${sock}"
    restart_php_fpm
}

env_write_value(){
    local key="$1" val="$2"
    if grep -qE "^${key}=" "${APP_DIR}/.env" 2>/dev/null; then
        run "Update .env ${key}" sed -i "s|^${key}=.*|${key}=${val}|g" "${APP_DIR}/.env"
    else
        run "Append .env ${key}" echo "${key}=${val}" >> "${APP_DIR}/.env"
    fi
}

app_env_setup(){
    if [[ ! -f "${APP_DIR}/.env" && -f "${APP_DIR}/.env.example" ]]; then
        run "Copy .env.example -> .env" cp "${APP_DIR}/.env.example" "${APP_DIR}/.env"
        
        local envfile="${APP_DIR}/.env"
        local lines=0
        lines=$(wc -l < "${envfile}" 2>/dev/null || echo 0)
        if (( lines > 4 )); then
            run "Removing the last 4 lines of the .env" bash -lc "head -n -4 '${envfile}' > '${envfile}.tmp' && mv -f '${envfile}.tmp' '${envfile}'"
        fi
        
        elif [[ ! -f "${APP_DIR}/.env" ]]; then
        run "Create empty .env" touch "${APP_DIR}/.env"
    fi
    
    env_write_value "APP_NAME" "\"DezerX Spartan\""
    env_write_value "APP_ENV" "production"
    env_write_value "APP_KEY" ""
    env_write_value "APP_DEBUG" "false"
    env_write_value "APP_URL" "http://${DOMAIN}"
    env_write_value "LICENSE_KEY" "${LICENSE_KEY}"
    env_write_value "PRODUCT_ID" "${PRODUCT_ID}"
    env_write_value "DB_CONNECTION" "mysql"
    env_write_value "DB_HOST" "${DB_HOST}"
    env_write_value "DB_PORT" "${DB_PORT}"
    env_write_value "DB_DATABASE" "${DB_NAME}"
    env_write_value "DB_USERNAME" "${DB_USER}"
    env_write_value "DB_PASSWORD" "${DB_PASS}"
}

app_get_variables() {
    local envfile="${APP_DIR}/.env"
    if [[ -f "$envfile" ]]; then
        section "Reading existing .env file for configuration"
        DOMAIN=$(grep -E '^APP_URL=' "$envfile" | cut -d'=' -f2 | sed 's|http[s]*://||' | sed 's|/.*||' || echo "")
        LICENSE_KEY=$(grep -E '^LICENSE_KEY=' "$envfile" | cut -d'=' -f2 || echo "")
        PRODUCT_ID=$(grep -E '^PRODUCT_ID=' "$envfile" | cut -d'=' -f2 || echo "")
        DB_ENGINE=$(grep -E '^DB_CONNECTION=' "$envfile" | cut -d'=' -f2 || echo "mariadb")
        [[ "$DB_ENGINE" == "mysql" ]] && DB_ENGINE="mysql" || DB_ENGINE="mariadb"
        DB_HOST=$(grep -E '^DB_HOST=' "$envfile" | cut -d'=' -f2 || echo "127.0.0.1")
        DB_PORT=$(grep -E '^DB_PORT=' "$envfile" | cut -d'=' -f2 || echo "3306")
        DB_NAME=$(grep -E '^DB_DATABASE=' "$envfile" | cut -d'=' -f2 || echo "dezerx")
        DB_USER=$(grep -E '^DB_USERNAME=' "$envfile" | cut -d'=' -f2 || echo "dezer")
        DB_PASS=$(grep -E '^DB_PASSWORD=' "$envfile" | cut -d'=' -f2 || echo "")
        
        if systemctl is-active --quiet nginx 2>/dev/null; then
            WEB="nginx"
            elif systemctl is-active --quiet apache2 2>/dev/null || systemctl is-active --quiet httpd 2>/dev/null; then
            WEB="apache"
        else
            die "No supported web server detected (nginx or apache)."
        fi
        
        section "Loaded values from .env: Domain=${DOMAIN}, Product ID=${PRODUCT_ID}, DB Engine=${DB_ENGINE}, Web Server=${WEB}"
    else
        section "No .env file found. Default values will be used."
    fi
}

app_install_steps(){
    COMPOSER_CMD="$(command -v composer || echo 'php /usr/local/bin/composer')"
    [[ -f "${APP_DIR}/composer.json" ]] && run "composer install" bash -lc "cd '${APP_DIR}' && COMPOSER_ALLOW_SUPERUSER=1 '${COMPOSER_CMD}' install --no-dev --optimize-autoloader -n --prefer-dist"
    [[ -f "${APP_DIR}/package.json"  ]] && run "npm install" bash -lc "cd '${APP_DIR}' && npm install"
    [[ -f "${APP_DIR}/package.json"  ]] && run "npm run build" bash -lc "cd '${APP_DIR}' && npm run build || true"
    run "artisan key:generate" bash -lc "cd '${APP_DIR}' && php artisan key:generate --force || true"
    run "artisan migrate --seed" bash -lc "cd '${APP_DIR}' && php artisan migrate --seed --force || true"
    run "php artisan storage:link" bash -lc "cd '${APP_DIR}' && php artisan storage:link || true"
}

app_update_steps(){
    COMPOSER_CMD="$(command -v composer || echo 'php /usr/local/bin/composer')"
    if [[ -f "${APP_DIR}/artisan" ]]; then
        run "artisan down (maintenance mode)" bash -lc "cd '${APP_DIR}' && php artisan down || true"
    fi
    [[ -f "${APP_DIR}/composer.json" ]] && run "composer install" bash -lc "cd '${APP_DIR}' && COMPOSER_ALLOW_SUPERUSER=1 '${COMPOSER_CMD}' install --no-dev --optimize-autoloader -n --prefer-dist"
    [[ -f "${APP_DIR}/package.json"  ]] && run "npm install" bash -lc "cd '${APP_DIR}' && npm install"
    [[ -f "${APP_DIR}/package.json"  ]] && run "npm run build" bash -lc "cd '${APP_DIR}' && npm run build || true"
    run "artisan migrate --force" bash -lc "cd '${APP_DIR}' && php artisan migrate --force || true"
    if [[ -f "${APP_DIR}/artisan" ]]; then
        run "artisan up (end maintenance mode)" bash -lc "cd '${APP_DIR}' && php artisan up || true"
    fi
}

apply_permissions(){
    run "Set ownership to ${APP_USER}:${APP_GROUP}" chown -R "${APP_USER}:${APP_GROUP}" "${APP_DIR}"
    run "Set permissions 755" chmod -R 755 "${APP_DIR}"
    [[ -d "${APP_DIR}/storage" ]] && run "storage perms" chmod -R ug+rwX "${APP_DIR}/storage" || true
    [[ -d "${APP_DIR}/bootstrap/cache" ]] && run "bootstrap/cache perms" chmod -R ug+rwX "${APP_DIR}/bootstrap/cache" || true
}

ensure_cron_running(){
    local cron_svc
    
    case "$DISTRO_ID" in
        debian|ubuntu) cron_svc="cron" ;;
        fedora|centos|rhel|almalinux|rocky) cron_svc="crond" ;;
        *) cron_svc="crond" ;;
    esac
    
    if start_service "$cron_svc"; then
        section "Cron service started. (${cron_svc})"
        return 0
    fi
    
    echo -e "Failed to start cron (${cron_svc}). please install & setup cron manually"
    return 1
}

setup_cron(){
    local cron_line="* * * * * cd ${APP_DIR} && php artisan schedule:run >> /dev/null 2>&1"
    ensure_cron_running
    if have crontab >/dev/null 2>&1; then
        run "Install cron for scheduler" bash -lc "(crontab -l 2>/dev/null | grep -v -F \"${cron_line}\"; echo \"${cron_line}\") | crontab -"
    fi
}

setup_systemd_queue(){
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
                pm_install certbot python3-certbot-nginx || pm_install certbot || true
            else
                pm_install certbot python3-certbot-apache || pm_install certbot || true
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

# Backup/Restore logic for updates
create_backup() {
    local backup_dir="/tmp/spartan_backup_$(date +%Y%m%d%H%M%S)"
    BACKUP_FILE="${backup_dir}.tar.gz"
    
    section "Creating backup of ${APP_DIR} at ${BACKUP_FILE}"
    mkdir -p "$(dirname "$BACKUP_FILE")"
    tar -czf "$BACKUP_FILE" -C "$(dirname "$APP_DIR")" "$(basename "$APP_DIR")" || die "Failed to create backup."
    echo "Backup created at: $BACKUP_FILE" | tee -a "$LOG"
}

create_db_backup() {
    if [[ "$DB_ENGINE" == "mysql" ]]; then
        local backup_dir="/tmp/spartan_db_backup_$(date +%Y%m%d%H%M%S)"
        DB_BACKUP_FILE="${backup_dir}.sql.gz"
        
        section "Creating database backup at ${DB_BACKUP_FILE}"
        mkdir -p "$(dirname "$DB_BACKUP_FILE")"
        mysqldump -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" | gzip > "$DB_BACKUP_FILE" || die "Failed to create database backup."
        echo "Database backup created at: $DB_BACKUP_FILE" | tee -a "$LOG"
        
        elif [[ "$DB_ENGINE" == "mariadb" ]]; then
        local backup_dir="/tmp/spartan_db_backup_$(date +%Y%m%d%H%M%S)"
        DB_BACKUP_FILE="${backup_dir}.sql.gz"
        
        section "Creating database backup at ${DB_BACKUP_FILE}"
        mkdir -p "$(dirname "$DB_BACKUP_FILE")"
        mysqldump -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" | gzip > "$DB_BACKUP_FILE" || die "Failed to create database backup."
        echo "Database backup created at: $DB_BACKUP_FILE" | tee -a "$LOG"
    else
        echo "Database backup skipped: Unsupported DB engine ${DB_ENGINE}" | tee -a "$LOG"
    fi
}

restore_backup() {
    if [[ -f "$BACKUP_FILE" ]]; then
        section "Restoring backup from ${BACKUP_FILE}"
        tar -xzf "$BACKUP_FILE" -C "$(dirname "$APP_DIR")" || die "Failed to restore backup."
        echo "Backup restored successfully."
    else
        die "No backup file found to restore."
    fi
}

restore_db_backup() {
    if [[ -f "$DB_BACKUP_FILE" ]]; then
        if [[ "$DB_ENGINE" == "mysql" || "$DB_ENGINE" == "mariadb" ]]; then
            section "Restoring database backup from ${DB_BACKUP_FILE}"
            gunzip < "$DB_BACKUP_FILE" | mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" || die "Failed to restore database backup."
            echo "Database backup restored successfully."
        else
            die "Unsupported database engine: ${DB_ENGINE}"
        fi
    else
        die "No database backup file found to restore."
    fi
}

cleanup_old_backups() {
    find /tmp -name "spartan_backup_*.tar.gz" -type f -mtime +7 -exec rm -f {} \;
    find /tmp -name "spartan_db_backup_*.sql.gz" -type f -mtime +7 -exec rm -f {} \;
}

# ---------------- Flow ----------------
need_root
detect_os
pm_update_upgrade 0
install_essentials

main_menu

if [[ "$CHOICE" == "install" ]]; then
    # Installation logic
    ask_domain
    ask_license_key
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

Product: ${PRODUCT_NAME} (ID: ${PRODUCT_ID})

    Proceed with installation (live output)?" 22 72 || exit 1
    
    # License part
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
    detect_web_user_group
    config_php_fpm
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
    echo "Product:      ${PRODUCT_NAME} (ID: ${PRODUCT_ID})"
    php -v | grep -qi ioncube && echo "ionCube:      enabled" || echo "ionCube:      not detected"
    echo "DB:           ${DB_USER}@${DB_HOST}:${DB_PORT}/${DB_NAME}"
    echo "Log:          ${LOG}"
    hr
    echo "Useful:"
    echo " systemctl status dezerx.service"
    echo " crontab -l"
    [[ "$WEB" == "nginx" ]] && echo " nginx logs: /var/log/nginx/" || echo " apache logs: /var/log/apache2/ or /var/log/httpd/"
    echo " SSL (if enabled): /etc/letsencrypt/live/${DOMAIN}/"
    hr
    exit 0
    
    elif [[ "$CHOICE" == "update" ]]; then
    # Get all needed variables
    app_get_variables
    
    # Validate APP_DIR exists
    if [[ ! -d "$APP_DIR" ]]; then
        echo "Error: Application directory $APP_DIR does not exist."
        exit 1
    fi
    
    # Validate required environment variables
    if [[ -z "$DOMAIN" || -z "$LICENSE_KEY" || -z "$PRODUCT_ID" || -z "$DB_ENGINE" || -z "$DB_HOST" || -z "$DB_PORT" || -z "$DB_NAME" || -z "$DB_USER" || -z "$DB_PASS" ]]; then
        echo "Error: Missing required configuration from .env file."
        exit 1
    fi
    
    # Backup app
    create_backup
    create_db_backup
    
    # License part
    license_verify
    license_download_and_extract
    
    # Install and set perms
    if app_update_steps; then
        apply_permissions
        
        # Restart services
        if [[ "$WEB" == "nginx" ]]; then
            restart_php_fpm
            run "Restart nginx" systemctl restart nginx
            elif [[ "$WEB" == "apache" ]]; then
            run "Restart Apache" systemctl restart apache2 || systemctl restart httpd
        else
            echo "Unknown web server, cannot restart." | tee -a "$LOG"
        fi
        
        section "All done!"
        echo "Domain:       ${DOMAIN}"
        echo "App Path:     ${APP_DIR}"
        echo "DocumentRoot: ${APP_DIR}/public"
        echo "Web server:   ${WEB}"
        echo "DB engine:    ${DB_ENGINE}"
        echo "Product:      ${PRODUCT_NAME} (ID: ${PRODUCT_ID})"
        php -v | grep -qi ioncube && echo "ionCube:      enabled" || echo "ionCube:      not detected"
        echo "DB:           ${DB_USER}@${DB_HOST}:${DB_PORT}/${DB_NAME}"
        echo "Log:          ${LOG}"
        hr
        echo "Useful:"
        echo " systemctl status dezerx.service"
        echo " crontab -l"
        [[ "$WEB" == "nginx" ]] && echo " nginx logs: /var/log/nginx/" || echo " apache logs: /var/log/apache2/ or /var/log/httpd/"
        echo " SSL (if enabled): /etc/letsencrypt/live/${DOMAIN}/"
        hr
    else
        restore_backup
        restore_db_backup
        die "Update failed, backup restored."
    fi
    
    # Cleanup old backups
    cleanup_old_backups
    exit 0
fi
