#!/usr/bin/env bash
# =============================================================================
# magneto-ssh — SSH connection manager for Magento environments
# Pure Bash. Zero dependencies beyond ssh and sshpass (for passwords)
# =============================================================================

set -euo pipefail

# ── Version ───────────────────────────────────────────────────────────────────
VERSION="1.8.000"

# ── Paths ─────────────────────────────────────────────────────────────────────
CONFIG_DIR="${HOME}/.magneto-ssh"
SERVERS_DIR="${CONFIG_DIR}/servers"
KEYS_DIR="${CONFIG_DIR}/keys"
UPDATE_CACHE="${CONFIG_DIR}/.update_cache"

# ── ANSI colors ───────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    DIM='\033[2m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' CYAN='' BOLD='' DIM='' NC=''
fi

# ── Output helpers ────────────────────────────────────────────────────────────
ok()   { printf "${GREEN}✓${NC} %b\n"   "$*"; }
err()  { printf "${RED}✗${NC} %b\n"    "$*" >&2; }
warn() { printf "${YELLOW}!${NC} %b\n" "$*"; }
die()  { err "$*"; exit 1; }

# ── Directory setup ───────────────────────────────────────────────────────────
ensure_dirs() {
    mkdir -p "${SERVERS_DIR}" "${KEYS_DIR}"
    chmod 700 "${CONFIG_DIR}" "${SERVERS_DIR}" "${KEYS_DIR}"
}

# ── Config field I/O ──────────────────────────────────────────────────────────

server_file()   { printf '%s' "${SERVERS_DIR}/$1"; }
server_exists() { [[ -f "$(server_file "$1")" ]]; }

read_field() {
    local file="$1" key="$2"
    grep "^${key}=" "${file}" 2>/dev/null | head -1 | cut -d'=' -f2- || true
}

write_server() {
    local name="$1"
    local file; file=$(server_file "${name}")
    ensure_dirs
    cat > "${file}"
    chmod 600 "${file}"
}

list_server_names() {
    find "${SERVERS_DIR}" -maxdepth 1 -type f -printf '%f\n' 2>/dev/null | sort
}

