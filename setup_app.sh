#!/usr/bin/env bash
set -euo pipefail

# =========================
# 🎨 Output helpers
# =========================
info()    { echo -e "\033[1;34m[INFO]:🔍 $*\033[0m"; }
warn()    { echo -e "\033[1;33m[WARN]:⚠️ $*\033[0m"; }
error()   { echo -e "\033[1;31m[ERROR]:❌ $*\033[0m"; }
success() { echo -e "\033[1;32m[SUCCESS]:✅ $*\033[0m"; }
debug()   { echo -e "\033[38;5;208m[DEBUG]:⚙️ $*\033[0m"; }

# =========================
# 📁 Constants
# =========================
VPS_CONFIG="/etc/vps/domains.json"
APPS_ROOT="/opt/apps"
NGINX_APPS_DIR="/etc/nginx/apps"

ENVIRONMENTS=("production" "staging")
COMPONENTS=("frontend" "backend" "both")

# =========================
# 🧠 State
# =========================
DOMAIN=""
ENVIRONMENT=""
APP_NAME=""
COMPONENT=""
DOMAIN_ROOT=""
FRONTEND_DOMAIN=""
BACKEND_DOMAIN=""

# =========================
# 🔍 Guards
# =========================
require_root() {
  [[ $EUID -eq 0 ]] || { error "Run as root"; exit 1; }
}

require_tools() {
  for t in jq nginx; do
    command -v "$t" &>/dev/null || {
      error "Missing required tool: $t"
      exit 1
    }
  done
}

# =========================
# 🌐 Domain Selection
# =========================
select_domain() {
  [[ -f "$VPS_CONFIG" ]] || {
    error "VPS config not found at $VPS_CONFIG"
    exit 1
  }

  mapfile -t DOMAINS < <(jq -r '.domains | keys[]' "$VPS_CONFIG")

  info "Select a domain:"
  select DOMAIN in "${DOMAINS[@]}"; do
    [[ -n "$DOMAIN" ]] && break
    warn "Invalid selection"
  done

  DOMAIN_ROOT="$APPS_ROOT/$DOMAIN"

  FRONTEND_DOMAIN=$(jq -r ".domains[\"$DOMAIN\"].frontend" "$VPS_CONFIG")
  BACKEND_DOMAIN=$(jq -r ".domains[\"$DOMAIN\"].backend" "$VPS_CONFIG")

  success "Using domain: $DOMAIN"
}

# =========================
# 🧪 Environment
# =========================
select_environment() {
  info "Select environment:"
  select ENVIRONMENT in "${ENVIRONMENTS[@]}"; do
    [[ -n "$ENVIRONMENT" ]] && break
    warn "Invalid selection"
  done
}

# =========================
# 📦 App details
# =========================
read_app_name() {
  read -rp "App name (path-safe, no spaces): " APP_NAME
  [[ "$APP_NAME" =~ ^[a-zA-Z0-9_-]+$ ]] || {
    error "Invalid app name"
    exit 1
  }
}

select_component() {
  info "Which component?"
  select COMPONENT in "${COMPONENTS[@]}"; do
    [[ -n "$COMPONENT" ]] && break
    warn "Invalid selection"
  done
}

# =========================
# 📁 Filesystem
# =========================
create_app_dirs() {
  local base="$DOMAIN_ROOT/$APP_NAME"

  mkdir -p "$base"

  [[ "$COMPONENT" =~ frontend|both ]] && \
    mkdir -p "$base/frontend-$ENVIRONMENT"

  [[ "$COMPONENT" =~ backend|both ]] && \
    mkdir -p "$base/backend-$ENVIRONMENT"

  success "Created app directories at $base"
}

# =========================
# 🌍 Nginx config generation
# =========================
nginx_app_conf_path() {
  echo "$NGINX_APPS_DIR/$DOMAIN/$APP_NAME-$ENVIRONMENT.conf"
}

generate_nginx_config() {
  local conf
  conf=$(nginx_app_conf_path)

  mkdir -p "$(dirname "$conf")"

  info "Generating nginx config: $conf"

  cat > "$conf" <<EOF
# App: $APP_NAME
# Environment: $ENVIRONMENT
# Generated: $(date)

EOF

  if [[ "$COMPONENT" =~ frontend|both ]]; then
    cat >> "$conf" <<EOF
location /apps/$APP_NAME/ {
    root $DOMAIN_ROOT/$APP_NAME/frontend-$ENVIRONMENT;
    index index.html;
    try_files \$uri /index.html;
}
EOF
  fi

  if [[ "$COMPONENT" =~ backend|both ]]; then
    local backend_port
    backend_port=$(
      jq -r ".domains[\"$DOMAIN\"].ports.backend_$ENVIRONMENT" "$VPS_CONFIG"
    )

    cat >> "$conf" <<EOF

location /apps/$APP_NAME/api/ {
    proxy_pass http://localhost:$backend_port;
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
}
EOF
  fi

  success "Nginx app config written"
}

# =========================
# 🔄 Reload nginx
# =========================
reload_nginx() {
  nginx -t || { error "nginx config test failed"; exit 1; }
  systemctl reload nginx
  success "nginx reloaded"
}

# =========================
# 🚀 Main
# =========================
main() {
  require_root
  require_tools

  select_domain
  select_environment
  read_app_name
  select_component

  create_app_dirs
  generate_nginx_config
  reload_nginx

  echo
  success "App onboarded successfully!"
  info "Frontend URL:"
  info "https://${FRONTEND_DOMAIN}/apps/${APP_NAME}/"
  info "Backend URL:"
  info "https://${BACKEND_DOMAIN}/apps/${APP_NAME}/"
}

main "$@"

exit_program() {
  info "Exiting program."
  exit 0
}

# === Header Menu UI ===
print_header() {
    local text="===== VPS Setup Wizard ====="
    local colors=("\033[1;31m" "\033[1;33m" "\033[1;32m" "\033[1;36m" "\033[1;34m" "\033[1;35m")
    local reset="\033[0m"
    local len=${#text}

    for (( i=0; i<len; i++ )); do
        local c="${text:i:1}"
        local color="${colors[i * ${#colors[@]} / len]}"
        printf "%b%s%b" "$color" "$c" "$reset"
    done
    printf "\n"
}

# === Menu Items ===
options=("Create new config" "Load existing config" "Remove existing config" \
         "Manage SMTP Profiles" "Backup Project Assets" "Exit")

# === Main Menu Loop ===
while true; do
    print_header

    PS3="Choose an option: "
    set +u
    select opt in "${options[@]}"; do
        case $REPLY in
            1) create_new_profile ;;
            2) load_profile ;;
            3) remove_profile ;;
            4) manage_smtp_profiles ;;
            5) backup_project_assets ;;
            6) exit_program ;;
            *) warn "Invalid option, choose 1-${#options[@]}" ;;
        esac
        break
    done
    set -u
done
