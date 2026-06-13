#!/usr/bin/env bash
# DezerX Spartan – Interactive Installer
# Distros: Ubuntu/Debian, CentOS/RHEL/Alma/Rocky, Fedora
# Made by HdBento & Anthony S

set -euo pipefail
trap 'echo "${RED}[ERR]${NC} An error occurred at line ${LINENO} while executing: ${BASH_COMMAND}" | tee /dev/tty >&2' ERR

TITLE="DezerX Spartan Installer"
LOG="/var/log/spartan_installer.log"
DOMAIN=""
APP_DIR="/var/www/spartan"
APP_DEFAULT_DIR="/var/www/spartan"
IONCUBE_DIR="/usr/local/ioncube"
BACKUP_DIR="/tmp/spartan"
CERT_DIR="/etc/letsencrypt/live/${DOMAIN}"
APP_USER_DEFAULT="www-data"
APP_GROUP_DEFAULT="www-data"
PHP_VER="8.4"

FORCE_SWAP=0
SWAP_SIZE="1024"

OPTIONS_JSON_NAME="script_options.json"

ACTION=""
ASSUME_YES=0
SHOW_HELP=0
NONINTERACTIVE=0
USED_APP_DIR=0
ENABLE_IPV6=0
KEEP_NGINX=0
KEEP_THEMES=1
KEEP_PORTALS=1
KEEP_EMAILS=1
KEEP_FAVICON=1
KEEP_CSS=1

mkdir -p "$(dirname "$LOG")"
exec 3>&1
exec 4>>"$LOG"
exec > >(tee -a "$LOG") 2>&1

# -------- Pretty output helpers --------
WHITE=$'\e[0;37m'
GRAY=$'\e[1;30m'
RED=$'\e[0;31m'
GREEN=$'\e[0;32m'
YELLOW=$'\e[1;33m'
BLUE=$'\e[0;34m'
PURPLE=$'\e[0;35m'
CYAN=$'\e[0;36m'
L_CYAN=$'\e[1;36m'
NC=$'\e[0m'

STEP_COUNTER=1
ts() { date +"%Y-%m-%d %H:%M:%S"; }
hr() { 
    sleep 0.02
    echo -e "${BLUE}---------------------------------------------------------------------${NC}" >&3 
}
section() { 
    hr
    echo -e "${GRAY}[$(ts)]${NC} ${WHITE}>>>${NC} ${CYAN}$*${NC}" >&3
    echo "[$(ts)] >>> $*" >&4
    hr
}

step() { 
    sleep 0.02
    echo -e "\n${BLUE}=====================================================================${NC}\n" >&3
    echo -e "${GRAY}[$(ts)]${NC} ${WHITE}>>>${NC} ${YELLOW}STEP ${STEP_COUNTER}: $*${NC}" >&3
    echo -e "\n${BLUE}=====================================================================${NC}\n" >&3
    echo "[$(ts)] =============== STEP ${STEP_COUNTER}: $* ===============" >&4
    STEP_COUNTER=$((STEP_COUNTER + 1))
}
cmdshow() { echo "$ $*" >&4; }

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
    
    echo "[$(ts)] $desc" >&4
    echo "$ $cmdstr" >&4
    
    local tmpout
    tmpout=$(mktemp)
    
    # Run command in background
    "$@" > "$tmpout" 2>&1 &
    local pid=$!
    
    local spin='-\|/'
    local i=0
    
    # Hide cursor
    echo -ne "\033[?25l" >&3
    
    while kill -0 $pid 2>/dev/null; do
        i=$(( (i+1) %4 ))
        local last_line=""
        if [ -s "$tmpout" ]; then
            last_line=$(tail -n 1 "$tmpout" | sed 's/\x1b\[[0-9;]*m//g' | tr -dc '[:print:]' | cut -c 1-50)
        fi
        
        printf "\r\033[K${YELLOW}${spin:$i:1}${NC} %.50s | %.50s" "$desc" "$last_line" >&3
        sleep 0.1
    done
    set +e
    wait $pid
    local extcode=$?
    set -e
    
    # Show cursor
    echo -ne "\033[?25h" >&3
    
    if [ $extcode -eq 0 ]; then
        printf "\r\033[K${GREEN}✔${NC} %s\n" "$desc" >&3
        cat "$tmpout" >&4
    else
        printf "\r\033[K${RED}✘${NC} %s (Failed)\n" "$desc" >&3
        echo -e "${RED}--- Output ---${NC}" >&3
        cat "$tmpout" >&3
        echo -e "${RED}--------------${NC}" >&3
        cat "$tmpout" >&4
    fi
    rm -f "$tmpout"
    return $extcode
}

need_root(){ [[ $EUID -eq 0 ]] || { echo -e "${RED}Run as root (sudo).${NC}" >&3; exit 1; }; }
have(){ command -v "$1" >/dev/null 2>&1; }
die(){ echo >&3; hr; echo -e "${RED}ERROR:${NC} $*" >&3; echo "See log: $LOG" >&3; hr; echo "ERROR: $*" >&4; exit 1; }
warn(){ echo >&3; hr; echo -e "${YELLOW}!\033[K Warning: $*${NC}" >&3; hr; echo "WARN: $*" >&4; }
error(){ echo >&3; hr; echo -e "${RED}ERROR:${NC} $*" >&3; echo "See log: $LOG" >&3; hr; echo "ERROR: $*" >&4; }

detect_os(){ source /etc/os-release || true; DISTRO_ID="${ID:-unknown}"; DISTRO_VER="${VERSION_ID:-}"; section "Detected OS: ${DISTRO_ID} ${DISTRO_VER}"; }

pm_install(){
    local desc
    if [[ -n "$1" ]] && [[ "$1" =~ [[:space:]:] ]]; then
        desc="$1"
        shift
    else
        desc="Installing: $*"
    fi
    
    case "$DISTRO_ID" in
        debian|ubuntu) run "${desc}" apt-get install -y "$@" ;;
        centos|rhel|almalinux|rocky) if have dnf; then run "${desc}" dnf -y --setopt=install_weak_deps=False install "$@"; else run "${desc}" yum -y install "$@"; fi ;;
        fedora) run "${desc}" dnf -y --setopt=install_weak_deps=False install "$@" ;;
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
                run "apt dist-upgrade" apt-get dist-upgrade -y;
            fi
        ;;
        centos|rhel|almalinux|rocky|fedora)
            if have dnf; then
                if ! run "dnf upgrade" dnf upgrade --refresh -y; then
                    echo "dnf upgrade failed, attempting distro-sync"
                    run "dnf distro-sync" dnf distro-sync -y
                fi

                if ((full)); then
                    run "dnf dist-upgrade" dnf upgrade --allowerasing -y
                fi
            else
                run "yum makecache" yum makecache fast -y
                run "yum upgrade" yum upgrade -y
            fi
        ;;
    esac
}

install_essentials(){
    local pkgs=()
    
    case "$DISTRO_ID" in
        debian|ubuntu)
            pkgs=(curl apt-transport-https ca-certificates gnupg lsb-release jq unzip rsync tar file openssl procps cron diffutils)
        ;;
        fedora|centos|rhel|almalinux|rocky)
            pkgs=(curl ca-certificates gnupg jq unzip rsync tar file openssl procps cronie diffutils)
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
    
    if is_systemd && have systemctl; then
        section "Attempting to start ${svc} via systemctl"
        if run "systemctl enable --now ${svc}" systemctl enable --now "$svc" || run "Using fallback (systemctl start ${svc})" systemctl start "$svc"; then
            return 0
        fi
    fi
    
    if have rc-service; then
        section "Attempting to start ${svc} via rc-service"
        if run "rc-service ${svc} start" rc-service "$svc" start; then
            return 0
        fi
    fi
    
    if have service; then
        section "Attempting to start ${svc} via service"
        if run "service ${svc} start" service "$svc" start; then
            return 0
        fi
    fi
    
    return 1
}

ensure_options_json(){
    local f; f="${APP_DIR}/${OPTIONS_JSON_NAME}"
    if [[ ! -f "${f}" ]]; then
        run "Creating ${OPTIONS_JSON_NAME}" bash -lc "cat > '${f}' <<'EOF'
{
    \"keep\": {
        \"nginx\": false,
        \"css\": true,
        \"themes\": true,
        \"portals\": true,
        \"emails\": true,
        \"favicon\": true
    },
    \"exclude\": {
        \"files\": [],
        \"folders\": []
    },
    \"delete\": []
}
EOF"
    fi
}

load_options_json_flags(){
    local json_file="${APP_DIR}/${OPTIONS_JSON_NAME}"
    [[ -f "$json_file" ]] || return 0


    if ! jq -e . "$json_file" >/dev/null 2>&1; then
        echo "Invalid json in ${json_file}. Skipping advanced exclusions."
        return 0
    fi

    section "Reading keep preferences from ${OPTIONS_JSON_NAME}"

    while IFS='=' read -r key val; do
        [[ -z "$key" ]] && continue

        local upper_key="${key^^}"

        if [[ "$val" == "true" ]]; then
            printf -v "KEEP_${upper_key}" "1"
            echo "KEEP_${upper_key}=1"
        elif [[ "$val" == "false" ]]; then
            printf -v "KEEP_${upper_key}" "0"
            echo "KEEP_${upper_key}=0"
        fi
    done < <(jq -r '.keep? | to_entries[]? | "\(.key)=\(.value)"' "$json_file")
}