# ── Interactive server picker ─────────────────────────────────────────────────
pick_server() {
    local prompt="${1:-Select server}"
    local names
    mapfile -t names < <(list_server_names)
    [[ ${#names[@]} -gt 0 ]] || die "No servers configured. Run: magneto-ssh add <name>"
    if command -v fzf &>/dev/null; then
        printf "%s\n" "${names[@]}" | fzf --prompt="${prompt}: " --height=40% --reverse --no-info
    else
        printf "${BOLD}%s:${NC}\n" "${prompt}" >&2
        select name in "${names[@]}"; do
            [[ -n "${name}" ]] && { printf "%s" "${name}"; return 0; }
            printf "Invalid selection.\n" >&2
        done
    fi
}

# ── TCP reachability (uses bash built-in /dev/tcp, no nc required) ────────────
tcp_check() {
    local host="$1" port="$2" timeout="${3:-5}"
    timeout "${timeout}" bash -c "echo >/dev/tcp/${host}/${port}" 2>/dev/null
}

# =============================================================================
# Commands
# =============================================================================

cmd_add() {
    local name="${1:-}"
    [[ -n "${name}" ]] || die "Usage: magneto-ssh add <name>"

    if server_exists "${name}"; then
        printf "Server '%s' already exists. Overwrite? [y/N] " "${name}"
        read -r confirm
        [[ "${confirm,,}" == "y" ]] || exit 0
    fi

    printf "\n${BOLD}Adding server:${NC} ${CYAN}%s${NC}\n\n" "${name}"

    # ── Required fields ───────────────────────────────────────────────────────
    local host port user auth_type
    printf "  Host (IP or domain): "; read -r host
    [[ -n "${host}" ]] || die "Host is required."

    printf "  Port [22]: "; read -r port; port="${port:-22}"
    [[ "${port}" =~ ^[0-9]+$ && "${port}" -ge 1 && "${port}" -le 65535 ]] \
        || die "Invalid port: ${port}"

    printf "  SSH user: "; read -r user
    [[ -n "${user}" ]] || die "User is required."

    printf "  Auth type:\n    1) password\n    2) ssh_key\n"
    printf "  Select [1/2]: "; read -r auth_choice
    [[ "${auth_choice}" == "2" ]] && auth_type="ssh_key" || auth_type="password"

    # ── Auth credentials ──────────────────────────────────────────────────────
    local password="" ssh_key=""
    if [[ "${auth_type}" == "password" ]]; then
        printf "  SSH password: "; read -rs password; printf '\n'
    else
        printf "  Path to SSH key [~/.ssh/id_rsa]: "; read -r ssh_key
        ssh_key="${ssh_key:-~/.ssh/id_rsa}"
    fi

    # ── Optional metadata ─────────────────────────────────────────────────────
    printf "\n${DIM}  Optional fields — press Enter to skip:${NC}\n"

    local project_dir admin_url admin_user admin_password frontend_url git_token
    printf "  Project directory: ";  read -r project_dir
    printf "  Admin URL: ";          read -r admin_url
    printf "  Admin username: ";     read -r admin_user

    admin_password=""
    if [[ -n "${admin_user}" ]]; then
        printf "  Admin password: "; read -rs admin_password; printf '\n'
    fi

    printf "  Frontend URL: ";  read -r frontend_url
    printf "  Git token: ";     read -rs git_token; printf '\n'

    local disk_path
    printf "  Disk usage path (for df -h) [~/application/]: "
    read -r disk_path

    # ── Database (optional) ──────────────────────────────────────────────────
    local db_host db_port db_name db_user db_password
    printf "\n${DIM}  Database (optional):${NC}\n"
    printf "  DB host [127.0.0.1]: ";   read -r db_host;          db_host="${db_host:-127.0.0.1}"
    printf "  DB port [3306]: ";        read -r db_port;           db_port="${db_port:-3306}"
    printf "  DB name: ";               read -r db_name
    printf "  DB user: ";               read -r db_user
    db_password=""
    if [[ -n "${db_user}" ]]; then
        printf "  DB password: ";       read -rs db_password; printf "\n"
    fi

    # ── Save ──────────────────────────────────────────────────────────────────
    write_server "${name}" <<EOF
HOST=${host}
PORT=${port}
USER=${user}
AUTH_TYPE=${auth_type}
PASSWORD=${password}
SSH_KEY=${ssh_key}
PROJECT_DIR=${project_dir}
ADMIN_URL=${admin_url}
ADMIN_USER=${admin_user}
ADMIN_PASSWORD=${admin_password}
FRONTEND_URL=${frontend_url}
GIT_TOKEN=${git_token}
DB_HOST=${db_host}
DB_PORT=${db_port}
DB_NAME=${db_name}
DB_USER=${db_user}
DB_PASSWORD=${db_password}
DISK_PATH=${disk_path}
EOF

    printf '\n'; ok "Server ${CYAN}${name}${NC} saved.\n"
}

# ─────────────────────────────────────────────────────────────────────────────

cmd_update() {
    local name="${1:-}"
    [[ -n "${name}" ]] || die "Usage: magneto-ssh edit <name>"
    server_exists "${name}" || die "Server '${name}' not found. Run: magneto-ssh list"

    local file; file=$(server_file "${name}")

    # ── Load all current values ───────────────────────────────────────────────
    local cur_host cur_port cur_user cur_auth_type cur_password cur_ssh_key
    local cur_project_dir cur_admin_url cur_admin_user cur_admin_password
    local cur_frontend_url cur_git_token
    local cur_db_host cur_db_port cur_db_name cur_db_user cur_db_password cur_disk_path

    cur_host=$(read_field "${file}" HOST)
    cur_port=$(read_field "${file}" PORT)
    cur_user=$(read_field "${file}" USER)
    cur_auth_type=$(read_field "${file}" AUTH_TYPE)
    cur_password=$(read_field "${file}" PASSWORD)
    cur_ssh_key=$(read_field "${file}" SSH_KEY)
    cur_project_dir=$(read_field "${file}" PROJECT_DIR)
    cur_admin_url=$(read_field "${file}" ADMIN_URL)
    cur_admin_user=$(read_field "${file}" ADMIN_USER)
    cur_admin_password=$(read_field "${file}" ADMIN_PASSWORD)
    cur_frontend_url=$(read_field "${file}" FRONTEND_URL)
    cur_git_token=$(read_field "${file}" GIT_TOKEN)
    cur_db_host=$(read_field "${file}" DB_HOST)
    cur_db_port=$(read_field "${file}" DB_PORT)
    cur_db_name=$(read_field "${file}" DB_NAME)
    cur_db_user=$(read_field "${file}" DB_USER)
    cur_db_password=$(read_field "${file}" DB_PASSWORD)
    cur_disk_path=$(read_field "${file}" DISK_PATH)

    # ── Field picker ─────────────────────────────────────────────────────────
    printf "\n${BOLD}Edit server:${NC} ${CYAN}%s${NC}\n" "${name}"

    local field_labels=(
        "Name            [${name}]"
        "Host            [${cur_host}]"
        "Port            [${cur_port}]"
        "SSH User        [${cur_user}]"
        "Auth Type       [${cur_auth_type}]"
        "SSH Password    $([ -n "${cur_password}" ] && echo "[set]" || echo "[not set]")"
        "SSH Key         [${cur_ssh_key}]"
        "Project Dir     [${cur_project_dir}]"
        "Admin URL       [${cur_admin_url}]"
        "Admin User      [${cur_admin_user}]"
        "Admin Password  $([ -n "${cur_admin_password}" ] && echo "[set]" || echo "[not set]")"
        "Frontend URL    [${cur_frontend_url}]"
        "Git Token       $([ -n "${cur_git_token}" ] && echo "[set]" || echo "[not set]")"
        "DB Host         [${cur_db_host}]"
        "DB Port         [${cur_db_port}]"
        "DB Name         [${cur_db_name}]"
        "DB User         [${cur_db_user}]"
        "DB Password     $([ -n "${cur_db_password}" ] && echo "[set]" || echo "[not set]")"
        "Disk Path       [${cur_disk_path}]"
    )

    local -a chosen_indices=()
    if command -v fzf &>/dev/null; then
        printf "${DIM}  ↑↓ navigate  Tab=toggle  Enter=confirm${NC}\n\n"
        local selected
        selected=$(printf '%s\n' "${field_labels[@]}" \
            | fzf --multi --prompt="Select fields to edit: " \
                  --height=~100% --reverse --no-info \
                  --bind 'tab:toggle+down') || true
        while IFS= read -r line; do
            for i in "${!field_labels[@]}"; do
                [[ "${field_labels[$i]}" == "$line" ]] && chosen_indices+=("$i") && break
            done
        done <<< "$selected"
    else
        printf "${DIM}  Enter numbers separated by spaces (e.g. 1 3 6):${NC}\n\n"
        local i=1
        for label in "${field_labels[@]}"; do
            printf "  %2d) %s\n" "$i" "${label}"
            (( i++ ))
        done
        printf "\n  Fields to edit: "; read -r choices
        for n in ${choices}; do
            [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#field_labels[@]} )) \
                && chosen_indices+=("$((n-1))")
        done
    fi

    [[ ${#chosen_indices[@]} -gt 0 ]] || { warn "No fields selected. Nothing changed."; return 0; }

    _field_is_chosen() {
        local idx=$1
        for i in "${chosen_indices[@]}"; do
            [[ "$i" == "$idx" ]] && return 0
        done
        return 1
    }

    # ── Prompt only selected fields ───────────────────────────────────────────
    local new_name="${name}"
    if _field_is_chosen 0; then
        printf "  Server name [%s]: " "${name}"; read -r new_name
        new_name="${new_name:-${name}}"
        if [[ "${new_name}" != "${name}" ]] && server_exists "${new_name}"; then
            printf "Server '%s' already exists. Overwrite? [y/N] " "${new_name}"; read -r _ow
            [[ "${_ow,,}" == "y" ]] || exit 0
        fi
    fi

    local host="${cur_host}" port="${cur_port}" user="${cur_user}" auth_type="${cur_auth_type}"
    if _field_is_chosen 1; then
        printf "  Host [%s]: " "${cur_host}"; read -r host; host="${host:-${cur_host}}"
        [[ -n "${host}" ]] || die "Host is required."
    fi
    if _field_is_chosen 2; then
        printf "  Port [%s]: " "${cur_port}"; read -r port; port="${port:-${cur_port}}"
        [[ "${port}" =~ ^[0-9]+$ && "${port}" -ge 1 && "${port}" -le 65535 ]] || die "Invalid port."
    fi
    if _field_is_chosen 3; then
        printf "  SSH user [%s]: " "${cur_user}"; read -r user; user="${user:-${cur_user}}"
        [[ -n "${user}" ]] || die "User is required."
    fi
    if _field_is_chosen 4; then
        printf "  Auth type (current: %s):\n    1) password\n    2) ssh_key\n  Select: " "${cur_auth_type}"
        read -r _ac
        case "${_ac}" in 1) auth_type="password";; 2) auth_type="ssh_key";; esac
    fi

    local password="${cur_password}" ssh_key="${cur_ssh_key}"
    if _field_is_chosen 5 && [[ "${auth_type}" == "password" ]]; then
        printf "  New SSH password: "; read -rs password; printf '\n'
    fi
    if _field_is_chosen 6 && [[ "${auth_type}" == "ssh_key" ]]; then
        printf "  SSH key path [%s]: " "${cur_ssh_key}"; read -r ssh_key; ssh_key="${ssh_key:-${cur_ssh_key}}"
    fi

    local project_dir="${cur_project_dir}" admin_url="${cur_admin_url}" admin_user="${cur_admin_user}"
    local frontend_url="${cur_frontend_url}"
    if _field_is_chosen 7; then
        printf "  Project dir [%s]: " "${cur_project_dir}"; read -r project_dir
        project_dir="${project_dir:-${cur_project_dir}}"
    fi
    if _field_is_chosen 8; then
        printf "  Admin URL [%s]: " "${cur_admin_url}"; read -r admin_url
        admin_url="${admin_url:-${cur_admin_url}}"
    fi
    if _field_is_chosen 9; then
        printf "  Admin username [%s]: " "${cur_admin_user}"; read -r admin_user
        admin_user="${admin_user:-${cur_admin_user}}"
    fi
    if _field_is_chosen 11; then
        printf "  Frontend URL [%s]: " "${cur_frontend_url}"; read -r frontend_url
        frontend_url="${frontend_url:-${cur_frontend_url}}"
    fi

    local admin_password="${cur_admin_password}" git_token="${cur_git_token}"
    if _field_is_chosen 10; then
        printf "  New admin password: "; read -rs admin_password; printf '\n'
    fi
    if _field_is_chosen 12; then
        printf "  New git token: "; read -rs git_token; printf '\n'
    fi

    local db_host="${cur_db_host:-127.0.0.1}" db_port="${cur_db_port:-3306}"
    local db_name="${cur_db_name}" db_user="${cur_db_user}" db_password="${cur_db_password}"
    if _field_is_chosen 13; then
        printf "  DB host [%s]: " "${cur_db_host:-127.0.0.1}"; read -r db_host
        db_host="${db_host:-${cur_db_host:-127.0.0.1}}"
    fi
    if _field_is_chosen 14; then
        printf "  DB port [%s]: " "${cur_db_port:-3306}"; read -r db_port
        db_port="${db_port:-${cur_db_port:-3306}}"
    fi
    if _field_is_chosen 15; then
        printf "  DB name [%s]: " "${cur_db_name}"; read -r db_name
        db_name="${db_name:-${cur_db_name}}"
    fi
    if _field_is_chosen 16; then
        printf "  DB user [%s]: " "${cur_db_user}"; read -r db_user
        db_user="${db_user:-${cur_db_user}}"
    fi
    if _field_is_chosen 17; then
        printf "  New DB password: "; read -rs db_password; printf '\n'
    fi

    local disk_path="${cur_disk_path}"
    if _field_is_chosen 18; then
        printf "  Disk usage path [%s]: " "${cur_disk_path}"; read -r disk_path
        disk_path="${disk_path:-${cur_disk_path}}"
    fi

    [[ "${auth_type}" == "ssh_key" ]] && password=""

    # ── Save ──────────────────────────────────────────────────────────────────
    write_server "${new_name}" <<EOF
HOST=${host}
PORT=${port}
USER=${user}
AUTH_TYPE=${auth_type}
PASSWORD=${password}
SSH_KEY=${ssh_key}
PROJECT_DIR=${project_dir}
ADMIN_URL=${admin_url}
ADMIN_USER=${admin_user}
ADMIN_PASSWORD=${admin_password}
FRONTEND_URL=${frontend_url}
GIT_TOKEN=${git_token}
DB_HOST=${db_host}
DB_PORT=${db_port}
DB_NAME=${db_name}
DB_USER=${db_user}
DB_PASSWORD=${db_password}
DISK_PATH=${disk_path}
EOF

    if [[ "${new_name}" != "${name}" ]]; then
        rm "$(server_file "${name}")"
        printf '\n'; ok "Server ${CYAN}${name}${NC} renamed to ${CYAN}${new_name}${NC} and updated."
    else
        printf '\n'; ok "Server ${CYAN}${new_name}${NC} updated."
    fi
    printf '\n'
}

# ─────────────────────────────────────────────────────────────────────────────

cmd_ssh() {
    local name="${1:-}"
    [[ -n "${name}" ]] || die "Usage: magneto-ssh ssh <name>"
    server_exists "${name}" || die "Server '${name}' not found. Run: magneto-ssh list"

    local file; file=$(server_file "${name}")

    local host port user auth_type password ssh_key project_dir
    host=$(read_field "${file}" HOST)
    port=$(read_field "${file}" PORT)
    user=$(read_field "${file}" USER)
    auth_type=$(read_field "${file}" AUTH_TYPE)
    password=$(read_field "${file}" PASSWORD)
    ssh_key=$(read_field "${file}" SSH_KEY)
    project_dir=$(read_field "${file}" PROJECT_DIR)

    local remote_cmd="exec \$SHELL"
    [[ -n "${project_dir}" ]] && remote_cmd="cd ${project_dir} 2>/dev/null || cd; exec \$SHELL"

    printf "\n${DIM}Connecting to${NC} ${CYAN}%s${NC} ${DIM}→ %s@%s:%s${NC}\n\n" \
        "${name}" "${user}" "${host}" "${port}"

    local ssh_opts=(-p "${port}"
                    -o StrictHostKeyChecking=accept-new
                    -o ConnectTimeout=10)

    if [[ "${auth_type}" == "password" ]]; then
        [[ -n "${password}" ]] || die "No password stored for '${name}'. Run: magneto-ssh edit ${name}"
        command -v sshpass &>/dev/null \
            || die "sshpass not installed. Run: sudo apt install sshpass"
        sshpass -p "${password}" \
            ssh "${ssh_opts[@]}" \
            -o PubkeyAuthentication=no \
            -o IdentitiesOnly=yes \
            -tt "${user}@${host}" "${remote_cmd}" \
            || die "Stored password incorrect or authentication failed."
    else
        local expanded_key="${ssh_key/#\~/${HOME}}"
        [[ -f "${expanded_key}" ]] || die "SSH key not found: ${ssh_key}"
        exec ssh "${ssh_opts[@]}" -i "${expanded_key}" -t "${user}@${host}" "${remote_cmd}"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────

cmd_scp() {
    local name="${1:-}"
    [[ -n "${name}" ]] || die "Usage: magneto-ssh scp <name> <remote_path> [local_dest]
       magneto-ssh scp <name> --upload <local_path> <remote_path>"
    server_exists "${name}" || die "Server '${name}' not found. Run: magneto-ssh list"
    shift

    local upload=false
    local src="" dst=""

    if [[ "${1:-}" == "--upload" || "${1:-}" == "-u" ]]; then
        upload=true
        shift
        src="${1:-}"; dst="${2:-}"
        [[ -n "${src}" && -n "${dst}" ]] \
            || die "Usage: magneto-ssh scp <name> --upload <local_path> <remote_path>"
        [[ -f "${src}" || -d "${src}" ]] || die "Local path not found: ${src}"
    else
        src="${1:-}"; dst="${2:-.}"
        [[ -n "${src}" ]] \
            || die "Usage: magneto-ssh scp <name> <remote_path> [local_dest]"
    fi

    local file; file=$(server_file "${name}")
    local host port user auth_type password ssh_key
    host=$(read_field "${file}" HOST)
    port=$(read_field "${file}" PORT)
    user=$(read_field "${file}" USER)
    auth_type=$(read_field "${file}" AUTH_TYPE)
    password=$(read_field "${file}" PASSWORD)
    ssh_key=$(read_field "${file}" SSH_KEY)

    local scp_opts=(-P "${port}" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
    local pw_only_opts=(-o PubkeyAuthentication=no -o IdentitiesOnly=yes)

    if [[ "${upload}" == true ]]; then
        printf "\n${DIM}Uploading${NC} ${CYAN}%s${NC} ${DIM}→ %s@%s:%s${NC}\n\n" \
            "${src}" "${user}" "${host}" "${dst}"
    else
        printf "\n${DIM}Downloading${NC} ${CYAN}%s:%s${NC} ${DIM}→ %s${NC}\n\n" \
            "${name}" "${src}" "${dst}"
    fi

    if [[ "${auth_type}" == "password" ]]; then
        [[ -n "${password}" ]] || die "No password stored for '${name}'."
        command -v sshpass &>/dev/null \
            || die "sshpass not installed. Run: sudo apt install sshpass"
        if [[ "${upload}" == true ]]; then
            sshpass -p "${password}" scp "${scp_opts[@]}" "${pw_only_opts[@]}" "${src}" "${user}@${host}:${dst}"
        else
            sshpass -p "${password}" scp "${scp_opts[@]}" "${pw_only_opts[@]}" "${user}@${host}:${src}" "${dst}"
        fi
    else
        local expanded_key="${ssh_key/#\~/${HOME}}"
        [[ -f "${expanded_key}" ]] || die "SSH key not found: ${ssh_key}"
        if [[ "${upload}" == true ]]; then
            scp "${scp_opts[@]}" -i "${expanded_key}" "${src}" "${user}@${host}:${dst}"
        else
            scp "${scp_opts[@]}" -i "${expanded_key}" "${user}@${host}:${src}" "${dst}"
        fi
    fi

    ok "Done."
}

# ─────────────────────────────────────────────────────────────────────────────

cmd_list() {
    ensure_dirs
    local servers
    mapfile -t servers < <(list_server_names)

    if [[ ${#servers[@]} -eq 0 ]]; then
        warn "No servers configured. Use: magneto-ssh add <name>"
        return
    fi

    printf '\n'
    printf "${BOLD}${CYAN}%-30s %-22s %-14s %-6s %-10s %s${NC}\n" \
        "NAME" "HOST" "USER" "PORT" "AUTH" "PROJECT DIR"
    printf '%0.s─' {1..95}; printf '\n'

    for name in "${servers[@]}"; do
        local file; file=$(server_file "${name}")
        local host user port auth_type project_dir
        host=$(read_field "${file}" HOST)
        user=$(read_field "${file}" USER)
        port=$(read_field "${file}" PORT)
        auth_type=$(read_field "${file}" AUTH_TYPE)
        project_dir=$(read_field "${file}" PROJECT_DIR)
        printf "%-30s %-22s %-14s %-6s %-10s %s\n" \
            "${name}" "${host}" "${user}" "${port}" \
            "${auth_type}" "${project_dir:--}"
    done
    printf '\n'
}

# ─────────────────────────────────────────────────────────────────────────────

cmd_info() {
    local name="${1:-}"
    [[ -n "${name}" ]] || die "Usage: magneto-ssh info <name>"
    server_exists "${name}" || die "Server '${name}' not found."

    local file; file=$(server_file "${name}")

    printf "\n${BOLD}${CYAN}%s${NC}\n" "${name}"

    local -A labels=(
        [HOST]="Host" [PORT]="Port" [USER]="User" [AUTH_TYPE]="Auth type"
        [SSH_KEY]="SSH key" [PROJECT_DIR]="Project dir"
        [ADMIN_URL]="Admin URL" [ADMIN_USER]="Admin user" [FRONTEND_URL]="Frontend URL"
        [DISK_PATH]="Disk path"
    )
    local field_order=(HOST PORT USER AUTH_TYPE SSH_KEY PROJECT_DIR
                       ADMIN_URL ADMIN_USER FRONTEND_URL DISK_PATH)

    for field in "${field_order[@]}"; do
        local val; val=$(read_field "${file}" "${field}")
        [[ -n "${val}" ]] && printf "  %-16s %s\n" "${labels[$field]}" "${val}"
    done

    local -A secret_labels=([PASSWORD]="SSH password" [ADMIN_PASSWORD]="Admin pass" [GIT_TOKEN]="Git token")
    for field in PASSWORD ADMIN_PASSWORD GIT_TOKEN; do
        local val; val=$(read_field "${file}" "${field}")
        [[ -n "${val}" ]] && printf "  %-16s %s\n" "${secret_labels[$field]}" "${val}"
    done
    printf '\n'
}

# ─────────────────────────────────────────────────────────────────────────────

cmd_remove() {
    local name="${1:-}"
    [[ -n "${name}" ]] || die "Usage: magneto-ssh remove <name>"
    server_exists "${name}" || die "Server '${name}' not found."

    printf "Remove server '%s'? [y/N] " "${name}"
    read -r confirm
    [[ "${confirm,,}" == "y" ]] || exit 0

    rm "$(server_file "${name}")"
    ok "Server ${CYAN}${name}${NC} removed.\n"
}

# ─────────────────────────────────────────────────────────────────────────────

cmd_validate() {
    ensure_dirs

    local timeout=5
    local filter=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --timeout|-t) timeout="$2"; shift 2 ;;
            *) filter+=("$1"); shift ;;
        esac
    done

    local servers
    if [[ ${#filter[@]} -gt 0 ]]; then
        for name in "${filter[@]}"; do
            server_exists "${name}" || die "Server not found: ${name}"
        done
        servers=("${filter[@]}")
    else
        mapfile -t servers < <(list_server_names)
    fi
    [[ ${#servers[@]} -eq 0 ]] && { warn "No servers configured."; return; }

    printf "\n${BOLD}Checking servers...${NC}\n\n"

    local pad=0
    for name in "${servers[@]}"; do (( ${#name} > pad )) && pad=${#name}; done
    (( pad += 4 ))

    local ok_count=0 fail_count=0

    for name in "${servers[@]}"; do
        local file; file=$(server_file "${name}")
        local host port user auth_type password
        host=$(read_field "${file}" HOST)
        port=$(read_field "${file}" PORT)
        user=$(read_field "${file}" USER)
        auth_type=$(read_field "${file}" AUTH_TYPE)
        password=$(read_field "${file}" PASSWORD)

        local padded; padded=$(printf "%-${pad}s" "${name}")

        if tcp_check "${host}" "${port}" "${timeout}"; then
            if [[ "${auth_type}" == "password" && -n "${password}" ]]; then
                if timeout "${timeout}" sshpass -p "${password}" \
                    ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
                    -o PasswordAuthentication=yes -o PubkeyAuthentication=no \
                    -o BatchMode=no "${user}@${host}" -p "${port}" "exit" 2>/dev/null; then
                    printf "  %s ${GREEN}✓${NC}  auth OK\n" "${padded}"
                    (( ++ok_count ))
                else
                    printf "  %s ${YELLOW}⚠${NC}  auth failed (wrong password?)\n" "${padded}"
                    (( ++fail_count ))
                fi
            else
                printf "  %s ${GREEN}✓${NC}  reachable\n" "${padded}"
                (( ++ok_count ))
            fi
        else
            printf "  %s ${RED}✗${NC}  unreachable\n" "${padded}"
            (( ++fail_count ))
        fi
    done

    printf '\n'
    local total=$(( ok_count + fail_count ))
    if [[ ${fail_count} -eq 0 ]]; then
        ok "All ${total} server(s) reachable.\n"
    else
        warn "${ok_count}/${total} reachable, ${fail_count} failed.\n"
    fi
}


cmd_filezilla() {
    local name="${1:-}"
    [[ -n "${name}" ]] || die "Usage: magneto-ssh filezilla <name>"
    local file="${SERVERS_DIR}/${name}"
    [[ -f "${file}" ]] || die "Server not found: ${name}"

    local host port user auth_type project_dir
    host=$(read_field "${file}" HOST)
    port=$(read_field "${file}" PORT)
    user=$(read_field "${file}" USER)
    auth_type=$(read_field "${file}" AUTH_TYPE)
    project_dir=$(read_field "${file}" PROJECT_DIR)

    local uri
    if [[ "${auth_type}" == "password" ]]; then
        local raw_pass
        raw_pass=$(read_field "${file}" PASSWORD)
        [[ -n "${raw_pass}" ]] || die "No password stored for '${name}'."
        local encoded_pass
        encoded_pass=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "${raw_pass}")
        uri="sftp://${user}:${encoded_pass}@${host}:${port}"
    else
        uri="sftp://${user}@${host}:${port}"
    fi

    [[ -n "${project_dir}" ]] && uri="${uri}/${project_dir#/}"

    if ! command -v filezilla &>/dev/null; then
        die "FileZilla not found. Install it with: sudo apt install filezilla"
    fi

    ok "Launching FileZilla → ${name} (${host}:${port})"
    filezilla "${uri}" &
    disown
}

# ─────────────────────────────────────────────────────────────────────────────

cmd_tunnel() {
    local name="${1:-}"
    [[ -n "${name}" ]] || die "Usage: magneto-ssh tunnel <name>"
    local file="${SERVERS_DIR}/${name}"
    [[ -f "${file}" ]] || die "Server not found: ${name}"

    local host port user auth_type db_host db_port tunnel_local_port
    host=$(read_field "${file}" HOST)
    port=$(read_field "${file}" PORT)
    user=$(read_field "${file}" USER)
    auth_type=$(read_field "${file}" AUTH_TYPE)
    db_host=$(read_field "${file}" DB_HOST)
    db_port=$(read_field "${file}" DB_PORT)
    tunnel_local_port=$(read_field "${file}" TUNNEL_LOCAL_PORT)

    db_host="${db_host:-127.0.0.1}"
    db_port="${db_port:-3306}"
    tunnel_local_port="${tunnel_local_port:-13306}"

    local existing_pid
    existing_pid=$(lsof -ti "tcp:${tunnel_local_port}" 2>/dev/null || true)
    if [[ -n "${existing_pid}" ]]; then
        kill "${existing_pid}" 2>/dev/null || true
        warn "Killed existing tunnel on port ${tunnel_local_port}."
    fi

    ok "Opening SSH tunnel: localhost:${tunnel_local_port} → ${db_host}:${db_port} via ${host}"

    if [[ "${auth_type}" == "password" ]]; then
        local raw_pass
        raw_pass=$(read_field "${file}" PASSWORD)
        [[ -n "${raw_pass}" ]] || die "No password stored for '${name}'."
        export SSHPASS="${raw_pass}"
        sshpass -e ssh -f -N \
            -o StrictHostKeyChecking=accept-new \
            -o ExitOnForwardFailure=yes \
            -o PubkeyAuthentication=no \
            -o IdentitiesOnly=yes \
            -L "${tunnel_local_port}:${db_host}:${db_port}" \
            -p "${port}" "${user}@${host}"
        unset SSHPASS
    else
        local key_path
        key_path=$(read_field "${file}" SSH_KEY)
        local key_args=()
        [[ -n "${key_path}" ]] && key_args=(-i "${key_path}")
        ssh -f -N \
            "${key_args[@]}" \
            -o StrictHostKeyChecking=accept-new \
            -o ExitOnForwardFailure=yes \
            -L "${tunnel_local_port}:${db_host}:${db_port}" \
            -p "${port}" "${user}@${host}"
    fi

    local db_name db_user
    db_name=$(read_field "${file}" DB_NAME)
    db_user=$(read_field "${file}" DB_USER)

    printf "\n"
    ok "Tunnel active on localhost:${tunnel_local_port}"
    printf "  ${BOLD}Host:${NC}      127.0.0.1\n"
    printf "  ${BOLD}Port:${NC}      ${tunnel_local_port}\n"
    printf "  ${BOLD}Database:${NC}  ${db_name:-<not set>}\n"
    printf "  ${BOLD}User:${NC}      ${db_user:-<not set>}\n"
    printf "\nClose tunnel:  kill \$(lsof -ti tcp:${tunnel_local_port})\n"
}

# ─────────────────────────────────────────────────────────────────────────────

cmd_dbeaver() {
    local name="${1:-}"
    [[ -n "${name}" ]] || die "Usage: magneto-ssh dbeaver <name>"
    local file="${SERVERS_DIR}/${name}"
    [[ -f "${file}" ]] || die "Server not found: ${name}"

    if ! command -v dbeaver &>/dev/null && ! command -v dbeaver-ce &>/dev/null; then
        die "DBeaver not found. Install it from https://dbeaver.io"
    fi

    cmd_tunnel "${name}"

    local tunnel_local_port db_name db_user db_password
    tunnel_local_port=$(read_field "${file}" TUNNEL_LOCAL_PORT)
    tunnel_local_port="${tunnel_local_port:-13306}"
    db_name=$(read_field "${file}" DB_NAME)
    db_user=$(read_field "${file}" DB_USER)
    db_password=$(read_field "${file}" DB_PASSWORD)

    local con_str="driver=mysql8|host=127.0.0.1|port=${tunnel_local_port}"
    [[ -n "${db_name}" ]]     && con_str="${con_str}|database=${db_name}"
    [[ -n "${db_user}" ]]     && con_str="${con_str}|user=${db_user}"
    [[ -n "${db_password}" ]] && con_str="${con_str}|password=${db_password}"
    con_str="${con_str}|name=${name}|save=true|connect=true"

    ok "Launching DBeaver → ${name} (127.0.0.1:${tunnel_local_port})"
    local dbeaver_bin
    dbeaver_bin=$(command -v dbeaver 2>/dev/null || command -v dbeaver-ce)
    "${dbeaver_bin}" -con "${con_str}" &
    disown
}

# ─────────────────────────────────────────────────────────────────────────────

# ── Remote execution helpers ─────────────────────────────────────────────────

# _ssh_exec <name> <script>  — run a bash script on the remote host, non-interactive.
_ssh_exec() {
    local name="$1" script="$2"
    local file; file=$(server_file "${name}")

    local host port user auth_type password ssh_key
    host=$(read_field "${file}" HOST)
    port=$(read_field "${file}" PORT)
    user=$(read_field "${file}" USER)
    auth_type=$(read_field "${file}" AUTH_TYPE)
    password=$(read_field "${file}" PASSWORD)
    ssh_key=$(read_field "${file}" SSH_KEY)

    local ssh_opts=(-p "${port}"
                    -o StrictHostKeyChecking=accept-new
                    -o ConnectTimeout=15
                    -o LogLevel=ERROR
                    -o BatchMode=no)

    if [[ "${auth_type}" == "password" ]]; then
        [[ -n "${password}" ]] || die "No password stored for '${name}'. Run: magneto-ssh edit ${name}"
        command -v sshpass &>/dev/null \
            || die "sshpass not installed. Run: sudo apt install sshpass"
        printf '%s' "${script}" | sshpass -p "${password}" \
            ssh "${ssh_opts[@]}" -o PubkeyAuthentication=no -o IdentitiesOnly=yes \
            "${user}@${host}" "bash -s"
    else
        local expanded_key="${ssh_key/#\~/${HOME}}"
        [[ -f "${expanded_key}" ]] || die "SSH key not found: ${ssh_key}"
        printf '%s' "${script}" | ssh "${ssh_opts[@]}" -i "${expanded_key}" \
            "${user}@${host}" "bash -s"
    fi
}

# _scp_fetch <name> <remote_path> <local_path>  — quiet file download.
_scp_fetch() {
    local name="$1" remote="$2" local_dst="$3"
    local file; file=$(server_file "${name}")

    local host port user auth_type password ssh_key
    host=$(read_field "${file}" HOST)
    port=$(read_field "${file}" PORT)
    user=$(read_field "${file}" USER)
    auth_type=$(read_field "${file}" AUTH_TYPE)
    password=$(read_field "${file}" PASSWORD)
    ssh_key=$(read_field "${file}" SSH_KEY)

    local scp_opts=(-P "${port}" -q
                    -o StrictHostKeyChecking=accept-new
                    -o ConnectTimeout=15
                    -o LogLevel=ERROR)

    if [[ "${auth_type}" == "password" ]]; then
        sshpass -p "${password}" scp "${scp_opts[@]}" \
            -o PubkeyAuthentication=no -o IdentitiesOnly=yes \
            "${user}@${host}:${remote}" "${local_dst}"
    else
        local expanded_key="${ssh_key/#\~/${HOME}}"
        scp "${scp_opts[@]}" -i "${expanded_key}" "${user}@${host}:${remote}" "${local_dst}"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────

# Shell-quote a path for the remote host, keeping a leading ~ expandable there.
_hk_rquote() {
    local p="$1"
    if [[ "${p}" == "~" ]]; then
        printf '"$HOME"'
    elif [[ "${p}" == "~/"* ]]; then
        printf '"$HOME"/%s' "$(printf '%q' "${p#\~/}")"
    else
        printf '%q' "${p}"
    fi
}

# _ssl_check <domain> — print certificate dates and days left.
# Returns 1 when the certificate is expired or expires within a week.
_ssl_check() {
    local domain="$1"
    local cert
    cert=$(timeout 20 openssl s_client -connect "${domain}:443" -servername "${domain}" \
           </dev/null 2>/dev/null | openssl x509 -noout -startdate -enddate -issuer 2>/dev/null) || true

    if [[ -z "${cert}" ]]; then
        err "  Could not read a certificate from ${domain}:443."
        return 1
    fi

    local not_before not_after issuer
    not_before=$(printf '%s\n' "${cert}" | grep '^notBefore=' | cut -d'=' -f2-)
    not_after=$(printf  '%s\n' "${cert}" | grep '^notAfter='  | cut -d'=' -f2-)
    issuer=$(printf     '%s\n' "${cert}" | grep '^issuer='    | sed 's/.*O *= *//; s/,.*//')

    printf "  %-14s %s\n" "Domain"    "${domain}"
    printf "  %-14s %s\n" "Issuer"    "${issuer:-unknown}"
    printf "  %-14s %s\n" "Issued"    "${not_before}"
    printf "  %-14s %s\n" "Expires"   "${not_after}"

    local end_epoch now_epoch days
    end_epoch=$(date -d "${not_after}" +%s 2>/dev/null) || {
        warn "  Could not parse the expiry date."
        return 0
    }
    now_epoch=$(date +%s)
    days=$(( (end_epoch - now_epoch) / 86400 ))

    if (( days < 0 )); then
        err "  Certificate EXPIRED ${days#-} day(s) ago."
        return 1
    elif (( days <= 7 )); then
        err "  Expires in ${days} day(s) — renew now."
        return 1
    elif (( days <= 30 )); then
        warn "  Expires in ${days} day(s)."
    else
        ok "  Valid for ${days} more day(s)."
    fi
    return 0
}

cmd_housekeeping() {
    local name="" tail_lines=20 download=true out_dir="" log_path="" disk_path_override=""
    local make_report=true check_ssl=true domain_override=""
    local check_speed=true url_override="" check_uptime=true

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-download)   download=false; shift ;;
            --tail|-n)       tail_lines="${2:-20}"; shift 2 ;;
            --output|-o)     out_dir="${2:-}"; shift 2 ;;
            --log)           log_path="${2:-}"; shift 2 ;;
            --disk)          disk_path_override="${2:-}"; shift 2 ;;
            --report)        make_report=true; shift ;;
            --no-report)     make_report=false; shift ;;
            --no-ssl)        check_ssl=false; shift ;;
            --domain)        domain_override="${2:-}"; shift 2 ;;
            --no-pagespeed)  check_speed=false; shift ;;
            --url)           url_override="${2:-}"; shift 2 ;;
            --no-uptime)     check_uptime=false; shift ;;
            --rules)         REPORT_CLASSIFIER="rules"; shift ;;
            *)               [[ -z "${name}" ]] && name="$1"; shift ;;
        esac
    done

    [[ -n "${name}" ]] || die "Usage: magneto-ssh housekeeping <name> [--tail N] [--no-download] [--no-report] [--no-ssl] [--no-pagespeed] [--no-uptime]
       [--output DIR] [--log PATH] [--disk PATH] [--domain HOST] [--url URL]"
    server_exists "${name}" || die "Server '${name}' not found. Run: magneto-ssh list"

    local file; file=$(server_file "${name}")
    local host project_dir disk_path
    host=$(read_field "${file}" HOST)
    project_dir=$(read_field "${file}" PROJECT_DIR)
    disk_path=$(read_field "${file}" DISK_PATH)

    [[ -n "${project_dir}" ]] \
        || die "No PROJECT_DIR set for '${name}'. Run: magneto-ssh edit ${name}"

    [[ -n "${disk_path_override}" ]] && disk_path="${disk_path_override}"
    disk_path="${disk_path:-~/application/}"
    log_path="${log_path:-${project_dir%/}/var/log/exception.log}"

    printf "\n${BOLD}${CYAN}Housekeeping report${NC} — ${BOLD}%s${NC} ${DIM}(%s)${NC}\n" "${name}" "${host}"
    printf "${DIM}%s${NC}\n\n" "$(date '+%Y-%m-%d %H:%M:%S')"

    # ── One SSH round-trip collects everything ───────────────────────────────
    local q_project q_disk q_log
    q_project=$(_hk_rquote "${project_dir}")
    q_disk=$(_hk_rquote "${disk_path}")
    q_log=$(_hk_rquote "${log_path}")

    local remote_script
    remote_script=$(cat <<REMOTE
set -u
cd ${q_project} 2>/dev/null || { echo "__ERR__ project dir not found: ${project_dir}"; }

echo "__SECTION__INDEXER"
if [ -f ${q_project}/bin/magento ]; then
    PHP_BIN=""
    for c in php php8.4 php8.3 php8.2 php8.1 php8.0 php7.4; do
        command -v "\$c" >/dev/null 2>&1 && { PHP_BIN="\$c"; break; }
    done
    if [ -n "\$PHP_BIN" ]; then
        "\$PHP_BIN" ${q_project}/bin/magento indexer:status 2>&1
    else
        echo "__ERR__ no php binary found in PATH"
    fi
else
    echo "__ERR__ bin/magento not found in ${project_dir}"
fi

echo "__SECTION__DISK"
df -h ${q_disk} 2>&1

echo "__SECTION__LOG"
if [ -f ${q_log} ]; then
    echo "EXISTS=1"
    echo "SIZE=\$(du -h ${q_log} 2>/dev/null | cut -f1)"
    echo "LINES=\$(wc -l < ${q_log} 2>/dev/null | tr -d ' ')"
    echo "MTIME=\$(date -r ${q_log} '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
    echo "__TAIL__"
    tail -n ${tail_lines} ${q_log} 2>/dev/null
else
    echo "EXISTS=0"
fi
REMOTE
)

    local output=""
    output=$(_ssh_exec "${name}" "${remote_script}") || die "SSH command failed for '${name}'."

    _hk_section() {
        printf '%s\n' "${output}" | awk -v s="__SECTION__$1" '
            $0 == s { grab=1; next }
            /^__SECTION__/ { grab=0 }
            grab { print }'
    }

    local exit_status=0
    local downloaded_log=""

    # ── 1. Indexer status ────────────────────────────────────────────────────
    printf "${BOLD}1) Indexer status${NC}\n"
    local indexer; indexer=$(_hk_section INDEXER)
    if [[ -z "${indexer}" || "${indexer}" == *"__ERR__"* ]]; then
        err "  ${indexer#*__ERR__}"
        exit_status=1
    else
        local bad
        bad=$(printf '%s\n' "${indexer}" \
              | grep -Ei 'invalid|reindex required|suspended' || true)
        printf '%s\n' "${indexer}" | sed 's/^/  /'
        printf '\n'
        if [[ -n "${bad}" ]]; then
            local bad_count; bad_count=$(printf '%s\n' "${bad}" | grep -c . || true)
            err "  ${bad_count} indexer(s) NOT ready:"
            printf '%s\n' "${bad}" | sed 's/^/    /'
            exit_status=1
        else
            ok "  All indexers Ready."
        fi
    fi
    printf '\n'

    # ── 2. Disk usage ────────────────────────────────────────────────────────
    printf "${BOLD}2) Disk usage${NC} ${DIM}(df -h %s)${NC}\n" "${disk_path}"
    local disk; disk=$(_hk_section DISK)
    if [[ -z "${disk}" ]]; then
        err "  No df output."
        exit_status=1
    else
        printf '%s\n' "${disk}" | sed 's/^/  /'
        printf '\n'
        local use_pct
        use_pct=$(printf '%s\n' "${disk}" | awk 'NR>1 {for(i=1;i<=NF;i++) if($i ~ /%$/){gsub("%","",$i); print $i; exit}}')
        if [[ "${use_pct}" =~ ^[0-9]+$ ]]; then
            if (( use_pct >= 90 )); then
                err "  Disk ${use_pct}% used — critical."
                exit_status=1
            elif (( use_pct >= 80 )); then
                warn "  Disk ${use_pct}% used — watch it."
            else
                ok "  Disk ${use_pct}% used."
            fi
        fi
    fi
    printf '\n'

    # ── 3. exception.log ─────────────────────────────────────────────────────
    printf "${BOLD}3) exception.log${NC} ${DIM}(%s)${NC}\n" "${log_path}"
    local logsec; logsec=$(_hk_section LOG)
    local log_exists log_size log_lines log_mtime
    log_exists=$(printf '%s\n' "${logsec}" | grep '^EXISTS=' | head -1 | cut -d'=' -f2- || true)

    if [[ "${log_exists}" != "1" ]]; then
        warn "  Not present on server (no exceptions logged, or path differs)."
    else
        log_size=$(printf  '%s\n' "${logsec}" | grep '^SIZE='  | head -1 | cut -d'=' -f2- || true)
        log_lines=$(printf '%s\n' "${logsec}" | grep '^LINES=' | head -1 | cut -d'=' -f2- || true)
        log_mtime=$(printf '%s\n' "${logsec}" | grep '^MTIME=' | head -1 | cut -d'=' -f2- || true)

        printf "  %-14s %s\n" "Size"          "${log_size:-?}"
        printf "  %-14s %s\n" "Lines"         "${log_lines:-?}"
        printf "  %-14s %s\n" "Last modified" "${log_mtime:-?}"

        if [[ "${tail_lines}" -gt 0 ]]; then
            printf "\n  ${DIM}last %s lines:${NC}\n" "${tail_lines}"
            printf '%s\n' "${logsec}" | sed -n '/^__TAIL__$/,$p' | tail -n +2 | sed 's/^/  │ /'
        fi

        if [[ "${download}" == true ]]; then
            out_dir="${out_dir:-${CONFIG_DIR}/reports/${name}}"
            mkdir -p "${out_dir}"
            local stamp; stamp=$(date '+%Y%m%d-%H%M%S')
            local dest="${out_dir%/}/exception-${stamp}.log"
            printf '\n'
            if _scp_fetch "${name}" "$(_hk_rquote "${log_path}")" "${dest}"; then
                ok "  Downloaded → ${CYAN}${dest}${NC}"
                downloaded_log="${dest}"
            else
                err "  Download failed: ${log_path}"
                exit_status=1
            fi
        fi
    fi

    printf '\n'

    # ── 4. SSL certificate ───────────────────────────────────────────────────
    if [[ "${check_ssl}" == true ]]; then
        local frontend_url domain
        frontend_url=$(read_field "${file}" FRONTEND_URL)
        domain="${domain_override}"
        if [[ -z "${domain}" && -n "${frontend_url}" ]]; then
            domain="${frontend_url#*://}"
            domain="${domain%%/*}"
            domain="${domain%%:*}"
        fi

        printf "${BOLD}4) SSL certificate${NC}\n"
        if [[ -z "${domain}" ]]; then
            warn "  No FRONTEND_URL set — skipped. Run: magneto-ssh edit ${name}"
        elif ! command -v openssl &>/dev/null; then
            warn "  openssl not installed — skipped."
        else
            _ssl_check "${domain}" || exit_status=1
        fi
        printf '\n'
    fi

    # ── 5. PageSpeed ─────────────────────────────────────────────────────────
    if [[ "${check_speed}" == true ]]; then
        local speed_url="${url_override}"
        [[ -z "${speed_url}" ]] && speed_url=$(read_field "${file}" FRONTEND_URL)

        printf "${BOLD}5) PageSpeed (mobile + desktop)${NC}\n"
        if [[ -z "${speed_url}" ]]; then
            warn "  No FRONTEND_URL set — skipped. Run: magneto-ssh edit ${name}"
        else
            [[ "${speed_url}" == http*://* ]] || speed_url="https://${speed_url}"
            _pagespeed_check "${speed_url}" \
                "${CONFIG_DIR}/reports/${name}/pagespeed.md" || exit_status=1
        fi
        printf '\n'
    fi

    # ── 6. Uptime ────────────────────────────────────────────────────────────
    if [[ "${check_uptime}" == true ]]; then
        local uptime_url="${url_override}"
        [[ -z "${uptime_url}" ]] && uptime_url=$(read_field "${file}" FRONTEND_URL)

        printf "${BOLD}6) Uptime (last 7 days)${NC}\n"
        if [[ -z "${uptime_url}" ]]; then
            warn "  No FRONTEND_URL set — skipped. Run: magneto-ssh edit ${name}"
        else
            _uptime_check "${uptime_url}" || exit_status=1
        fi
        printf '\n'
    fi

    # ── 7. Exception report ──────────────────────────────────────────────────
    if [[ "${make_report}" == true && -n "${downloaded_log}" ]]; then
        printf "${BOLD}7) Exception report${NC}\n"
        _run_report "${downloaded_log}" "${name}" \
            "${downloaded_log%.log}.xlsx" || exit_status=1
        printf '\n'
    fi

    if [[ ${exit_status} -eq 0 ]]; then
        ok "Housekeeping clean for ${CYAN}${name}${NC}.\n"
    else
        warn "Housekeeping found issues on ${CYAN}${name}${NC}.\n"
    fi
    return ${exit_status}
}

# ─────────────────────────────────────────────────────────────────────────────

# ── UptimeRobot ──────────────────────────────────────────────────────────────

# Reads the monitor matching a URL and reports the 7-day uptime ratio, average
# response time and any down events in that window. Supports both the v2 API
# (api_key in the POST body) and v3 (bearer token), probed in that order.
_uptime_fetch() {
    python3 - <<'PYEOF'
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

V2_URL = "https://api.uptimerobot.com/v2/getMonitors"
V3_URL = "https://api.uptimerobot.com/v3/monitors"
WINDOW_DAYS = 7


def host_of(url):
    parsed = urllib.parse.urlparse(url if "://" in url else f"https://{url}")
    return (parsed.hostname or url).lower().lstrip("www.")


def post_v2(api_key):
    body = urllib.parse.urlencode({
        "api_key": api_key,
        "format": "json",
        "custom_uptime_ratios": str(WINDOW_DAYS),
        "response_times": "1",
        "response_times_average": "86400",
        "logs": "1",
    }).encode()
    request = urllib.request.Request(
        V2_URL, data=body,
        headers={"Content-Type": "application/x-www-form-urlencoded",
                 "Cache-Control": "no-cache"})
    with urllib.request.urlopen(request, timeout=45) as response:
        return json.load(response)


def get_v3(api_key):
    request = urllib.request.Request(
        f"{V3_URL}?limit=50", headers={"Authorization": f"Bearer {api_key}"})
    with urllib.request.urlopen(request, timeout=45) as response:
        return json.load(response)


def normalize_v2(payload):
    if payload.get("stat") != "ok":
        message = payload.get("error", {}).get("message", "unknown error")
        raise RuntimeError(f"v2: {message}")
    monitors = []
    for monitor in payload.get("monitors", []):
        ratios = str(monitor.get("custom_uptime_ratio", "")).split("-")
        monitors.append({
            "name": monitor.get("friendly_name", ""),
            "url": monitor.get("url", ""),
            "up": monitor.get("status") == 2,
            "ratio": ratios[0] if ratios and ratios[0] else "",
            "response": monitor.get("average_response_time", ""),
            "events": [
                log for log in monitor.get("logs", [])
                if log.get("type") == 1                     # 1 = down
            ],
        })
    return monitors


def normalize_v3(payload):
    monitors = []
    items = payload.get("data") or payload.get("monitors") or []
    for monitor in items:
        monitors.append({
            "name": monitor.get("friendlyName") or monitor.get("friendly_name", ""),
            "url": monitor.get("url", ""),
            "up": str(monitor.get("status", "")).lower() in ("2", "up", "active"),
            "ratio": monitor.get("uptimeRatio") or monitor.get("uptime_ratio") or "",
            "response": monitor.get("averageResponseTime")
            or monitor.get("average_response_time", ""),
            "events": [],
        })
    return monitors


def main():
    api_key = os.environ.get("UPTIMEROBOT_API_KEY", "").strip()
    target = host_of(os.environ.get("MSSH_URL", ""))
    if not api_key:
        print("ERR|no UPTIMEROBOT_API_KEY set")
        return 0

    monitors = None
    errors = []
    for label, call, shape in (("v2", post_v2, normalize_v2),
                               ("v3", get_v3, normalize_v3)):
        try:
            monitors = shape(call(api_key))
            print(f"API|{label}")
            break
        except urllib.error.HTTPError as error:
            body = error.read().decode("utf-8", "replace")
            errors.append(f"{label} HTTP {error.code} {' '.join(body.split())[:80]}")
        except Exception as error:                             # noqa: BLE001
            errors.append(f"{label} {error}")

    if monitors is None:
        print(f"ERR|{'; '.join(errors)[:160]}")
        return 0
    if not monitors:
        print("ERR|the key returned no monitors")
        return 0

    match = next((m for m in monitors if host_of(m["url"]) == target), None)
    if match is None:
        names = ", ".join(host_of(m["url"]) for m in monitors[:6])
        print(f"ERR|no monitor for {target} (found: {names})")
        return 0

    print("OK|{}|{}|{}|{}|{}".format(
        match["name"], "up" if match["up"] else "DOWN",
        match["ratio"] or "n/a", match["response"] or "n/a",
        len(match["events"])))

    for event in match["events"][:5]:
        print("EVENT|{}|{}".format(
            event.get("datetime", ""), event.get("duration", "")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
PYEOF
}

# _uptime_check <url> — returns 1 when the monitor is down or the ratio is poor.
_uptime_check() {
    local url="$1"
    local status=0

    command -v python3 &>/dev/null || { warn "  python3 not installed — skipped."; return 0; }

    if [[ -z "${UPTIMEROBOT_API_KEY:-}" && -f "${CONFIG_DIR}/.env" ]]; then
        UPTIMEROBOT_API_KEY=$(grep '^UPTIMEROBOT_API_KEY=' "${CONFIG_DIR}/.env" 2>/dev/null \
                              | head -1 | cut -d'=' -f2- || true)
        export UPTIMEROBOT_API_KEY
    fi

    local results
    results=$(MSSH_URL="${url}" _uptime_fetch) || {
        err "  UptimeRobot request failed."
        return 1
    }

    local api_version="" got_data=false
    while IFS='|' read -r kind a b c d e; do
        case "${kind}" in
            API)
                api_version="${a}"
                ;;
            ERR)
                warn "  ${a}"
                ;;
            OK)
                got_data=true
                printf "  %-14s %s\n" "Monitor"  "${a}"
                printf "  %-14s %s\n" "State"    "${b}"
                printf "  %-14s %s\n" "Uptime 7d" "${c}%"
                printf "  %-14s %s\n" "Avg response" "${d} ms"
                printf "  %-14s %s\n" "Down events" "${e}"

                [[ "${b}" == "up" ]] || status=1
                # Compare as integers scaled by 100 — bash has no float maths.
                if [[ "${c}" =~ ^[0-9.]+$ ]]; then
                    local scaled; scaled=$(printf '%.0f' "$(echo "${c} 100" | awk '{print $1*$2}')")
                    if   (( scaled < 9900 )); then status=1
                    elif (( scaled < 9990 )); then warn "  Uptime under 99.9% this week."
                    fi
                fi
                ;;
            EVENT)
                printf "    ${DIM}down %s for %ss${NC}\n" "${a}" "${b}"
                ;;
        esac
    done <<< "${results}"

    [[ -n "${api_version}" ]] && printf "  ${DIM}API: %s${NC}\n" "${api_version}"

    printf '\n'
    if [[ "${got_data}" != true ]]; then
        warn "  Uptime unknown — no monitor data."
        return 0
    fi
    if [[ ${status} -eq 0 ]]; then
        ok "  Uptime healthy."
    else
        err "  Uptime needs attention."
    fi
    return ${status}
}

# ─────────────────────────────────────────────────────────────────────────────

# ── PageSpeed Insights ───────────────────────────────────────────────────────

# Runs Lighthouse for one URL on both strategies and prints a table. Also
# appends the run to a per-server markdown history so trends stay visible.
_pagespeed_fetch() {
    python3 - <<'PYEOF'
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

API_URL = "https://www.googleapis.com/pagespeedonline/v5/runPagespeed"
CATEGORIES = ["performance", "accessibility", "best-practices", "seo"]
SCORE_KEYS = ["performance", "accessibility", "best-practices", "seo"]


def fetch(url, strategy, api_key):
    params = {"url": url, "strategy": strategy, "category": CATEGORIES}
    if api_key:
        params["key"] = api_key
    query = urllib.parse.urlencode(params, doseq=True)
    with urllib.request.urlopen(f"{API_URL}?{query}", timeout=180) as response:
        return json.load(response)


def scores(data):
    categories = data["lighthouseResult"]["categories"]
    return {
        key: round(categories[key]["score"] * 100)
        for key in SCORE_KEYS
        if categories.get(key) and categories[key].get("score") is not None
    }


def vitals(data):
    """Field data from CrUX — absent for low-traffic sites, hence the n/a."""
    metrics = data.get("loadingExperience", {}).get("metrics", {})

    def value(key, divisor=1, unit="", decimals=1):
        metric = metrics.get(key)
        if not metric:
            return "n/a"
        number = metric["percentile"] / divisor
        return f"{number:.{decimals}f}{unit}" if divisor != 1 else f"{number:.0f}{unit}"

    return {
        "LCP": value("LARGEST_CONTENTFUL_PAINT_MS", 1000, "s"),
        "CLS": value("CUMULATIVE_LAYOUT_SHIFT_SCORE", 100, "", 2),
        "INP": value("INTERACTION_TO_NEXT_PAINT", 1, "ms"),
    }


def main():
    url = os.environ["MSSH_URL"]
    api_key = os.environ.get("PAGESPEED_API_KEY", "").strip()

    for strategy in ("mobile", "desktop"):
        try:
            data = fetch(url, strategy, api_key)
        except urllib.error.HTTPError as error:
            body = error.read().decode("utf-8", "replace")
            try:
                detail = json.loads(body)["error"]["message"]
            except (ValueError, KeyError, TypeError):
                detail = " ".join(body.split())
            print(f"ERR|{strategy}|HTTP {error.code}: {detail[:120]}")
            continue
        except Exception as error:                             # noqa: BLE001
            print(f"ERR|{strategy}|{error}")
            continue

        score = scores(data)
        vital = vitals(data)
        print("OK|{}|{}|{}|{}|{}|{}|{}|{}".format(
            strategy,
            score.get("performance", "n/a"),
            score.get("accessibility", "n/a"),
            score.get("best-practices", "n/a"),
            score.get("seo", "n/a"),
            vital["LCP"], vital["CLS"], vital["INP"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
PYEOF
}

# _pagespeed_check <url> <history_file> — returns 1 if a run failed or scored poorly.
_pagespeed_check() {
    local url="$1" history="$2"
    local status=0

    command -v python3 &>/dev/null || { warn "  python3 not installed — skipped."; return 0; }

    # Key is optional: Google allows a small keyless quota, but a key avoids
    # the 429s that show up as soon as the check runs regularly.
    if [[ -z "${PAGESPEED_API_KEY:-}" && -f "${CONFIG_DIR}/.env" ]]; then
        PAGESPEED_API_KEY=$(grep '^PAGESPEED_API_KEY=' "${CONFIG_DIR}/.env" 2>/dev/null \
                            | head -1 | cut -d'=' -f2- || true)
        export PAGESPEED_API_KEY
    fi

    printf "  ${DIM}Running Lighthouse for %s (takes up to a minute)...${NC}\n\n" "${url}"

    local results
    results=$(MSSH_URL="${url}" _pagespeed_fetch) || {
        err "  PageSpeed request failed."
        return 1
    }

    printf "  ${BOLD}%-9s %5s %5s %5s %5s   %7s %6s %8s${NC}\n" \
        "DEVICE" "PERF" "A11Y" "BP" "SEO" "LCP" "CLS" "INP"

    local today; today=$(date '+%Y-%m-%d')
    local wrote_header=false
    [[ -f "${history}" ]] || wrote_header=true

    while IFS='|' read -r kind strategy a b c d e f g; do
        if [[ "${kind}" == "ERR" ]]; then
            err "  ${strategy}: ${a}"
            status=1
            continue
        fi
        [[ "${kind}" == "OK" ]] || continue

        local color="${GREEN}"
        if [[ "${a}" =~ ^[0-9]+$ ]]; then
            if   (( a < 50 )); then color="${RED}";    status=1
            elif (( a < 90 )); then color="${YELLOW}"; fi
        fi
        printf "  %-9s ${color}%5s${NC} %5s %5s %5s   %7s %6s %8s\n" \
            "${strategy}" "${a}" "${b}" "${c}" "${d}" "${e}" "${f}" "${g:-n/a}"

        if [[ -n "${history}" ]]; then
            mkdir -p "$(dirname "${history}")"
            if [[ "${wrote_header}" == true ]]; then
                {
                    printf '# PageSpeed history\n\n'
                    printf '| Date | URL | Device | Performance | Accessibility | Best Practices | SEO | LCP | CLS | INP |\n'
                    printf '|---|---|---|---|---|---|---|---|---|---|\n'
                } > "${history}"
                wrote_header=false
            fi
            printf '| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
                "${today}" "${url}" "${strategy}" "${a}" "${b}" "${c}" "${d}" "${e}" "${f}" "${g:-n/a}" \
                >> "${history}"
        fi
    done <<< "${results}"

    printf '\n'
    if [[ ${status} -eq 0 ]]; then
        ok "  Performance is in the green on both devices."
    else
        warn "  Performance below 50 on at least one device."
    fi
    [[ -n "${history}" ]] && printf "  ${DIM}History: %s${NC}\n" "${history}"
    return ${status}
}

# ─────────────────────────────────────────────────────────────────────────────

# ── Exception log report (xlsx) ──────────────────────────────────────────────

# Embedded analyser: parses a Magento exception.log, groups it by signature,
# assigns P1-P4 priorities (Gemini, with a cached/log-level fallback) and
# writes an xlsx report. Configured entirely through MSSH_* env vars.
_report_analyzer() {
    python3 - <<'PYEOF'
#!/usr/bin/env python3
"""Turn a Magento exception.log into a prioritized xlsx report.

Reads configuration from the environment:
    MSSH_LOG     path to the exception.log to analyse (required)
    MSSH_OUT     path of the xlsx to write (required)
    MSSH_LABEL   report subtitle, normally the server name (required)
    MSSH_CACHE   path of the signature -> priority JSON cache
    MSSH_TOP     max rows in the detail sheet (0 = all)
    MSSH_DAYS    only include entries from the last N days (0 = all)
    MSSH_CLASSIFIER  rules | gemini
    GEMINI_API_KEY, MSSH_GEMINI_MODEL
"""
import hashlib
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from collections import OrderedDict
from datetime import datetime, timedelta

# ── Log parsing ──────────────────────────────────────────────────────────────

ENTRY_RE = re.compile(
    r"^\[(?P<ts>[^\]]+)\]\s+"
    r"(?P<channel>[A-Za-z0-9_.\-]+)\."
    r"(?P<level>EMERGENCY|ALERT|CRITICAL|ERROR|WARNING|NOTICE|INFO|DEBUG)"
    r":\s*(?P<msg>.*)$"
)

# Applied in order to collapse one message into a signature.
NORMALIZERS = [
    (re.compile(r"\{\"exception\".*$", re.S), ""),            # trailing monolog context
    (re.compile(r"\s*\[\]\s*$"), ""),                          # empty extra
    (re.compile(r"\s*\{[^{}]*\}\s*$"), ""),                    # trailing context object
    (re.compile(r"[a-f0-9]{32,}", re.I), "{HASH}"),
    (re.compile(r"\b[\w.+-]+@[\w-]+\.[\w.]+\b"), "{EMAIL}"),
    (re.compile(r"(/[\w.\-]+){3,}"), "{PATH}"),
    (re.compile(r"\b\d{1,3}(\.\d{1,3}){3}\b"), "{IP}"),
    (re.compile(r"\b\d+\b"), "{N}"),
    (re.compile(r"\s+"), " "),
]

LEVEL_FALLBACK = {
    "EMERGENCY": "P1", "ALERT": "P1", "CRITICAL": "P1",
    "ERROR": "P2",
    "WARNING": "P3", "NOTICE": "P3",
    "INFO": "P4", "DEBUG": "P4",
}

PRIORITY_ORDER = ["P1", "P2", "P3", "P4"]
PRIORITY_NAME = {"P1": "Critical", "P2": "High", "P3": "Medium", "P4": "Low"}


def parse_timestamp(raw):
    raw = raw.strip()
    for fmt in ("%Y-%m-%dT%H:%M:%S.%f%z", "%Y-%m-%dT%H:%M:%S%z",
                "%Y-%m-%d %H:%M:%S.%f", "%Y-%m-%d %H:%M:%S"):
        try:
            return datetime.strptime(raw, fmt).replace(tzinfo=None)
        except ValueError:
            continue
    return None


CONTEXT_RE = [
    re.compile(r"\s*\{\"exception\".*$", re.S),
    re.compile(r"\s*\[\]\s*$"),
    re.compile(r"\s*\{[^{}]*\}\s*$"),
]


def strip_context(message):
    """Drop monolog's trailing context so the message reads cleanly."""
    text = message
    for pattern in CONTEXT_RE:
        text = pattern.sub("", text)
    return text.strip() or message.strip()


def normalize(message):
    text = message
    for pattern, replacement in NORMALIZERS:
        text = pattern.sub(replacement, text)
    return text.strip(" \t.;:")


def parse_log(path, days=0):
    """Group log entries by normalized signature."""
    cutoff = datetime.now() - timedelta(days=days) if days else None
    groups = OrderedDict()
    parsed = skipped = 0

    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            match = ENTRY_RE.match(line)
            if not match:
                skipped += 1          # stack-trace continuation lines
                continue

            stamp = parse_timestamp(match.group("ts"))
            if cutoff and stamp and stamp < cutoff:
                continue

            message = match.group("msg").strip()
            signature = normalize(message)
            if not signature:
                continue
            parsed += 1

            key = hashlib.sha1(signature.encode()).hexdigest()[:16]
            group = groups.get(key)
            if group is None:
                groups[key] = group = {
                    "key": key,
                    "signature": signature[:400],
                    "sample": strip_context(message),
                    "level": match.group("level"),
                    "channel": match.group("channel"),
                    "count": 0,
                    "first": stamp,
                    "last": stamp,
                }
            group["count"] += 1
            if stamp:
                if group["first"] is None or stamp < group["first"]:
                    group["first"] = stamp
                if group["last"] is None or stamp > group["last"]:
                    group["last"] = stamp
            # Keep the most severe level seen for this signature.
            if PRIORITY_ORDER.index(LEVEL_FALLBACK[match.group("level")]) < \
               PRIORITY_ORDER.index(LEVEL_FALLBACK[group["level"]]):
                group["level"] = match.group("level")

    return list(groups.values()), parsed, skipped


# ── Classification ───────────────────────────────────────────────────────────

SYSTEM_PROMPT = """You triage Magento 2 exception.log signatures for a support team.

Assign each signature a priority by CUSTOMER and REVENUE impact, not by log level:
  P1 Critical - checkout, payment, order placement or the whole site is broken
  P2 High     - a customer-facing flow fails repeatedly: cart, login, search,
                static content, integrations that block orders
  P3 Medium   - recoverable or self-inflicted errors: wrong password, validation
                messages, expired tokens, individual data issues
  P4 Low      - noise, bots, out-of-range pagination, deprecations

Also write a short reason (max 12 words) explaining the choice.
Return one entry for every id you were given."""

RESPONSE_SCHEMA = {
    "type": "object",
    "properties": {
        "items": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "id": {"type": "integer"},
                    "priority": {"type": "string", "enum": PRIORITY_ORDER},
                    "reason": {"type": "string"},
                },
                "required": ["id", "priority", "reason"],
            },
        }
    },
    "required": ["items"],
}

MODEL_CANDIDATES = [
    "gemini-flash-latest",
    "gemini-2.5-flash",
    "gemini-3.5-flash",
    "gemini-flash-lite-latest",
]


def api_message(body):
    """Best-effort human-readable message out of a Gemini error body."""
    try:
        return json.loads(body)["error"]["message"]
    except (ValueError, KeyError, TypeError):
        return " ".join(body.split())


def gemini_request(url, payload=None, timeout=90):
    data = json.dumps(payload).encode() if payload is not None else None
    request = urllib.request.Request(
        url, data=data, headers={"Content-Type": "application/json"},
        method="POST" if data else "GET")
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.load(response)


SKIP_MODEL = re.compile(r"tts|image|audio|video|embedding|vision|live|omni|native", re.I)


def pick_models(api_key):
    """Ordered list of models to try — flash first, preview variants last."""
    configured = os.environ.get("MSSH_GEMINI_MODEL", "").strip()
    if configured:
        return [configured]

    listing = gemini_request(
        f"https://generativelanguage.googleapis.com/v1beta/models?key={api_key}&pageSize=200",
        timeout=30)
    available = [
        model["name"].split("/")[-1] for model in listing.get("models", [])
        if "generateContent" in model.get("supportedGenerationMethods", [])
        and not SKIP_MODEL.search(model["name"])
    ]

    ordered = [name for name in MODEL_CANDIDATES if name in available]
    extra = sorted(
        (name for name in available
         if name not in ordered and "flash" in name and "preview" not in name),
        reverse=True)
    ordered += extra
    if not ordered:
        raise RuntimeError("no usable Gemini model for this key")
    return ordered[:4]


def classify_with_gemini(pending, api_key):
    """Ask Gemini to prioritize the signatures it has not seen before.

    Overloaded models answer 503 and rate limits answer 429; both are worth
    one retry before moving on to the next candidate model.
    """
    payload = {
        "systemInstruction": {"parts": [{"text": SYSTEM_PROMPT}]},
        "contents": [{"role": "user", "parts": [{"text": json.dumps([
            {"id": index, "level": group["level"], "count": group["count"],
             "message": group["signature"][:300]}
            for index, group in enumerate(pending)
        ], ensure_ascii=False)}]}],
        "generationConfig": {
            "responseMimeType": "application/json",
            "responseSchema": RESPONSE_SCHEMA,
            "temperature": 0,
            "maxOutputTokens": 8192,
        },
    }
    models = pick_models(api_key)
    last_error = None
    response = model = None

    for candidate in models:
        url = (f"https://generativelanguage.googleapis.com/v1beta/models/"
               f"{candidate}:generateContent?key={api_key}")
        for attempt in range(3):
            try:
                response = gemini_request(url, payload)
                model = candidate
                break
            except urllib.error.HTTPError as error:
                detail = api_message(error.read().decode("utf-8", "replace"))
                last_error = f"{candidate}: HTTP {error.code} {detail[:90]}"
                # 429/503 are load, not a bad request — back off, then try the
                # next model rather than giving up on the whole report.
                if error.code in (429, 500, 503) and attempt < 2:
                    time.sleep(2 + attempt * 3)
                    continue
                break
        if response is not None:
            break

    if response is None:
        raise RuntimeError(last_error or "no Gemini response")

    text = "".join(
        part.get("text", "")
        for part in response["candidates"][0]["content"]["parts"]
    )
    verdicts = {}
    for item in json.loads(text).get("items", []):
        index = item.get("id")
        if isinstance(index, int) and 0 <= index < len(pending):
            priority = item.get("priority")
            if priority in PRIORITY_ORDER:
                verdicts[index] = (priority, item.get("reason", "")[:120])
    return verdicts, model


def classify(groups, cache_path, classifier):
    """Fill in priority/reason for every group. Returns (source, model, note)."""
    cache = {}
    if cache_path and os.path.exists(cache_path):
        try:
            with open(cache_path) as handle:
                cache = json.load(handle)
        except (ValueError, OSError):
            cache = {}

    pending = []
    for group in groups:
        cached = cache.get(group["key"])
        if cached:
            group["priority"] = cached["priority"]
            group["reason"] = cached.get("reason", "")
            group["source"] = "cache"
        else:
            group["priority"] = LEVEL_FALLBACK[group["level"]]
            group["reason"] = ""
            group["source"] = "rules"
            pending.append(group)

    model = ""
    note = ""
    api_key = os.environ.get("GEMINI_API_KEY", "").strip()

    if classifier == "gemini" and pending:
        if not api_key:
            note = "GEMINI_API_KEY not set — fell back to log-level priorities"
        else:
            try:
                verdicts, model = classify_with_gemini(pending, api_key)
                for index, (priority, reason) in verdicts.items():
                    group = pending[index]
                    group["priority"] = priority
                    group["reason"] = reason
                    group["source"] = "gemini"
                    cache[group["key"]] = {
                        "priority": priority,
                        "reason": reason,
                        "signature": group["signature"][:200],
                    }
                if cache_path:
                    os.makedirs(os.path.dirname(cache_path), exist_ok=True)
                    with open(cache_path, "w") as handle:
                        json.dump(cache, handle, indent=1, sort_keys=True)
            except urllib.error.HTTPError as error:
                body = error.read().decode("utf-8", "replace")
                try:
                    detail = json.loads(body)["error"]["message"]
                except (ValueError, KeyError, TypeError):
                    detail = " ".join(body.split())
                note = f"Gemini HTTP {error.code} — used log-level priorities: {detail[:90]}"
            except Exception as error:                       # noqa: BLE001
                note = f"Gemini call failed — used log-level priorities ({error})"

    source = "gemini" if any(g["source"] == "gemini" for g in groups) else "rules"
    if any(g["source"] == "cache" for g in groups) and source == "rules":
        source = "cache"
    return source, model, note


# ── Spreadsheet ──────────────────────────────────────────────────────────────

HEADER_FILL = "1F4E79"
PRIORITY_FILL = {"P1": "F8CBAD", "P2": "FCE4D6", "P3": "FFF2CC", "P4": "E2EFDA"}
BAND_FILL = "F2F7FB"


def write_xlsx(path, label, groups, totals, meta):
    from openpyxl import Workbook
    from openpyxl.styles import Alignment, Border, Font, PatternFill, Side
    from openpyxl.utils import get_column_letter

    thin = Side(style="thin", color="D9D9D9")
    border = Border(left=thin, right=thin, top=thin, bottom=thin)
    head_font = Font(bold=True, color="FFFFFF", size=10)
    head_fill = PatternFill("solid", fgColor=HEADER_FILL)

    workbook = Workbook()

    # ── Summary sheet ────────────────────────────────────────────────────────
    sheet = workbook.active
    sheet.title = "Summary"
    sheet["A1"] = "Exception Log Summary"
    sheet["A1"].font = Font(bold=True, size=18, color=HEADER_FILL)
    sheet.merge_cells("A1:D1")
    sheet["A1"].alignment = Alignment(horizontal="center")

    sheet["A2"] = label
    sheet["A2"].font = Font(size=12)
    sheet.merge_cells("A2:D2")
    sheet["A2"].alignment = Alignment(horizontal="center")

    period = "n/a"
    if meta["first"] and meta["last"]:
        period = f"{meta['first']:%Y-%m-%d} to {meta['last']:%Y-%m-%d}"
    sheet["A3"] = (f"Period: {period}  |  Generated: {meta['generated']:%Y-%m-%d %H:%M}"
                   f"  |  Unique issues: {len(groups)}  |  Total occurrences: {totals['all']}")
    sheet.merge_cells("A3:D3")
    sheet["A3"].alignment = Alignment(horizontal="center")

    row = 5
    for column, title in enumerate(
            ["Priority", "Unique Issues", "Occurrences", "% of Total"], start=1):
        cell = sheet.cell(row=row, column=column, value=title)
        cell.font, cell.fill, cell.border = head_font, head_fill, border
        cell.alignment = Alignment(horizontal="center")

    for priority in PRIORITY_ORDER:
        bucket = totals["by_priority"].get(priority)
        if not bucket:
            continue
        row += 1
        share = bucket["count"] / totals["all"] * 100 if totals["all"] else 0
        values = [f"{priority} {PRIORITY_NAME[priority]}", bucket["unique"],
                  bucket["count"], round(share, 1)]
        for column, value in enumerate(values, start=1):
            cell = sheet.cell(row=row, column=column, value=value)
            cell.border = border
            cell.alignment = Alignment(
                horizontal="left" if column == 1 else "center")
            if column == 1:
                cell.fill = PatternFill("solid", fgColor=PRIORITY_FILL[priority])
            if column == 4:
                cell.number_format = '0.0"%"'

    row += 2
    sheet.cell(row=row, column=1, value="Legend:").font = Font(bold=True)
    sheet.cell(row=row, column=2,
               value="P1 Critical | P2 High | P3 Medium | P4 Low")
    row += 1
    sheet.cell(row=row, column=1, value="Priorities by:").font = Font(bold=True)
    sheet.cell(row=row, column=2, value=meta["source_label"])
    if meta["note"]:
        row += 1
        cell = sheet.cell(row=row, column=1, value=meta["note"])
        cell.font = Font(italic=True, color="C00000")

    for column, width in enumerate([26, 16, 16, 14], start=1):
        sheet.column_dimensions[get_column_letter(column)].width = width

    # ── Detail sheet ─────────────────────────────────────────────────────────
    detail = workbook.create_sheet("Errors")
    headers = ["#", "Count", "Pri", "Error", "Level",
               "First seen", "Last seen", "Why this priority"]
    for column, title in enumerate(headers, start=1):
        cell = detail.cell(row=1, column=column, value=title)
        cell.font, cell.fill, cell.border = head_font, head_fill, border
        cell.alignment = Alignment(horizontal="center")

    for index, group in enumerate(groups, start=1):
        row = index + 1
        values = [
            index,
            group["count"],
            group["priority"],
            group["sample"][:400],
            group["level"],
            f"{group['first']:%Y-%m-%d %H:%M}" if group["first"] else "",
            f"{group['last']:%Y-%m-%d %H:%M}" if group["last"] else "",
            group["reason"],
        ]
        for column, value in enumerate(values, start=1):
            cell = detail.cell(row=row, column=column, value=value)
            cell.border = border
            if column == 3:
                cell.fill = PatternFill(
                    "solid", fgColor=PRIORITY_FILL[group["priority"]])
                cell.alignment = Alignment(horizontal="center")
            elif column in (1, 2, 5):
                cell.alignment = Alignment(horizontal="center")
            else:
                cell.alignment = Alignment(vertical="top", wrap_text=(column == 4))
            if column != 3 and index % 2 == 0:
                cell.fill = PatternFill("solid", fgColor=BAND_FILL)

    for column, width in enumerate([5, 8, 6, 78, 10, 17, 17, 40], start=1):
        detail.column_dimensions[get_column_letter(column)].width = width
    detail.freeze_panes = "A2"
    detail.auto_filter.ref = f"A1:H{len(groups) + 1}"

    workbook.save(path)


# ── Entry point ──────────────────────────────────────────────────────────────

def main():
    log_path = os.environ["MSSH_LOG"]
    out_path = os.environ["MSSH_OUT"]
    label = os.environ.get("MSSH_LABEL", "")
    cache_path = os.environ.get("MSSH_CACHE", "")
    classifier = os.environ.get("MSSH_CLASSIFIER", "gemini")
    top = int(os.environ.get("MSSH_TOP", "0") or 0)
    days = int(os.environ.get("MSSH_DAYS", "0") or 0)

    groups, parsed, skipped = parse_log(log_path, days)
    if not groups:
        print("EMPTY", file=sys.stderr)
        return 2

    source, model, note = classify(groups, cache_path, classifier)

    groups.sort(key=lambda g: (-g["count"], PRIORITY_ORDER.index(g["priority"])))
    if top:
        groups = groups[:top]

    totals = {"all": sum(g["count"] for g in groups), "by_priority": {}}
    for group in groups:
        bucket = totals["by_priority"].setdefault(
            group["priority"], {"unique": 0, "count": 0})
        bucket["unique"] += 1
        bucket["count"] += group["count"]

    stamps = [g["first"] for g in groups if g["first"]] + \
             [g["last"] for g in groups if g["last"]]
    source_label = {
        "gemini": f"Gemini ({model})" if model else "Gemini",
        "cache": "cached Gemini verdicts",
        "rules": "log level (no AI call)",
    }[source]

    write_xlsx(out_path, label, groups, totals, {
        "first": min(stamps) if stamps else None,
        "last": max(stamps) if stamps else None,
        "generated": datetime.now(),
        "source_label": source_label,
        "note": note,
    })

    summary = " ".join(
        f"{p}={totals['by_priority'][p]['count']}"
        for p in PRIORITY_ORDER if p in totals["by_priority"])
    print(f"OK|{len(groups)}|{totals['all']}|{parsed}|{skipped}|{source_label}|{summary}|{note}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
PYEOF
}

# _run_report <log_file> <label> <out_file> — analyse a local log, print result.
_run_report() {
    local log_file="$1" label="$2" out_file="$3"

    command -v python3 &>/dev/null || die "python3 is required for reports."
    python3 -c "import openpyxl" 2>/dev/null \
        || die "python3 openpyxl is required. Run: pip install --user openpyxl"

    [[ -s "${log_file}" ]] || { warn "Log file is empty: ${log_file}"; return 1; }

    mkdir -p "$(dirname "${out_file}")"

    local result
    if ! result=$(MSSH_LOG="${log_file}" \
                  MSSH_OUT="${out_file}" \
                  MSSH_LABEL="${label}" \
                  MSSH_CACHE="${CONFIG_DIR}/priority-map.json" \
                  MSSH_CLASSIFIER="${REPORT_CLASSIFIER:-gemini}" \
                  MSSH_TOP="${REPORT_TOP:-0}" \
                  MSSH_DAYS="${REPORT_DAYS:-0}" \
                  _report_analyzer); then
        err "Report generation failed."
        return 1
    fi

    if [[ "${result}" != OK\|* ]]; then
        warn "No parsable log entries found in ${log_file}."
        return 1
    fi

    local unique total parsed skipped source summary note
    IFS='|' read -r _ unique total parsed skipped source summary note <<< "${result}"

    printf "\n  %-16s %s\n" "Unique issues"  "${unique}"
    printf "  %-16s %s\n"   "Occurrences"    "${total}"
    printf "  %-16s %s\n"   "Lines parsed"   "${parsed}"
    printf "  %-16s %s\n"   "Priorities by"  "${source}"
    printf "  %-16s %s\n"   "Breakdown"      "${summary}"
    [[ -n "${note}" ]] && warn "  ${note}"
    printf '\n'
    ok "Report → ${CYAN}${out_file}${NC}"
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────

cmd_report() {
    local name="" log_file="" out_file="" remote_log=""
    REPORT_CLASSIFIER="gemini"; REPORT_TOP=0; REPORT_DAYS=0
    local open_after=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --file|-f)   log_file="${2:-}"; shift 2 ;;
            --output|-o) out_file="${2:-}"; shift 2 ;;
            --log)       remote_log="${2:-}"; shift 2 ;;
            --rules)     REPORT_CLASSIFIER="rules"; shift ;;
            --gemini)    REPORT_CLASSIFIER="gemini"; shift ;;
            --days|-d)   REPORT_DAYS="${2:-0}"; shift 2 ;;
            --top|-t)    REPORT_TOP="${2:-0}"; shift 2 ;;
            --open)      open_after=true; shift ;;
            *)           [[ -z "${name}" ]] && name="$1"; shift ;;
        esac
    done

    local label="${name}"
    local stamp; stamp=$(date '+%Y%m%d-%H%M%S')

    if [[ -z "${log_file}" ]]; then
        [[ -n "${name}" ]] \
            || die "Usage: magneto-ssh report <name> [options]
       magneto-ssh report --file <exception.log> [options]"
        server_exists "${name}" || die "Server '${name}' not found. Run: magneto-ssh list"

        local file; file=$(server_file "${name}")
        local project_dir; project_dir=$(read_field "${file}" PROJECT_DIR)
        [[ -n "${project_dir}" ]] \
            || die "No PROJECT_DIR set for '${name}'. Run: magneto-ssh edit ${name}"
        remote_log="${remote_log:-${project_dir%/}/var/log/exception.log}"

        log_file="${CONFIG_DIR}/reports/${name}/exception-${stamp}.log"
        mkdir -p "$(dirname "${log_file}")"

        printf "\n${DIM}Downloading${NC} ${CYAN}%s:%s${NC}\n" "${name}" "${remote_log}"
        _scp_fetch "${name}" "$(_hk_rquote "${remote_log}")" "${log_file}" \
            || die "Could not download ${remote_log} from '${name}'."
    else
        [[ -f "${log_file}" ]] || die "Log file not found: ${log_file}"
        label="${label:-$(basename "${log_file}")}"
    fi

    out_file="${out_file:-${CONFIG_DIR}/reports/${label// /_}/exception-report-${stamp}.xlsx}"

    printf "\n${BOLD}${CYAN}Exception log report${NC} — ${BOLD}%s${NC}\n" "${label}"
    _run_report "${log_file}" "${label}" "${out_file}" || return 1

    if [[ "${open_after}" == true ]] && command -v xdg-open &>/dev/null; then
        xdg-open "${out_file}" &>/dev/null &
        disown
    fi
    printf '\n'
}

