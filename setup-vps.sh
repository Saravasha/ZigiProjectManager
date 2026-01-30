#!/usr/bin/env bash
set -euo pipefail

# === Colored Output Functions ===
info()    { echo -e "\033[1;34m[INFO]:🔍 $*\033[0m"; }
warn()    { echo -e "\033[1;33m[WARN]:⚠️ $*\033[0m"; }
error()   { echo -e "\033[1;31m[ERROR]:❌ $*\033[0m"; }
success() { echo -e "\033[1;32m[SUCCESS]:✅ $*\033[0m"; }
debug()   { echo -e "\033[38;5;208m[DEBUG]:⚙️ $*\033[0m"; }

# === Config Paths ===
CONFIG_DIR="$HOME/.vps-configs"
SMTP_PROFILE_DIR="$HOME/.smtp-profiles"
CLONE_PROFILE_DIR="$HOME/.clone-website-profiles"
BACKUP_BASE_DIR="$(cd "$(pwd)/.." && pwd)/vps-backups"

mkdir -p "$CONFIG_DIR" "$SMTP_PROFILE_DIR" "$CLONE_PROFILE_DIR" "$BACKUP_BASE_DIR"

# === Config State Handlers ===
CONFIG_LOADED=false

auto_detect_config() {
    shopt -s nullglob
    CONFIG_FILES=("$CONFIG_DIR"/*.env)
    shopt -u nullglob

    if [[ ${#CONFIG_FILES[@]} -gt 0 ]]; then
        CONFIG_LOADED=true
        CONFIG_FILE=$(basename "${CONFIG_FILES[0]}")  # optional: pick first one
        source "$CONFIG_DIR/$CONFIG_FILE"
        info "Auto-detected config: $CONFIG_FILE"
    else
        CONFIG_LOADED=false
    fi
}
auto_detect_config

init_profile_state() {
    : "${PROFILE_NAME:?PROFILE_NAME is not set}"

    PROFILE_JSON="$CLONE_PROFILE_DIR/$PROFILE_NAME.json"

    if [[ ! -f "$PROFILE_JSON" ]]; then
        error "Clone profile not found: $PROFILE_JSON"
        return 1
    fi
}


# === Helper Functions ===

confirm() {
    local r
    read -rp "⏳ $1 (y/n): " r || return 1
    [[ $r =~ ^[Yy]$ ]]
}

# === Functions ===

main_config() {

    info "Running Main Config loop..."
    CONFIG_PATH="$CONFIG_DIR/${CONFIG_FILE:?main_config requires CONFIG_FILE to be set}"

    # Prompt only if creating a new config
    if [[ ! -f "$CONFIG_PATH" ]]; then
    KEY_NAME="id_vps_key"
    KEY_PATH="$HOME/.ssh/$KEY_NAME"
    PUB_KEY="${KEY_PATH}.pub"

    # === Step 3: Ask User if SSH Key Setup Should Proceed ===
    info "Hi and welcome to the VPS Setup"

    if confirm "🔑 Do you want to generate a new SSH key and copy the public key to clipboard?"; then
        if [[ -f "$KEY_PATH" ]]; then
        warn "SSH key already exists at: $KEY_PATH"
        else
        info "🔐 Generating new SSH key at $KEY_PATH"
        ssh-keygen -t ed25519 -f "$KEY_PATH"
        fi

        if command -v pbcopy &>/dev/null; then
        pbcopy < "$PUB_KEY"
        success "Public key copied to clipboard (macOS)"
        elif grep -qi microsoft /proc/version && command -v clip.exe &>/dev/null; then
        cat "$PUB_KEY" | clip.exe
        success "Public key copied to clipboard (WSL)"
        elif command -v xclip &>/dev/null && [[ -n "${DISPLAY:-}" ]]; then
        xclip -selection clipboard < "$PUB_KEY"
        success "Public key copied to clipboard (X11)"
        elif command -v wl-copy &>/dev/null; then
        wl-copy < "$PUB_KEY"
        success "Public key copied to clipboard (Wayland)"
        else
        warn "Clipboard utility not available. Here's your public key:"
        echo
        cat "$PUB_KEY"
        fi
    else
        info "⏩ Skipping SSH key generation and clipboard copy."
    fi

    
    if confirm "⏳ Have you already pasted the public key into ~/.ssh/authorized_keys on your VPS?"; then
        success "Public key setup confirmed. Continuing..."
    else
        warn "Skipping key setup. Make sure the key is already added to the VPS before continuing."
    fi

    # === Step 4: Select clone-website profile ===
    # Force profile selection for new configs
    unset PROFILE_NAME  # ensure no previous value interferes

    shopt -s nullglob
    PROFILE_FILES=("$CLONE_PROFILE_DIR"/*.json)
    shopt -u nullglob

    PROFILE_OPTIONS=()
    for file in "${PROFILE_FILES[@]}"; do
        [[ -f "$file" ]] && PROFILE_OPTIONS+=("$(basename "$file" .json)")
    done

    if [[ ${#PROFILE_OPTIONS[@]} -eq 0 ]]; then
        warn "No clone-website profiles found. Create one first."
        return
    fi

    info "📂 Select a clone-website profile:"
    select PROFILE_NAME in "${PROFILE_OPTIONS[@]}" "❌ Cancel"; do
        if [[ "$REPLY" =~ ^[0-9]+$ ]] && [[ "$REPLY" -gt 0 && "$REPLY" -le "${#PROFILE_OPTIONS[@]}" ]]; then
            success "Using profile: $PROFILE_NAME"
            info "PROFILE_NAME=\"$PROFILE_NAME\"" >> "$CONFIG_PATH"
            break
        elif [[ "$PROFILE_NAME" == "❌ Cancel" ]]; then
            warn "Cancelled."
            return
        else
            warn "Invalid option."
        fi
    done

    # === Load repo names from JSON profile ===
    PROFILE_JSON="$CLONE_PROFILE_DIR/$PROFILE_NAME.json"
    REPO_NAME_1=$(jq -r .frontend "$PROFILE_JSON")
    REPO_NAME_2=$(jq -r .backend "$PROFILE_JSON")

    # === VPS + GitHub settings ===
    read -p "🌐 VPS IP or hostname: " VPS_IP
    read -p "👤 SSH username [default: root]: " SSH_USER
    SSH_USER=${SSH_USER:-root}

    read -s -p "🔐 STAGING MSSQL password: " STAGING_PASS; echo
    read -s -p "🔐 PRODUCTION MSSQL password: " PROD_PASS; echo

    read -rp "Enter your base domain (e.g. saravasha.com): " BASE_DOMAIN
    if [[ -z "$BASE_DOMAIN" ]]; then
        error "Base domain cannot be empty."
        return
    fi

    info "Using base domain: $BASE_DOMAIN"

    BASE_DOMAIN="${BASE_DOMAIN}"
    DOMAIN_FE_PROD="www.${BASE_DOMAIN}"
    DOMAIN_FE_STAGING="www.staging.${BASE_DOMAIN}"
    DOMAIN_BE_PROD="www.admin.${BASE_DOMAIN}"
    DOMAIN_BE_STAGING="www.admin-staging.${BASE_DOMAIN}"
    PRODUCTION_URL_TARGET="https://admin.${BASE_DOMAIN}/"

    read -s -p "🔐 Admin Password (Production): " ADMIN_PASSWORD; echo
    read -s -p "🔐 Admin Password (Staging): " ADMIN_PASSWORD_STAGING; echo

    read -p "👤 GitHub Username or Org (case-sensitive): " REPO_OWNER
    read -p "🔐 Paste your GitHub PAT (starts with 'ghp_'): " GITHUB_PAT
    read -p "📧 SSL Email (Let's Encrypt): " SSL_EMAIL

    # === SMTP Profile Selection / Creation ===
    shopt -s nullglob
    SMTP_PROFILES=("$SMTP_PROFILE_DIR"/*.json)
    shopt -u nullglob
    
    info "📧 Select an SMTP profile for this VPS config:"
    select SMTP_FILE in "${SMTP_PROFILES[@]}" "➕ Create new SMTP profile" "❌ Cancel"; do
        if [[ "$REPLY" -le ${#SMTP_PROFILES[@]} ]]; then
            success "Selected SMTP profile: $(basename "$SMTP_FILE")"
            SMTP_HOST=$(jq -r .host "$SMTP_FILE")
            SMTP_USERNAME=$(jq -r .username "$SMTP_FILE")
            SMTP_PASSWORD=$(jq -r .password "$SMTP_FILE")
            SMTP_FROM=$(jq -r .from "$SMTP_FILE")
            SMTP_PORT=$(jq -r .port "$SMTP_FILE")
            SMTP_PROFILE_NAME="$(basename "$SMTP_FILE")"
            break
        elif [[ "$REPLY" -eq $((${#SMTP_PROFILES[@]}+1)) ]]; then
            info "➕ Creating new SMTP profile..."
            read -rp "SMTP Host: " SMTP_HOST
            read -rp "SMTP Username: " SMTP_USERNAME
            read -srp "SMTP Password: " SMTP_PASSWORD; echo
            read -rp "SMTP From Email: " SMTP_FROM
            read -rp "SMTP Port: " SMTP_PORT
            SMTP_PROFILE_NAME="custom-$(date +%s)"
            NEW_PROFILE="$SMTP_PROFILE_DIR/$SMTP_PROFILE_NAME.json"
            jq -n \
                --arg host "$SMTP_HOST" \
                --arg username "$SMTP_USERNAME" \
                --arg password "$SMTP_PASSWORD" \
                --arg from "$SMTP_FROM" \
                --arg port "$SMTP_PORT" \
                '{host:$host,username:$username,password:$password,from:$from,port:$port}' > "$NEW_PROFILE"
            success "Created new SMTP profile: $SMTP_PROFILE_NAME"
            break
        elif [[ "$REPLY" -eq $((${#SMTP_PROFILES[@]}+2)) ]]; then
            warn "Cancelled."
            return
        else
            error "Invalid option."
        fi
    done

# === Persist config ===
cat > "$CONFIG_PATH" <<EOF
KEY_NAME="$KEY_NAME"
KEY_PATH="$KEY_PATH"
PUB_KEY="$PUB_KEY"
VPS_IP="$VPS_IP"
SSH_USER="$SSH_USER"
STAGING_PASS="$STAGING_PASS"
PROD_PASS="$PROD_PASS"
BASE_DOMAIN="$BASE_DOMAIN"
DOMAIN_FE_PROD="$DOMAIN_FE_PROD"
DOMAIN_FE_STAGING="$DOMAIN_FE_STAGING"
DOMAIN_BE_PROD="$DOMAIN_BE_PROD"
DOMAIN_BE_STAGING="$DOMAIN_BE_STAGING"
PRODUCTION_URL_TARGET="$PRODUCTION_URL_TARGET"
ADMIN_PASSWORD="$ADMIN_PASSWORD"
ADMIN_PASSWORD_STAGING="$ADMIN_PASSWORD_STAGING"
REPO_OWNER="$REPO_OWNER"
REPO_NAME_1="$REPO_NAME_1"
REPO_NAME_2="$REPO_NAME_2"
GITHUB_PAT="$GITHUB_PAT"
SSL_EMAIL="$SSL_EMAIL"

# clone-website profile reference
PROFILE_NAME="$PROFILE_NAME"

# SMTP Profile reference
SMTP_PROFILE_NAME="$SMTP_PROFILE_NAME"
SMTP_HOST="$SMTP_HOST"
SMTP_USERNAME="$SMTP_USERNAME"
SMTP_PASSWORD="$SMTP_PASSWORD"
SMTP_FROM="$SMTP_FROM"
SMTP_PORT="$SMTP_PORT"
EOF

        success "Config saved."
    else
        success "📂 Loaded existing config from $CONFIG_PATH"
        source "$CONFIG_PATH"

        init_profile_state || return
        CONFIG_LOADED=true
    fi

    if confirm "Do you want to continue to setting up the VPS with remote operations now?"; then
        success "Proceeding with Setup VPS..."
        setup_vps
    else
        info "⏩ Returning to Main Menu."
    fi
}

remove_profile() {
    info "🗑️ Remove a saved VPS config:"

    shopt -s nullglob
    EXISTING=("$CONFIG_DIR"/*.env)
    shopt -u nullglob

  if [ ${#EXISTING[@]} -eq 0 ]; then
    warn "No configs found to delete."
    return
  fi

  info "Choose a config to remove:"
  select f in "${EXISTING[@]}" "❌ Cancel"; do
    [[ -z "${f:-}" ]] && continue
    if [[ "$REPLY" -gt 0 && "$REPLY" -le "${#EXISTING[@]}" ]]; then
      if confirm "⚠️ Are you sure you want to delete $(basename "$f")?"; then
        rm -f "$f"
        success "Deleted: $(basename "$f")"
        return
      else
        warn "Deletion cancelled."
      fi
      break
    elif [[ "$f" == "❌ Cancel" ]]; then
      info "Cancelled."
      break
    else
      warn "Invalid option."
    fi
  done
 
}


remove_smtp_profile() {
  info "🗑️  Remove an SMTP profile:"

  shopt -s nullglob
  SMTP_PROFILES=("$SMTP_PROFILE_DIR"/*.json)
  shopt -u nullglob

  if [[ ${#SMTP_PROFILES[@]} -eq 0 ]]; then
    warn "No SMTP profiles found."
    return
  fi

  info "Choose an SMTP profile to delete:"
  select f in "${SMTP_PROFILES[@]}" "❌ Cancel"; do
    [[ -z "${f:-}" ]] && continue
    if [[ "$REPLY" -gt 0 && "$REPLY" -le "${#SMTP_PROFILES[@]}" ]]; then
      PROFILE_NAME="$(basename "$f")"
      if confirm "⚠️ Are you sure you want to delete $PROFILE_NAME?"; then
        rm -f "$f"
        success "Deleted SMTP profile: $PROFILE_NAME"
      else
        warn "Deletion cancelled."
      fi
      break
    elif [[ "$f" == "❌ Cancel" ]]; then
      warn "Cancelled."
      break
    else
      error "Invalid option."
    fi
  done

}

load_profile() {

    info "Load saved config"

    shopt -s nullglob
    CONFIG_FILES=("$CONFIG_DIR"/*.env)
    shopt -u nullglob

      CONFIG_OPTIONS=()
      for file in "${CONFIG_FILES[@]}"; do
        [[ -f "$file" ]] && CONFIG_OPTIONS+=("$(basename "$file")")
      done

      if [[ ${#CONFIG_OPTIONS[@]} -eq 0 ]]; then
        error "No saved configs to load."
        return
      fi

      info "Choose a saved configuration to load:"
      select conf in "${CONFIG_OPTIONS[@]}" "❌ Cancel"; do
        if [[ "$REPLY" -gt 0 && "$REPLY" -le "${#CONFIG_OPTIONS[@]}" ]]; then
          CONFIG_FILE="${CONFIG_OPTIONS[$((REPLY - 1))]}"
          success "Loading saved config: $CONFIG_FILE"
          source "$CONFIG_DIR/$CONFIG_FILE"
          CONFIG_LOADED=true
          init_profile_state || return
          main_config
          return # exit both select loops
        elif [[ "$conf" == "❌ Cancel" ]]; then
          warn "Cancelled."
          return
        else
          warn "Invalid option."
        fi
      done
}

manage_smtp_profiles() {
    info "Manage SMTP Profiles"
      shopt -s nullglob
      SMTP_PROFILES=("$SMTP_PROFILE_DIR"/*.json)
      shopt -u nullglob

      if [ ${#SMTP_PROFILES[@]} -eq 0 ]; then
          info "⚠️ No SMTP profiles found. Let's create one now."
          CREATE_NEW_SMTP=true
      else
          CREATE_NEW_SMTP=false
      fi

      while true; do
          if $CREATE_NEW_SMTP; then
              info "📧 Creating a new SMTP profile..."
              read -rp "Enter a profile name (e.g. default): " SMTP_NAME
              read -rp "SMTP host: " SMTP_HOST
              read -rp "SMTP username: " SMTP_USERNAME
              read -srp "SMTP password: " SMTP_PASSWORD; echo
              read -rp "From email address: " SMTP_FROM
              read -rp "SMTP port [587]: " SMTP_PORT
              SMTP_PORT=${SMTP_PORT:-587}

              SMTP_FILE="$SMTP_PROFILE_DIR/${SMTP_NAME}.json"
              cat > "$SMTP_FILE" <<EOF
{
  "host": "$SMTP_HOST",
  "username": "$SMTP_USERNAME",
  "password": "$SMTP_PASSWORD",
  "from": "$SMTP_FROM",
  "port": $SMTP_PORT
}
EOF
              success "SMTP profile saved to $SMTP_FILE"
              break
          else
              info "📧 Select an SMTP profile for this VPS:"
              select SMTP_FILE in "${SMTP_PROFILES[@]}" "Create new profile" "Delete a profile" "❌ Cancel"; do
                  if [[ "$REPLY" -gt 0 && "$REPLY" -le "${#SMTP_PROFILES[@]}" ]]; then
                      success "Using SMTP profile: $SMTP_FILE"
                      return
                  elif [[ "$REPLY" -eq $((${#SMTP_PROFILES[@]} + 1)) ]]; then
                      CREATE_NEW_SMTP=true
                      break
                  elif [[ "$REPLY" -eq $((${#SMTP_PROFILES[@]} + 2)) ]]; then
                      remove_smtp_profile
                      SMTP_PROFILES=("$SMTP_PROFILE_DIR"/*.json)
                      break
                  elif [[ "$REPLY" -eq $((${#SMTP_PROFILES[@]} + 3)) ]]; then
                      warn "Cancelled."
                      return
                  else
                      warn "Invalid option."
                  fi
              done
          fi
      done
}

create_new_profile() {
    info "Create new config"
    read -rp "Enter a name for your new config (e.g. Example): " CONFIG_NAME
    CONFIG_FILE="${CONFIG_NAME}.env"
    info "Creating new config: $CONFIG_NAME"
    main_config
}

setup_vps() {

    if ! $CONFIG_LOADED; then
        error "No config loaded. Please create or load a config first."
        return
    fi

    info "Running VPS setup..."
    
    info "Choose Certbot mode:"
    info "1) Staging (testing, no rate limits) - When running the onboarder for the first time use Staging, use Production afterwards."
    info "2) Production (live certificates)"
    info "3) Skip (You know what you're doing)"
    read -rp "Enter choice [1, 2 or 3]: " cert_mode

    if [[ "$cert_mode" == "2" ]]; then
        info "🔐 Running Certbot interactively in PRODUCTION mode..."
        ssh -t -i "$KEY_PATH" "$SSH_USER@$VPS_IP" 'sudo certbot'
        success "Certbot finished. Exiting."
        return
    elif [[ "$cert_mode" == "3" ]]; then
      info "⏭️ Skipping Certbot setup. You must configure certificates manually."
      certbot_args="SKIP_CERTBOT"
    else
        certbot_args="--staging"
        info "Running Certbot in STAGING mode at the near end of setup."
    fi


    NODE_VERSION=$(jq -r '.runtimes.node // empty' "$PROFILE_JSON")
    DOTNET_VERSION=$(jq -r '.runtimes.dotnet // empty' "$PROFILE_JSON")

    [[ -z "$NODE_VERSION" ]] && NODE_VERSION="18"
    [[ -z "$DOTNET_VERSION" ]] && DOTNET_VERSION="8.0"
    NODE_VERSION="${NODE_VERSION#v}"
    NODE_MAJOR="${NODE_VERSION%%.*}"
    DOTNET_SDK_VERSION="${DOTNET_VERSION#net}"
    
    # debug "$NODE_MAJOR"
    # debug "$DOTNET_SDK_VERSION"

# === Step 5: SSH and Setup ===
ssh -t -i "$KEY_PATH" "$SSH_USER@$VPS_IP" sudo -E bash -s -- \
  "$VPS_IP" "$PROD_PASS" "$STAGING_PASS" "$ADMIN_PASSWORD" "$ADMIN_PASSWORD_STAGING" \
  "$PRODUCTION_URL_TARGET" "$REPO_OWNER" "$REPO_NAME_1" "$REPO_NAME_2" "$GITHUB_PAT" \
  "$SSL_EMAIL" "$BASE_DOMAIN" "$DOMAIN_FE_PROD" "$DOMAIN_FE_STAGING" "$DOMAIN_BE_PROD" "$DOMAIN_BE_STAGING" "$certbot_args" \
  "$SMTP_HOST" "$SMTP_USERNAME" "$SMTP_PASSWORD" "$SMTP_FROM" "$SMTP_PORT" "$PROFILE_NAME" "$NODE_MAJOR" "$DOTNET_SDK_VERSION" <<'EOF_SCRIPT'

# === re-implementing Colorized echo functions inside heredoc ===
info()    { echo -e "\033[1;34m[INFO]:🔍 $*\033[0m"; }
warn()    { echo -e "\033[1;33m[WARN]:⚠️ $*\033[0m"; }
error()   { echo -e "\033[1;31m[ERROR]:❌ $*\033[0m"; }
success() { echo -e "\033[1;32m[SUCCESS]:✅ $*\033[0m"; }
debug()   { echo -e "\033[38;5;208m[DEBUG]:⚙️ $*\033[0m"; }

if [[ $EUID -ne 0 ]]; then
  error "Remote script is NOT running as root"
  exit 1
fi


set -eu
trap 'echo "❌ Setup failed at line $LINENO"; exit 1' ERR

VPS_IP="$1"
PROD_PASS="$2"
STAGING_PASS="$3"
ADMIN_PASSWORD="$4"
ADMIN_PASSWORD_STAGING="$5"
PRODUCTION_URL_TARGET="$6"
REPO_OWNER="$7"
REPO_NAME_1="$8"
REPO_NAME_2="$9"
GITHUB_PAT="${10}"
SSL_EMAIL="${11}"
BASE_DOMAIN="${12}"
DOMAIN_FE_PROD="${13}"
DOMAIN_FE_STAGING="${14}"
DOMAIN_BE_PROD="${15}"
DOMAIN_BE_STAGING="${16}"
certbot_args="${17:-SKIP_CERTBOT}"
SMTP_HOST="${18}"
SMTP_USERNAME="${19}"
SMTP_PASSWORD="${20}"
SMTP_FROM="${21}"
SMTP_PORT="${22}"
PROFILE_NAME="${23}"
NODE_MAJOR="${24:-}"
DOTNET_SDK_VERSION="${25:-}"


cleanup_old_runners() {
    info "🔍 Cleaning up old GitHub Actions runners..."

    # Stop and remove old systemd services
    for SERVICE in /etc/systemd/system/actions.runner.*.service; do
        [[ -f "$SERVICE" ]] || continue
        SERVICE_NAME=$(basename "$SERVICE")
        warn "Stopping and disabling service: $SERVICE_NAME"
        systemctl stop "$SERVICE_NAME" || true
        systemctl disable "$SERVICE_NAME" || true
        rm -f "$SERVICE"
        success "Removed service file: $SERVICE_NAME"
    done

    # Remove old runner directories
    for DIR in /opt/actions-runners/*; do
        [[ -d "$DIR" ]] || continue
        warn "Removing folder: $DIR"
        rm -rf "$DIR"
        success "Removed: $DIR"
    done

    # Reload systemd
    info "🔄 Reloading systemd daemon..."
    systemctl daemon-reload
    success "Old runners cleaned up."
}

# Set environment file
ENV_FILE="/etc/myapp_${REPO_OWNER}.env"

# Check if running as root
if [[ "$(id -u)" -ne 0 ]]; then
  error "This script must be run as root. Exiting."
  exit 1
fi

SAFE_REPO_OWNER=$(echo "$REPO_OWNER" | tr -cd '[:alnum:]_-')
ENV_FILE="/etc/myapp_${SAFE_REPO_OWNER}.env"

info "🔄 Updating package index..."
apt update -y

info "Install docker.io only if not installed"
if ! dpkg -s docker.io &>/dev/null; then
  apt install -y docker.io
else
  info "docker.io already installed, skipping."
fi

info "Install nginx only if not installed"
if ! dpkg -s nginx &>/dev/null; then
  apt install -y nginx
else
  info "nginx already installed, skipping."
fi

info "Configurating Nginx file limit to 400M"
NGINX_CONF="/etc/nginx/nginx.conf"
LINE="client_max_body_size 400M;"

if grep -qF "$LINE" "$NGINX_CONF"; then
  success "'client_max_body_size' already present in nginx.conf"
else
  info "➕ Adding 'client_max_body_size 400M;' to nginx.conf"
  # Insert inside the http block
  sed -i "/http {/a \    $LINE" "$NGINX_CONF"
fi

info "Install certbot and python3-certbot-nginx if missing"
for pkg in certbot python3-certbot-nginx ffmpeg curl apt-transport-https software-properties-common jq; do
  if ! dpkg -s $pkg &>/dev/null; then
    apt install -y $pkg
  else
    info "$pkg already installed, skipping."
  fi
done

systemctl enable --now docker
systemctl enable --now nginx

info "📦 Checking/installing required Python dependencies..."

# Ensure Python 3 and pip are installed
if ! command -v python3 >/dev/null 2>&1; then
  error "Python3 is not installed. Please install Python 3 manually."
  exit 1
fi

if ! command -v pip3 >/dev/null 2>&1; then
  info "⚙️ Installing pip3..."
  sudo apt-get update -qq
  sudo apt-get install -y python3-pip
fi

info "Ensure PyNaCl is installed for GitHub secrets encryption"
if ! python3 -c "import nacl" >/dev/null 2>&1; then
  info "⚙️ Installing PyNaCl for secrets encryption..."
  pip3 install pynacl --quiet
else
  info "✅ PyNaCl already installed"
fi

info "🔄 Installing Node.js v$NODE_MAJOR"

if ! command -v node &>/dev/null || [[ "$(node -v)" != v$NODE_MAJOR.* ]]; then
  curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash -E -
  apt-get install -y nodejs
else
  info "Node.js $(node -v) already installed."
fi

info "🔄 Installing pm2 globally only if not installed"
if ! command -v pm2 &>/dev/null; then
  info "Installing pm2 globally"
  npm install -g pm2
else
  info "pm2 already installed globally."
fi

info "⬇️ Installing .NET SDK $DOTNET_SDK_VERSION"

if ! command -v dotnet &>/dev/null; then
  wget -q https://packages.microsoft.com/config/ubuntu/22.04/packages-microsoft-prod.deb
  dpkg -i packages-microsoft-prod.deb && rm packages-microsoft-prod.deb
  apt-get update
  apt-get install -y dotnet-sdk-$DOTNET_SDK_VERSION
else
  DOTNET_INSTALLED=$(dotnet --version)
  if [[ "$DOTNET_INSTALLED" != $DOTNET_SDK_VERSION* ]]; then
    info "Updating .NET SDK to net$DOTNET_SDK_VERSION"
    apt-get install -y dotnet-sdk-$DOTNET_SDK_VERSION
  else
    info ".NET SDK $DOTNET_INSTALLED already installed"
  fi
fi


info "🔐 Configuring UFW firewall rules..."

# Enable UFW if not already enabled
if ! ufw status | grep -q "Status: active"; then
  info "🔧 Enabling UFW..."
  ufw --force enable
fi

# Function to safely allow a rule only if it doesn't exist
allow_if_not_exists() {
  local rule="$1"
  if ! ufw status | grep -qw "$rule"; then
    success "Allowing: $rule"
    ufw allow "$rule"
  else
    info "⏭️ Rule already exists: $rule"
  fi
}

# Allow rules only if not already present
allow_if_not_exists "OpenSSH"
allow_if_not_exists "Nginx Full"
allow_if_not_exists "1433/tcp"
allow_if_not_exists "1434/tcp"

info "💾 Writing environment variables to $ENV_FILE..."

cat > "$ENV_FILE" <<EOF_ENV
# Shared
Smtp__Host="$SMTP_HOST"
Smtp__Username="$SMTP_USERNAME"
Smtp__Password="$SMTP_PASSWORD"
Smtp__From="$SMTP_FROM"
Smtp__Port="$SMTP_PORT"

# Production
CONNECTION_STRING="Data Source=$VPS_IP,1434;Database=production_db;User ID=sa;Password=$PROD_PASS;Encrypt=True;Trust Server Certificate=True"
ADMIN_PASSWORD="$ADMIN_PASSWORD"
PRODUCTION_URL_TARGET="$PRODUCTION_URL_TARGET"

# Staging
CONNECTION_STRING_STAGING="Data Source=$VPS_IP,1433;Database=staging_db;User ID=sa;Password=$STAGING_PASS;Encrypt=True;Trust Server Certificate=True"
ADMIN_PASSWORD_STAGING="$ADMIN_PASSWORD_STAGING"

# Default runtime
DOTNET_ENVIRONMENT="Production"
ASPNETCORE_ENVIRONMENT="Production"
EOF_ENV

chmod 600 "$ENV_FILE"
chown root:root "$ENV_FILE"

# Add sourcing of env file to root's bashrc if not already present
if ! grep -Fxq "source $ENV_FILE" ~/.bashrc; then
  echo "source $ENV_FILE" >> ~/.bashrc
fi

# Patch systemd runner services to load environment file (run once before loop)
info "🔧 Patching existing GitHub Actions runner systemd services to load env variables..."
for SERVICE_PATH in /etc/systemd/system/actions.runner.*.service; do
  if [[ -f "$SERVICE_PATH" ]] && ! grep -q "^EnvironmentFile=$ENV_FILE" "$SERVICE_PATH"; then
    sed -i "/^\[Service\]/a EnvironmentFile=$ENV_FILE" "$SERVICE_PATH"
  fi
done
systemctl daemon-reload

# Source env file for current script run
source "$ENV_FILE"

# Run MSSQL Docker containers
info "🐳 Starting MSSQL Docker containers..."

if ! docker ps -q -f name=sqlserver_production | grep -q .; then
  if docker ps -aq -f name=sqlserver_production | grep -q .; then
    docker start sqlserver_production
  else
    docker run -d --name sqlserver_production \
      -e 'ACCEPT_EULA=Y' -e "MSSQL_SA_PASSWORD=$PROD_PASS" \
      -e 'MSSQL_PID=Express' -v sqlservervol_production:/var/opt/mssql \
      -p 1434:1433 --restart=always \
      mcr.microsoft.com/mssql/server:2019-latest || true
  fi
else
  info "sqlserver_production container is already running."
fi

if ! docker ps -q -f name=sqlserver_staging | grep -q .; then
  if docker ps -aq -f name=sqlserver_staging | grep -q .; then
    docker start sqlserver_staging
  else
    docker run -d --name sqlserver_staging \
      -e 'ACCEPT_EULA=Y' -e "MSSQL_SA_PASSWORD=$STAGING_PASS" \
      -e 'MSSQL_PID=Express' -v sqlservervol_staging:/var/opt/mssql \
      -p 1433:1433 --restart=always \
      mcr.microsoft.com/mssql/server:2019-latest || true
  fi
else
  info "sqlserver_staging container is already running."
fi

info "Installing MSSQL Tools..."
for c in sqlserver_production sqlserver_staging; do
  docker exec -u 0 "$c" bash -c '
    if ! command -v sqlcmd >/dev/null 2>&1; then
        echo "Installing mssql-tools in $HOSTNAME..."

        apt update
        apt install -y curl apt-transport-https gnupg

        curl https://packages.microsoft.com/keys/microsoft.asc \
          | gpg --dearmor > /usr/share/keyrings/microsoft.gpg

        echo "deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft.gpg] \
https://packages.microsoft.com/ubuntu/20.04/prod focal main" \
          > /etc/apt/sources.list.d/mssql-release.list

        apt update
        ACCEPT_EULA=Y apt install -y mssql-tools unixodbc-dev

        echo "export PATH=\$PATH:/opt/mssql-tools/bin" >> /etc/profile
    else
        echo "mssql-tools already installed in $HOSTNAME"
    fi
  '
done

info "🔗 Ensuring sqlcmd is on PATH inside MSSQL containers..."

for c in sqlserver_production sqlserver_staging; do
  info "➡️  Configuring $c"

  docker exec -u 0 "$c" bash -c '
    if [ -x /opt/mssql-tools/bin/sqlcmd ]; then
      ln -sf /opt/mssql-tools/bin/sqlcmd /usr/local/bin/sqlcmd
      echo "✅ sqlcmd symlinked in /usr/local/bin"
    else
      echo "❌ sqlcmd not found in /opt/mssql-tools/bin"
      exit 1
    fi
  '
done


set -euo pipefail

# Set GitHub Secrets to Repositories
# 🔧 Configuration

REPO_FRONTEND="$REPO_NAME_1"
REPO_BACKEND="$REPO_NAME_2"

# === Repo-Wide Secrets ===

# Backend (shared + environment-specific)
declare -A SECRETS_BACKEND=(
  ["SMTP_HOST"]="$SMTP_HOST"
  ["SMTP_USERNAME"]="$SMTP_USERNAME"
  ["SMTP_PASSWORD"]="$SMTP_PASSWORD"
  ["SMTP_FROM"]="$SMTP_FROM"
  ["SMTP_PORT"]="$SMTP_PORT"
  ["CONNECTION_STRING"]="Data Source=$VPS_IP,1434;Database=production_db;User ID=sa;Password=$PROD_PASS;Encrypt=True;Trust Server Certificate=True"
  ["CONNECTION_STRING_STAGING"]="Data Source=$VPS_IP,1433;Database=staging_db;User ID=sa;Password=$STAGING_PASS;Encrypt=True;Trust Server Certificate=True"
  ["ADMIN_PASSWORD"]="$ADMIN_PASSWORD"
  ["ADMIN_PASSWORD_STAGING"]="$ADMIN_PASSWORD_STAGING"
)

# Frontend (staging specific)
declare -A SECRETS_FRONTEND=(
  ["VITE_ENVIRONMENT_STAGING"]="staging"
)

# === FUNCTIONS ===

encrypt_secret() {
  python3 - <<EOF "$1" "$2"
import base64, sys
from nacl import encoding, public

public_key = sys.argv[1]
secret_value = sys.argv[2]

pk = public.PublicKey(base64.b64decode(public_key), encoding.RawEncoder())
sealed_box = public.SealedBox(pk)
encrypted = sealed_box.encrypt(secret_value.encode("utf-8"))
print(base64.b64encode(encrypted).decode("utf-8"))
EOF
}

add_or_update_secret() {
  local repo="$1"
  local secret_name="$2"
  local secret_value="$3"

  info "🔐 Uploading [$secret_name] to [$repo]..."

  local pubkey_json public_key key_id
  pubkey_json=$(curl -s -H "Authorization: token $GITHUB_PAT" \
    "https://api.github.com/repos/$REPO_OWNER/$repo/actions/secrets/public-key")
  public_key=$(echo "$pubkey_json" | jq -r '.key')
  key_id=$(echo "$pubkey_json" | jq -r '.key_id')

  if [[ "$public_key" == "null" || "$key_id" == "null" ]]; then
    error "Failed to get public key for $repo"
    return 1
  fi

  encrypted_value=$(encrypt_secret "$public_key" "$secret_value")

  curl -s -X PUT -H "Authorization: token $GITHUB_PAT" \
    -H "Content-Type: application/json" \
    -d "{\"encrypted_value\":\"$encrypted_value\",\"key_id\":\"$key_id\"}" \
    "https://api.github.com/repos/$REPO_OWNER/$repo/actions/secrets/$secret_name" > /dev/null

  success "Secret [$secret_name] uploaded to [$repo]"
}

add_secrets_to_repo() {
  local repo="$1"
  declare -n secrets=$2

  info "📦 Setting secrets for repo: $repo"
  for key in "${!secrets[@]}"; do
    add_or_update_secret "$repo" "$key" "${secrets[$key]}"
  done
}

# === Upload ===
info "🚀 Uploading repo-wide secrets..."

add_secrets_to_repo "$REPO_BACKEND" SECRETS_BACKEND
add_secrets_to_repo "$REPO_FRONTEND" SECRETS_FRONTEND

# GitHub Actions Runners setup
declare -A REPO_MAP=(
  ["frontend"]="$REPO_NAME_1"
  ["backend"]="$REPO_NAME_2"
)

cleanup_old_runners

for APP_LABEL in frontend backend; do
  for ENV in staging production; do
    REPO_NAME="${REPO_MAP[$APP_LABEL]}"
    DIR="/opt/actions-runners/${APP_LABEL}-${ENV}"
    CAP_ENV="$(tr '[:lower:]' '[:upper:]' <<< ${ENV:0:1})${ENV:1}"
    LABELS="${APP_LABEL},${CAP_ENV},vps"

    info "⚙️ Setting up GitHub Actions runner in $DIR..."
    info "   - Repo: $REPO_OWNER/$REPO_NAME"
    info "   - Name: ${APP_LABEL}-${ENV}"
    info "   - Labels: $LABELS"

    if [[ -z "$LABELS" ]]; then
      warn "ERROR: LABELS variable is empty. Skipping runner registration."
      continue
    fi

    mkdir -p "$DIR"
    cd "$DIR"

    export RUNNER_ALLOW_RUNASROOT=1

    # Skip if already configured
    if [[ -f config.sh ]] && [[ -f .runner ]]; then
      warn "Runner already configured at $DIR. Restarting service if needed..."

      SERVICE_NAME="actions.runner.${REPO_OWNER}-${REPO_NAME//\//.}.${APP_LABEL}-${ENV}.service"
      SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}"

      if [[ ! -f "$SERVICE_PATH" ]]; then
        warn "Missing service file. Reinstalling..."
        ./svc.sh install
        systemctl daemon-reexec
        systemctl start "$SERVICE_NAME"
      else
        info "🔄 Restarting runner service: $SERVICE_NAME"
        systemctl daemon-reexec
        systemctl restart "$SERVICE_NAME"
      fi
      continue
    fi

    info "⬇️ Downloading GitHub Actions runner..."
    curl -sL -o runner.tar.gz https://github.com/actions/runner/releases/download/v2.316.1/actions-runner-linux-x64-2.316.1.tar.gz
    tar xzf runner.tar.gz && rm runner.tar.gz

    info "🔐 Requesting GitHub runner token..."
    TOKEN=$(curl -s -X POST \
      -H "Authorization: token $GITHUB_PAT" \
      "https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/actions/runners/registration-token" \
      | jq -r '.token // empty')

    if [[ -z "$TOKEN" ]]; then
      error "Failed to get runner registration token for $REPO_OWNER/$REPO_NAME"
      exit 1
    fi

    info "🛠 Registering runner..."
    ./config.sh --unattended --replace \
      --url "https://github.com/$REPO_OWNER/$REPO_NAME" \
      --token "$TOKEN" \
      --name "${APP_LABEL}-${ENV}" \
      --labels "$LABELS" | tee config.log

    info "🧩 Installing and starting runner service..."
    ./svc.sh install
    ./svc.sh start

    success "Runner for $APP_LABEL-$ENV configured."

    # Optional: GitHub API check
    info "Verifying runner registration..."
    curl -s -H "Authorization: token $GITHUB_PAT" \
      "https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/actions/runners" \
      | jq -r '.runners[] | [.name, (.labels | map(.name) | join(","))] | @tsv' \
      | grep "${APP_LABEL}-${ENV}" || echo "⚠️ Runner not found via GitHub API."

    echo
  done
done

info "📁 Copying built frontend apps into Nginx target directories..."

mkdir -p /opt/apps

for ENV in production staging; do
  REPO_NAME="$REPO_NAME_1"
  RUNNER_WORK_DIR="/opt/actions-runners/frontend-${ENV}/_work/${REPO_NAME}/${REPO_NAME}"
  DIST_DIR="${RUNNER_WORK_DIR}/dist"
  TARGET_DIR="/opt/apps/frontend-${ENV}"

  info "Checking build folder for frontend-${ENV}..."

  if [[ ! -d "$DIST_DIR" ]]; then
    error "Build folder not found at: $DIST_DIR"
    warn "Make sure your GitHub Actions workflow builds the frontend before syncing here."
    continue
  fi

  info "📦 Copying frontend-${ENV} dist to $TARGET_DIR..."
  mkdir -p "$TARGET_DIR"
  cp -a "${DIST_DIR}/." "$TARGET_DIR/"

  success "frontend-${ENV} build copied to $TARGET_DIR"
done

# Running PM2 apps

info "🚀 Starting backend PM2 apps..."

for ENV in production staging; do
  APP="backend"
  REPO_VAR="REPO_NAME_2"
  REPO_NAME="${!REPO_VAR}"
  APP_NAME="${APP}-${ENV}"

  RUNNER_PATH="/opt/actions-runners/${APP}-${ENV}/_work/${REPO_NAME}/${REPO_NAME}"
  DLL_PATH="${RUNNER_PATH}/WebAppBackend.dll"

  if [[ ! -f "$DLL_PATH" ]]; then
    error "DLL not found at $DLL_PATH. Skipping $APP_NAME."
    continue
  fi

  # Set environment-specific variables
  if [[ "$ENV" == "staging" ]]; then
    DOTNET_ENVIRONMENT="Staging"
    ASPNETCORE_ENVIRONMENT="Staging"
    FINAL_CONNECTION_STRING="$CONNECTION_STRING_STAGING"
    FINAL_ADMIN_PASSWORD="$ADMIN_PASSWORD_STAGING"
  else
    DOTNET_ENVIRONMENT="Production"
    ASPNETCORE_ENVIRONMENT="Production"
    FINAL_CONNECTION_STRING="$CONNECTION_STRING"
    FINAL_ADMIN_PASSWORD="$ADMIN_PASSWORD"
  fi

  info "Checking PM2 process: $APP_NAME..."
  PM2_STATUS=$(pm2 jlist | jq -r ".[] | select(.name==\"$APP_NAME\") | .pm2_env.status" 2>/dev/null || echo "")

  if [[ -z "$PM2_STATUS" ]]; then
    success "Starting $APP_NAME with PM2..."
    info "DEBUG: Running: pm2 start \"$DLL_PATH\" --name \"$APP_NAME\" --interpreter dotnet --update-env"

    # Ensure SMTP env vars are assigned
    Smtp__Host="${Smtp__Host}"
    Smtp__Username="${Smtp__Username}"
    Smtp__Password="${Smtp__Password}"
    Smtp__From="${Smtp__From}"
    Smtp__Port="${Smtp__Port}"

    export DOTNET_ENVIRONMENT ASPNETCORE_ENVIRONMENT CONNECTION_STRING ADMIN_PASSWORD \
          Smtp__Host Smtp__Username Smtp__Password Smtp__From Smtp__Port

    pm2 start "$DLL_PATH" \
      --name "$APP_NAME" \
      --interpreter dotnet \
      --update-env

  elif [[ "$PM2_STATUS" == "stopped" || "$PM2_STATUS" == "errored" ]]; then
    info "♻️ Restarting $APP_NAME (status: $PM2_STATUS)..."
    pm2 restart "$APP_NAME"
  else
    info "⏭️ $APP_NAME already running (status: $PM2_STATUS). Skipping."
  fi
done

info "💾 Saving PM2 process list so 'pm2 resurrect' can work later"

pm2 startup systemd
pm2 save --update-env

info "🚀 Running a Github Action Workflow"

ENVIRONMENTS=("staging" "production")

trigger_workflow() {
  local repo_name=$1
  local workflow_file=$2
  info "Triggering workflow $workflow_file on repo $repo_name"
  
  curl -s -X POST \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer $GITHUB_PAT" \
    "https://api.github.com/repos/$REPO_OWNER/$repo_name/actions/workflows/$workflow_file/dispatches" \
    -d '{"ref":"main"}'
  
  success "Triggered $workflow_file on $repo_name"
}

for env in "${ENVIRONMENTS[@]}"; do
  repo1="${REPO_NAME_1}"
  repo2="${REPO_NAME_2}"
  
  if [[ "$env" == "staging" ]]; then
    workflow_file="deploy-dev.yml"      # dev -> staging workflow
  elif [[ "$env" == "production" ]]; then
    workflow_file="deploy-staging.yml"  # staging -> production workflow
  else
    error "Unknown environment: $env"
    continue
  fi

  trigger_workflow "$repo1" "$workflow_file"
  trigger_workflow "$repo2" "$workflow_file"
  
done

success "Workflows done!"

info "🔧 Starting Nginx + Certbot setup"

set -euo pipefail

# Domains mapping
declare -A REPO_ENV_PATHS=(
  ["frontend-production"]="/opt/apps/frontend-production"
  ["frontend-staging"]="/opt/apps/frontend-staging"
  ["backend-production"]="backend"
  ["backend-staging"]="backend"
)

declare -A BACKEND_PORTS=(
  ["backend-production"]=5002
  ["backend-staging"]=5001
)

declare -A DOMAIN_MAP=(
  ["frontend-production"]="$BASE_DOMAIN"
  ["backend-production"]="admin.$BASE_DOMAIN"
  ["frontend-staging"]="staging.$BASE_DOMAIN"
  ["backend-staging"]="admin-staging.$BASE_DOMAIN"
)

# 1. Clean up old configs and certs
rm -rf /etc/nginx/sites-enabled/*
rm -rf /etc/nginx/sites-available/*
rm -rf /etc/letsencrypt/live/*
rm -rf /etc/letsencrypt/archive/*
rm -rf /etc/letsencrypt/renewal/*
rm -f /etc/letsencrypt/options-ssl-nginx.conf /etc/letsencrypt/ssl-dhparams.pem

# 2. Install packages
apt update
apt install -y nginx certbot python3-certbot-nginx
systemctl enable nginx
systemctl start nginx

# 3. Generate HTTP-only Nginx configs
for env in "${!REPO_ENV_PATHS[@]}"; do
  domain="${DOMAIN_MAP[$env]}"
  config_name="$(echo "$env" | tr '_' '-')"
  config_path="/etc/nginx/sites-available/$config_name"
  path="${REPO_ENV_PATHS[$env]}"
  is_backend=false
  [[ "$path" == "backend" ]] && is_backend=true

  cat > "$config_path" <<EOF
server {
    listen 80;
    server_name $domain www.$domain;
EOF

  if $is_backend; then
    port="${BACKEND_PORTS[$env]}"
    cat >> "$config_path" <<EOF
    location / {
        proxy_pass http://localhost:$port;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection keep-alive;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
    }
EOF
  else
    cat >> "$config_path" <<EOF
    root $path;
    index index.html;
    location / {
        try_files \$uri /index.html;
    }
EOF
  fi

  echo "}" >> "$config_path"
  ln -sf "$config_path" "/etc/nginx/sites-enabled/$config_name"
done

info "🔄4. Testing Nginx configuration and reloading..."
NGINX_OUTPUT=$(nginx -t 2>&1)
if [[ $? -eq 0 ]]; then
    success "$NGINX_OUTPUT"
    systemctl reload nginx
else
    error "$NGINX_OUTPUT"
    exit 1
fi

# 5. Run certbot with nginx plugin to install certs and enable HTTPS if needed
if [[ "$certbot_args" != "SKIP_CERTBOT" ]]; then
    info "➡️ Running certbot with args: [$certbot_args]"
    for env in "${!DOMAIN_MAP[@]}"; do
        domain="${DOMAIN_MAP[$env]}"
        cert_name="${domain//./_}"
        primary_domain="$domain"
        www_domain="www.$domain"

        info "🔍 Checking if certificate for $domain already exists..."

        if certbot certificates --cert-name "$cert_name" 2>&1 | grep -q "Certificate Name: $cert_name"; then
            info "✅ Certificate for [$domain] already exists, skipping issuance."
        else
            info "🔐 Issuing new certificate for [$domain] and [$www_domain]..."
            certbot --nginx --non-interactive $certbot_args --agree-tos --redirect \
                --email "$SSL_EMAIL" -d "$primary_domain" -d "$www_domain" --cert-name "$cert_name"
            success "Certificate successfully created for [$domain]"
            sleep 10
        fi
    done
else
    info "⏭️ Skipping Certbot inside heredoc (dummy arg detected)"
fi


success "SSL setup complete for all environments."
echo

info "🔑 Summary of environment variables (keep these safe):"
echo

info "🌐 Production:"
info "  PRODUCTION_URL_TARGET: \033[1;36m$PRODUCTION_URL_TARGET\033[0m"
info "  ADMIN_PASSWORD:        \033[1;31m$ADMIN_PASSWORD\033[0m"
info "  CONNECTION_STRING:     \033[1;35m$CONNECTION_STRING\033[0m"

info "🌐 Staging:"
info "  ADMIN_PASSWORD_STAGING:   \033[1;31m$ADMIN_PASSWORD_STAGING\033[0m"
info "  CONNECTION_STRING_STAGING: \033[1;35m$CONNECTION_STRING_STAGING\033[0m"

info "📦 Repositories:"
info "  REPO_OWNER:  \033[1;36m$REPO_OWNER\033[0m"
info "  REPO_NAME_1: \033[1;36m$REPO_NAME_1\033[0m"
info "  REPO_NAME_2: \033[1;36m$REPO_NAME_2\033[0m"

info "🔐 Credentials:"
info "  GITHUB_PAT:   \033[1;31m$GITHUB_PAT\033[0m"
info "  SSL_EMAIL:    \033[1;32m$SSL_EMAIL\033[0m"
info "  STAGING_PASS: \033[1;31m$STAGING_PASS\033[0m"
info "  PROD_PASS:    \033[1;31m$PROD_PASS\033[0m"

echo
success "VPS Setup is complete!"

EOF_SCRIPT
}

# === Backup Module program flow & Helper Functions ===
# === 1. Select Project from previous templates ===
select_backup_config() {
    shopt -s nullglob
    local configs=("$CONFIG_DIR"/*.env)
    shopt -u nullglob

    if [[ ${#configs[@]} -eq 0 ]]; then
        error "No configs available for backup."
        return 1
    fi

    info "📂 Select a project to manage backups:"
    select f in "${configs[@]}" "❌ Cancel"; do
      [[ -z "${f:-}" ]] && continue
        if [[ "$REPLY" -gt 0 && "$REPLY" -le "${#configs[@]}" ]]; then
            CONFIG_FILE="$(basename "$f")"
            source "$f"
            CONFIG_LOADED=true
            init_profile_state || return
            success "Loaded config: $CONFIG_FILE"
            return 0
        elif [[ "$f" == "❌ Cancel" ]]; then
            return 1
        else
            warn "Invalid option."
        fi
    done
   

}

# === 2. Remote Environment Selector ===
select_environment() {
    info "🌍 Select environment:"
    select ENV in "Production" "Staging" "❌ Cancel"; do
        case $REPLY in
            1)
                ENVIRONMENT="production"
                DB_NAME="production_db"
                DB_PASS="$PROD_PASS"
                DOMAIN_FE="$DOMAIN_FE_PROD"
                DOMAIN_BE="$DOMAIN_BE_PROD"
                break
                ;;
            2)
                ENVIRONMENT="staging"
                DB_NAME="staging_db"
                DB_PASS="$STAGING_PASS"
                DOMAIN_FE="$DOMAIN_FE_STAGING"
                DOMAIN_BE="$DOMAIN_BE_STAGING"
                break
                ;;
            3) return 1 ;;
            *) warn "Invalid option." ;;
        esac
    done
}

# === 3. Get or Update Asset/DB Functions ===
select_backup_action() {
    info "🔁 What would you like to do?"
    select ACTION in "[ ⬇️] Get assets & DB from VPS" "[ ⬆️] Update VPS with local assets & DB" "❌ Cancel"; do
        case $REPLY in
            1) BACKUP_ACTION="get"; return 0 ;;
            2) BACKUP_ACTION="update"; return 0 ;;
            3) return 1 ;;
            *) warn "Invalid option." ;;
        esac
    done
}

# === 4. Specify Assets and or DB ===
select_backup_scope() {
    info "📦 What should be included?"
    select SCOPE in "🖼️ Assets only" "🗄️ Database only" "🖼️🗄️ Assets + Database" "❌ Cancel"; do
        case $REPLY in
            1) INCLUDE_ASSETS=true;  INCLUDE_DB=false; break ;;
            2) INCLUDE_ASSETS=false; INCLUDE_DB=true;  break ;;
            3) INCLUDE_ASSETS=true;  INCLUDE_DB=true;  break ;;
            4) return 1 ;;
            *) warn "Invalid option." ;;
        esac
    done
}

# === 5. Assert backup folders ===
init_backup_dirs() {
    timestamp="$(date '+%Y-%m-%d_%H-%M-%S')"
    info "Timestamp: $timestamp"
    BACKUP_ROOT="$BACKUP_BASE_DIR/${CONFIG_FILE%.env}/$ENVIRONMENT"
    BACKUP_DIR="$BACKUP_ROOT/$timestamp"

    mkdir -p "$BACKUP_DIR"

    [[ "$INCLUDE_ASSETS" == true ]] && mkdir -p "$BACKUP_DIR"
    [[ "$INCLUDE_DB" == true ]] && mkdir -p "$BACKUP_DIR/db"

    ln -sfn "$BACKUP_DIR" "$BACKUP_ROOT/latest"

    success "Backup directory created:"
    info "$BACKUP_DIR"
}

# === Helper Functions to execute_backup ===
# === Download assets from VPS to local backup ===
backup_get_assets() {
    info "Downloading assets from VPS (compressed)..."

    REMOTE_PATH="/opt/actions-runners/backend-$ENVIRONMENT/_work/$PROFILE_NAME-backend/Uploads"
    LOCAL_PATH="$BACKUP_DIR/Uploads"
    LOCAL_TAR="$BACKUP_DIR/Uploads.tar.gz"

    # Create local backup folder if missing
    mkdir -p "$BACKUP_DIR"

    debug "Remote path: $REMOTE_PATH"
    debug "Local path: $LOCAL_PATH"
    debug "Local tarball: $LOCAL_TAR"

    # Create compressed archive on VPS
    ssh -i "$KEY_PATH" "$SSH_USER@$VPS_IP" bash <<EOF
set -e
cd "$REMOTE_PATH"
tar -czf "/tmp/${PROFILE_NAME}_uploads_${ENVIRONMENT}.tar.gz" .
EOF

    # Pull the tarball to local machine
    rsync -avz -e "ssh -i $KEY_PATH" "$SSH_USER@$VPS_IP:/tmp/${PROFILE_NAME}_uploads_${ENVIRONMENT}.tar.gz" "$LOCAL_TAR"
    
    # Optionally decompress locally
    if confirm "⏳ Do you want to decompress the Assets?"; then
        mkdir -p "$LOCAL_PATH"
        tar -xzf "$LOCAL_TAR" -C "$LOCAL_PATH"
        success "Decompression complete!"
    else
        info "Skipping optional decompression."
    fi


    # Cleanup remote tarball
    ssh -i "$KEY_PATH" "$SSH_USER@$VPS_IP" rm -f "/tmp/${PROFILE_NAME}_uploads_${ENVIRONMENT}.tar.gz"
    info "Removing remote tarball"

    success "Assets backed up to $LOCAL_PATH (compressed copy: $LOCAL_TAR)"
}

# === Push local assets back to VPS (decompress on server) ===
backup_push_assets() {
    info "Restoring assets to VPS from compressed backup..."

    LOCAL_TAR="$BACKUP_DIR/Uploads.tar.gz"
    REMOTE_UPLOADS="/opt/actions-runners/backend-$ENVIRONMENT/_work/$PROFILE_NAME-backend/Uploads"
    REMOTE_TAR="/tmp/${PROFILE_NAME}_uploads_${ENVIRONMENT}.tar.gz"

    # Validate local backup exists
    if [[ ! -f "$LOCAL_TAR" ]]; then
        error "No asset backup tarball found at $LOCAL_TAR"
        return 1
    fi

    info "📦 Uploading compressed assets to VPS..."
    rsync -avz -e "ssh -i $KEY_PATH" "$LOCAL_TAR" "$SSH_USER@$VPS_IP:$REMOTE_TAR"

    info "📦 Decompressing assets on VPS..."
    ssh -i "$KEY_PATH" "$SSH_USER@$VPS_IP" bash <<EOF
set -e
mkdir -p "$REMOTE_UPLOADS"
tar -xzf "$REMOTE_TAR" -C "$REMOTE_UPLOADS"
rm -f "$REMOTE_TAR"
EOF

    success "Assets restored to VPS successfully"
}

# === Get Remote DB Gzip ===
backup_get_db() {
    info "Dumping MSSQL database from Docker container..."

    # Paths
    VPS_CONTAINER_BACKUP="/tmp/${ENVIRONMENT}_${DB_NAME}.bak"       # Backup inside container
    VPS_HOST_BACKUP="/tmp/${ENVIRONMENT}_${DB_NAME}.bak"            # Backup on VPS host
    LOCAL_BAK="$BACKUP_DIR/db/${ENVIRONMENT}_${DB_NAME}.bak"
    LOCAL_BAK_GZ="$LOCAL_BAK.gz"

    # === Step 1: Run SQL Server backup inside container ===
    info "📦 Running BACKUP DATABASE inside container on VPS via SSH..."
    ssh -i "$KEY_PATH" "$SSH_USER@$VPS_IP" bash <<EOF
set -e

# Ensure container /tmp folder is accessible
docker exec -u 0 sqlserver_$ENVIRONMENT mkdir -p /tmp

# Run SQL Server backup inside container
docker exec -u 0 sqlserver_$ENVIRONMENT /opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "$DB_PASS" \
    -Q "BACKUP DATABASE [$DB_NAME] TO DISK = N'$VPS_CONTAINER_BACKUP' WITH INIT"

# Copy backup from container to VPS host
docker cp "sqlserver_$ENVIRONMENT:$VPS_CONTAINER_BACKUP" "$VPS_HOST_BACKUP"

# Confirm file exists on VPS host
ls -lh "$VPS_HOST_BACKUP"
EOF

    # === Step 2: Pull backup to local machine via rsync ===
    info "📦 Pulling backup from VPS host to local machine..."
    mkdir -p "$BACKUP_DIR/db"
    rsync -avz -e "ssh -i $KEY_PATH" "$SSH_USER@$VPS_IP:$VPS_HOST_BACKUP" "$LOCAL_BAK"
    
    # === Step 3: Compress locally ===
    info "📦 Compressing backup locally..."
    gzip -f "$LOCAL_BAK"

    # === Step 4: Validate ===
    if [[ -s "$LOCAL_BAK_GZ" ]]; then
        success "Database $DB_NAME dumped and saved to $LOCAL_BAK_GZ"
    else
        error "Backup failed — file is empty or missing at $LOCAL_BAK_GZ"
    fi

    # === Step 5: Cleanup VPS host temporary file ===
    ssh -i "$KEY_PATH" "$SSH_USER@$VPS_IP" rm -f "$VPS_HOST_BACKUP"
}


backup_push_db() {
  info "Restoring MSSQL database to VPS Docker container..."

  LOCAL_BAK_GZ="$BACKUP_DIR/db/${ENVIRONMENT}_${DB_NAME}.bak.gz"
  LOCAL_BAK="${LOCAL_BAK_GZ%.gz}"
  VPS_HOST_BACKUP="/tmp/${ENVIRONMENT}_${DB_NAME}.bak"
  VPS_CONTAINER_BACKUP="/var/opt/mssql/backups/${ENVIRONMENT}_${DB_NAME}.bak"

  # === Step 1: Validate local backup exists ===
  if [[ ! -f "$LOCAL_BAK_GZ" ]]; then
      error "Local backup not found: $LOCAL_BAK_GZ"
      return 1
  fi

  info "📦 Decompressing local backup..."
  gzip -dkf "$LOCAL_BAK_GZ"  # keep original .gz

  if [[ ! -s "$LOCAL_BAK" ]]; then
      error "Decompressed backup is empty: $LOCAL_BAK"
      return 1
  fi
  success "Local backup decompressed: $LOCAL_BAK"

  # === Step 2: Push backup to VPS host ===
  info "📦 Pushing backup to VPS host via rsync..."
  rsync -avz -e "ssh -i $KEY_PATH" "$LOCAL_BAK" "$SSH_USER@$VPS_IP:$VPS_HOST_BACKUP"

  # === Step 3: Restore backup inside container via SSH ===
  info "📦 Restoring database inside Docker container on VPS..."
  info "⚠️ Forcing database into SINGLE_USER mode (disconnecting active sessions)"
  ssh -A -i "$KEY_PATH" "$SSH_USER@$VPS_IP" bash <<EOF
set -e

# Ensure container backup folder exists
docker exec -u 0 sqlserver_$ENVIRONMENT mkdir -p /var/opt/mssql/backups

# Copy backup from host into container
docker cp "$VPS_HOST_BACKUP" "sqlserver_$ENVIRONMENT:$VPS_CONTAINER_BACKUP"

# Restore database
docker exec -u 0 sqlserver_$ENVIRONMENT /opt/mssql-tools/bin/sqlcmd \
    -S localhost -U sa -P "$DB_PASS" -b -Q "
ALTER DATABASE [$DB_NAME] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
RESTORE DATABASE [$DB_NAME] FROM DISK = N'$VPS_CONTAINER_BACKUP' WITH REPLACE;
ALTER DATABASE [$DB_NAME] SET MULTI_USER;
"

# Confirm restoration
docker exec -u 0 sqlserver_$ENVIRONMENT /opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "$DB_PASS" \
    -Q "SELECT name, state_desc FROM sys.databases WHERE name = '$DB_NAME'"

# Cleanup temporary VPS host backup
rm -f "$VPS_HOST_BACKUP"
EOF

  # Optional: cleanup local decompressed file
  rm -f "$LOCAL_BAK"

  success "Database '$DB_NAME' restored successfully to $ENVIRONMENT container."
}

# === Helper functions for Selecting Backup | Default or Select from List  ===
select_backup_source() {
    BACKUP_ROOT="$BACKUP_BASE_DIR/${CONFIG_FILE%.env}/$ENVIRONMENT"

    if [[ -L "$BACKUP_ROOT/latest" ]]; then
        LATEST_TARGET="$(readlink -f "$BACKUP_ROOT/latest" 2>/dev/null)"

        if [[ -n "$LATEST_TARGET" && -e "$LATEST_TARGET" ]]; then
            LATEST="$(basename "$LATEST_TARGET")"

            if confirm "🕒 The latest backup is [🟢 $LATEST], use it?"; then
                SELECTED_BACKUP_DIR="$BACKUP_ROOT/latest"
                success "Using latest backup ($LATEST)"
                return 0
            fi
        else
            warn "Latest symlink exists but is invalid."
        fi
    else
        warn "No latest backup found."
    fi

    mapfile -t backups < <(ls -1 "$BACKUP_ROOT" | grep -v '^latest$')

    if [[ ${#backups[@]} -eq 0 ]]; then
        error "No backups found"
        return 1
    fi

    DISPLAY_BACKUPS=()
    for b in "${backups[@]}"; do
        if [[ "$b" == "$LATEST" ]]; then
            DISPLAY_BACKUPS+=("🟢 $b (latest)")
        else
            DISPLAY_BACKUPS+=("⚪ $b")
        fi
    done

    info "📂 Select a backup:"
    select choice in "${DISPLAY_BACKUPS[@]}" "❌ Cancel"; do
        [[ "$choice" == "❌ Cancel" ]] && info "❌ Cancelling operation" && return 1

        index=$((REPLY - 1))
        [[ $index -ge 0 && $index -lt ${#backups[@]} ]] || {
            warn "Invalid option."
            continue
        }

        SELECTED_BACKUP_DIR="$BACKUP_ROOT/${backups[$index]}"
        success "Selected backup: ${backups[$index]}"
        return 0
    done
}

# === 6. Execute ===
execute_backup() {
    if [[ "$BACKUP_ACTION" == "get" ]]; then
        init_backup_dirs  # create timestamped folder for backup
    else
        # For push, use the latest backup folder
        BACKUP_ROOT="$BACKUP_BASE_DIR/${CONFIG_FILE%.env}/$ENVIRONMENT"
        BACKUP_DIR="$SELECTED_BACKUP_DIR"
        if [[ ! -d "$BACKUP_DIR" ]]; then
            error "No backup found to push. Run 'get assets' first."
            return 1
        fi
    fi

    if [[ "$BACKUP_ACTION" == "get" ]]; then
        [[ "$INCLUDE_ASSETS" == true ]] && backup_get_assets
        [[ "$INCLUDE_DB" == true ]] && backup_get_db
    else
        [[ "$INCLUDE_ASSETS" == true ]] && backup_push_assets
        [[ "$INCLUDE_DB" == true ]] && backup_push_db
    fi

    success "Backup operation completed"
    info "Location: $BACKUP_DIR"
}

backup_project_assets() {
  info "Backup Project Assets (uploads + DB)"

  info "Starting Backup Manager"
  
  CONFIG_LOADED=false
  unset CONFIG_FILE
  
  select_backup_config    || return
  select_environment      || return
  select_backup_action    || return
  select_backup_scope     || return
  
  if [[ "$BACKUP_ACTION" == "update" ]]; then
    select_backup_source || return
  fi

  ACTION_ICON=$([[ "$BACKUP_ACTION" == "get" ]] && echo "[ ⬇️] GET" || echo "[ ⬆️] PUSH")
  ASSETS_ICON=$([[ "$INCLUDE_ASSETS" == true ]] && echo "✅" || echo "❌")
  DB_ICON=$([[ "$INCLUDE_DB" == true ]] && echo "✅" || echo "❌")

  info "Backup plan:"
  info "Project: $CONFIG_FILE"
  info "Environment: $ENVIRONMENT"
  info "Action: $ACTION_ICON"
  info "Assets: $ASSETS_ICON | DB: $DB_ICON"

  if confirm "Proceed with this operation?"; then
      execute_backup
  else
      warn "Backup cancelled."
  fi
}

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
