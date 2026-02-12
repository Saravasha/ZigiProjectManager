#!/usr/bin/env bash
set -euo pipefail

# --- Default settings ---
DEBUG=false
DEBUG_VERBOSE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --debug)
            DEBUG=true
            shift
            ;;
        --debug-verbose)
            DEBUG=true
            DEBUG_VERBOSE=true
            set -x  # enable full shell tracing
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [--debug] [--debug-verbose]"
            exit 0
            ;;
        *)
            echo "Unknown argument: $1"
            exit 1
            ;;
    esac
done

# === Colored Output Functions ===
info()    { echo -e "\033[1;34m[INFO]:🔍 $*\033[0m"; }
warn()    { echo -e "\033[1;33m[WARN]:⚠️ $*\033[0m"; }
error()   { echo -e "\033[1;31m[ERROR]:❌ $*\033[0m"; }
success() { echo -e "\033[1;32m[SUCCESS]:✅ $*\033[0m"; }
debug() {
  if [[ "$DEBUG" == true && "$DEBUG_VERBOSE" == false ]]; then
    echo -e "\033[38;5;208m[DEBUG]:⚙️ $*\033[0m"
  fi
}

# === Config Paths ===
CONFIG_DIR="$HOME/.vps-configs"
APPS_CONFIG_DIR="$CONFIG_DIR/Apps"
SMTP_PROFILE_DIR="$HOME/.smtp-profiles"
CLONE_PROFILE_DIR="$HOME/.clone-website-profiles"
BACKUP_BASE_DIR="$(cd "$(pwd)/.." && pwd)/vps-backups"

mkdir -p "$CONFIG_DIR" "$SMTP_PROFILE_DIR" "$CLONE_PROFILE_DIR" "$BACKUP_BASE_DIR" "$APPS_CONFIG_DIR"

# === Config State Handlers ===
CONFIG_LOADED=false

# auto_detect_config() {
#     shopt -s nullglob
#     CONFIG_FILES=("$APPS_CONFIG_DIR"/*.env)
#     shopt -u nullglob