# ─────────────────────────────────────────────────────────────────────────────

cmd_import() {
    local xml_file="${1:-}"
    [[ -n "${xml_file}" ]] || die "Usage: magneto-ssh import <filezilla_export.xml>"
    [[ -f "${xml_file}" ]] || die "File not found: ${xml_file}"
    command -v python3 &>/dev/null || die "python3 is required for XML import."

    printf "\n${BOLD}Parsing FileZilla XML:${NC} %s\n\n" "${xml_file}"

    # Parse with python3 stdlib — outputs SOH-delimited lines:
    # slug \x01 host \x01 port \x01 user \x01 auth_type \x01 raw_pw \x01 keyfile \x01 project_dir \x01 orig_name
    local parsed_data
    parsed_data=$(python3 -c "
import base64, xml.etree.ElementTree as ET, re, sys

def parse_dir(s):
    if not s: return ''
    p = s.split()
    if len(p) < 2: return ''
    idx, segs = 2, []
    while idx + 1 < len(p):
        segs.append(p[idx+1]); idx += 2
    return ('/' if p[0]=='1' else '') + '/'.join(segs)

def slug(n):
    s = re.sub(r'[^a-z0-9]+', '_', n.lower().strip())
    return re.sub(r'_+', '_', s).strip('_')

tree = ET.parse(sys.argv[1])
for s in tree.getroot().iter('Server'):
    host = (s.findtext('Host') or '').strip()
    port = (s.findtext('Port') or '22').strip()
    user = (s.findtext('User') or '').strip()
    name = (s.findtext('Name') or '').strip()
    lt   = (s.findtext('Logontype') or '1').strip()
    kf   = (s.findtext('Keyfile') or '').strip()
    rd   = parse_dir(s.findtext('RemoteDir') or '')
    pw   = ''
    pe   = s.find('Pass')
    if pe is not None and pe.get('encoding')=='base64' and pe.text:
        try: pw = base64.b64decode(pe.text).decode('utf-8')
        except: pass
    auth = 'ssh_key' if (lt=='5' or kf) else 'password'
    sl   = slug(name) if name else slug(host)
    row  = [sl, host, port, user, auth, pw, kf, rd, name]
    print('\x01'.join(f.replace('\x01',' ').replace('\n',' ') for f in row))
" "${xml_file}" 2>&1) || die "XML parse failed: ${parsed_data}"

    [[ -n "${parsed_data}" ]] || { warn "No servers found in XML."; return; }

    # ── Count servers ─────────────────────────────────────────────────────────
    local total=0
    while IFS=$'\x01' read -r sl host port user auth pw kf rd name; do
        (( ++total ))
    done <<< "${parsed_data}"

    # ── Preview table ─────────────────────────────────────────────────────────
    printf "${BOLD}Found %d servers to import:${NC}\n\n" "${total}"
    printf "${BOLD}${CYAN}%-32s %-24s %-6s %-14s %-10s %s${NC}\n" \
        "NAME" "HOST" "PORT" "USER" "AUTH" "PROJECT DIR"
    printf '%0.s─' {1..100}; printf '\n'

    while IFS=$'\x01' read -r sl host port user auth pw kf rd name; do
        local pw_flag=""
        [[ -n "${pw}" ]] && pw_flag=" ${DIM}[has pw]${NC}"
        [[ -n "${kf}" ]] && pw_flag=" ${DIM}[key: $(basename "${kf}")]${NC}"
        printf "%-32s %-24s %-6s %-14s %-10s %b\n" \
            "${sl}" "${host}" "${port}" "${user}" "${auth}" "${rd:--}${pw_flag}"
    done <<< "${parsed_data}"

    # ── Confirm ───────────────────────────────────────────────────────────────
    printf '\n'
    local overwrite_all=false
    printf "Import %d servers? [y/N] " "${total}"; read -r confirm
    [[ "${confirm,,}" == "y" ]] || exit 0

    printf "Overwrite existing servers? [y/N] "; read -r ow
    [[ "${ow,,}" == "y" ]] && overwrite_all=true

    # ── Import servers ────────────────────────────────────────────────────────
    printf '\n'
    local imported=0 skipped=0

    while IFS=$'\x01' read -r sl host port user auth pw kf rd name; do
        if server_exists "${sl}" && [[ "${overwrite_all}" == false ]]; then
            printf "  ${YELLOW}!${NC} %-32s already exists — skipped\n" "${sl}"
            (( ++skipped )); continue
        fi

        printf 'HOST=%s\nPORT=%s\nUSER=%s\nAUTH_TYPE=%s\nPASSWORD=%s\nSSH_KEY=%s\nPROJECT_DIR=%s\nADMIN_URL=\nADMIN_USER=\nADMIN_PASSWORD=\nFRONTEND_URL=\nGIT_TOKEN=\nDB_HOST=\nDB_PORT=\nDB_NAME=\nDB_USER=\nDB_PASSWORD=\nTUNNEL_LOCAL_PORT=\nDISK_PATH=\n' \
            "${host}" "${port}" "${user}" "${auth}" \
            "${pw}" "${kf}" "${rd}" \
            | write_server "${sl}"

        printf "  ${GREEN}✓${NC} %-32s imported  ${DIM}(%s)${NC}\n" "${sl}" "${name}"
        (( ++imported ))
    done <<< "${parsed_data}"

    printf '\n'
    ok "${imported} server(s) imported, ${skipped} skipped."
    printf '\n'
}

# ─────────────────────────────────────────────────────────────────────────────

cmd_help() {
    printf "
${BOLD}${CYAN}magneto-ssh${NC} ${DIM}v${VERSION}${NC}
SSH connection manager for Magento environments.

${BOLD}Usage:${NC}
  magneto-ssh <command> [arguments]
  magneto-ssh <name>               Connect directly to a server

${BOLD}Commands:${NC}
  ${CYAN}add${NC}    <name>            Add a server interactively
  ${CYAN}edit${NC}   <name>            Edit an existing server config
  ${CYAN}ssh${NC}    <name>            Connect to a server
  ${CYAN}scp${NC}    <name> <remote> [local]   Download file from server
  ${CYAN}scp${NC}    <name> --upload <local> <remote>  Upload file to server
  ${CYAN}list${NC}                     List all configured servers
  ${CYAN}info${NC}   <name>            Show server details
  ${CYAN}remove${NC} <name>            Delete a server config
  ${CYAN}import${NC}   <file.xml>        Import servers from FileZilla XML export
  ${CYAN}validate${NC} [--timeout N]   Test connectivity for all servers
  ${CYAN}filezilla${NC} <name>         Open server in FileZilla (SFTP)
  ${CYAN}tunnel${NC}   <name>          Create SSH tunnel to remote DB (localhost:TUNNEL_LOCAL_PORT)
  ${CYAN}dbeaver${NC}  <name>          Open tunnel + launch DBeaver with DB connection
  ${CYAN}housekeeping${NC} <name>     Indexers, disk, SSL, PageSpeed, uptime, exception report
  ${CYAN}report${NC} <name>            Prioritized exception.log report as xlsx
  ${CYAN}version${NC}                  Print version and check for updates
  ${CYAN}update${NC}                   Update magneto-ssh to latest version

${BOLD}Tab completion:${NC}
  magneto-ssh install-completion   Add bash tab completion to ~/.bashrc

${BOLD}Examples:${NC}
  magneto-ssh add petzone_stage
  magneto-ssh petzone_stage
  magneto-ssh edit petzone_stage
  magneto-ssh list
  magneto-ssh info petzone_stage
  magneto-ssh housekeeping petzone_stage
  magneto-ssh hk petzone_stage --tail 50 --no-download

${BOLD}housekeeping options:${NC}
  --tail N          Lines of exception.log to show inline (default 20, 0 = none)
  --no-download     Skip downloading exception.log
  --output DIR      Where to save the log (default ~/.magneto-ssh/reports/<name>)
  --log PATH        Override exception.log path (default <PROJECT_DIR>/var/log/exception.log)
  --disk PATH       Override df -h path (default DISK_PATH, else ~/application/)
  --no-report       Skip the xlsx exception report (built by default)
  --no-ssl          Skip the SSL certificate expiry check
  --domain HOST     Check this host's certificate instead of FRONTEND_URL's
  --no-pagespeed    Skip the PageSpeed Insights run
  --url URL         Measure this URL instead of FRONTEND_URL
  --no-uptime       Skip the UptimeRobot check

${BOLD}report options:${NC}
  --file PATH       Analyse a local log instead of downloading one
  --output FILE     Where to write the xlsx (default ~/.magneto-ssh/reports/<name>/)
  --days N          Only include entries from the last N days
  --top N           Keep only the N most frequent issues
  --rules           Skip Gemini, prioritize by log level only
  --open            Open the xlsx when it is done

${BOLD}PageSpeed:${NC}  export PAGESPEED_API_KEY=...  (or put it in ~/.magneto-ssh/.env)
  Key from https://console.cloud.google.com — optional, but without one Google
  rate-limits the anonymous quota quickly.

${BOLD}UptimeRobot:${NC}  export UPTIMEROBOT_API_KEY=...  (or ~/.magneto-ssh/.env)
  A read-only key from the UptimeRobot dashboard is enough. The monitor is
  matched to the server's FRONTEND_URL host.

${BOLD}Gemini:${NC}  export GEMINI_API_KEY=...   (key from https://aistudio.google.com/apikey)
  Priorities are cached in ~/.magneto-ssh/priority-map.json, so repeat errors
  never hit the API again. Without a key the report falls back to log levels.

${BOLD}Name format:${NC}  project_environment
  e.g.  petzone_stage   petzone_production   clientA_dev
"
}

# ─────────────────────────────────────────────────────────────────────────────

cmd_install_completion() {
    local bashrc="${HOME}/.bashrc"
    mkdir -p "${HOME}/.bash_completion.d"

    cat > "${HOME}/.bash_completion.d/magneto-ssh" <<'COMPLETION'
# magneto-ssh bash tab completion
_magneto_ssh_complete() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local prev="${COMP_WORDS[COMP_CWORD-1]}"
    local cmds="add edit ssh scp download list info remove import validate filezilla tunnel dbeaver housekeeping hk report install-completion version update help"

    if [[ ${COMP_CWORD} -eq 1 ]]; then
        # Complete both commands and server names
        local servers=""
        [[ -d "${HOME}/.magneto-ssh/servers" ]] \
            && servers=$(ls "${HOME}/.magneto-ssh/servers" 2>/dev/null | tr '\n' ' ')
        COMPREPLY=($(compgen -W "${cmds} ${servers}" -- "${cur}"))
        compopt +o default 2>/dev/null
        return 0
    fi

    case "${prev}" in
        ssh|scp|download|info|remove|add|edit|update|filezilla|fz|tunnel|dbeaver|db|housekeeping|hk|report)
            local servers=""
            [[ -d "${HOME}/.magneto-ssh/servers" ]] \
                && servers=$(ls "${HOME}/.magneto-ssh/servers" 2>/dev/null | tr '\n' ' ')
            COMPREPLY=($(compgen -W "${servers}" -- "${cur}"))
            compopt +o default 2>/dev/null
            return 0
            ;;
    esac

    COMPREPLY=()
    compopt +o default 2>/dev/null
    return 0
}
complete -F _magneto_ssh_complete magneto-ssh
COMPLETION

    local source_line='[[ -f "${HOME}/.bash_completion.d/magneto-ssh" ]] && source "${HOME}/.bash_completion.d/magneto-ssh"'
    if ! grep -q '.bash_completion.d/magneto-ssh' "${bashrc}" 2>/dev/null; then
        printf '\n# magneto-ssh completion\n%s\n' "${source_line}" >> "${bashrc}"
    fi

    ok "Tab completion installed. Run: source ~/.bash_completion.d/magneto-ssh"
}