process_options_json(){
    local json_file="${APP_DIR}/${OPTIONS_JSON_NAME}"
    [[ -f "$json_file" ]] || return 0

    section "Processing exclusions from ${OPTIONS_JSON_NAME}"

    if ! jq -e . "$json_file" >/dev/null 2>&1; then
        warn "Invalid json in ${json_file}. Skipping advanced exclusions."
        return 0
    fi

    EXCLUDE_TMPDIR=$(mktemp -d "/tmp/spartan_exclude.XXXXXX")
    run "Saving exclusions state" cp -a "$json_file" "${EXCLUDE_TMPDIR}/${OPTIONS_JSON_NAME}"

    _do_deletions() {
        local total_items=$(jq -r '.delete | length' "$json_file" 2>/dev/null || echo 0)
        local idx=0
        jq -r '.delete[]? // empty' "$json_file" | while read -r item; do
            idx=$((idx + 1))
            item=$(echo "$item" | xargs)
            [[ -z "$item" ]] && continue
            good_path="${item#"$APP_DIR"}"
            good_path="${good_path#/}"
            good_path="${good_path%/}"
            if [[ -z "$good_path" || "$good_path" == "." || "$good_path" == ".." || "$good_path" == *".."* ]]; then
                continue
            fi
            src_path="${APP_DIR}/${good_path}"
            if [[ "$src_path" != "$APP_DIR"/* ]]; then
                continue
            fi
            if [[ -e "$src_path" ]]; then
                rm -fr "$src_path" || true
                echo "$idx/$total_items | deleted $good_path"
            fi
        done
    }

    _do_exclusions() {
        local total_items=$(jq -r '(.exclude.files | length) + (.exclude.folders | length)' "$json_file" 2>/dev/null || echo 0)
        local idx=0
        jq -r '.exclude.files[]?, .exclude.folders[]? // empty' "$json_file" | while read -r item; do
            idx=$((idx + 1))
            item=$(echo "$item" | xargs)
            [[ -z "$item" ]] && continue
            good_path="${item#"$APP_DIR"}"
            good_path="${good_path#/}"
            good_path="${good_path%/}"
            [[ -z "$good_path" || "$good_path" == "." || "$good_path" == ".." ]] && continue
            src_path="${APP_DIR}/${good_path}"
            if [[ -e "$src_path" ]]; then
                mkdir -p "${EXCLUDE_TMPDIR}/$(dirname "$good_path")"
                cp -a "$src_path" "${EXCLUDE_TMPDIR}/${good_path}"
                echo "$idx/$total_items | queued $good_path"
            fi
        done
    }

    run "Deleting excluded options.json items" _do_deletions
    run "Backing up excluded options.json items" _do_exclusions
}

restore_options_items(){
    if [[ -n "${EXCLUDE_TMPDIR:-}" && -d "${EXCLUDE_TMPDIR:-}" ]]; then
        section "Restoring items from ${OPTIONS_JSON_NAME}"
        rsync -a --ignore-missing-args "${EXCLUDE_TMPDIR:-}/" "${APP_DIR}/"
        [[ -n "${EXCLUDE_TMPDIR}" && "${EXCLUDE_TMPDIR}" != "/" ]] && rm -fr "${EXCLUDE_TMPDIR}" || true
    fi
}

app_prepare_dir(){
    run "Ensuring app directory '${APP_DIR}' exists" bash -lc "mkdir -p '${APP_DIR}'"

    [ -z "$APP_DIR" ] && { echo "'${APP_DIR}' is empty no need to delete anything."; return 0; }
    [ "$APP_DIR" = "/" ] && { echo "Refusing to run on /"; return 1; }

    update_tmpdir=""
    css_save_methode=""

    if [[ $CHOICE == "update" ]]; then
        process_options_json
        update_tmpdir=$(mktemp -d "${APP_DIR}/.cleanup.XXXXXX") || { echo "mktemp failed"; return 1; }

        if [[ "$KEEP_CSS" == 1 ]]; then
            if php "${APP_DIR}/artisan" help theme:backup --no-interaction >/dev/null 2>&1; then
                css_save_methode="php"
            else
                css_save_methode="fallback"
            fi

            if [[ "$css_save_methode" == "php" ]]; then
                if ! run "Saving dashboard css (Methode: php)" bash -lc "cd '${APP_DIR}' && php artisan theme:backup --save"; then
                    css_save_methode="fallback"
                    run "Saving dashboard css (Methode: fallback)" bash -lc "mv -- '${APP_DIR}/resources/css/' '${update_tmpdir}/' 2>/dev/null || true"
                fi
            else
                css_save_methode="fallback"
                run "Saving dashboard css (Methode: fallback)" bash -lc "mv -- '${APP_DIR}/resources/css/' '${update_tmpdir}/' 2>/dev/null || true"
            fi
        fi

        if [[ "$KEEP_THEMES" == 1 ]]; then
            run "Saving themes" bash -lc "rsync -a --remove-source-files --ignore-missing-args '${APP_DIR}/resources/js/pages/theme' '${update_tmpdir}/' 2>/dev/null || true"
        fi

        if [[ "$KEEP_PORTALS" == 1 ]]; then
            if [[ -d "${APP_DIR}/resources/js/pages/Portal" ]]; then
                portals="$(find "${APP_DIR}/resources/js/pages/Portal" -mindepth 1 -maxdepth 1 -type d ! -iname "default" -printf '.' | wc -c)"
                if [[ "$portals" -gt 0 ]]; then
                    [[ ! -d "${update_tmpdir}/Portals" ]] && mkdir -p "${update_tmpdir}/Portals"
                    run "Saving dashboard portals" bash -lc "rsync -a --remove-source-files --exclude='Default' --exclude='default' '${APP_DIR}/resources/js/pages/Portal/' '${update_tmpdir}/Portals/' 2>/dev/null || true"
                else
                    echo "No custom portals found to save - skipping"
                fi
            else
                echo "Portal source directory does not exist - skipping"
            fi
        fi

        if [[ "$KEEP_EMAILS" == 1 ]]; then
            run "Saving email templates" bash -lc "rsync -a --remove-source-files --ignore-missing-args '${APP_DIR}/resources/views/emails' '${update_tmpdir}/' 2>/dev/null || true"
        fi

        if [[ "$KEEP_FAVICON" == 1 ]]; then
            _do_save_favicon() {
                [[ ! -d "${update_tmpdir}/favicon" ]] && mkdir -p "${update_tmpdir}/favicon"
                rsync -a --remove-source-files --ignore-missing-args \
                    "${APP_DIR}/public/favicon.ico" \
                    "${APP_DIR}/public/favicon.svg" \
                    "${update_tmpdir}/favicon/" 2>/dev/null || true
            }
            run "Saving favicon" _do_save_favicon
        fi

        run "Saving application core folders" rsync -a --remove-source-files --ignore-missing-args \
            "${APP_DIR}/storage" \
            "${APP_DIR}/public" \
            "${APP_DIR}/Modules" \
            "${APP_DIR}/modules_statuses.json" \
            "${APP_DIR}/.env" \
            "${update_tmpdir}/"
    fi

    _do_cleanup() {
        shopt -s dotglob nullglob
        local entries=("${APP_DIR}"/*)
        local total=${#entries[@]}
        local i=0
        for entry in "${entries[@]}"; do
            [ "${entry}" = "${update_tmpdir}" ] && continue
            i=$((i + 1))
            rm -fr -- "${entry}"
            echo "$i/$total | removed $(basename "$entry")"
        done
    }
    run "Cleaning up old application directory" _do_cleanup

    if [[ $CHOICE == "update" ]]; then
        run "Restoring application core folders" bash -c "rsync -aI --remove-source-files --ignore-missing-args '${update_tmpdir}/storage' '${update_tmpdir}/public' '${APP_DIR}/' 2>/dev/null || true"
        run "Restoring modules_statuses.json" bash -c "mv -- '${update_tmpdir}/modules_statuses.json' '${APP_DIR}/modules_statuses.json.old' 2>/dev/null || true"
        if [[ "$KEEP_PORTALS" == 1 && -d "${update_tmpdir}/Portals" ]]; then
            run "Ensuring dashboard portal directory exists" mkdir -p "${APP_DIR}/resources/js/pages/Portal"
            run "Restoring dashboard portals" bash -lc "rsync -aI --remove-source-files --ignore-missing-args '${update_tmpdir}/Portals/' '${APP_DIR}/resources/js/pages/Portal/' 2>/dev/null || true"
        fi
        if [[ "$KEEP_THEMES" == 1 && -d "${update_tmpdir}/theme" ]]; then
            run "Ensuring themes directory exists" mkdir -p "${APP_DIR}/resources/js/pages/theme"
            run "Restoring themes" bash -lc "rsync -aI --remove-source-files --ignore-missing-args '${update_tmpdir}/default/' '${APP_DIR}/resources/js/pages/theme/default/' || true"
        fi
        if [[ "$KEEP_EMAILS" == 1 && -d "${update_tmpdir}/emails" ]]; then
            mkdir -p "${APP_DIR}/resources/views/emails"
            run "Restoring email templates" bash -lc "rsync -aI --remove-source-files --ignore-missing-args '${update_tmpdir}/emails/' '${APP_DIR}/resources/views/emails/' || true"
        fi
    fi
}

# Restores the user's modules into the freshly-deployed release, sorting each
# one into its category sub-folder (Gateways/Services/Providers/Addons) by name suffix.
# Modules that already ship with the new release are skipped (new version wins);
# only genuinely user-added modules are preserved. Runs AFTER the new release is
# deployed so the "already shipped?" check sees the new Modules tree.
app_restore_modules(){
    local saved="${update_tmpdir}/Modules"
    local dest="${APP_DIR}/Modules"

    [[ -d "$saved" ]] || { echo "No saved modules to restore - skipping"; return 0; }
    mkdir -p "$dest"

    local restored=0 skipped=0
    while IFS= read -r -d '' modjson; do
        local moddir name sub
        moddir="$(dirname "$modjson")"
        name="$(basename "$moddir")"

        # New release wins: if a module with this name already ships in the new
        # release (in any category sub-folder, or flat), keep the new version.
        if [[ -n "$(find "$dest" -mindepth 1 -maxdepth 2 -type d -name "$name" -print -quit 2>/dev/null)" ]]; then
            echo "Skipping '${name}' - shipped with new release (keeping new version)"
            skipped=$((skipped + 1))
            continue
        fi

        # User-added module: sort into the correct category by name suffix.
        case "$name" in
            *Gateway)  sub="Gateways"  ;;
            *Service)  sub="Services"  ;;
            *Provider) sub="Providers" ;;
            *)         sub="Addons"    ;;
        esac

        mkdir -p "${dest}/${sub}"
        rsync -aI --ignore-missing-args "${moddir}/" "${dest}/${sub}/${name}/" 2>/dev/null || true
        echo "Preserved custom module '${name}' -> Modules/${sub}/"
        restored=$((restored + 1))
    done < <(find "$saved" -mindepth 1 -name module.json -print0 2>/dev/null)

    echo "User modules preserved: ${restored} | skipped (shipped with release): ${skipped}"
    rm -rf -- "$saved" 2>/dev/null || true
}

app_restore_files(){
    run "Restoring .env configuration" bash -c "rsync -aI --remove-source-files --ignore-missing-args '${update_tmpdir}/.env' '${APP_DIR}/' 2>/dev/null || true"
    [[ "$KEEP_FAVICON" == 1 ]] && run "Restoring favicon files" bash -c "rsync -aI --remove-source-files --ignore-missing-args '${update_tmpdir}/favicon/' '${APP_DIR}/public/' 2>/dev/null || true"
    if [[ "$KEEP_CSS" == 1 && "$css_save_methode" == "fallback" ]]; then
        run "Restoring dashboard css (Methode: fallback)" bash -lc "rsync -aI --remove-source-files --ignore-missing-args '${update_tmpdir}/css/' '${APP_DIR}/resources/css/' 2>/dev/null || true"
    fi
    rmdir -- "${update_tmpdir}" 2>/dev/null || true
}

app_merge_json(){
    local old="$1"
    local new="$2"
    local merged="$3"

    if [[ ! -f "$old" || ! -f "$new" ]]; then
        echo "both old and new files need to be present for merge. $(basename ${old}) -> $(basename ${new})"
        return 1
    fi

    section "Merging: $(basename ${old}) -> $(basename ${new})"

    jq -s '
        .[0] as $old |
        .[1] as $new |
        ( ($old|keys) + ($new|keys) | unique ) as $ks |
        reduce $ks[] as $k ( {}; .[$k] = ( if ($old | has($k)) then $old[$k] else $new[$k] end ) )
    ' "$old" "$new" > "${merged}.tmp" || { echo "Failed to merge $(basename ${old}) -> $(basename ${new})"; return 1; }

    mv -- "${merged}.tmp" "$merged"
    rm -f "$old" "$new"
    section "Merged to ${merged}"
}

load_env_into_array() {
    local file="$1"
    local -n arr_ref="$2"

    [[ -f "$file" ]] || return 0
    while IFS='=' read -r key value; do
        [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
        key=$(echo "$key" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        value=$(echo "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

        if [[ "${value}" =~ ^\"(.*)\"$ ]]; then
            value="${BASH_REMATCH[1]}"
        elif [[ "${value}" =~ ^\'(.*)\'$ ]]; then
            value="${BASH_REMATCH[1]}"
        fi

        value=$(echo "${value}" | sed -e 's/\\\\/\\/g' -e 's/\\"/"/g')
        arr_ref["$key"]="$value"
    done < "$file"
}

no_apache(){
    [[ "$WEB" != "nginx" ]] && { section "No need to deactivate apache (skipping)"; return 0; }

    local pkg_name svc_name sock_name

    case "$DISTRO_ID" in
        debian|ubuntu)
            pkg_name="apache2"
            svc_name="apache2.service"
            sock_name="apache2.socket"
            ;;
        fedora|centos|rhel|almalinux|rocky)
            pkg_name="httpd"
            svc_name="httpd.service"
            sock_name="httpd.socket"
            ;;
        *)
            section "Unsupported distro ($DISTRO_ID) - cannot detect Apache"
            return 1
            ;;
    esac

    unit_exists() {
        systemctl list-unit-files "$1" >/dev/null 2>&1
    }

    package_installed() {
        case "$DISTRO_ID" in
            debian|ubuntu) dpkg -s "$1" >/dev/null 2>&1 ;;
            *) rpm -q "$1" >/dev/null 2>&1 ;;
        esac
    }

    if package_installed "$pkg_name" || unit_exists "$svc_name" || unit_exists "$sock_name" 2>/dev/null; then
        echo "Found a apache cave diver, deactivating it."
        if unit_exists "$svc_name"; then
            run "stopping apache" systemctl stop "$svc_name" || true
            run "deactivating apache" systemctl disable "$svc_name" || true
        fi

        if unit_exists "$sock_name"; then
            run "stopping apache.socket" systemctl stop "$sock_name" || true
            run "deactivating apache.socket" systemctl disable "$sock_name" || true
        fi
    else
        echo "No apache cave diver found"
    fi
}

rotate_backups(){
    section "Rotating old backups (Keeping the 7 most recent of each type)"

    local prefixes=(
        "spartan_backup_"
        "spartan_db_backup_"
        "spartan_php_backup_"
        "spartan_ioncube_backup_"
        "spartan_conf_backup_"
    )

    for prefix in "${prefixes[@]}"; do
        ls -t "${BACKUP_DIR}/${prefix}"* 2>/dev/null | tail -n +8 | xargs -r rm -f || true
    done

    echo "Old backups cleaned up."
}

setup_permanent_swap(){
    if systemd-detect-virt -q --container 2>/dev/null || grep -qa 'container=' /proc/1/environ 2>/dev/null; then
        section "Container environment detected. Skipping swap creation."
        echo "Containers cannot manage kernel swap space. Please ensure your host node has adequate swap allocated."
        return 0
    fi

    local target_mb=0
    local mem_pad=50
    local total_ram=0
    
    if [[ "${FORCE_SWAP:-0}" == 1 ]]; then
        if [[ "$SWAP_SIZE" == *"G" || "$SWAP_SIZE" == *"g" ]]; then
            target_mb=$((${SWAP_SIZE%[Gg]} * 1024 ))
        elif [[ "$SWAP_SIZE" == *"M" || "$SWAP_SIZE" == *"m" ]]; then
            target_mb=${SWAP_SIZE%[Mm]}
        else
            target_mb=2048
        fi
    else
        total_ram=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
        target_mb=2048

        if (( total_ram > target_mb )); then
            return 0
        fi
    fi

    local current_swap
    current_swap=$(awk '/SwapTotal/ {printf "%d", $2/1024}' /proc/meminfo)
    
    if (( current_swap >= (target_mb - mem_pad) )); then
        return 0
    fi

    if [[ "${FORCE_SWAP:-0}" == 1 ]]; then
        section "Swap requested via flag. Target: ${target_mb}MB"
    else
        section "Low memory detected (${total_ram}MB)."
    fi

    echo "Current swap (${current_swap}MB) is less than required (${target_mb}MB)."

    local swap_file="/swapfile"

    if grep -q "$swap_file" /proc/swaps; then
        run "Disabling old swap file" swapoff "$swap_file" || true
    fi

    if [[ -f "$swap_file" ]]; then
        run "Removing old swap file" rm -f "$swap_file"
    fi

    run "Allocating ${target_mb}MB swap file" bash -c "fallocate -l ${target_mb}M ${swap_file} 2>/dev/null || dd if=/dev/zero of=${swap_file} bs=1M count=${target_mb} status=none"
    run "Formatting swap file" bash -lc "chmod 600 ${swap_file} && mkswap ${swap_file}"
    run "Enabling swap file" swapon "$swap_file"

    if ! grep -q "^${swap_file}" /etc/fstab; then
        run "Adding swap to /etc/fstab" bash -c "echo '${swap_file} none swap sw 0 0' >> /etc/fstab"
    fi

    if ! grep -q "vm.swappiness" /etc/sysctl.conf /etc/sysctl.d/* 2>/dev/null; then
        run "Tuning swappiness to 10" bash -c "sysctl vm.swappiness=10 && echo 'vm.swappiness=10' > /etc/sysctl.d/99-spartan-swappiness.conf" || true
    fi

    echo "Swap upgraded and enabled successfully."
}

check_db_connection() {
    section "Testing Database Connection"
    echo -e "Testing connection to ${DB_HOST}:${DB_PORT} as user '${DB_USER}'..."

    if output=$(mysql --connect-timeout=5 -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASS" -e "SELECT 1;" 2>&1); then
        echo "Database connection successful!"
        return 0
    else
        echo -e "CRITICAL: Could not connect to the database ${DB_NAME} at ${DB_HOST}."
        echo "Please check your credentials and ensure the database server is running."

        echo -e "\n--- Detailed MySQL Error ---"
        echo "$output"
        echo "----------------------------"
        return 1
    fi
}

showcase_colors(){
    section "Color UI Showcase"
    echo -e "${WHITE}White text${NC}" >&3
    echo -e "${GRAY}Gray text${NC}" >&3
    echo -e "${RED}Red text${NC}" >&3
    echo -e "${GREEN}Green text${NC}" >&3
    echo -e "${YELLOW}Yellow text${NC}" >&3
    echo -e "${BLUE}Blue text${NC}" >&3
    echo -e "${PURPLE}Purple text${NC}" >&3
    echo -e "${CYAN}Cyan text${NC}" >&3
    echo -e "${L_CYAN}Light cyan text${NC}" >&3
    run "Simulating a fast background task" bash -c "echo 'Working...' && sleep 1"
    run "Simulating a failing task" bash -c "echo 'Oops, something went wrong!' && exit 1" || true
}

smoke_test(){
    section "Performing Smoke Test"

    local protocol="http"
    [[ "${certbot_choice:-}" != "later" && -n "${certbot_choice:-}" ]] && protocol="https"

    local target_url="${protocol}://127.0.0.1"
    echo "Checking if ${target_url} is online..."

    local max_attempts=3
    local attempt=1
    local status_code=0

    while (( attempt <= max_attempts )); do
        status_code=$(curl -s -o /dev/null -w "%{http_code}" -H "Host: ${DOMAIN}" --insecure "${target_url}" || echo "000")

        if [[ "$status_code" == "200" || "$status_code" == "301" || "$status_code" == "302" ]]; then
            echo  "Smoke Test Passed! Website is responding (HTTP $status_code)."
            return 0
        fi

        echo "Attempt $attempt/$max_attempts: Received HTTP $status_code. Retrying in 3 seconds..."
        sleep 3
        ((attempt++))
    done

    warn "Smoke Test failed.\nThe website returned HTTP $status_code instead of a success code.\nThe installation completed, but you may need to check your NGINX/Apache error logs."
}

sync_server_time(){
    section "Synchronizing System Time (NTP)"

    if systemd-detect-virt -q --container 2>/dev/null || grep -qa 'container=' /proc/1/environ 2>/dev/null; then
        echo "Container environment detected. Skipping time synchronization."
        echo "Note: Containers share the host's clock. If you get SSL errors, fix the host machine's time."
        return 0
    fi

    if have timedatectl; then
        run "Syncing time via timedatectl" timedatectl set-ntp true || true
        echo "System time synced via systemd (timedatectl): $(date)"
        return 0
    fi

    if have ntpdate; then
        run "Syncing time via ntpdate" ntpdate -u pool.ntp.org || true
        echo "Time synced via ntpdate: $(date)"
        return 0
    fi

    if ! have chronyc; then
        run "Installing chrony" pm_install chrony
    fi
    if have chronyc; then
        local chrony_svc="chronyd"
        [[ "$DISTRO_ID" == "debian" || "$DISTRO_ID" == "ubuntu" ]] && chrony_svc="chrony"

        start_service "$chrony_svc" || true

        run "Syncing time via chrony" chronyc -a makestep || true
        echo "Time synced via chrony: $(date)"
        return 0
    fi

    warn "No supported time synchronization tool installed/found. Current system time: $(date)"
}

# ---------------- Menus ----------------
main_menu(){
    while :; do
        local input=""
        input=$(whiptail --title "$TITLE" --menu "Welcome to the DezerX Spartan installer.\nChoose an option:\n" 14 72 4 \
            "install" "Install DezerX Spartan" \
            "update" "Update DezerX Spartan" \
            "uninstall" "Delete DezerX Spartan" \
            "debug" "Open the debug menu" 3>&1 1>&2 2>&3) || { echo "Operation cancelled."; exit 0; }
        
        if [[ "$input" == "debug" ]]; then
            input=$(whiptail --title "$TITLE" --menu "DezerX Spartan installer Debug Menu.\nChoose an option:\n" 14 72 4 \
                "setup perms" "Apply permissions on a installation" \
                "upload logs" "Upload logs" \
                "back" "Go back to the main menu" 3>&1 1>&2 2>&3) || { echo "Operation cancelled."; exit 0; }
        fi
        if [[ "$input" == "upload logs" ]]; then
            whiptail --title "$TITLE" --msgbox "I couldn't find a secure platform where to send the logs, so this function doesn't work for now." 8 50
            continue
        fi
        [[ "$input" == "debug" || "$input" == "back" ]] && continue
        CHOICE="$input"
        break
    done
}

ask_domain(){
    if [[ -z "${DOMAIN:-}" ]]; then
        while :; do
            DOMAIN=$(whiptail --title "$TITLE" --inputbox "Enter your primary domain (e.g. example.com)\nThis will be used for vHost, APP_URL and SSL." 10 70 "" 3>&1 1>&2 2>&3) || exit 1
            [[ -n "$DOMAIN" ]] && break
            whiptail --title "$TITLE" --msgbox "Domain is required." 8 50
            section "Domain set to: ${DOMAIN}"
        done
    else
        echo "Skipping domain prompt, using provided domain."
    fi
    CERT_DIR="/etc/letsencrypt/live/${DOMAIN}"
}

ask_app_dir(){
    local default_dir="$APP_DIR"
    if [[ "$ASSUME_YES" == 1 ]]; then
        echo "Assuming yes, using default dir."
    else
        if [[ "$NONINTERACTIVE" == 0 && "$APP_DIR" == "$APP_DEFAULT_DIR" && "$USED_APP_DIR" == 0 ]]; then
            APP_DIR=$(whiptail --title "$TITLE" --inputbox "Application directory (DocumentRoot = APP_DIR/public)\n\nEdit if needed:" 12 70 "$default_dir" 3>&1 1>&2 2>&3) || exit 1
        else
            echo "Skipping app dir prompt, using provided app dir."
        fi
    fi
    section "APP_DIR set to: ${APP_DIR}"
}

ask_update_app_dir(){
    local default_dir="$APP_DIR"
    APP_DIR=$(whiptail --title "$TITLE" --inputbox "Please Provide the path to the application directory (Where spartan is installed)\n\nEdit:" 12 70 "$default_dir" 3>&1 1>&2 2>&3) || exit 1
    section "APP_DIR set to: ${APP_DIR}"
}

choose_webserver(){
    if [[ -z "${WEB:-}" ]]; then
        WEB=$(whiptail --title "$TITLE" --radiolist "Select your web server" 15 70 2 \
            "nginx"  "Nginx (recommended)" ON \
            "apache" "Apache (not a option)" OFF \
        3>&1 1>&2 2>&3) || exit 1
    else
        echo "Skipping webserver prompt, using provided webserver."
    fi
    [[ "$WEB" == "apache" ]] && exit 1
    section "Web server: ${WEB}"
}

choose_db_engine(){
    if [[ -z "${DB_ENGINE:-}" ]]; then
    DB_ENGINE=$(whiptail --title "$TITLE" --radiolist "Choose database server" 12 70 2 \
        "mariadb" "MariaDB Server" ON \
        "mysql"   "MySQL Server" OFF \
    3>&1 1>&2 2>&3) || exit 1
    else
        echo "Skipping database type prompt, using provided database type."
    fi
    section "DB engine: ${DB_ENGINE}"
}

# ---------------- DB Wizard ----------------
DB_HOST="127.0.0.1"; DB_PORT="3306"; DB_NAME="dezerx"; DB_USER="dezer"; DB_PASS=""
db_collect(){
    if [[ "$ASSUME_YES" == 0 ]]; then
        DB_HOST=$(whiptail --title "$TITLE" --inputbox "Database Host" 10 70 "${DB_HOST}" 3>&1 1>&2 2>&3) || exit 1
        DB_PORT=$(whiptail --title "$TITLE" --inputbox "Database Port" 10 70 "${DB_PORT}" 3>&1 1>&2 2>&3) || exit 1
        DB_NAME=$(whiptail --title "$TITLE" --inputbox "Database Name" 10 70 "${DB_NAME}" 3>&1 1>&2 2>&3) || exit 1
        DB_USER=$(whiptail --title "$TITLE" --inputbox "Database User" 10 70 "${DB_USER}" 3>&1 1>&2 2>&3) || exit 1
    else
        echo "Assuming yes, using default settings for database setup"
    fi
    while :; do
        [[ "$ASSUME_YES" == 0 ]] && DB_PASS=$(whiptail --title "$TITLE" --passwordbox "Database Password\n\nUse a strong unique password.\n\nLeave empty to auto-generate one." 12 70 3>&1 1>&2 2>&3)
        if [[ -z "$DB_PASS" ]]; then
            DB_PASS=$(openssl rand -hex 16)
            if [[ "$ASSUME_YES" == 0 ]]; then
                whiptail --title "$TITLE" --msgbox "No password entered, a secure password was generated for you:\n\n${DB_PASS}\n\nSave it somewhere safe. (it will be written to the .env file)" 14 70
            else
                echo "Automaticaly generated a password for the database: ${DB_PASS}"
            fi
            break
        fi
        
        DB_PASS2=$(whiptail --title "$TITLE" --passwordbox "Confirm Password" 12 70 3>&1 1>&2 2>&3) || exit 1
        
        if [[ "$DB_PASS" == "$DB_PASS2" ]]; then
            break
        fi
        
        whiptail --title "$TITLE" --msgbox "Passwords do not match. Please try again." 10 60
    done
    if [[ "$ASSUME_YES" == 0 ]]; then
        whiptail --title "$TITLE" --yesno "Database configuration:\n\nHost: ${DB_HOST}\nPort: ${DB_PORT}\nName: ${DB_NAME}\nUser: ${DB_USER}\n\nProceed to create database and user?" 14 70 || exit 1
        section "DB config confirmed: ${DB_USER}@${DB_HOST}:${DB_PORT}/${DB_NAME}"
    else
        section "DB config: ${DB_USER}@${DB_HOST}:${DB_PORT}/${DB_NAME}"
    fi
}

mysql_exec(){
    local SQL="$1"
    local ROOTPW="${2:-}"
    if mysql --protocol=socket -uroot -e "SELECT 1;" >/dev/null 2>&1; then
        mysql --protocol=socket -uroot -e "$SQL"
        return $?
    fi
    if mysql -uroot -e "SELECT 1;" >/dev/null 2>&1; then
        mysql -uroot -e "$SQL"
        return $?
    fi
    if [[ -n "$ROOTPW" ]]; then
        mysql -uroot -p"${ROOTPW}" -e "$SQL"
        return $?
    fi
    return 1
}

db_create(){
    local SQL_PASS="${DB_PASS//\\/\\\\}"
    SQL_PASS="${SQL_PASS//\'/\\\'}"
    local SQL="
    CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`;
    CREATE USER IF NOT EXISTS '${DB_USER}'@'${DB_HOST}' IDENTIFIED BY '${SQL_PASS}';
    GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'${DB_HOST}' WITH GRANT OPTION;
    FLUSH PRIVILEGES;"
    local ROOTPW=""
    if ! mysql --protocol=socket -uroot -e "SELECT 1;" >/dev/null 2>&1 && mysql -uroot -e "SELECT 1;" >/dev/null 2>&1; then
        [[ "$NONINTERACTIVE" == "0" ]] && ROOTPW=$(whiptail --title "$TITLE" --passwordbox "Enter MySQL/MariaDB root password" 10 70 3>&1 1>&2 2>&3) || return 1
    fi
    run "Create database & user" mysql_exec "$SQL" "$ROOTPW" || die "Failed to create database/user. Check root access."
}

# ---------------- Package Ops ----------------

enable_php_repo_and_update(){
    case "$DISTRO_ID" in
        debian)
            pm_install curl apt-transport-https ca-certificates gnupg lsb-release
            if ! dpkg -l | grep -q debsuryorg-archive-keyring; then
                run "Installing sury keyring (GPG key)" curl -SLo "/tmp/debsuryorg-archive-keyring.deb" https://packages.sury.org/debsuryorg-archive-keyring.deb >/dev/null
                run "Adding sury keyring (GPG key)" dpkg -i "/tmp/debsuryorg-archive-keyring.deb"
                run "Cleaning up deb file" rm -f "/tmp/debsuryorg-archive-keyring.deb"
            fi

            if ! grep -q "^deb .*packages.sury.org/php/ $(lsb_release -sc)" "/etc/apt/sources.list.d/php.list" >/dev/null 2>&1; then
                run "Adding sury repo" bash -c "echo \"deb [signed-by=/usr/share/keyrings/debsuryorg-archive-keyring.gpg] https://packages.sury.org/php/ $(lsb_release -sc) main\" > /etc/apt/sources.list.d/php.list"
            fi
            run "Updating apt repositories" apt-get update
        ;;
        ubuntu)
            pm_install software-properties-common curl apt-transport-https ca-certificates gnupg lsb-release
            if ! grep -q "^deb .*ondrej/php" /etc/apt/sources.list /etc/apt/sources.list.d/*; then 
                run "Add PPA ondrej/php" add-apt-repository -y ppa:ondrej/php
            fi
            run "Updating apt repositories" apt-get update
        ;;
        fedora)
            pm_install dnf-plugins-core
            if dnf module list php >/dev/null 2>&1; then
                local MODULE_NAME="php"
                if dnf module list php 2>/dev/null | grep -q "remi-${PHP_VER}"; then
                    MODULE_NAME="php:remi-${PHP_VER}"
                elif dnf module list php 2>/dev/null | grep -Ewq "^php\s+${PHP_VER}"; then
                    MODULE_NAME="php:${PHP_VER}"
                else
                    pm_install "Installing remi repo" "https://rpms.remirepo.net/fedora/remi-release-$(rpm -E %fedora).rpm" || true
                    MODULE_NAME="php:remi-${PHP_VER}"
                fi
                run "dnf module reset php" dnf -y module reset php || true
                run "dnf module enable ${MODULE_NAME}" dnf -y module enable "${MODULE_NAME}" || true
            else
                pm_install "Installing remi repo" "https://rpms.remirepo.net/fedora/remi-release-$(rpm -E %fedora).rpm" || true
                if dnf module list php 2>/dev/null | grep -q "remi-${PHP_VER}"; then
                    run "dnf module reset php" dnf -y module reset php || true
                    run "dnf module enable php:remi-${PHP_VER}" dnf -y module enable "php:remi-${PHP_VER}" || true
                fi
            fi
        ;;
        centos|rhel|almalinux|rocky)
            pm_install dnf-plugins-core epel-release || true
            if have dnf; then
                pm_install "Installing Remi repo" "https://rpms.remirepo.net/enterprise/remi-release-$(rpm -E %rhel).rpm" || true
                if dnf module list php >/dev/null 2>&1; then
                    run "dnf module reset php" dnf -y module reset php || true
                    if dnf module list php 2>/dev/null | grep -q "remi-${PHP_VER}"; then
                        run "dnf module enable php:remi-${PHP_VER}" dnf -y module enable "php:remi-${PHP_VER}" || true
                    else
                        error "PHP ${PHP_VER} not found in remi repo."
                    fi
                fi
            fi
        ;;
    esac
}

install_php_stack(){
    case "$DISTRO_ID" in
        debian|ubuntu)
            enable_php_repo_and_update
            run "Install PHP stack (latest available)" apt-get install --no-install-recommends -y php${PHP_VER} php${PHP_VER}-cli php${PHP_VER}-fpm \
            php${PHP_VER}-gd php${PHP_VER}-mysql php${PHP_VER}-mbstring php${PHP_VER}-bcmath php${PHP_VER}-xml php${PHP_VER}-curl php${PHP_VER}-zip \
            php${PHP_VER}-intl php${PHP_VER}-opcache
        ;;
        fedora|centos|rhel|almalinux|rocky)
            if have dnf; then
                enable_php_repo_and_update
                run "Install PHP stack (latest available)" dnf -y install php php-cli php-fpm php-gd php-mysqlnd php-mbstring php-bcmath php-xml \
                php-curl php-zip php-intl php-opcache
            else
                pm_install php php-cli php-fpm php-gd php-mysqlnd php-mbstring php-bcmath php-xml php-curl php-zip php-intl php-opcache || true
            fi
        ;;
    esac
}

install_nodejs_lts(){
    case "$DISTRO_ID" in
        debian|ubuntu)
            run "Setup NodeSource LTS" bash -lc "curl -fsSL https://deb.nodesource.com/setup_lts.x -o /tmp/nodesource.sh && bash /tmp/nodesource.sh"
            pm_install "Installing/Updating Node.js" nodejs
        ;;
        fedora|centos|rhel|almalinux|rocky)
            run "Setup NodeSource LTS (RPM)" bash -lc "curl -fsSL https://rpm.nodesource.com/setup_lts.x | bash - || true"
            if have dnf; then 
                if dnf module list nodejs >/dev/null 2>&1 | grep -qi "^nodejs"; then
                    run "Resetting Node.js DNF module" dnf module reset nodejs -y || true
                fi
                run "Installing/Updating Node.js" dnf install -y nodejs
            else 
                pm_install "Installing/Updating Node.js" nodejs || true
            fi
        ;;
        *) pm_install "Installing/Updating Node.js" nodejs || true
        ;;
    esac
    have npm || pm_install npm || true
    echo "Node.js version: $(node -v)"
}

install_webserver(){
    if [[ "$WEB" == "nginx" ]]; then
        case "$DISTRO_ID" in
            debian|ubuntu)
                run "Adding nginx signing key" bash -c "curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor | tee /usr/share/keyrings/nginx-archive-keyring.gpg >/dev/null"
                run "Using nginx mainline packages as default" bash -lc "cat > '/etc/apt/sources.list.d/nginx.list' <<'EOF'
deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/mainline/${DISTRO_ID} $(lsb_release -cs) nginx
EOF"

                run "Setting up nginx repository pinning" bash -lc "cat > '/etc/apt/preferences.d/99nginx' << 'EOF'
Package: *
Pin: origin nginx.org
Pin: release o=nginx
Pin-Priority: 900
EOF"

                run "Updating apt repositories" apt-get update
                pm_install nginx
            ;;
            fedora)
                pm_install nginx
            ;;
            centos|rhel|almalinux|rocky)
                run "Installing yum-utils" yum install yum-utils
                
                run "Creating /etc/yum.repos.d/nginx.repo" bash -lc " cat > '/etc/yum.repos.d/nginx.repo' <<'EOF'
[nginx-stable]
name=nginx stable repo
baseurl=http://nginx.org/packages/centos/$releasever/$basearch/
gpgcheck=1
enabled=1
gpgkey=https://nginx.org/keys/nginx_signing.key
module_hotfixes=true

[nginx-mainline]
name=nginx mainline repo
baseurl=http://nginx.org/packages/mainline/centos/$releasever/$basearch/
gpgcheck=1
enabled=0
gpgkey=https://nginx.org/keys/nginx_signing.key
module_hotfixes=true
EOF"
                run "Enabling nginx mainline packages" yum-config-manager --enable nginx-mainline
                run "installing nginx" sudo yum install nginx
            ;;
        esac
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
            debian|ubuntu)
                pm_install mariadb-server mariadb-client || pm_install "Installing: mariadb-server (fallback)" mariadb-server
                ;;
            fedora|centos|rhel|almalinux|rocky)
                pm_install mariadb-server mariadb || pm_install "(fallback) Only Installing Server: mariadb-server" mariadb-server 
                ;;
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
    if have composer; then
        echo "Composer already installed: $(command -v composer)"
        return 0
    fi

    run "Install composer" bash -lc "curl -fsSL https://getcomposer.org/composer-stable.phar -o /usr/local/bin/composer"
    run "Making composer executable" bash -lc "chmod +x /usr/local/bin/composer || true"

    if [[ ! -e "/usr/bin/composer" ]]; then
        run "Creating a symlink from /usr/local/bin/composer -> /usr/bin/composer" ln -sf /usr/local/bin/composer /usr/bin/composer || true
    fi

    if have composer; then
        echo "Composer installed: $(command -v composer)"
        return 0
    fi

    # Fallback to the installer
    local temp_installer
    temp_installer="$(mktemp)"

    run "Downloading composer installer." bash -lc "curl -fsSL https://getcomposer.org/installer -o '${temp_installer}'"
    run "Running composer installer" bash -lc "php '${temp_installer}' --install-dir=/usr/local/bin --filename=composer"

    rm -f "${temp_installer}" || true

    if have composer; then
        echo "Composer installed: $(command -v composer)"
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
    if [[ -z ${LICENSE_KEY:-} ]]; then
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
            elif [[ "$LICENSE_KEY" == SPARTANDEV_* ]]; then
                PRODUCT_ID="6"
                PRODUCT_NAME="Spartan Developer"
            else
                whiptail --title "$TITLE" --msgbox "Invalid license key. Please try again." 8 50
                continue
            fi
            
            local masked="${LICENSE_KEY:0:4}****${LICENSE_KEY: -4}"
            whiptail --title "$TITLE" --yesno "Use this license key?\n\n${masked}\n\nDomain: ${DOMAIN}" 12 70 && break
        done
        section "License key captured (masked)."
    fi
}

license_verify(){
    local API="https://market.dezerx.com/api/license/verify"
    local TMP; TMP="$(mktemp)"
    trap 'rm -rf "${TMP:-}"' RETURN
    local masked="${LICENSE_KEY:0:4}****${LICENSE_KEY: -4}"
    section "Verify license (GET)"
    cmdshow "curl -fsS -H 'Authorization: Bearer ${masked}' -H 'X-Domain: ${DOMAIN}' -H 'X-Product-ID: ${PRODUCT_ID}' ${API}"
    local CODE
    if [[ ${ENABLE_IPV6-} -eq 0 ]]; then
        CODE=$(curl -4 -sS -X GET "$API" \
            -H "Authorization: Bearer ${LICENSE_KEY}" \
            -H "X-Domain: ${DOMAIN}" \
            -H "X-Product-ID: ${PRODUCT_ID}" \
            -H "Content-Type: application/json" \
        -o "$TMP" -w '%{http_code}') || CODE=0
    else
        CODE=$(curl -sS -X GET "$API" \
            -H "Authorization: Bearer ${LICENSE_KEY}" \
            -H "X-Domain: ${DOMAIN}" \
            -H "X-Product-ID: ${PRODUCT_ID}" \
            -H "Content-Type: application/json" \
        -o "$TMP" -w '%{http_code}') || CODE=0
    fi
    
    [[ "$CODE" =~ ^2 ]] || { echo "API response:"; cat "$TMP" 2>/dev/null || true; error "Verify API returned HTTP ${CODE}."; return 1; }
    
    local SUCCESS IS_ACTIVE PNAME PDID PDOMAIN MSG
    SUCCESS=$(jq -r '.success // false' "$TMP") || SUCCESS=false
    IS_ACTIVE=$(jq -r '.data.is_active // false' "$TMP") || IS_ACTIVE=false
    PNAME=$(jq -r '.data.product_name // empty' "$TMP")
    PDID=$(jq -r '.data.product_id // empty' "$TMP")
    PDOMAIN=$(jq -r '.data.domain // empty' "$TMP")
    MSG=$(jq -r '.message // empty' "$TMP")
    
    [[ "$SUCCESS" == "true" && "$IS_ACTIVE" == "true" ]] || { echo "API response:"; cat "$TMP"; error "License not active/valid: ${MSG:-Unknown}"; return 1; }
    
    echo "License OK: ${PNAME:-${PRODUCT_NAME}} (product_id=${PDID:-${PRODUCT_ID}})"
    [[ -n "$PDOMAIN" ]] && echo "Registered domain: $PDOMAIN" || true
}

ask_what_to_keep(){
    load_options_json_flags
    if [[ "$NONINTERACTIVE" == 0 ]]; then
        local s_nginx="OFF" s_css="ON" s_themes="ON" s_portals="ON" s_emails="ON" s_favicon="ON"
        [[ "${KEEP_NGINX:-}" == 1 ]] && s_nginx="ON"
        [[ "${KEEP_CSS:-}" == 1 ]] && s_css="ON"
        [[ "${KEEP_THEMES:-}" == 1 ]] && s_themes="ON"
        [[ "${KEEP_PORTALS:-}" == 1 ]] && s_portals="ON"
        [[ "${KEEP_EMAILS:-}" == 1 ]] && s_emails="ON"
        [[ "${KEEP_FAVICON:-}" == 1 ]] && s_favicon="ON"

        local choices
        choices=$(whiptail --title "$TITLE" --checklist \
        "Select components to KEEP during the update (Space to toggle):\n(Advanced exclusions can be set in ${OPTIONS_JSON_NAME})" 16 75 6 \
        "NGINX" "Keep current NGINX configuration" $s_nginx \
        "CSS" "Keep custom dashboard CSS" $s_css \
        "THEMES" "Keep custom dashboard themes" $s_themes \
        "PORTALS" "Keep custom portals" $s_portals \
        "EMAILS" "Keep custom email templates" $s_emails \
        "FAVICON" "Keep custom favicons" $s_favicon 3>&1 1>&2 2>&3) || true

        KEEP_NGINX=0; KEEP_CSS=0; KEEP_THEMES=0; KEEP_PORTALS=0; KEEP_EMAILS=0; KEEP_FAVICON=0
        [[ $choices == *"\"NGINX\""* ]] && KEEP_NGINX=1 || true
        [[ $choices == *"\"CSS\""* ]] && KEEP_CSS=1 || true
        [[ $choices == *"\"THEMES\""* ]] && KEEP_THEMES=1 || true
        [[ $choices == *"\"PORTALS\""* ]] && KEEP_PORTALS=1 || true
        [[ $choices == *"\"EMAILS\""* ]] && KEEP_EMAILS=1 || true
        [[ $choices == *"\"FAVICON\""* ]] && KEEP_FAVICON=1 || true
    fi
}

license_download_and_extract(){
    local API="https://market.dezerx.com/api/license/download"
    local TMPDIR; TMPDIR="$(mktemp -d)"
    local RESP_FILE="$TMPDIR/resp.json"
    local masked="${LICENSE_KEY:0:4}****${LICENSE_KEY: -4}"
    
    section "Request one-time download link (POST)"
    cmdshow "curl -fsS -X POST '${API}' -H 'Authorization: Bearer ${masked}' -H 'X-Domain: ${DOMAIN}' -H 'X-Product-ID: ${PRODUCT_ID}'"
    
    local CODE
    if [[ ${ENABLE_IPV6-} -eq 0 ]]; then
        CODE=$(curl -4 -sS -X POST "$API" \
            -H "Authorization: Bearer ${LICENSE_KEY}" \
            -H "X-Domain: ${DOMAIN}" \
            -H "X-Product-ID: ${PRODUCT_ID}" \
            -H "Content-Type: application/json" \
        -o "$RESP_FILE" -w '%{http_code}') || CODE=0
    else
        CODE=$(curl -sS -X POST "$API" \
            -H "Authorization: Bearer ${LICENSE_KEY}" \
            -H "X-Domain: ${DOMAIN}" \
            -H "X-Product-ID: ${PRODUCT_ID}" \
            -H "Content-Type: application/json" \
        -o "$RESP_FILE" -w '%{http_code}') || CODE=0
    fi
    
    [[ "$CODE" =~ ^2 ]] || { echo "API response:"; cat "$RESP_FILE" 2>/dev/null || true; error "Download-token API returned HTTP ${CODE}."; return 1; }
    
    local SUCCESS URL EXPIRES NAME SIZE MSG
    SUCCESS=$(jq -r '.success // false' "$RESP_FILE") || SUCCESS=false
    MSG=$(jq -r '.message // empty' "$RESP_FILE")
    URL=$(jq -r '.data.download_url // empty' "$RESP_FILE")
    EXPIRES=$(jq -r '.data.expires_at // empty' "$RESP_FILE")
    NAME=$(jq -r '.data.product_name // empty' "$RESP_FILE")
    SIZE=$(jq -r '.data.file_size // empty' "$RESP_FILE")
    
    [[ "$SUCCESS" == "true" && -n "$URL" ]] || { echo "API response:"; cat "$RESP_FILE"; error "No valid download_url in response: ${MSG:-Unknown}"; return 1; }
    
    section "License OK"
    echo -e "\nDownload URL (one-time): $URL"
    [[ -n "$NAME" ]] && echo -e  "Product: $NAME"
    [[ -n "$EXPIRES" ]] && echo -e "Expires on: $EXPIRES"
    [[ -n "$SIZE" ]] && echo -e "File size: $SIZE bytes"
    
    local OUT="$TMPDIR/app"
    mkdir -p "$OUT"
    (
        cd "$OUT" && curl -fL -OJ "$URL"
    ) || { error "Failed to download application payload."; return 1; }

    local FILE="$(find "$OUT" -maxdepth 1 -type f -print -quit)" 
    local EXT="$(file -b "$FILE")"
    local TYPE
    if echo "${EXT}" | grep -qi "zip"; then
        TYPE="zip"
    elif echo "${EXT}" | grep -Eiq "gzip|tar"; then
        TYPE="targz"
    else
        case "$FILE" in
            *.zip) TYPE="zip" ;;
            *.tar.gz|*.tgz) TYPE="targz" ;;
            *) 
                error "Unknown archive type (expected zip or tar.gz)."
                return 1
                ;;
        esac
    fi
    
    section "Extract application archive (${TYPE})"
    local EXTRACT="$OUT/extract"
    mkdir -p "$EXTRACT"
    if [[ "$TYPE" == "zip" ]]; then
        unzip -q "${FILE}" -d "$EXTRACT"
    else
        run "Extracting tar archive" tar -xzf "${FILE}" -C "$EXTRACT"
    fi
    
    local SRC="$EXTRACT"
    local TOP_COUNT
    TOP_COUNT="$(find "$EXTRACT" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
    if [[ "$TOP_COUNT" -eq 1 ]]; then
        SRC="$(find "$EXTRACT" -mindepth 1 -maxdepth 1 -type d | head -n1)"
    fi
    
    app_prepare_dir
    section "Sync application to ${APP_DIR}"
    run "Deploying extracted files to core" rsync -aI --remove-source-files --ignore-missing-args "$SRC"/ "${APP_DIR}/"

    if [[ $CHOICE == "update" ]]; then
        run "Restoring user modules" app_restore_modules
        app_restore_files
    elif [[ -d "${update_tmpdir}" ]]; then
        rmdir -- "${update_tmpdir}" 2>/dev/null || true
    fi

    [[ -f "${APP_DIR}/composer.json" ]] || { error "composer.json missing after extraction; invalid payload?"; exit 1; }
    echo "App synced to ${APP_DIR}"
}

# ---------------- PHP-FPM helpers ----------------
find_php_fpm_service(){ systemctl list-unit-files --type=service | awk '/php.*-fpm\.service/ {print $1}' | sort -r | head -n1; }
php_minor(){ php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || echo "${PHP_VER}"; }
start_php_fpm(){
    local svc; svc="$(find_php_fpm_service)"
    if [[ -n "$svc" ]]; then run "Enable/start ${svc}" systemctl enable --now "$svc"; else run "Enable/start php-fpm (generic)" systemctl enable --now php-fpm || true; fi
}
restart_php_fpm(){
    local svc; svc="$(find_php_fpm_service)"
    if [[ -n "$svc" ]]; then run "Restart ${svc}" systemctl restart "$svc" || true; else run "Restart php-fpm (generic)" systemctl restart php-fpm || true; fi
}
php_fpm_socket(){
    shopt -s nullglob
    for s in /run/php/php"$(php_minor)"-fpm.sock /run/php/php*-fpm.sock /var/run/php/php*-fpm.sock /run/php/php-fpm.sock /var/run/php/php-fpm.sock /run/php-fpm/www.sock; do
        [[ -S "$s" ]] && { echo "unix:$s"; return 0; }
    done
    shopt -u nullglob
    echo "unix:/run/php/php-fpm.sock"
}
php_fpm_find_conf(){
    local candidates=()
    
    case "$DISTRO_ID" in
        debian|ubuntu)
            candidates+=("/etc/php/$(php_minor)/fpm/pool.d/www.conf")
            shopt -s nullglob
            candidates+=(/etc/php/*/fpm/pool.d/www.conf)
            shopt -u nullglob
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
php_find_fpm_conf_dir(){
    local candidates=()
    
    case "$DISTRO_ID" in
        debian|ubuntu)
            candidates+=("/etc/php/$(php_minor)/fpm/conf.d")
            shopt -s nullglob
            candidates+=(/etc/php/*/fpm/conf.d)
            shopt -u nullglob
        ;;
        fedora|centos|rhel|almalinux|rocky)
            candidates+=("/etc/php.d")
        ;;
    esac
    
    for dir in "${candidates[@]}"; do
        [[ -d "$dir" ]] && { echo "$dir"; return 0; }
    done
    
    return 1
}

# ---------------- ionCube ----------------

prepare_ioncube(){
    local PHPV ARCH URL TMP TAR SO DST CUR_VER NEW_VER INI
    PHPV="$(php_minor)"

    case "$(uname -m)" in
        x86_64) ARCH="x86-64" ;;
        aarch64|arm64) ARCH="aarch64" ;;
        *) die "ionCube: unsupported architecture $(uname -m)" ;;
    esac

    URL="https://downloads.ioncube.com/loader_downloads/ioncube_loaders_lin_${ARCH}.tar.gz"
    TMP="$(mktemp -d)"
    TAR="$TMP/ioncube.tar.gz"
    trap 'rm -rf "${TMP:-}"' RETURN

    run "Download IonCube" curl -fsSL "$URL" -o "$TAR"
    if [[ -f "$TAR" ]]; then
        run "Extrat IonCube" tar -xzf "$TAR" -C "$TMP"
    else
        die "Archive of IonCube loader for PHP ${PHPV} not found."
    fi

    SO="$TMP/ioncube/ioncube_loader_lin_${PHPV}.so"
    [[ -f "$SO" ]] || die "IonCube loader for PHP ${PHPV} not found in extracted archive."

    NEW_VER="$(php -n -d "zend_extension=$SO" -r 'echo function_exists("ioncube_loader_version")?ioncube_loader_version():"0";' 2>/dev/null || true)"
    CUR_VER="$(php -r 'echo function_exists("ioncube_loader_version")?ioncube_loader_version():"0";' 2>/dev/null || true)"
    DST="${IONCUBE_DIR}/ioncube_loader_lin_${PHPV}.so"

    [[ ! -d $IONCUBE_DIR ]] && run "Ensuring ionCube dir exists" bash -lc "install -d '$IONCUBE_DIR'"

    if [[ "$CUR_VER" == "0" || -z "$CUR_VER" ]]; then
        echo "IonCube is not installed. Installing version $NEW_VER..."
        run "Installing IonCube ${NEW_VER}" bash -lc "install -m 0644 '$SO' '$DST'"
    elif [[ "$(printf '%s\n' "$CUR_VER" "$NEW_VER" | sort -V | tail -n1)" != "$CUR_VER" ]]; then
        echo "Updating IonCube loader from $CUR_VER -> $NEW_VER"
        run "Uninstalling all old INI files" bash -lc "find /etc/php* -type f -name '*ioncube*.ini' -exec rm -f {} +"
        run "Uninstalling all old IonCube loader" bash -lc "rm -f /usr/local/ioncube/ioncube_loader_lin_*.so"
        run "Installing IonCube ${NEW_VER}" bash -lc "install -m 0644 '$SO' '$DST'"
    else
        echo "IonCube loader is up to date ($CUR_VER). Skipping file copy."
    fi


    INI="zend_extension=/usr/local/ioncube/ioncube_loader_lin_${PHPV}.so"
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
        NGINX_CONF_PATH="$NGINX_AVAIL/spartan.conf"
        NGINX_CONF_OLD_PATH="$NGINX_AVAIL/dezerx.conf"
        NGINX_CONF_OLD_SYMLINK="$NGINX_ENABLED/dezerx.conf"
    else
        NGINX_MODE="rhel"
        NGINX_CONF_PATH="/etc/nginx/conf.d/spartan.conf"
        NGINX_CONF_OLD_PATH="/etc/nginx/conf.d/dezerx.conf"
        NGINX_CONF_OLD_SYMLINK=""
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
    if [[ "$NGINX_MODE" == "debian" && -n "$NGINX_ENABLED" ]]; then
        run "Enable site (symlink)" ln -sf "$NGINX_CONF_PATH" "$NGINX_ENABLED/spartan.conf"
    fi
}

configure_nginx_http_only(){
    local sock; sock="$(php_fpm_socket)"
    nginx_remove_defaults

    local listen_80="listen 80;"
    if [[ ${ENABLE_IPV6-} -ne 0 ]]; then
        listen_80="listen 80;\n    listen [::]:80;"
    fi
    
  run "Write NGINX HTTP-only vHost for ${DOMAIN}" bash -lc "cat >'$NGINX_CONF_PATH' <<'EOF'
server {
    ${listen_80}
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
        fastcgi_buffer_size 64k;
        fastcgi_buffers 8 64k;
        fastcgi_connect_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_read_timeout 300;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }
}
EOF"
    nginx_enable_site
    start_php_fpm
    run "Test nginx configuration" nginx -t || true
    run "Enable/start nginx" systemctl enable --now nginx
    run "Restart nginx" systemctl restart nginx
}

configure_nginx_ssl(){
    local sock; sock="$(php_fpm_socket)"
    nginx_remove_defaults

    local listen_80="listen 80;"
    local listen_443="listen 443 ssl;"
    if [[ ${ENABLE_IPV6-} -ne 0 ]]; then
        listen_80="listen 80;\n    listen [::]:80;"
        listen_443="listen 443 ssl;\n    listen [::]:443 ssl;"
    fi

  run "Write NGINX SSL vHost for ${DOMAIN}" bash -lc "cat >'$NGINX_CONF_PATH' <<'EOF'
server {
    ${listen_80}
    server_name ${DOMAIN};
    return 301 https://\$server_name\$request_uri;
}

server {
    ${listen_443}
    server_name ${DOMAIN};

    root ${APP_DIR}/public;
    index index.php index.html;

    access_log /var/log/nginx/dezerx.app-access.log;
    error_log  /var/log/nginx/dezerx.app-error.log error;

    client_max_body_size 100m;
    client_body_timeout 120s;

    sendfile off;

    ssl_certificate ${CERT_DIR}/fullchain.pem;
    ssl_certificate_key ${CERT_DIR}/privkey.pem;
    ssl_session_cache shared:SSL:10m;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384";
    ssl_prefer_server_ciphers on;

    add_header Strict-Transport-Security \"max-age=31536000; includeSubDomains\";
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
        fastcgi_buffer_size 64k;
        fastcgi_buffers 8 64k;
        fastcgi_connect_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_read_timeout 300;
        include /etc/nginx/fastcgi_params;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }
}
EOF"
    [[ "$NGINX_MODE" == "debian" ]] && run "Enable site (symlink)" nginx_enable_site
    start_php_fpm
    run "Test nginx configuration" nginx -t || true
    run "Restart nginx" systemctl restart nginx || true
}

# ---------------- APP bootstrap (.env, composer, npm, artisan) ----------------
detect_web_user_group(){
    local user="" group="" proc_user pid candidates conf_file detection_method=""
    APP_USER="$APP_USER_DEFAULT"; APP_GROUP="$APP_GROUP_DEFAULT"

    if [[ "${WEB:-}" == "nginx" ]]; then
        conf_file=(/etc/nginx/nginx.conf)
        for cfg in "${conf_file[@]}"; do
            [[ -f "$cfg" ]] || continue
            user="$(grep -i '^[[:space:]]*user[[:space:]]' ${cfg} | grep -v '^[[:space:]]*#' | awk '{print $2}' | tr -d ';' || true)"
            group="$(grep -i '^[[:space:]]*user[[:space:]]' ${cfg} | grep -v '^[[:space:]]*#' | awk '{print $3}' | tr -d ';' || true)"
            [[ -z "$group" ]] && group="$(id -gn "$user" 2>/dev/null || echo "$user")"
            if [[ -n "$user" ]]; then
                detection_method="config file"
                break
            fi
        done
    else
        conf_file=(/etc/apache2/apache2.conf /etc/httpd/conf/httpd.conf)
        for cfg in "${conf_file[@]}"; do
            [[ -f "$cfg" ]] || continue
            user="$(grep -i '^[[:space:]]*User[[:space:]]' ${cfg} | grep -v '^[[:space:]]*#' | awk '{print $2}' | tr -d ';' || true)"
            group="$(grep -i '^[[:space:]]*Group[[:space:]]' ${cfg} | grep -v '^[[:space:]]*#' | awk '{print $2}' | tr -d ';' || true)"
            [[ -z "$group" ]] && group="$(id -gn "$user" 2>/dev/null || echo "$user")"
            if [[ -n "$user" ]]; then
                detection_method="config file"
                break
            fi
        done
    fi

    if [[ "${WEB:-}" == "nginx" ]]; then
        candidates=(www-data nginx www)
    else
        candidates=(apache2 httpd apache)
    fi
    
    # Get user from pid using systemctl and group using id
    if [[ -z "${user}" || -z "${group}" ]]; then
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
    fi

    # Fallback to id if systemctl isn't active/installed
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
    
    # Last fallback to the defaults
    if [[ -z "${user}" || -z "${group}" ]]; then
        user="$APP_USER_DEFAULT"
        group="$APP_GROUP_DEFAULT"
        detection_method="defaults"
    fi
    
    APP_USER="${user}"
    APP_GROUP="${group}"
    
    section "Using web user/group: ${APP_USER}:${APP_GROUP} (method=${detection_method})"
}

config_php_fpm(){
    local cfg; cfg="$(php_fpm_find_conf)"
    run "Updating user to ${APP_USER} in: ${cfg}" sed -Ei "s|^[[:space:]]*;?[[:space:]]*user.*|user = ${APP_USER}|" "${cfg}"
    run "Updating group to ${APP_GROUP} in: ${cfg}" sed -Ei "s|^[[:space:]]*;?[[:space:]]*group.*|group = ${APP_GROUP}|" "${cfg}"

    run "Updating listen user to ${APP_USER} in: ${cfg}" sed -Ei "s|^[[:space:]]*;?[[:space:]]*listen\.owner.*|listen.owner = ${APP_USER}|" "${cfg}"
    run "Updating listen group to ${APP_GROUP} in: ${cfg}" sed -Ei "s|^[[:space:]]*;?[[:space:]]*listen\.group.*|listen.group = ${APP_GROUP}|" "${cfg}"
    restart_php_fpm
}

config_opcache(){
    local ini_file; ini_file="$(php_find_fpm_conf_dir)/10-opcache-custom.ini"

    if [[ -f "${ini_file}" ]]; then
        section "Updating OPcache configuration"
        run "Removing existing OPcache config" rm -f "${ini_file}" || true
        run "Creating OPcache configuration file at: ${ini_file}" touch "${ini_file}" || true
    else
        section "Configuring OPcache"
        run "Creating OPcache configuration file at: ${ini_file}" touch "${ini_file}" || true
    fi

    run "writing OPcache config" bash -c "cat > '${ini_file}' <<EOF
opcache.enable=1
opcache.enable_cli=1

opcache.memory_consumption=512

opcache.interned_strings_buffer=16

opcache.max_accelerated_files=10000

opcache.validate_timestamps=0
opcache.revalidate_freq=2

opcache.fast_shutdown=1

opcache.save_comments=1
EOF"
}

config_network() {
    if [[ ${ENABLE_IPV6-} -eq 0 ]]; then

        if [[ ! -f "/etc/sysctl.d/99-spartan-disable-ipv6.conf" ]]; then
            section "Network Configuration"
            echo "Configuring Network: Disabling IPv6"
            run "Writting sysctl config to disabled IPv6" bash -c "cat > '/etc/sysctl.d/99-spartan-disable-ipv6.conf' <<EOF
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF"
            run "Applying sysctl changes (IPV6 config)" sysctl -p "/etc/sysctl.d/99-spartan-disable-ipv6.conf" || true
        fi
    else
        section "Network Configuration"

        if [[ -f "/etc/sysctl.d/99-spartan-disable-ipv6.conf" ]]; then
            echo "Removing IPv6 Network Configuration"
            run "Removing sysctl IPv6 config" rm -f "/etc/sysctl.d/99-spartan-disable-ipv6.conf"
            run "Applying sysctl changes (IPV6 config deletition)" sysctl --system || true
        else
            echo "Skipping IPv6 Network Configuration"
        fi

    fi
}

env_write_value(){
    local key="$1" value="$2"
    local env_file="${3:-${APP_DIR:-/var/www/spartan}/.env}"
    local formatted

    if [[ "$value" =~ [^a-zA-Z0-9_./-] ]]; then
        local escaped_value
        escaped_value=$(printf '%s' "$value" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
        formatted="${key}=\"${escaped_value}\""
    else
        formatted="${key}=${value}"
    fi

    [[ ! -f "$env_file" ]] && touch "$env_file"

    if grep -qE "^${key}=" "$env_file"; then
        echo "[env] Updating ${key}" >&4
        local sed_formatted="${formatted//\\/\\\\}"
        sed_formatted="${sed_formatted//&/\\&}"
        sed_formatted="${sed_formatted//|/\\|}"
        sed -i -E "s|^${key}=.*|${sed_formatted}|g" "$env_file"
    else
        echo "[env] Adding ${key}" >&4
        printf '%s\n' "$formatted" >> "$env_file"
    fi
}

app_env_setup(){
    APP_KEY=${APP_KEY:-}
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

    env_write_value "APP_NAME" "DezerX Spartan"
    env_write_value "APP_ENV" "production"
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

safe_npm_build(){
    [[ -f "${APP_DIR}/package.json" ]] || return

    section "Analyzing system memory for npm run build"

    local total_ram total_swap
    total_ram=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
    total_swap=$(awk '/SwapTotal/ {printf "%d", $2/1024}' /proc/meminfo)

    local current_total=$((total_ram + total_swap))

    local target_memory=4096
    local os_overhead=512

    local swap_needed=0
    local swap_file="/swapfile_spartan_temp"
    local swap_added=0

    echo "Detected Memory: ${total_ram}MB RAM + ${total_swap}MB Swap (Total: ${current_total}MB)"

    if (( $current_total < $target_memory )); then
        swap_needed=$((target_memory - current_total + os_overhead))
        echo "System falls short of targeted ${target_memory}MB required memory. Need ${swap_needed}MB additional memory."

        if systemd-detect-virt -q --container 2>/dev/null || grep -qa 'container=' /proc/1/environ 2>/dev/null; then
            echo "Container environment detected. Cannot dynamically allocate temporary swap."
            echo "NPM build will attempt to run with existing memory limits, but may fail if resources are exhausted."
        else
            section "Creating temporary ${swap_needed}MB of swap space"

            if ! swapon --show | grep -q "$swap_file"; then
                run "Allocating swap file" dd if=/dev/zero of="$swap_file" bs=1M count="$swap_needed" status=none
                chmod 600 "$swap_file"
                mkswap "$swap_file" >/dev/null 2>&1
                if swapon "$swap_file" >/dev/null 2>&1; then
                    swap_added=1
                    echo "Temporary swap enabled."
                    current_total=$((current_total + swap_needed))
                else
                    echo "Failed to enable temporary swap. Proceeding with available memory."
                fi
            fi
        fi
    else
        echo "Memory is sufficient. No temporary swap needed."
    fi

    local node_max_mem=$((current_total - os_overhead))

    if (( node_max_mem <= 512 )); then
        node_max_mem=512
    fi
    if (( node_max_mem > 8192 )); then
        node_max_mem=8192
    fi

    section "Building assets (NODE_OPTIONS='--max-old-space-size=${node_max_mem}')"

    local build_status=0
    run "npm run build (this could take some time)" bash -lc "cd '${APP_DIR}' && NODE_OPTIONS='--max-old-space-size=${node_max_mem}' npm run build" || build_status=$?

    if [[ $swap_added -eq 1 ]]; then
        echo "Removing temporary swap file..."
        swapoff "$swap_file" >/dev/null 2>&1 || true
        rm -f "$swap_file"
    fi

    if [[ $build_status -eq 0 ]]; then
        echo "npm run build succeeded!"
    else
        echo "npm run build failed (Exit Code: $build_status)."
        return 1
    fi
}

app_install_steps(){
    COMPOSER_CMD="$(command -v composer || echo 'php /usr/local/bin/composer')"
    [[ -f "${APP_DIR}/composer.json" ]] && run "composer install" bash -lc "cd '${APP_DIR}' && COMPOSER_ALLOW_SUPERUSER=1 '${COMPOSER_CMD}' install --no-dev --optimize-autoloader -n --prefer-dist"
    if [[ -f "${APP_DIR}/package-lock.json" ]]; then
        run "npm ci (this could take some time)" bash -lc "cd '${APP_DIR}' && npm ci"
    elif [[ -f "${APP_DIR}/package.json" ]]; then
        run "npm install (this could take some time)" bash -lc "cd '${APP_DIR}' && npm install"
    fi
    safe_npm_build
    app_maintenance_on
    run "php artisan key:generate" bash -lc "cd '${APP_DIR}' && php artisan key:generate --force"
    run "php artisan migrate --force" bash -lc "cd '${APP_DIR}' && php artisan migrate --force"
    run "php artisan db:seed --force" bash -lc "cd '${APP_DIR}' && php artisan db:seed --force"
    run "php artisan storage:link" bash -lc "cd '${APP_DIR}' && php artisan storage:link"
}

app_update_steps(){
    COMPOSER_CMD="$(command -v composer || echo 'php /usr/local/bin/composer')"
    [[ -f "${APP_DIR}/composer.json" ]] && run "composer install" bash -lc "cd '${APP_DIR}' && COMPOSER_ALLOW_SUPERUSER=1 '${COMPOSER_CMD}' install --no-dev --optimize-autoloader -n --prefer-dist"
    if [[ -f "${APP_DIR}/package-lock.json" ]]; then
        run "npm ci (this could take some time)" bash -lc "cd '${APP_DIR}' && npm ci"
    elif [[ -f "${APP_DIR}/package.json" ]]; then
        run "npm install (this could take some time)" bash -lc "cd '${APP_DIR}' && npm install"
    fi
    app_maintenance_on
    run "php artisan migrate --force" bash -lc "cd '${APP_DIR}' && php artisan migrate --force"
    run "php artisan db:seed --force" bash -lc "cd '${APP_DIR}' && php artisan db:seed --force"
    run "php artisan storage:link" bash -lc "cd '${APP_DIR}' && php artisan storage:link"
    if [[ "$css_save_methode" == "php" ]]; then
        run "Restoring dashboard theme (Methode: php)" bash -lc "cd '${APP_DIR}' && php artisan theme:backup --restore"
    fi
    safe_npm_build
}

app_restore_steps(){
    COMPOSER_CMD="$(command -v composer || echo 'php /usr/local/bin/composer')"
    [[ -f "${APP_DIR}/composer.json" ]] && run "composer install" bash -lc "cd '${APP_DIR}' && COMPOSER_ALLOW_SUPERUSER=1 '${COMPOSER_CMD}' install --no-dev --optimize-autoloader -n --prefer-dist"
    if [[ -f "${APP_DIR}/package-lock.json" ]]; then
        run "npm ci (this could take some time)" bash -lc "cd '${APP_DIR}' && npm ci"
    elif [[ -f "${APP_DIR}/package.json" ]]; then
        run "npm install (this could take some time)" bash -lc "cd '${APP_DIR}' && npm install"
    fi
    safe_npm_build
    run "php artisan migrate --force" bash -lc "cd '${APP_DIR}' && php artisan migrate --force"
    run "php artisan storage:link" bash -lc "cd '${APP_DIR}' && php artisan storage:link"
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
    local escaped_app_dir=$(printf '%s\n' "${APP_DIR}" | sed 's/[][\.*^$(){}?+|/]/\\&/g')
    local match_regex="cd ${escaped_app_dir} .*artisan schedule:run"
    ensure_cron_running
    if have crontab; then
        local tmp_file=$(mktemp)
        run "Install cron for scheduler" bash -lc "
            (crontab -l 2>/dev/null || true) | sed '\\|${match_regex}|d' > \"${tmp_file}\"
            echo -e \"${cron_line}\" >> \"${tmp_file}\"
            crontab \"${tmp_file}\"
            rm -f \"${tmp_file}\"
        "
    fi
}

setup_systemd_queue(){
    if [[ -f "/etc/systemd/system/dezerx.service" ]]; then
        run "Removing duplicate/old dezerx.service file" rm -f "/etc/systemd/system/dezerx.service"
    fi

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
    run "Enable & start dezerx.service" bash -lc "systemctl daemon-reload && systemctl enable dezerx.service && systemctl restart dezerx.service || true"
}

# ---------------- Certbot ----------------

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

create_self_signed_certs(){
    local local_cert_dir="/etc/certs/spartan/${DOMAIN}"
    local priv_key_path="${local_cert_dir}/privkey.pem"
    local cert_path="${local_cert_dir}/fullchain.pem"

    run "Creating dir for self-signed certificate" mkdir -p "${local_cert_dir}"

    run "Generating a self-signed certificate for ${DOMAIN}" \
    openssl req -x509 -nodes -sha256 -days 365 \
    -newkey rsa:4096 \
    -subj "/O=DezerX Spartan - Bauer Kuke EDV GBR/CN=*.${DOMAIN}" \
    -keyout "${priv_key_path}" \
    -out "${cert_path}"

    if [[ -f "${priv_key_path}" && -f "${cert_path}" ]]; then
        section "Self-signed certificates created at ${local_cert_dir}"
        run "Making '${local_cert_dir}' only accessible by owner and group" chmod -R 640 "${local_cert_dir}"
        run "Allowing ${WEB} access to '${local_cert_dir}' (${APP_USER}:${APP_GROUP})" chown -R "${APP_USER}:${APP_GROUP}" "${local_cert_dir}"
        CERT_DIR="${local_cert_dir}"
    else
        section "Failed to generate a self-signed cert for ${DOMAIN}"
    fi
}

# HTTPS flip
flip_app_url_to_https(){
    if [[ -f "${APP_DIR}/.env" ]]; then
        run "Flip APP_URL to https://${DOMAIN}" sed -i "s|^APP_URL=.*|APP_URL=https://${DOMAIN}|g" "${APP_DIR}/.env" || true
        if [[ -f "${APP_DIR}/artisan" ]]; then
            run "artisan config:clear" bash -lc "cd '${APP_DIR}' && php artisan config:clear || true"
            run "artisan config:cache" bash -lc "cd '${APP_DIR}' && php artisan config:cache || true"
        fi
    fi
}

# Backup/Restore logic for updates
app_maintenance_on(){
    if [[ -f "${APP_DIR}/artisan" ]]; then
        run "artisan down (maintenance mode)" bash -lc "cd '${APP_DIR}' && php artisan down || true"
    fi
}

app_maintenance_off(){
    if [[ -f "${APP_DIR}/artisan" ]]; then
        run "artisan up (end maintenance mode)" bash -lc "cd '${APP_DIR}' && php artisan up || true"
    fi
}

create_ioncube_backup() {
    local listf backup_path="${BACKUP_DIR}/spartan_ioncube_backup_$(date +%Y%m%d%H%M%S)"
    IONCUBE_BACKUP_FILE="${backup_path}.tar.gz"

    section "Creating backup of ${IONCUBE_DIR} at ${IONCUBE_BACKUP_FILE}"

    listf="${BACKUP_DIR}/ioncube_filelist.txt"
    : > "$listf"
    if [[ -d "$IONCUBE_DIR" ]]; then
        printf '%s\n' "$IONCUBE_DIR" >> "$listf"
        find "$IONCUBE_DIR" -maxdepth 1 -type f -name 'ioncube_loader_lin_*.so' -print >> "$listf"
    fi

    if [[ -s "$listf" ]]; then
        run "Creating ioncube backup" bash -c "sed 's#^/##' "$listf" | tar -czf "$IONCUBE_BACKUP_FILE" -C / -T -" || die "Failed to create ioncube backup." 
        echo "Backup created at: $IONCUBE_BACKUP_FILE" | tee -a "$LOG"
        rm -f "$listf"
    else
        echo "Nothing to back up in ${IONCUBE_DIR}." | tee -a "$LOG"
    fi
}

create_php_backup() {
    local listf backup_path="${BACKUP_DIR}/spartan_php_backup_$(date +%Y%m%d%H%M%S)"
    PHP_BACKUP_FILE="${backup_path}.tar.gz"

    section "Creating backup of PHP at ${PHP_BACKUP_FILE}"

    listf="${BACKUP_DIR}/php_filelist.txt"
    : > "$listf"

    find /etc/php* -type f -name '*ioncube*.ini' -print 2>/dev/null >> "$listf" || true

    if [[ -s "$listf" ]]; then
        run "Creating PHP config backup" bash -c "sed 's#^/##' '$listf' | tar -czf '$PHP_BACKUP_FILE' -C / -T -" || die "Failed to create php backup."
        echo "Backup created at: $PHP_BACKUP_FILE" | tee -a "$LOG"
        rm -f "$listf"
    else
        echo "Nothing to back up in /etc/php*." | tee -a "$LOG"
    fi
}

create_nginx_backup() {
    local backup_path="${BACKUP_DIR}/spartan_conf_backup_$(date +%Y%m%d%H%M%S)"
    NGINX_BACKUP_FILE="${backup_path}.conf"
    
    section "Creating a backup of spartan nginx config at ${NGINX_BACKUP_FILE}"
    if [[ -f "$NGINX_CONF_OLD_PATH" ]]; then
        run "Backing up nginx config old path" cp "$NGINX_CONF_OLD_PATH" "$NGINX_BACKUP_FILE"
        NGINX_RESTORE_PATH="$NGINX_CONF_OLD_PATH"
        echo "Backup created at: ${NGINX_BACKUP_FILE}"
    elif [[ -f "$NGINX_CONF_PATH" ]]; then
        run "Backing up nginx config" cp "$NGINX_CONF_PATH" "$NGINX_BACKUP_FILE"
        NGINX_RESTORE_PATH="$NGINX_CONF_PATH"
        echo "Backup created at: ${NGINX_BACKUP_FILE}"
    fi
}

create_app_backup() {
    local backup_path
    backup_path="${BACKUP_DIR}/spartan_backup_$(date +%Y%m%d%H%M%S)"
    APP_BACKUP_FILE="${backup_path}.tar.gz"
    
    section "Creating backup of ${APP_DIR} at ${APP_BACKUP_FILE}"
    run "Archiving application directory" tar -czf "$APP_BACKUP_FILE" -C "$(dirname "$APP_DIR")" --exclude="$(basename "$APP_DIR")/node_modules" "$(basename "$APP_DIR")" || die "Failed to create backup."
    echo "Backup created at: $APP_BACKUP_FILE" | tee -a "$LOG"
}

create_db_backup() {
    if [[ "$DB_ENGINE" == "mysql" || "$DB_ENGINE" == "mariadb" ]]; then
        local backup_path="${BACKUP_DIR}/spartan_db_backup_$(date +%Y%m%d%H%M%S)"
        DB_BACKUP_FILE="${backup_path}.sql.gz"
        
        section "Creating database backup at ${DB_BACKUP_FILE}"
        run "Dumping database" bash -c "mysqldump -h '$DB_HOST' -P '$DB_PORT' -u '$DB_USER' -p'$DB_PASS' '$DB_NAME' | gzip > '$DB_BACKUP_FILE'" || die "Failed to create database backup."
        echo "Database backup created at: $DB_BACKUP_FILE" | tee -a "$LOG"
    else
        echo "Database backup skipped: Unsupported DB engine ${DB_ENGINE}" | tee -a "$LOG"
    fi
}

create_backups(){
    mkdir -p "$BACKUP_DIR"
    create_nginx_backup
    create_app_backup
    create_db_backup
    create_php_backup
    create_ioncube_backup
}

restore_ioncube_backup() {
    if [[ -n "${IONCUBE_BACKUP_FILE:-}" && -f "$IONCUBE_BACKUP_FILE" ]]; then
        section "Restoring IonCube from ${IONCUBE_BACKUP_FILE}"
        run "Extracting IonCube backup" tar -xzf "$IONCUBE_BACKUP_FILE" -C / || echo "Failed to restore IonCube backup."
        echo "IonCube backup restored." | tee -a "$LOG"
    else
        echo "No IonCube backup file to restore."
    fi
}

restore_php_backup() {
    if [[ -n "${PHP_BACKUP_FILE:-}" && -f "$PHP_BACKUP_FILE" ]]; then
        section "Restoring PHP config from ${PHP_BACKUP_FILE}"
        run "Extracting PHP config backup" tar -xzf "$PHP_BACKUP_FILE" -C / || echo "Failed to restore PHP backup."
        echo "PHP config backup restored" | tee -a "$LOG"
    else
        echo "No PHP backup file to restore." | tee -a "$LOG"
    fi
}

restore_nginx_backup() {
    if [[ -n "${NGINX_BACKUP_FILE}" && -f "${NGINX_BACKUP_FILE}" && -n "${NGINX_CONF_PATH}" ]]; then
        section "Restoring spartan nginx config from ${NGINX_BACKUP_FILE}"

        run "Copying nginx backup config" cp "$NGINX_BACKUP_FILE" "$NGINX_RESTORE_PATH"

        if [[ "${NGINX_MODE:-}" == "debian" ]]; then
            local filename; filename=$(basename "$NGINX_RESTORE_PATH")
            run "Linking nginx config to sites-enabled" ln -sf "$NGINX_RESTORE_PATH" "/etc/nginx/sites-enabled/${filename}"
        fi
        echo "Nginx backup restored."
    else
        echo "No nginx backup to restore."
    fi
}

restore_app_backup() {
    if [[ -n "${APP_BACKUP_FILE:-}" && -f "$APP_BACKUP_FILE" ]]; then
        section "Restoring application backup from ${APP_BACKUP_FILE}"
        find "$APP_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} + || true
        [[ -d "$APP_DIR" ]] || mkdir -p "$APP_DIR"
        run "Extracting application backup" tar -xzf "$APP_BACKUP_FILE" -C "$(dirname "$APP_DIR")" || echo "Failed to restore app backup."
        echo "App backup restored successfully." | tee -a "$LOG"
    else
        echo "No app backup file found to restore." | tee -a "$LOG"
    fi
}

restore_db_backup() {
    if [[ -n "$DB_BACKUP_FILE" && -f "$DB_BACKUP_FILE" ]]; then
        if [[ "$DB_ENGINE" == "mysql" || "$DB_ENGINE" == "mariadb" ]]; then
            section "Restoring database backup from ${DB_BACKUP_FILE}"
            run "Importing database dump" bash -c "gunzip < '$DB_BACKUP_FILE' | mysql -h '$DB_HOST' -P '$DB_PORT' -u '$DB_USER' -p'$DB_PASS' '$DB_NAME'" || echo "Failed to restore database backup."
            echo "Database backup restored successfully." | tee -a "$LOG"
        else
            echo "Unsupported database engine: ${DB_ENGINE}" | tee -a "$LOG"
        fi
    else
        echo "No database backup file found to restore." | tee -a "$LOG"
    fi
}

restore_backups() {
    set +e
    STEP_COUNTER=1
    section "Something went wrong! restoring backups..."
    restore_app_backup
    restore_db_backup
    restore_php_backup
    restore_ioncube_backup
    restore_nginx_backup
    step "Setup Spartan"
    app_restore_steps
    apply_permissions
    config_php_fpm
    [[ "$WEB" == "nginx" ]] && run "Restart nginx" systemctl restart nginx
    app_maintenance_off
    run "php artisan optimize:clear" bash -lc "cd '${APP_DIR}' && php artisan optimize:clear" || true
    rotate_backups
    step "Self Tests"
    check_db_connection
    smoke_test
    die "Backups restored!"
}

app_get_dir() {
    if [[ ! -d "${APP_DIR}" || -z "$(ls -A -- "$APP_DIR" 2>/dev/null)" ]]; then
        if [[ "$NONINTERACTIVE" == 0 ]]; then
            ask_update_app_dir
        else
            echo "APP directory doesn't exist or is empty."
            exit 1
        fi
    fi
}

app_find_web(){
    if [[ -z "${WEB:-}" ]]; then
        if systemctl is-active --quiet nginx 2>/dev/null || [[ -f /etc/nginx/nginx.conf ]]; then
            WEB="nginx"
        elif systemctl is-active --quiet apache2 2>/dev/null || systemctl is-active --quiet httpd 2>/dev/null || [[ -f /etc/apache2/apache2.conf ]] || [[ -f /etc/httpd/conf/httpd.conf ]]; then
            WEB="apache"
        else
            die "No supported web server detected (nginx or apache)."
        fi
    fi
}

app_get_var() {
    local envfile="${APP_DIR}/.env"

    get_product_name(){
        local NAME="" ID=$1
        case $ID in
            1)
                NAME="Spartan Starter"
                ;;
            5)
                NAME="Spartan Professional"
                ;;
            6)
                NAME="Spartan Ultimate/Dev"
                ;;
            *)
                NAME="PlaceHolder"
                ;;
        esac
        echo "${NAME:-}"
    }

    get_env_value(){
        local key=$1 
        val=$(grep -E "^${key}=" "$envfile" | head -n 1 | cut -d'=' -f2-)
        val="$(echo "${val}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

        if [[ "${val}" =~ ^\"(.*)\"$ ]]; then
            val="${BASH_REMATCH[1]}"
        elif [[ "${val}" =~ ^\'(.*)\'$ ]]; then
            val="${BASH_REMATCH[1]}"
        fi
        val=$(echo "${val}" | sed -e 's/\\\\/\\/g' -e 's/\\"/"/g')
        echo "${val}"
    }

    if [[ -f "$envfile" ]]; then
        section "Reading existing .env file for configuration"
        DOMAIN=$(get_env_value "APP_URL" | sed 's|http[s]*://||' | sed 's|/.*||')
        LICENSE_KEY=$(get_env_value "LICENSE_KEY")
        APP_KEY=$(get_env_value "APP_KEY")
        PRODUCT_ID=$(get_env_value "PRODUCT_ID")
        PRODUCT_NAME=$(get_product_name "${PRODUCT_ID:-}")
        DB_CONNECTION=$(get_env_value "DB_CONNECTION")
        DB_HOST=$(get_env_value "DB_HOST")
        DB_PORT=$(get_env_value "DB_PORT")
        DB_NAME=$(get_env_value "DB_DATABASE")
        DB_USER=$(get_env_value "DB_USERNAME")
        DB_PASS=$(get_env_value "DB_PASSWORD")
        
        DB_CONNECTION=${DB_CONNECTION:-mariadb}
        DB_ENGINE=${DB_ENGINE:-mariadb}
        DB_HOST=${DB_HOST:-127.0.0.1}
        DB_PORT=${DB_PORT:-3306}
        DB_NAME=${DB_NAME:-dezerx}
        DB_USER=${DB_USER:-dezer}
        DB_PASS=${DB_PASS:-}

        case "$DB_CONNECTION" in
            mysql) DB_ENGINE="mysql" ;;
            mariadb) DB_ENGINE="mariadb" ;;
            *) DB_ENGINE="mariadb" ;;
        esac
        
        if [[ -z "$DOMAIN" || -z "$LICENSE_KEY" || -z "$PRODUCT_ID" || -z "$DB_ENGINE" || -z "$DB_HOST" || -z "$DB_PORT" || -z "$DB_NAME" || -z "$DB_USER" || -z "$DB_PASS" ]]; then
            die "Missing required configuration. Ensure all variables are properly set."
        fi

        app_find_web

        section "Loaded values from .env: Domain=${DOMAIN}, Product ID=${PRODUCT_ID}, DB Engine=${DB_ENGINE}, Web Server=${WEB}"
    else
        section "No .env file found. Default values will be used."
    fi
}

merge_env() {
    local old_file="${APP_DIR}/.env"
    local tmpl_file="${APP_DIR}/.env.example"
    local merged_tmp=$(mktemp "${APP_DIR}/.env.merged.XXXXXX")

    declare -A OLD_ENV NEW_ENV MERGED_ENV

    load_env_into_array "$old_file" OLD_ENV
    load_env_into_array "$tmpl_file" NEW_ENV

    section "Merging .env"

    while IFS='=' read -r key _; do
        [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
        key=$(echo "$key" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        if [[ -n "${OLD_ENV[$key]+_}" ]]; then
            MERGED_ENV["$key"]="${OLD_ENV[$key]}"
        else
            MERGED_ENV["$key"]="${NEW_ENV[$key]}"
        fi
    done < "$tmpl_file"

    {
        for key in $(printf '%s\n' "${!MERGED_ENV[@]}" | LC_ALL=C sort); do
            env_write_value "$key" "${MERGED_ENV[$key]}" "$merged_tmp"
        done
    }

    mv -f "$merged_tmp" "$old_file"
    section ".env merged"
}

app_setup_dir(){
    merge_env
    if [[ -f "${APP_DIR}/modules_statuses.json" ]]; then
        mv -- "${APP_DIR}/modules_statuses.json" "${APP_DIR}/modules_statuses.json.new"
        app_merge_json "${APP_DIR}/modules_statuses.json.old" "${APP_DIR}/modules_statuses.json.new" "${APP_DIR}/modules_statuses.json"
    fi
}

Summary(){
    local summary
    local line="---------------------------------------------------------------------"
    summary+="\n${line}\n"
    summary+="${CHOICE^} Summary:\n"
    summary+="${line}\n"
    summary+="> Product:\n"
    summary+="-  Name:        ${PRODUCT_NAME:-}\n"
    summary+="-  ID:          ${PRODUCT_ID:-}\n"
    summary+="> Domain:       ${DOMAIN:-}\n"
    [[ "${CHOICE:-}" != "get_link" ]] &&  summary+="> App Path:     ${APP_DIR}\n"
    [[ -n "${WEB:-}" ]] && summary+="> Web server:   ${WEB:-}\n"
    if [[ -n "${DB_ENGINE:-}" ]]; then
        summary+="> DB:\n"
        summary+="-  Engine:      ${DB_ENGINE:-}\n"
        summary+="-  Connection:  ${DB_USER:-(not set)}@${DB_HOST:-(not set)}:${DB_PORT:-(not set)}/${DB_NAME:-(not set)}\n"
    fi
    summary+="${line}\n"

    if [[ "$ASSUME_YES" == 0 || "$NONINTERACTIVE" == 0 ]]; then
        whiptail --title "$TITLE" --yesno "$summary" 22 73 || exit 1
    else
        echo -e "${summary//$line/${BLUE}$line${NC}}"
    fi
}

verify_webserver(){
    local webserver="$1"
    case "$webserver" in
        nginx)
            WEB="nginx" ;;
        apache)
            WEB="apache" ;;
        *)
            echo "Unknown/unsupported webserver" >&2
            exit 1
            ;;
    esac
}

verify_database(){
    local db_type="$1"
    case "$db_type" in
        mariadb)
            DB_ENGINE="mariadb" ;;
        mysql)
            DB_ENGINE="mysql" ;;
        *)
            echo "Unknown/unsupported database type" >&2
            exit 1
            ;;
    esac
}

verify_license(){
    local license="$1"
    case "$license" in
        SPARTANSTARTER_*)
            PRODUCT_ID="1"
            PRODUCT_NAME="Spartan Starter"
            LICENSE_KEY="${license}"
            ;;
        SPARTANPROFESSIONAL_*)
            PRODUCT_ID="5"
            PRODUCT_NAME="Spartan Professional"
            LICENSE_KEY="${license}"
            ;;
        SPARTANULTIMATE_*)
            PRODUCT_ID="6"
            PRODUCT_NAME="Spartan Ultimate"
            LICENSE_KEY="${license}"
            ;;
        SPARTANDEV_*)
            PRODUCT_ID="6"
            PRODUCT_NAME="Spartan Developer"
            LICENSE_KEY="${license}"
            ;;
        *)
            echo "Invalid license key. Please try again."
            exit 1
            ;;
    esac
}

verify_ssl(){
    local ssl_mode="$1"
    case "$ssl_mode" in
        install)
            certbot_choice="install"
            ;;
        later)
            certbot_choice="later"
            ;;
        assume)
            certbot_choice="assume"
            ;;
        *)
            echo "Invalid ssl mode. Please try again."
            exit 1
            ;;
    esac
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --non-interactive)
                NONINTERACTIVE=1
                ASSUME_YES=1
                shift
                ;;
            -h|--help)
                SHOW_HELP=1
                shift
                ;;
            --install)
                ACTION="install"
                shift
                ;;
            --update)
                ACTION="update"
                shift
                ;;
            --delete|--uninstall)
                ACTION="uninstall"
                shift
                ;;
            --test)
                ACTION="test"
                shift
                ;;
            --setup-perms)
                ACTION="setup_perms"
                shift
                ;;
            --upload-logs)
                ACTION="upload_logs"
                shift
                ;;
            --app-dir=*)
                local dir="${1#--app-dir=}"
                if [[ "${dir-}" ]]; then
                    APP_DIR="$dir"
                    USED_APP_DIR=1
                    shift
                else
                    echo "Missing argument for --app-dir=" >&2
                    exit 1
                fi
                ;;
            --app-dir)
                if [[ -n "${2-}" ]]; then
                    APP_DIR="$2"
                    shift 2
                else
                    echo "Missing argument for --app-dir" >&2
                    exit 1
                fi
                ;;
            --license=*)
                local license="${1#--license=}"
                if [[ "${license-}" ]]; then
                    verify_license "$license"
                    shift
                else
                    echo "Missing argument for --license=" >&2
                    exit 1
                fi
                ;;
            --license)
                if [[ -n "${2-}" ]]; then
                    verify_license "$2"
                    shift 2
                else
                    echo "Missing argument for --license" >&2
                    exit 1
                fi
                ;;
            --domain=*)
                local domain="${1#--domain=}"
                if [[ "${DOMAIN-}" ]]; then
                    DOMAIN="$domain"
                    shift
                else
                    echo "Missing argument for --domain=" >&2
                    exit 1
                fi
                ;;
            --domain)
                if [[ -n "${2-}" ]]; then
                    DOMAIN="$2"
                    shift 2
                else
                    echo "Missing argument for --domain" >&2
                    exit 1
                fi
                ;;
            --webserver=*)
                local webserver
                webserver="${1#--webserver=}"
                if [[ -n "${webserver-}" ]]; then
                    verify_webserver "$webserver"
                    shift
                else
                    echo "Missing argument for --webserver=" >&2
                    exit 1
                fi
                ;;
            --webserver)
                local webserver
                webserver="$2"
                if [[ -n "${webserver-}" ]]; then
                    verify_webserver "$webserver"
                    shift 2
                else
                    echo "Missing argument for --webserver" >&2
                    exit 1
                fi
                ;;
            --db-type=*)
                local db_type
                db_type="${1#--db-type=}"
                if [[ -n "${db_type-}" ]]; then
                    verify_database "$db_type"
                    shift
                else
                    echo "Missing argument for --db-type=" >&2
                    exit 1
                fi
                ;;
            --db-type)
                local db_type
                db_type="$2"
                if [[ -n "${db_type-}" ]]; then
                    verify_database "$db_type"
                    shift 2
                else
                    echo "Missing argument for --db-type" >&2
                    exit 1
                fi
                ;;
            --ssl-mode)
                local ssl_mode
                ssl_mode="$2"
                if [[ -n "${ssl_mode-}" ]]; then
                    verify_ssl "$ssl_mode"
                    shift 2
                else
                    echo "Missing argument for --ssl-mode" >&2
                    exit 1
                fi
                ;;
            --ssl-mode=*)
                local ssl_mode
                ssl_mode="${1#--ssl-mode=}"
                if [[ -n "${ssl_mode-}" ]]; then
                    verify_ssl "$ssl_mode"
                    shift
                else
                    echo "Missing argument for --ssl-mode=" >&2
                    exit 1
                fi
                ;;
            --ipv6=*)
                local ipv6
                ipv6="${1#--ipv6=}"
                if [[ -n "${ipv6-}" ]]; then
                    case "${ipv6-}" in
                        true|enable)
                            ENABLE_IPV6=1
                            ;;
                        false|disable)
                            ENABLE_IPV6=0
                            ;;
                    esac
                    shift
                else
                    echo "Missing argument for --ipv6=" >&2
                    exit 1
                fi
                ;;
            --ipv6)
                local ipv6
                ipv6="${2}"
                if [[ -n "${ipv6-}" ]]; then
                    case "${ipv6-}" in
                        true|enable)
                            ENABLE_IPV6=1
                            shift 2
                            ;;
                        false|disable)
                            ENABLE_IPV6=0
                            shift 2
                            ;;
                        *)
                            echo "unsupported argument for --ipv6\ndefaulting to true"
                            ENABLE_IPV6=1
                            shift 1
                            ;;
                    esac
                else
                    echo "No argument provided for --ipv6\ndefaulting to true"
                    ENABLE_IPV6=1
                    shift 1
                fi
                ;;
            --keep-nginx)
                KEEP_NGINX=1
                shift
                ;;
            --keep-css)
                KEEP_CSS=1
                shift
                ;;
            --keep-themes)
                KEEP_THEMES=1
                shift
                ;;
            --keep-portals)
                KEEP_PORTALS=1
                shift
                ;;
            --keep-emails)
                KEEP_EMAILS=1
                shift
                ;;
            --keep-favicon)
                KEEP_FAVICON=1
                shift
                ;;
            --options-file) 
                local optionsFile
                optionsFile="${2:-}"
                if [[ -n "${optionsFile}" ]]; then
                    OPTIONS_JSON_NAME="${optionsFile}"
                    shift 2
                else
                    echo "Missing argument for --options-file" >&2
                    exit 1
                fi
                ;;
            --options-file=*) 
                local optionsFile
                optionsFile="${1#--options-file=}"
                if [[ -n "${optionsFile}" ]]; then
                    OPTIONS_JSON_NAME="${optionsFile}"
                    shift 1
                else
                    echo "Missing argument for --options-file=" >&2
                    exit 1
                fi
                ;;
            --add-swap)
                local swap
                swap="${2:-1024}"
                if [[ -n "${swap}" ]]; then
                    FORCE_SWAP=1
                    SWAP_SIZE="${swap}"
                    shift 2
                fi
                ;;
            --add-swap=*) 
                local swap
                swap="${1#--add-swap=}"
                if [[ -n "${swap}" ]]; then
                    FORCE_SWAP=1
                    SWAP_SIZE="${swap}"
                    shift 1
                else
                    echo "Missing argument for --add-swap=" >&2
                    exit 1
                fi
                ;;
            *)
                echo "Unknown option: $1" >&2
                shift
                ;;
        esac
    done
}

noninteractive_checks(){
    local missing_args required_args
    if [[ "$ACTION" == "install" || "$ACTION" == "test" || -z "$ACTION" ]]; then
        missing_args=()
        required_args=(
            ACTION
            DOMAIN
            LICENSE_KEY
            WEB
            DB_ENGINE
            certbot_choice
        )

        for arg in "${required_args[@]}"; do
            [[ -z "${!arg:-}" ]] && missing_args+=("$arg")
        done

        if [[ "${#missing_args[@]}" -eq 0 ]]; then
            echo "All required arguments supplied continuing in non-interactive mode."
        else
            echo "Missing arguments for non-interactive mode to continue: ${missing_args[*]}"
            exit 1
        fi
    elif [[ "$ACTION" == "update" ]]; then
        if [[ "$USED_APP_DIR" == 1 ]]; then
            echo "All required and optional arguments supplied continuing in non-interactive mode."
        else
            echo "All required arguments supplied continuing in non-interactive mode. (missing optional --app-dir)"
        fi
    elif [[ "$ACTION" == "upload_logs" || "$ACTION" == "upload logs" || "$ACTION" == "setup_perms" || "$ACTION" == "setup perms" ]]; then
        if [[ "$USED_APP_DIR" == 1 ]]; then
            echo "All required and optional arguments supplied continuing in non-interactive mode."
        else
            echo "All required arguments supplied continuing in non-interactive mode. (missing optional --app-dir)"
        fi
    else
        echo "non-interactive mode not available for this action at the moment."
        exit 1
    fi
}

show_help(){
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
    -h, --help                  Show this help message and exit
    --install                   Run a fresh installation (interactive/non-interactive)
    --update                    Update an existing installation (non-interactive)
    --setup-perms               Setup permissions on a installation (non-interactive)
    --delete, --uninstall       Delete the application directory (no DB removal)
    --non-interactive           hides all confirmation and configuration dialogs
                                (used for 1 line installs/updates)

    --ipv6                      Enables ipv6 support for requests.

    --app-dir=PATH              Sets the application directory (DocumentRoot = PATH/public)
                                You can also use the spaced form:  --app-dir PATH

    --license=KEY               Sets the DezerX license key.
                                You can also use the spaced form:  --license KEY

    --domain=HOSTNAME           Primary domain for the vHost, APP_URL and SSL.
                                You can also use the spaced form:  --domain HOSTNAME

    --webserver=SERVER          Sets the web server to install and configure.
                                Accepted values:  nginx | apache (apache not supported atm)
                                You can also use the spaced form:  --webserver SERVER

    --db-type=ENGINE            Sets the database engine to install and configure.
                                Accepted values:  mariadb | mysql
                                You can also use the spaced form:  --db-type ENGINE

    --ssl-mode=MODE             Sets SSL mode to use.
                                Accepted values:  install | later | assume
                                You can also use the spaced form:  --ssl-mode MODE

It's also recommanded to use -- at the start and "" in case the script can't find the custom setting example:
    $0 -- --update --app-dir "/Path To/My spartan/Install/"
EOF
    exit 0
}

# ---------------- Flow ----------------

parse_args "$@"

[[ "$SHOW_HELP" == 1 ]] && show_help
[[ "$NONINTERACTIVE" == 1 ]] && noninteractive_checks

need_root
detect_os
setup_permanent_swap
sync_server_time
section "Install essentials"
pm_update_upgrade 0
install_essentials

echo
hr
VERSION=$(curl -fs "https://api.github.com/repos/dezerx-spartan/Spartan-Installer/releases/latest" | jq -r .tag_name)
VERSION=${VERSION:-"Undefined"}
echo -e "Script version ${VERSION}"
hr
echo

if [[ -z "$ACTION" ]]; then
    main_menu
else
    CHOICE="$ACTION" 
fi

if [[ "$CHOICE" == "install" ]]; then
    # Installation logic
    ask_domain
    [[ -z "$LICENSE_KEY" ]] && ask_license_key
    ask_app_dir
    choose_webserver
    choose_db_engine
    db_collect

    # A resume
    Summary
    install(){
        # License part
        step "Download & Install Spartan"
        license_verify
        license_download_and_extract
        

        # Install system stack & app deps
        step "Install Components"
        install_php_stack
        install_webserver
        no_apache
        install_nodejs_lts
        install_db_engine
        db_create
        install_composer
        prepare_ioncube
        

        # App setup & build
        step "Setup Spartan & Components"
        detect_web_user_group
        config_php_fpm
        config_opcache
        config_network
        app_env_setup
        app_install_steps
        apply_permissions
        setup_cron
        setup_systemd_queue
        
        nginx_layout_detect
        configure_nginx_http_only
        if [[ -n "${certbot_choice-}" ]]; then
            echo "Skipping certbot/ssl prompt, using provided ssl mode."
        elif [[ "$ASSUME_YES" == 1 ]]; then
            certbot_choice="install"
            echo "Assuming certbot/ssl mode as install."
        else
            certbot_choice=$(whiptail --title "$TITLE" --menu "Install SSL with Certbot for ${DOMAIN} now?" 11 70 3 "install" "(run certbot automatically)" "later" "(skip SSL completely)" "assume" "(https template with self-signed certs)" 3>&1 1>&2 2>&3) || true
        fi

        if [[ "$WEB" == "nginx" ]]; then
            case "$certbot_choice" in
                install)
                    install_certbot_pkgs
                    run_certbot_webroot
                    configure_nginx_ssl
                    flip_app_url_to_https
                    ;;
                later)
                    section "Chose HTTP only."
                    ;;
                assume)
                    section "Assuming SSL – base config for HTTPS."
                    install_certbot_pkgs
                    create_self_signed_certs
                    configure_nginx_ssl
                    flip_app_url_to_https
                    ;;
                *)
                    section "unexpected response – skipping SSL setup."
                    ;;
            esac
        else
            case "$certbot_choice" in
                install)
                    install_certbot_pkgs
                    run "Certbot (apache)" certbot --apache -d "${DOMAIN}" || true
                    flip_app_url_to_https
                    ;;
                later)
                    section "User chose to install SSL later (Apache)."
                    ;;
                assume)
                    section "Assuming SSL template for Apache – enabling SSL vhost"
                    install_certbot_pkgs
                    flip_app_url_to_https
                    ;;
                *)   section "Dialog cancelled – skipping Apache SSL setup."
                    ;;
            esac

        fi

        ensure_options_json
        app_maintenance_off
        run "php artisan optimize:clear" bash -lc "cd '${APP_DIR}' && php artisan optimize:clear"
        step "Self Tests"
        smoke_test
        check_db_connection

        section "All done!"
        echo
        hr 
        echo "Summary:"
        hr
        echo "- Domain:       ${DOMAIN:-}"
        echo "- App Path:     ${APP_DIR:-}"
        echo "- Web server:   ${WEB:-}"
        [[ "${certbot_choice:-}" != "later" && -n "${certbot_choice:-}" ]] && echo "- SSL Path:     /etc/letsencrypt/live/${DOMAIN:-}/"
        php -v | grep -qi ioncube && echo "- ionCube:      enabled" || echo "- ionCube:      not detected"
        echo "- DB:"
        echo "-  Engine:      ${DB_ENGINE:-}"
        echo "-  Connection:  ${DB_USER:-}@${DB_HOST:-}:${DB_PORT:-}/${DB_NAME:-}"
        echo "- Logs:"
        echo "-  Script:      ${LOG:-}"
        echo "-  Spartan:     ${APP_DIR:-}/storage/logs/laravel.log"
        [[ "${WEB:-}" == "nginx" ]] && echo "-  nginx:       /var/log/nginx/error.log" || echo "-  apache:      /var/log/httpd/error.log"
        hr
        echo "Dashboard Access:"
        hr
        local protocol="http"
        [[ "${certbot_choice:-}" != "later" && -n "${certbot_choice:-}" ]] && protocol="https"
        local full_url="${protocol}://${DOMAIN:-}"
        local clickable_url="\033]8;;${full_url}\033\\${full_url}\033]8;;\033\\"
        echo -e "- URL:          ${L_CYAN}${clickable_url}${NC}"
        echo "- Next Step:    Go to the URL above and create an account."
        echo "- Note:         The first account created is automatically granted Admin privileges."
        hr
        echo "Useful Commands:"
        hr
        echo "- Check Services: systemctl status dezerx.service"
        echo "- Check Cron:     crontab -l"
        echo "- Check Logs:     tail -n 50 -f ${APP_DIR:-}/storage/logs/laravel.log"
        hr
        echo
    }
    install
    exit 0
elif [[ "$CHOICE" == "update" ]]; then
    # Get all needed variables
    app_maintenance_on
    app_get_dir
    app_get_var
    detect_web_user_group
    nginx_layout_detect

    # Backup app
    if ! create_backups; then
        app_maintenance_off
        die "Couldn't make backups. Abording"
    fi

    # License part
    if ! license_verify; then
        app_maintenance_off
        exit 1
    fi

    ask_what_to_keep

    Summary

    safe_update() {
        check_db_connection
        update_status=0
        trap 'if [[ $update_status -eq 0 ]]; then restore_backups; fi' EXIT

        step "Download & Install New Spartan Version"

        license_download_and_extract
        
        step "Install/Upgrade Components"

        install_php_stack
        install_nodejs_lts
        prepare_ioncube
        config_opcache
        config_network

        step "Setup Spartan & Components"

        # Install and set perms
        app_setup_dir
        app_update_steps
        restore_options_items
        apply_permissions
        setup_cron
        setup_systemd_queue
        
        # Restart services and update nginx config
        if [[ "$WEB" == "nginx" ]]; then
            if [[ "$KEEP_NGINX" == "0" ]]; then
                section "Updating NGINX configuration"
                if grep -qE "^APP_URL=[[:space:]]*[\"']?https://" "${APP_DIR}/.env"; then
                    echo "Detected HTTPS in .env"
                    CERT_DIR=""
                    local existing_cert_path

                    if [[ -f "${NGINX_CONF_OLD_PATH}" ]]; then
                        existing_cert_path=$(grep -Eo 'ssl_certificate[[:space:]]+[^;]+' "$NGINX_CONF_OLD_PATH" | head -n1 | awk '{print $2}')

                        if [[ -n "${existing_cert_path-}" ]]; then
                            CERT_DIR=$(dirname "${existing_cert_path-}")
                            echo "Extracted certificate directory from the old NGINX configuration"
                        fi
                    elif [[ -f "${NGINX_CONF_PATH}" ]]; then
                        existing_cert_path=$(grep -Eo 'ssl_certificate[[:space:]]+[^;]+' "$NGINX_CONF_PATH" | head -n1 | awk '{print $2}')

                        if [[ -n "${existing_cert_path-}" ]]; then
                            CERT_DIR=$(dirname "${existing_cert_path-}")
                            echo "Extracted certificate directory from the old NGINX configuration"
                        fi
                    fi

                    if [[ -z ${CERT_DIR-} ]]; then
                        if [[ -d "/etc/certs/spartan/${DOMAIN}" ]]; then
                            CERT_DIR="/etc/certs/spartan/${DOMAIN}"
                        elif [[ -d "/etc/letsencrypt/live/${DOMAIN}" ]]; then
                            CERT_DIR="/etc/letsencrypt/live/${DOMAIN}"
                        else
                            error "Could not locate SSL certificates for NGINX. Falling back to a self-signed cert to prevent crash."
                            create_self_signed_certs
                        fi
                    fi

                    if [[ -f "${NGINX_CONF_OLD_PATH}" ]]; then
                        run "Removing old nginx config" rm -f "${NGINX_CONF_OLD_PATH}" || true
                    fi

                    if [[ -n "${NGINX_CONF_OLD_SYMLINK}" && -L "${NGINX_CONF_OLD_SYMLINK}" ]]; then
                        run "Removing old nginx symlink" rm -f "${NGINX_CONF_OLD_SYMLINK}" || true
                    fi

                    configure_nginx_ssl
                else
                    echo "Detected HTTP in .env"

                    if [[ -f "${NGINX_CONF_OLD_PATH}" ]]; then
                        run "Removing old nginx config" rm -f "${NGINX_CONF_OLD_PATH}" || true
                    fi

                    if [[ -n "${NGINX_CONF_OLD_SYMLINK}" && -L "${NGINX_CONF_OLD_SYMLINK}" ]]; then
                        run "Removing old nginx symlink" rm -f "${NGINX_CONF_OLD_SYMLINK}" || true
                    fi

                    configure_nginx_http_only
                fi
            else
                echo "Skipping NGINX configuration update"
            fi
            restart_php_fpm
            run "Restart nginx" systemctl restart nginx
        elif [[ "$WEB" == "apache" ]]; then
            run "Restart Apache" systemctl restart apache2 || systemctl restart httpd
        else
            echo "Unknown web server, cannot restart." | tee -a "$LOG"
        fi
        
        ensure_options_json
        app_maintenance_off
        run "php artisan optimize:clear" bash -lc "cd '${APP_DIR}' && php artisan optimize:clear"
        rotate_backups
        step "Self Tests"
        check_db_connection
        smoke_test
        update_status=1
        trap - EXIT


        section "All done!"
        echo
        hr 
        echo "Summary:"
        hr
        echo "- Domain:       ${DOMAIN:-}"
        echo "- App Path:     ${APP_DIR:-}"
        echo "- Web server:   ${WEB:-}"
        [[ "${certbot_choice:-}" != "later" && -n "${certbot_choice:-}" ]] && echo "- SSL Path:     /etc/letsencrypt/live/${DOMAIN:-}/"
        php -v | grep -qi ioncube && echo "- ionCube:      enabled" || echo "- ionCube:      not detected"
        echo "- DB:"
        echo "-  Engine:      ${DB_ENGINE:-}"
        echo "-  Connection:  ${DB_USER:-}@${DB_HOST:-}:${DB_PORT:-}/${DB_NAME:-}"
        echo "- Logs:"
        echo "-  Script:      ${LOG:-}"
        echo "-  Spartan:     ${APP_DIR:-}/storage/logs/laravel.log"
        [[ "${WEB:-}" == "nginx" ]] && echo "-  nginx:       /var/log/nginx/error.log" || echo "-  apache:      /var/log/httpd/error.log"
        hr
        echo "Dashboard Access:"
        hr
        local protocol="http"
        [[ "${certbot_choice:-}" != "later" && -n "${certbot_choice:-}" ]] && protocol="https"
        local full_url="${protocol}://${DOMAIN:-}"
        local clickable_url="\033]8;;${full_url}\033\\${full_url}\033]8;;\033\\"
        echo -e "- URL:          ${L_CYAN}${clickable_url}${NC}"
        echo "- Next Step:    Go to the URL above and create an account."
        echo "- Note:         The first account created is automatically granted Admin privileges."
        hr
        echo "Useful Commands:"
        hr
        echo "- Check Services: systemctl status dezerx.service"
        echo "- Check Cron:     crontab -l"
        echo "- Check Logs:     tail -n 50 -f ${APP_DIR:-}/storage/logs/laravel.log"
        hr
        echo
    }
    safe_update
    exit 0
elif [[ "$CHOICE" == "setup_perms" || "$CHOICE" == "setup perms" ]]; then
    app_find_web
    detect_web_user_group
    section "Applying permissions to ${APP_DIR}..."
    apply_permissions
    config_php_fpm
    echo "Permissions applied!"
    exit 0
elif [[ "$CHOICE" == "upload_logs" || "$CHOICE" == "upload logs" ]]; then
    echo "I couldn't find a secure platform where to send the logs, so this function doesn't work for now."
    exit 1
    section "Bundling and uploading logs..."
    if ! command -v zip >/dev/null 2>&1; then
        echo "Zip command not found, installing..."
        pm_install zip
    fi
    log_zip=$(mktemp -u "/tmp/spartan_logs_XXXXXX.zip")
    shopt -s nullglob
    zip -qj "$log_zip" "$LOG" "${APP_DIR}/storage/logs/"* 2>/dev/null || true
    shopt -u nullglob
    if [[ -f "$log_zip" ]]; then
        echo "Uploading logs to  (auto-deletes after 1 download)..."
        local upload_response
        upload_response=$(curl -s -F "file=@${log_zip}" )
        upload_url=$(echo "$upload_response" | jq -r '.link // empty' 2>/dev/null)

        local clickable_url="\033]8;;${upload_url}\033\\${upload_url}\033]8;;\033\\"

        echo -e "\n${GREEN}Logs uploaded successfully! Share this URL:${NC}\n${CYAN}${clickable_url}${NC}"
        rm -f "$log_zip"
    else
        echo "Failed to gather logs for upload."
    fi
    exit 0
elif [[ "$CHOICE" == "uninstall" ]]; then
    whiptail --title "$TITLE" --yesno "Are you sure you want to delete the application at ${APP_DIR}?\nThis will NOT delete the database or any backups you may have created.\n\nThis action cannot be undone." 15 70 || exit 1
    if [[ -d "$APP_DIR" ]]; then
        run "Remove application directory ${APP_DIR}" rm -rf "$APP_DIR"
        echo "Application at ${APP_DIR} has been deleted."
        echo "Note: Database and backups are NOT deleted."
        exit 0
    else
        die "Application directory ${APP_DIR} does not exist."
    fi
elif [[ "$CHOICE" == "test" ]]; then
    echo "test :3"

    step "test"
    showcase_colors
    Summary

    app_get_dir
    app_get_var
    detect_web_user_group
    nginx_layout_detect
    rotate_backups

    test_summary(){
        echo
        hr 
        echo "Summary:"
        hr
        echo "- Domain:       ${DOMAIN:-}"
        echo "- App Path:     ${APP_DIR:-}"
        echo "- Web server:   ${WEB:-}"
        [[ "${certbot_choice:-}" != "later" && -n "${certbot_choice:-}" ]] && echo "- SSL Path:     /etc/letsencrypt/live/${DOMAIN:-}/"
        php -v | grep -qi ioncube && echo "- ionCube:      enabled" || echo "- ionCube:      not detected"
        echo "- DB:"
        echo "-  Engine:      ${DB_ENGINE:-}"
        echo "-  Connection:  ${DB_USER:-}@${DB_HOST:-}:${DB_PORT:-}/${DB_NAME:-}"
        echo "- Logs:"
        echo "-  Script:      ${LOG:-}"
        echo "-  Spartan:     ${APP_DIR:-}/storage/logs/laravel.log"
        [[ "${WEB:-}" == "nginx" ]] && echo "-  nginx:       /var/log/nginx/error.log" || echo "-  apache:      /var/log/httpd/error.log"
        hr
        echo "Dashboard Access:"
        hr
        local protocol="http"
        [[ "${certbot_choice:-}" != "later" && -n "${certbot_choice:-}" ]] && protocol="https"
        local full_url="${protocol}://${DOMAIN:-}"
        local clickable_url="\033]8;;${full_url}\033\\${full_url}\033]8;;\033\\"
        echo -e "- URL:          ${L_CYAN}${clickable_url}${NC}"
        echo "- Next Step:    Go to the URL above and create an account."
        echo "- Note:         The first account created is automatically granted Admin privileges."
        hr
        echo "Useful Commands:"
        hr
        echo "- Check Services: systemctl status dezerx.service"
        echo "- Check Cron:     crontab -l"
        echo "- Check Logs:     tail -n 50 -f ${APP_DIR:-}/storage/logs/laravel.log"
        hr
        echo
    }
    test_summary
    exit 0
else
    echo "No valid choice made, exiting."
fi