#     if [[ ${#CONFIG_FILES[@]} -gt 0 ]]; then
#         CONFIG_LOADED=true
#         CONFIG_FILE=$(basename "${CONFIG_FILES[0]}")  # optional: pick first one
#         source "$APPS_CONFIG_DIR/$CONFIG_FILE"
#         info "Auto-detected config: $CONFIG_FILE"
#     else
#         CONFIG_LOADED=false
#     fi
# }
# auto_detect_config

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

    # Determine the config path: argument overrides default
    local CONFIG_PATH="${1:-$APPS_CONFIG_DIR/${CONFIG_NAME}.env}"
    debug "CONFIG_PATH: $CONFIG_PATH"

    if [[ -f "$CONFIG_PATH" ]]; then
        # -------------------------------
        # Existing config branch
        # -------------------------------
        success "📂 Loaded existing config from $CONFIG_PATH"
        source "$CONFIG_PATH"
        init_profile_state || return
        CONFIG_LOADED=true

    else
        # -------------------------------
        # New config branch
        # -------------------------------
        info "Creating new config at $CONFIG_PATH"

        KEY_NAME="id_vps_key"
        KEY_PATH="$HOME/.ssh/$KEY_NAME"
        PUB_KEY="${KEY_PATH}.pub"

        # === Step: Select child clone-website-template profile ===
        PROFILE_FILES=()
        PROFILE_LABELS=()
        shopt -s nullglob
        for file in "$CLONE_PROFILE_DIR"/*.json; do
            [[ -f "$file" ]] || continue
            PARENT_PROJECT=$(jq -r '.parent_project // empty' "$file")
            if [[ -n "$PARENT_PROJECT" ]]; then
                PROFILE_FILES+=("$file")
                PROFILE_NAME=$(basename "$file" .json)
                PROFILE_LABELS+=("$PROFILE_NAME [Parent: $PARENT_PROJECT]")
            fi
        done
        shopt -u nullglob

        if [[ ${#PROFILE_FILES[@]} -eq 0 ]]; then
            warn "No child clone-website-template profiles found under $CLONE_PROFILE_DIR"
            return 1
        fi

        PROFILE_LABELS+=("❌ Cancel")
        info "📂 Select a child clone-website-template profile:"
        select CHOICE in "${PROFILE_LABELS[@]}"; do
            if [[ "$CHOICE" == "❌ Cancel" ]]; then
                warn "Cancelled."
                return 1
            elif [[ -n "$CHOICE" ]]; then
                INDEX=$((REPLY - 1))
                PROFILE_JSON="${PROFILE_FILES[$INDEX]}"
                PROFILE_NAME=$(basename "$PROFILE_JSON" .json)
                success "Selected child profile: $PROFILE_NAME (Parent: $(jq -r '.parent_project' "$PROFILE_JSON"))"
                break
            else
                warn "Invalid selection. Try again."
            fi
        done

        PROJECT_NAME=$(jq -r '.project_name // empty' "$PROFILE_JSON")
        API_BASE_PATH=$(jq -r '.api_base_path // empty' "$PROFILE_JSON")
        PARENT_PROJECT_NAME=$(jq -r '.parent_project // empty' "$PROFILE_JSON")
        CHILD_PROFILE_NAME="$PROJECT_NAME"

        if [[ -n "$PARENT_PROJECT_NAME" ]]; then
            info "Child profile detected. Parent project: $PARENT_PROJECT_NAME"
            PARENT_ENV_FILE="$CONFIG_DIR/${PARENT_PROJECT_NAME}.env"
            [[ -f "$PARENT_ENV_FILE" ]] || { error "Parent .env not found: $PARENT_ENV_FILE"; return 1; }
            info "Parent env found at $PARENT_ENV_FILE"

            # Source parent environment
            set -a
            source "$PARENT_ENV_FILE"
            set +a

            PROFILE_NAME="$CHILD_PROFILE_NAME"

            DOMAIN_FE_PROD="www.${BASE_DOMAIN}${API_BASE_PATH}"
            DOMAIN_FE_STAGING="www.staging.${BASE_DOMAIN}${API_BASE_PATH}"
            DOMAIN_BE_PROD="www.admin.${BASE_DOMAIN}${API_BASE_PATH}"
            DOMAIN_BE_STAGING="www.admin-staging.${BASE_DOMAIN}${API_BASE_PATH}"
            PRODUCTION_URL_TARGET="https://admin.${BASE_DOMAIN}${API_BASE_PATH}/"

            info "This is a child app config (child of: $PARENT_PROJECT_NAME)"
            info "✅ Parent project environment loaded, child API base path applied: $API_BASE_PATH"
        else
            error "Selected child profile '$PROJECT_NAME' has no parent_project. Cannot proceed."
            return 1
        fi

        unset REPO_NAME_1 REPO_NAME_2

        REPO_NAME_1=$(jq -r '.frontend' "$PROFILE_JSON")
        REPO_NAME_2=$(jq -r '.backend' "$PROFILE_JSON")



        # Hard validation
        [[ -n "$REPO_NAME_1" ]] || { error "frontend repo missing in $PROFILE_JSON"; return 1; }
        [[ -n "$REPO_NAME_2" ]] || { error "backend repo missing in $PROFILE_JSON"; return 1; }

        info "📦 Getting the repos for the $REPO_NAME_1 and $REPO_NAME_2 applications..."
        debug "📦 Frontend repo: $REPO_NAME_1"
        debug "📦 Backend repo:  $REPO_NAME_2"

        # Optional: Override passwords
        if confirm "Do you want to manually override MSSQL or Admin passwords for this child app?"; then
            read -s -p "🔐 STAGING MSSQL password: " STAGING_PASS; echo
            read -s -p "🔐 PRODUCTION MSSQL password: " PROD_PASS; echo
            read -s -p "🔐 Admin Password (Production): " ADMIN_PASSWORD; echo
            read -s -p "🔐 Admin Password (Staging): " ADMIN_PASSWORD_STAGING; echo
        else
            info "⚡ Using parent project passwords for MSSQL and Admin."
            info "Using base domain: $BASE_DOMAIN"
        fi

        info "Loading SMTP settings from parent env: $PARENT_ENV_FILE"
        success "✅ Inherited SMTP profile from parent: $SMTP_PROFILE_NAME"

        # GitHub info
        REPO_OWNER=$(jq -r .github_org "$PROFILE_JSON")
        info "Skipping Github Username/Org, using clone-website-template profile"
        GITHUB_PAT=$(jq -r .github_pat "$PROFILE_JSON")
        info "Using GitHub PAT from profile"
        debug "API_BASE_PATH: $API_BASE_PATH"

        [[ -n "$GITHUB_PAT" && "$GITHUB_PAT" != "null" ]] || { error "GitHub PAT missing"; return 1; }
        : "${SSL_EMAIL:?SSL_EMAIL missing in parent env}"

        # --- Persist new config and oad the new config immediately ---
        info "Persisting new config"
        persist_config "$CONFIG_PATH"
       
    fi

    # --- Proceed to VPS setup ---
    if confirm "Do you want to continue to setting up the VPS with remote operations now?"; then
        success "Proceeding with Setup VPS..."
        debug "Local PROFILE_NAME='$PROFILE_NAME'"
        setup_vps
    else
        info "⏩ Returning to Main Menu."
    fi
}


persist_config() {
    local path="$1"

    cat > "$path" <<EOF
PARENT_PROJECT_NAME="$PARENT_PROJECT_NAME"

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
API_BASE_PATH="$API_BASE_PATH"

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

    # Load immediately
    source "$path"
    init_profile_state || return
    CONFIG_LOADED=true
    success "✅ Config saved and loaded: $path"
}


remove_profile() {
  info "🗑️ Remove a saved Child app config:"

  shopt -s nullglob
  EXISTING=("$APPS_CONFIG_DIR"/*.env)
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

load_profile() {
    info "Load saved config"

    shopt -s nullglob
    CONFIG_FILES=("$APPS_CONFIG_DIR"/*.env)
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
            CONFIG_FILE="${CONFIG_OPTIONS[$((REPLY-1))]}"
            CONFIG_NAME="${CONFIG_FILE%.env}"        # strip .env extension
            CONFIG_PATH="$APPS_CONFIG_DIR/$CONFIG_FILE"
            success "Loading saved config: $CONFIG_FILE"
            source "$CONFIG_PATH"
            CONFIG_LOADED=true
            init_profile_state || return

            # Pass the config path explicitly to main_config
            main_config "$CONFIG_PATH"
            return
        elif [[ "$conf" == "❌ Cancel" ]]; then
            warn "Cancelled."
            return
        else
            warn "Invalid option."
        fi
    done
}

create_new_profile() {
    info "Create new child app config"

    # Ask user for config name
    read -rp "Enter a name for your new config (e.g. ExampleApp): " CONFIG_NAME
    CONFIG_FILE="${CONFIG_NAME}.env"
    CONFIG_PATH="$APPS_CONFIG_DIR/$CONFIG_FILE"

    debug "CONFIG_NAME in main_config: $CONFIG_NAME"
    debug "CONFIG_PATH in main_config: $CONFIG_PATH"

    if [[ -f "$CONFIG_PATH" ]]; then
        error "Config '$CONFIG_NAME' already exists in Apps."
        return 1
    fi

    info "Creating new config: $CONFIG_NAME at $CONFIG_PATH"

    # Pass the path explicitly to main_config
    main_config "$CONFIG_PATH"
}


setup_vps() {

    if ! $CONFIG_LOADED; then
      error "No config loaded. Please create or load a config first."
      return
    fi

    debug "PROFILE_NAME='$PROFILE_NAME'"
    
    info "Running VPS setup..."
    
    info "Skipping Certbot because we already did that step in VPS Setup..."

# === Step 5: SSH and Setup ===
ssh -t -i "$KEY_PATH" "$SSH_USER@$VPS_IP" sudo -E bash -s -- \
  "$VPS_IP" "$PROD_PASS" "$STAGING_PASS" "$ADMIN_PASSWORD" "$ADMIN_PASSWORD_STAGING" \
  "$PRODUCTION_URL_TARGET" "$REPO_OWNER" "$REPO_NAME_1" "$REPO_NAME_2" "$GITHUB_PAT" \
  "$SSL_EMAIL" "$BASE_DOMAIN" "$DOMAIN_FE_PROD" "$DOMAIN_FE_STAGING" "$DOMAIN_BE_PROD" "$DOMAIN_BE_STAGING" \
  "$SMTP_HOST" "$SMTP_USERNAME" "$SMTP_PASSWORD" "$SMTP_FROM" "$SMTP_PORT" "$PROFILE_NAME" \
  "$API_BASE_PATH" "$DEBUG" "$DEBUG_VERBOSE" "$PARENT_PROJECT_NAME" <<'EOF_SCRIPT'

set -eu
trap 'echo "❌ Setup failed at line $LINENO"; exit 1' ERR

if [[ $EUID -ne 0 ]]; then
  error "Remote script is NOT running as root"
  exit 1
fi

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
SMTP_HOST="${17}"
SMTP_USERNAME="${18}"
SMTP_PASSWORD="${19}"
SMTP_FROM="${20}"
SMTP_PORT="${21}"
PROFILE_NAME="${22}"
API_BASE_PATH="${23:-}"
DEBUG="${24:-false}"
DEBUG_VERBOSE="${25:-false}"
PARENT_PROJECT_NAME="${26}"

env | sort
echo "DEBUG: All passed arguments"
for i in {1..26}; do
    eval "echo ARG$i=\${$i}"
done

# === re-implementing Colorized echo functions inside heredoc ===
info()    { echo -e "\033[1;34m[INFO]:🔍 $*\033[0m"; }
warn()    { echo -e "\033[1;33m[WARN]:⚠️ $*\033[0m"; }
error()   { echo -e "\033[1;31m[ERROR]:❌ $*\033[0m"; }
success() { echo -e "\033[1;32m[SUCCESS]:✅ $*\033[0m"; }
debug() {
  if [[ "$DEBUG" == true && "$DEBUG_VERBOSE" == false ]]; then
    echo -e "\033[38;5;208m[DEBUG]:⚙️ $*\033[0m"
  fi
}

info "💡 We are on the remote machine now!"

debug "PROFILE_NAME: $PROFILE_NAME"

# Set environment file
PROJECT_NAME="${PARENT_PROJECT_NAME}-${PROFILE_NAME}"
SAFE_REPO_OWNER=$(echo "$REPO_OWNER" | tr -cd '[:alnum:]_-')
SAFE_PROJECT_NAME=$(echo "$PROJECT_NAME" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]_-')
ENV_FILE="/etc/myapp_${SAFE_REPO_OWNER}-${PROFILE_NAME}.env"

RUNNER_PREFIX="${SAFE_REPO_OWNER}-${PROFILE_NAME}"

cleanup_old_runners() {
    info "Cleaning up GitHub Actions runners for this child app only: $RUNNER_PREFIX"

    # Stop and remove systemd services that match this app only
    for SERVICE in /etc/systemd/system/actions.runner.${RUNNER_PREFIX}*.service; do
        [[ -f "$SERVICE" ]] || continue
        SERVICE_NAME=$(basename "$SERVICE")
        warn "Stopping and disabling service: $SERVICE_NAME"
        systemctl stop "$SERVICE_NAME" || true
        systemctl disable "$SERVICE_NAME" || true
        rm -f "$SERVICE"
        success "Removed service file: $SERVICE_NAME"
    done

    # Remove runner directories for this app only
    for DIR in /opt/actions-runners/${RUNNER_PREFIX}*; do
        [[ -d "$DIR" ]] || continue
        warn "Removing folder: $DIR"
        rm -rf "$DIR"
        success "Removed: $DIR"
    done

    # Reload systemd
    info "🔄 Reloading systemd daemon..."
    systemctl daemon-reload
    success "Cleanup for $RUNNER_PREFIX completed."
}


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

SQL_PORT_START=1435
SQL_PORT_END=1535   # optional upper limit to prevent crazy high numbers

find_free_port() {
  local start=$1
  local end=$2
  local used_ports
  used_ports=$(ss -lnt | awk '{print $4}' | grep -oE '[0-9]+$' | sort -n)

  for ((p=start; p<=end; p++)); do
    if ! echo "$used_ports" | grep -qx "$p"; then
      echo "$p"
      return 0
    fi
  done

  return 1  # no free port found
}

SQL_STAGING_PORT=$(find_free_port $SQL_PORT_START $SQL_PORT_END)
if [[ -z "$SQL_STAGING_PORT" ]]; then
  echo "❌ No free staging port available!"
  exit 1
fi

SQL_PRODUCTION_PORT=$((SQL_STAGING_PORT + 1))
if (( SQL_PRODUCTION_PORT >= SQL_PORT_START && SQL_PRODUCTION_PORT <= SQL_PORT_END )); then
  if ss -lnt | awk '{print $4}' | grep -q ":$SQL_PRODUCTION_PORT$"; then
    echo "❌ No free production port available!"
    exit 1
  fi
else
  echo "❌ Production port exceeds limit!"
  exit 1
fi

echo "✅ Allocated ports:"
echo "  Staging: $SQL_STAGING_PORT"
echo "  Production: $SQL_PRODUCTION_PORT"

# Allow rules only if not already present
allow_if_not_exists "OpenSSH"
allow_if_not_exists "Nginx Full"
allow_if_not_exists "$SQL_STAGING_PORT/tcp"
allow_if_not_exists "$SQL_PRODUCTION_PORT/tcp"

info "💾 Writing environment variables to $ENV_FILE..."

cat > "$ENV_FILE" <<'EOF_ENV'
# Shared
Smtp__Host="$SMTP_HOST"
Smtp__Username="$SMTP_USERNAME"
Smtp__Password="$SMTP_PASSWORD"
Smtp__From="$SMTP_FROM"
Smtp__Port="$SMTP_PORT"

# db names
DB_NAME_PRODUCTION="${SAFE_PROJECT_NAME}_production"
DB_NAME_STAGING="${SAFE_PROJECT_NAME}_staging"

# sql server volumes
SQLSERVERVOL_NAME_PRODUCTION="sqlserver_${SAFE_PROJECT_NAME}_production"
SQLSERVERVOL_NAME_STAGING="sqlserver_${SAFE_PROJECT_NAME}_staging"

# Production
CONNECTION_STRING="Data Source=$VPS_IP,$SQL_PRODUCTION_PORT;Database=$DB_NAME_PRODUCTION;User ID=sa;Password=$PROD_PASS;Encrypt=True;Trust Server Certificate=True"
ADMIN_PASSWORD="$ADMIN_PASSWORD"
PRODUCTION_URL_TARGET="$PRODUCTION_URL_TARGET"

# Staging
CONNECTION_STRING_STAGING="Data Source=$VPS_IP,$SQL_STAGING_PORT;Database=$DB_NAME_STAGING;User ID=sa;Password=$STAGING_PASS;Encrypt=True;Trust Server Certificate=True"
ADMIN_PASSWORD_STAGING="$ADMIN_PASSWORD_STAGING"

# Default runtime
DOTNET_ENVIRONMENT="Production"
ASPNETCORE_ENVIRONMENT="Production"
EOF_ENV

debug "SQL_STAGIN_PORT: $SQL_STAGING_PORT SQL_PRODUCTION_PORT: $SQL_PRODUCTION_PORT"

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

SQL_PRODUCTION_CONTAINER="sqlserver_${SAFE_PROJECT_NAME}_production"
SQL_STAGING_CONTAINER="sqlserver_${SAFE_PROJECT_NAME}_staging"

# Run MSSQL Docker containers
info "🐳 Starting MSSQL Docker containers..."

# checking if port is in use
for p in $SQL_STAGING_PORT $SQL_PRODUCTION_PORT; do
  if ss -lnt | awk '{print $4}' | grep -q ":$p$"; then
    error "Port $p already in use"
    exit 1
  fi
done

if ! docker ps -q -f name=$SQL_PRODUCTION_CONTAINER | grep -q .; then
  if docker ps -aq -f name=$SQL_PRODUCTION_CONTAINER | grep -q .; then
    docker start $SQL_PRODUCTION_CONTAINER
  else
    docker run -d --name $SQL_PRODUCTION_CONTAINER \
      -e 'ACCEPT_EULA=Y' -e "MSSQL_SA_PASSWORD=$PROD_PASS" \
      -e 'MSSQL_PID=Express' -v $SQLSERVERVOL_NAME_PRODUCTION:/var/opt/mssql \
      -p $SQL_PRODUCTION_PORT:1433 --restart=always \
      mcr.microsoft.com/mssql/server:2019-latest || true
  fi
else
  info "$SQL_PRODUCTION_CONTAINER container is already running."
fi

if ! docker ps -q -f name=$SQL_STAGING_CONTAINER | grep -q .; then
  if docker ps -aq -f name=$SQL_STAGING_CONTAINER | grep -q .; then
    docker start $SQL_STAGING_CONTAINER
  else
    docker run -d --name $SQL_STAGING_CONTAINER \
      -e 'ACCEPT_EULA=Y' -e "MSSQL_SA_PASSWORD=$STAGING_PASS" \
      -e 'MSSQL_PID=Express' -v $SQLSERVERVOL_NAME_STAGING:/var/opt/mssql \
      -p $SQL_STAGING_PORT:1433 --restart=always \
      mcr.microsoft.com/mssql/server:2019-latest || true
  fi
else
  info "$SQL_STAGING_CONTAINER container is already running."
fi

info "🐳 Installing MSSQL Tools..."
for c in SQL_PRODUCTION_CONTAINER SQL_STAGING_CONTAINER; do
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

for c in SQL_PRODUCTION_CONTAINER SQL_STAGING_CONTAINER; do
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
  ["CONNECTION_STRING"]="Data Source=$VPS_IP,$SQL_PRODUCTION_PORT;Database=$DB_NAME_PRODUCTION;User ID=sa;Password=$PROD_PASS;Encrypt=True;Trust Server Certificate=True"
  ["CONNECTION_STRING_STAGING"]="Data Source=$VPS_IP,$SQL_STAGING_PORT;Database=$DB_NAME_STAGING;User ID=sa;Password=$STAGING_PASS;Encrypt=True;Trust Server Certificate=True"
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
      warn "Runner already configured at $DIR."

      SERVICE_PATH="/etc/systemd/system/actions.runner.${REPO_OWNER}-${REPO_NAME//\//.}.${APP_LABEL}-${ENV}.service"
      if [[ ! -f "$SERVICE_PATH" ]]; then
          ./svc.sh install
          systemctl daemon-reexec
          systemctl start "$SERVICE_PATH"
      else
          info "🔄 Service $SERVICE_PATH already exists, restarting..."
          systemctl daemon-reexec
          systemctl restart "$SERVICE_PATH"
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
  TARGET_DIR="/opt/apps/$API_BASE_PATH/$PROFILE_NAME/$REPO_NAME_1-${ENV}"

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

# Running PM2 backend apps

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

pm2 startup systemd -u root --hp /root || true
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

info "🔧 Starting Nginx setup"

BASE_APP_DIR="/opt/apps/$API_BASE_PATH"
# Domains mapping

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

info "Generate HTTP-only Nginx configs"
for env in frontend-production frontend-staging backend-production backend-staging; do
  domain="${DOMAIN_MAP[$env]}"
  config_name="$(echo "$env" | tr '_' '-')"
  config_path="/etc/nginx/sites-available/$config_name"

  cat > "$config_path" <<EOF
server {
    listen 80;
    server_name $domain www.$domain;
EOF

  if [[ "$env" == backend-* ]]; then
    port="${BACKEND_PORTS[$env]}"
    cat >> "$config_path" <<EOF
    location / {
        proxy_pass http://localhost:$port;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
EOF
  else
    cat >> "$config_path" <<EOF
    location /$API_BASE_PATH/$PROFILE_NAME/ {
        alias /opt/apps/$API_BASE_PATH/$PROFILE_NAME/$REPO_NAME_1-production/;
        index index.html;
        try_files \$uri \$uri/ index.html;
    }
EOF
  fi

  echo "}" >> "$config_path"
  ln -sf "$config_path" "/etc/nginx/sites-enabled/$config_name"
done

info "🔄 Testing Nginx configuration and reloading..."
NGINX_OUTPUT=$(nginx -t 2>&1)
if [[ $? -eq 0 ]]; then
    success "$NGINX_OUTPUT"
    systemctl reload nginx
else
    error "$NGINX_OUTPUT"
    exit 1
fi

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
success "App Setup is complete!"

EOF_SCRIPT
}

# === Backup Module program flow & Helper Functions ===
# === 1. Select Project from previous templates ===
select_backup_config() {
    shopt -s nullglob
    local configs=("$APPS_CONFIG_DIR"/*.env)
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

exit_program() {  info "Exiting program."; exit 0; }

# === Header Menu UI ===
print_header() {
    local text="===== ZigiProjectManager >> App Setup Wizard ====="
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
"Backup Project Assets" $'\033[1;33mReturn to Menu\033[0m')

# === Main Menu Loop ===
while true; do
    print_header
    debug "Debug mode engaged!"

    PS3="Choose an option: "
    set +u
    select opt in "${options[@]}"; do
        case $REPLY in
            1) create_new_profile ;;
            2) load_profile ;;
            3) remove_profile ;;
            4) backup_project_assets ;;
            5) exit_program ;;
            *) warn "Invalid option, choose 1-${#options[@]}" ;;
        esac
        break
    done
    set -u
done