# =============================================================================
# Version / update check
# =============================================================================

_fetch_latest_version() {
    local fetch_cmd=""
    if command -v curl &>/dev/null; then
        fetch_cmd="curl -fsSL --max-time 5"
    elif command -v wget &>/dev/null; then
        fetch_cmd="wget -qO- --timeout=5"
    else
        return 1
    fi
    ${fetch_cmd} "https://raw.githubusercontent.com/JainamDeveloper/magneto-ssh/main/magneto-ssh.sh" 2>/dev/null \
        | grep '^VERSION=' | head -1 | cut -d'"' -f2
}

check_for_update() {
    # Refresh cache at most once per day
    local now
    now=$(date +%s)
    local last_check=0
    local cached_version=""
    if [[ -f "${UPDATE_CACHE}" ]]; then
        last_check=$(grep '^checked=' "${UPDATE_CACHE}" 2>/dev/null | cut -d= -f2 || echo 0)
        cached_version=$(grep '^latest=' "${UPDATE_CACHE}" 2>/dev/null | cut -d= -f2 || echo "")
    fi
    if (( now - last_check > 86400 )); then
        local fetched
        fetched=$(_fetch_latest_version 2>/dev/null) || fetched=""
        if [[ -n "${fetched}" ]]; then
            printf "checked=%s\nlatest=%s\n" "${now}" "${fetched}" > "${UPDATE_CACHE}" 2>/dev/null || true
            cached_version="${fetched}"
        fi
    fi
    printf "%s" "${cached_version}"
}

show_update_notice() {
    [[ -f "${UPDATE_CACHE}" ]] || return 0
    local latest
    latest=$(grep '^latest=' "${UPDATE_CACHE}" 2>/dev/null | cut -d= -f2 || echo "") || true
    [[ -n "${latest}" ]] || return 0
    # Only notify when remote is strictly newer than local
    local newer
    newer=$(printf "%s\n%s\n" "${VERSION}" "${latest}" | sort -V | tail -1)
    [[ "${newer}" == "${latest}" && "${latest}" != "${VERSION}" ]] || return 0
    printf "\n${YELLOW}Update available: v%s → v%s${NC}  Run: ${CYAN}magneto-ssh update${NC}\n" \
        "${VERSION}" "${latest}"
}

cmd_upgrade() {
    local latest
    latest=$(check_for_update)
    if [[ -n "${latest}" && "${latest}" == "${VERSION}" ]]; then
        ok "Already on latest version (v${VERSION})."
        return 0
    fi
    # Guard against downgrades — e.g. a locally built version not pushed yet
    if [[ -n "${latest}" ]]; then
        local newer
        newer=$(printf "%s\n%s\n" "${VERSION}" "${latest}" | sort -V | tail -1)
        if [[ "${newer}" == "${VERSION}" ]]; then
            warn "Local version v${VERSION} is newer than GitHub (v${latest})."
            printf "Downgrade to v%s? [y/N] " "${latest}"
            read -r _dg
            [[ "${_dg,,}" == "y" ]] || { ok "Kept v${VERSION}."; return 0; }
        fi
    fi

    printf "Upgrading magneto-ssh"
    [[ -n "${latest}" ]] && printf " v%s → v%s" "${VERSION}" "${latest}"
    printf "...\n"
    local install_url="https://raw.githubusercontent.com/JainamDeveloper/magneto-ssh/main/install.sh"
    if command -v curl &>/dev/null; then
        curl -fsSL --max-time 30 "${install_url}" | bash
    elif command -v wget &>/dev/null; then
        wget -qO- --timeout=30 "${install_url}" | bash
    else
        die "curl or wget required to upgrade."
    fi
    # Bust cache so next run reflects new version
    rm -f "${UPDATE_CACHE}" 2>/dev/null || true
}

cmd_version() {
    printf "magneto-ssh v%s\n" "${VERSION}"
    local latest
    latest=$(_fetch_latest_version 2>/dev/null) || latest=""
    if [[ -z "${latest}" ]]; then
        printf "${DIM}(could not check for updates)${NC}\n"
        return 0
    fi
    # Bust cache with fresh result
    printf "checked=%s\nlatest=%s\n" "$(date +%s)" "${latest}" > "${UPDATE_CACHE}" 2>/dev/null || true
    local newer
    newer=$(printf "%s\n%s\n" "${VERSION}" "${latest}" | sort -V | tail -1)
    if [[ "${latest}" == "${VERSION}" ]]; then
        printf "${GREEN}You are on the latest version.${NC}\n"
    elif [[ "${newer}" == "${latest}" ]]; then
        printf "${YELLOW}Update available: v%s → v%s${NC}  Run: ${CYAN}magneto-ssh update${NC}\n" \
            "${VERSION}" "${latest}"
    else
        printf "${GREEN}You are running a newer version than GitHub (v%s > v%s).${NC}\n" \
            "${VERSION}" "${latest}"
    fi
}

# =============================================================================
# Main dispatcher
# =============================================================================

main() {
    local cmd="${1:-help}"
    shift || true

    case "${cmd}" in
        add)                    cmd_add "$@" ;;
        edit)                   cmd_update "$@" ;;
        ssh)                    cmd_ssh "$@" ;;
        scp|download)           cmd_scp "$@" ;;
        list)                   cmd_list ;;
        info)                   cmd_info "$@" ;;
        remove|rm|delete)       cmd_remove "$@" ;;
        import)                 cmd_import "$@" ;;
        filezilla|fz)           cmd_filezilla "$@" ;;
        tunnel)                 cmd_tunnel "$@" ;;
        dbeaver|db)             cmd_dbeaver "$@" ;;
        housekeeping|hk)        cmd_housekeeping "$@" ;;
        report)                 cmd_report "$@" ;;
        validate|check)         cmd_validate "$@" ;;
        version|--version|-v)   cmd_version ;;
        upgrade|update|self-update) cmd_upgrade ;;
        install-completion)     cmd_install_completion ;;
        help|--help|-h)         cmd_help ;;
        *)
            # Direct connect: magneto-ssh <server-name>
            if server_exists "${cmd}"; then
                cmd_ssh "${cmd}" "$@"
            else
                err "Unknown command or server: ${cmd}"; cmd_help; exit 1
            fi
            ;;
    esac

    case "${cmd}" in
        version|upgrade|update|self-update|help|--help|-h|--version|-v) : ;;
        *) check_for_update > /dev/null 2>&1 & show_update_notice ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
