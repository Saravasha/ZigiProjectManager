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



# === Global Paths & Constants ===

# Absolute path to script directory (stable anchor)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

info "$SCRIPT_DIR"

# Absolute path to project root (one level above script)
SCRIPT_PARENT_DIR="$(realpath "$SCRIPT_DIR/..")"

info "$SCRIPT_PARENT_DIR"

# Absolute path to templates (sibling of script parent)
TEMPLATE_PARENT_DIR="$(realpath "$SCRIPT_PARENT_DIR/website-templates")"

info "$TEMPLATE_PARENT_DIR"

PROFILE_DIR="$HOME/.clone-website-profiles"
TEMPLATE_FRONTEND="website-template-frontend"
TEMPLATE_BACKEND="website-template-backend"

mkdir -p "$PROFILE_DIR" "$TEMPLATE_PARENT_DIR"
# === Helper Functions === 🤡
install_tools() {
    declare -A tools=( [git]=git [jq]=jq [sed]=sed [bash]=bash [gh]=gh [curl]=curl [unzip]=unzip )
    local missing=()

    for cmd in "${!tools[@]}"; do
        command -v "$cmd" &>/dev/null || missing+=("${tools[$cmd]}")
    done

    if (( ${#missing[@]} )); then
        warn "Installing missing tools: ${missing[*]}"
        sudo apt-get update -qq
        sudo apt-get install -y "${missing[@]}"
    fi
}
install_dotnet() {
    if ! command -v dotnet &>/dev/null; then
        warn "⚡ .NET SDK not found, installing..."
        wget -q https://packages.microsoft.com/config/ubuntu/22.04/packages-microsoft-prod.deb -O packages-microsoft-prod.deb
        sudo dpkg -i packages-microsoft-prod.deb
        rm packages-microsoft-prod.deb
        sudo apt-get update -qq
        sudo apt-get install -y dotnet-sdk-8.0
    else
        info "dotnet $(dotnet --version) already installed"
    fi
}

migrations_dotnet() {

    local backend_path="$1"

    if [[ -z "$backend_path" ]]; then
        error "backend_path not provided to migrations_dotnet"
        return 1
    fi

    [[ "$DEBUG" == true ]] && {
        debug "Skipping dotnet migrations (DEBUG mode)"
        return 0
    }
     # ------------------------------------------------------------------
    # EF Core migrations
    # ------------------------------------------------------------------
    local migrations_dir="$backend_path/Migrations"
    info "🔎 Checking backend migrations for init..."

    if [[ -d "$migrations_dir" ]] && find "$migrations_dir" -iname "*init*.cs" | grep -q .; then
        success "Init migration already exists."
    else
        info "⚡ Creating init migration..."
        dotnet ef migrations add init --context ApplicationDbContext --output-dir Migrations
        success "Init migration created."
    fi

    # ------------------------------------------------------------------
    # Database update
    # ------------------------------------------------------------------
    if grep -qi microsoft /proc/version &>/dev/null; then
        info "⚡ Skipping database update on WSL"
    else
        info "⚡ Updating database..."
        dotnet ef database update --context ApplicationDbContext
        success "Database up-to-date."
    fi

}
normalize_api_path() {
    local path="$1"
    # Remove trailing slash
    path="${path%/}"
    # Ensure starts with /
    [[ "$path" != /* ]] && path="/$path"
    # Lowercase the path
    path=$(echo "$path" | tr '[:upper:]' '[:lower:]')
    echo "$path"
}
normalize_profile() {
    local profile_file="$1"
    local tmp="$profile_file.tmp"

    # Read current profile fields
    local project_name domain frontend backend parent_project api_base_path github_pat github_org repo_owner email profile_type project_dir runtimes
    project_name=$(jq -r '.project_name // empty' "$profile_file")
    domain=$(jq -r '.domain // empty' "$profile_file")
    frontend=$(jq -r '.frontend // empty' "$profile_file")
    backend=$(jq -r '.backend // empty' "$profile_file")
    parent_project=$(jq -r '.parent_project // empty' "$profile_file")
    api_base_path=$(jq -r '.api_base_path // empty' "$profile_file")
    github_pat=$(jq -r '.github_pat // empty' "$profile_file")
    github_org=$(jq -r '.github_org // empty' "$profile_file")
    repo_owner=$(jq -r '.repo_owner // empty' "$profile_file")
    email=$(jq -r '.email // empty' "$profile_file")
    profile_type=$(jq -r '.profile_type // "domain"' "$profile_file")
    project_dir=$(jq -r '.project_dir // empty' "$profile_file")
    runtimes=$(jq -r '.runtimes // {}' "$profile_file")

    # --- Compute missing fields ---
    [[ -z "$project_dir" ]] && {
        if [[ -n "$github_org" ]]; then
            project_dir="$SCRIPT_PARENT_DIR/$github_org/$project_name"
        else
            project_dir="$SCRIPT_PARENT_DIR/$project_name"
        fi
        info "📁 Adding missing project_dir to $project_name"
    }

    [[ "$profile_type" == "apps" && -z "$api_base_path" ]] && {
        api_base_path="/myapps/$project_name"
        info "🔗 Adding missing api_base_path to $project_name"
    }

    # --- Ensure runtimes object exists ---
    [[ "$runtimes" == "null" ]] && runtimes="{}"

    # --- Write back normalized profile ---
    jq -n \
      --arg project_name "$project_name" \
      --arg domain "$domain" \
      --arg frontend "$frontend" \
      --arg backend "$backend" \
      --arg parent_project "$parent_project" \
      --arg api_base_path "$api_base_path" \
      --arg github_pat "$github_pat" \
      --arg github_org "$github_org" \
      --arg repo_owner "$repo_owner" \
      --arg email "$email" \
      --arg profile_type "$profile_type" \
      --arg project_dir "$project_dir" \
      --argjson runtimes "$runtimes" \
      '{
          project_name: $project_name,
          domain: $domain,
          frontend: $frontend,
          backend: $backend,
          parent_project: $parent_project,
          api_base_path: $api_base_path,
          github_pat: $github_pat,
          github_org: $github_org,
          repo_owner: $repo_owner,
          email: $email,
          profile_type: $profile_type,
          project_dir: $project_dir,
          runtimes: $runtimes
      }' > "$tmp" && mv "$tmp" "$profile_file"

    chmod 600 "$profile_file"
}

generate_project_dir() {
    local name="$1"
    local org="$2"

    if [[ -n "$org" ]]; then
        echo "$SCRIPT_PARENT_DIR/$org/$name"
    else
        echo "$SCRIPT_PARENT_DIR/$name"
    fi
}

# === Profile Management ===
create_new_profile() {

    info "Create Domain App Profile"
    read -rp "📦 Project name: " PROJECT_NAME

    local profile_path="$PROFILE_DIR/$PROJECT_NAME.json"

    if [[ -f "$profile_path" ]]; then
        error "Profile '$PROJECT_NAME' already exists."
        return 1
    fi

    read -rp "🏢 GitHub Username (Saravasha): " REPO_OWNER
    read -rp "📧 GitHub Email (example@gmail.com): " EMAIL
    read -rsp "🔑 GitHub PAT: " GITHUB_PAT; echo

    read -rp "🏢 Use GitHub Org? (y/n): " USE_ORG
    if [[ "$USE_ORG" =~ ^[Yy]$ ]]; then
        read -rp "🏢 Org name: " GITHUB_ORG
    else
        GITHUB_ORG=""
    fi

    PROFILE_TYPE="domain"
    read -rp "🌐 Domain name (example.com): " DOMAIN_NAME

    FRONTEND_NAME="${PROJECT_NAME}-frontend"
    BACKEND_NAME="${PROJECT_NAME}-backend"

    # ✅ SINGLE SOURCE OF TRUTH
    PROJECT_DIR="$(generate_project_dir "$PROJECT_NAME" "$GITHUB_ORG")"

    debug "frontend = $FRONTEND_NAME"
    debug "backend = $BACKEND_NAME"
    debug "project_dir = $PROJECT_DIR"

    jq -n \
      --arg project_name "$PROJECT_NAME" \
      --arg domain "$DOMAIN_NAME" \
      --arg frontend "$FRONTEND_NAME" \
      --arg backend "$BACKEND_NAME" \
      --arg github_pat "$GITHUB_PAT" \
      --arg github_org "$GITHUB_ORG" \
      --arg repo_owner "$REPO_OWNER" \
      --arg email "$EMAIL" \
      --arg profile_type "$PROFILE_TYPE" \
      --arg project_dir "$PROJECT_DIR" \
      '{
        project_name: $project_name,
        domain: $domain,
        frontend: $frontend,
        backend: $backend,
        parent_project: "",
        api_base_path: "",
        github_pat: $github_pat,
        github_org: $github_org,
        repo_owner: $repo_owner,
        email: $email,
        profile_type: $profile_type,
        project_dir: $project_dir,
        runtimes: {}
      }' > "$profile_path"

    chmod 600 "$profile_path"
    success "Profile saved: $profile_path"
}

create_routed_app() {

    info "Create Routed App"

    if [[ "$PROFILE_TYPE" != "domain" ]]; then
        error "Routed apps can only be created from a domain profile."
        return 1
    fi

    if [[ -z "${PROJECT_NAME:-}" ]]; then
        error "No active parent project selected."
        return 1
    fi

    read -rp "📦 App name: " APP_NAME

    FRONTEND_NAME="${PROJECT_NAME}-${APP_NAME}-frontend"
    BACKEND_NAME="${PROJECT_NAME}-${APP_NAME}-backend"

    API_BASE_PATH="/myapps/$APP_NAME"
    API_BASE_PATH=$(normalize_api_path "$API_BASE_PATH")

    APP_PROJECT_DIR="$(generate_project_dir "$APP_NAME" "$GITHUB_ORG")"

    APP_PROFILE="$PROFILE_DIR/$APP_NAME.json"

    parent_profile="$PROFILE_DIR/${PROJECT_NAME}.json"

    if [[ ! -f "$parent_profile" ]]; then
        error "Parent profile not found: $parent_profile"
        return 1
    fi

    parent_domain="$(jq -r '.domain // ""' "$parent_profile")"

    if [[ -z "$parent_domain" ]]; then
        error "Parent domain missing in profile"
        return 1
    fi

    jq -n \
    --arg project_name "$APP_NAME" \
    --arg domain "$parent_domain" \
    --arg frontend "$FRONTEND_NAME" \
    --arg backend "$BACKEND_NAME" \
    --arg parent_project "$PROJECT_NAME" \
    --arg api_base_path "$API_BASE_PATH" \
    --arg github_pat "$GITHUB_PAT" \
    --arg github_org "$GITHUB_ORG" \
    --arg repo_owner "$REPO_OWNER" \
    --arg email "$EMAIL" \
    --arg profile_type "apps" \
    --arg project_dir "$APP_PROJECT_DIR" \
    '{
        project_name: $project_name,
        domain: $domain,
        frontend: $frontend,
        backend: $backend,
        parent_project: $parent_project,
        api_base_path: $api_base_path,
        github_pat: $github_pat,
        github_org: $github_org,
        repo_owner: $repo_owner,
        email: $email,
        profile_type: $profile_type,
        project_dir: $project_dir,
        runtimes: {}
    }' > "$APP_PROFILE"

    chmod 600 "$APP_PROFILE"
    success "Routed app profile saved: $APP_PROFILE"
}
build_profile_menu() {

    info "📁 Available profiles:"

    shopt -s nullglob
    local files=("$PROFILE_DIR"/*.json)
    shopt -u nullglob

    PROFILE_OPTIONS=()
    PROFILE_FILES=()

    [[ ${#files[@]} -eq 0 ]] && return 1

    for file in "${files[@]}"; do
        parent=$(jq -r '.parent_project // empty' "$file")
        name=$(jq -r '.project_name // empty' "$file")
        [[ -z "$name" ]] && name="$(basename "$file" .json)"

        if [[ -z "$parent" || "$parent" == "null" ]]; then
            PROFILE_OPTIONS+=($'\e[33m'"$name  (parent)"$'\e[0m')
        else
            PROFILE_OPTIONS+=($'\e[32m'"$name  (parent: $parent)"$'\e[0m')
        fi

        PROFILE_FILES+=("$file")
    done

    PROFILE_OPTIONS+=("❌ Cancel")
}
reset_session() {

    unset PROFILE_JSON
    unset PROJECT_NAME
    unset DOMAIN_NAME
    unset FRONTEND_NAME
    unset BACKEND_NAME
    unset PROJECT_DIR
    unset PROFILE_TYPE

    unset GITHUB_ORG
    unset GITHUB_PAT
    unset REPO_OWNER
    unset EMAIL

    unset APP_PROFILE
    unset GH_TARGET
}
remove_profile() {
    warn "📁 Remove a profile:"

    build_profile_menu || { error "No profiles to remove."; return; }

    select choice in "${PROFILE_OPTIONS[@]}"; do
        if [[ "$choice" == "❌ Cancel" ]]; then
            info "Cancelled profile removal."
            return
        elif [[ -n "$choice" ]]; then
            local file="${PROFILE_FILES[$((REPLY - 1))]}"
            local name="$(basename "$file")"

            read -rp "Delete '$name'? (y/n): " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                rm -f "$file"
                success "Removed $name"
            else
                info "Cancelled"
            fi
            break
        else
            warn "Invalid selection, try again."
        fi
    done
}

dump_state() {
    [[ "$DEBUG" == false ]] && return 0
    info "===== STATE ====="

    debug "PROJECT_NAME=${PROJECT_NAME:-}"
    debug "PROFILE_TYPE=${PROFILE_TYPE:-}"
    debug "PROJECT_DIR=${PROJECT_DIR:-}"
    debug "FRONTEND_NAME=${FRONTEND_NAME:-}"
    debug "BACKEND_NAME=${BACKEND_NAME:-}"
}

validate_state() {

    [[ -n "${PROFILE_JSON:-}" ]] || {
        error "No profile selected"
        return 1
    }

    [[ -f "$PROFILE_JSON" ]] || {
        error "Profile file missing"
        return 1
    }

    [[ -n "${PROJECT_NAME:-}" ]] || {
        error "PROJECT_NAME missing"
        return 1
    }

    [[ -n "${PROFILE_TYPE:-}" ]] || {
        error "PROFILE_TYPE missing"
        return 1
    }
}

load_profile() {

 local profile="$1"

    PROFILE_JSON="$profile"

    PROJECT_NAME=$(jq -r .project_name "$profile")
    DOMAIN_NAME=$(jq -r .domain "$profile")
    FRONTEND_NAME=$(jq -r .frontend "$profile")
    BACKEND_NAME=$(jq -r .backend "$profile")
    PARENT_PROJECT=$(jq -r '.parent_project // empty' "$profile")
    API_BASE_PATH=$(jq -r '.api_base_path // empty' "$profile")
    GITHUB_PAT=$(jq -r .github_pat "$profile")
    GITHUB_ORG=$(jq -r .github_org "$profile")
    REPO_OWNER=$(jq -r .repo_owner "$profile")
    EMAIL=$(jq -r .email "$profile")
    PROFILE_TYPE=$(jq -r .profile_type "$profile")
    PROJECT_DIR=$(jq -r .project_dir "$profile")
    RUNTIMES=$(jq -r '.runtimes // {}' "$profile")
}

use_profile() {
    info "Select an existing profile"

    reset_session

    build_profile_menu || { error "No profiles found."; return; }

    
    select choice in "${PROFILE_OPTIONS[@]}"; do
        if [[ "$choice" == "❌ Cancel" ]]; then
            info "Cancelled profile selection."
            return
        elif [[ -n "$choice" ]]; then
            PROFILE_JSON="${PROFILE_FILES[$((REPLY - 1))]}"

            normalize_profile "$PROFILE_JSON"

            load_profile "$PROFILE_JSON"

            info "Using profile: ${PROJECT_NAME:-None}"
            break
        else
            warn "Invalid selection, try again."
        fi
    done
}

clone_templates() {
    info "Cloning Templates..."
    mkdir -p "$TEMPLATE_PARENT_DIR"

    local frontend_dest="$TEMPLATE_PARENT_DIR/$TEMPLATE_FRONTEND"
    local backend_dest="$TEMPLATE_PARENT_DIR/$TEMPLATE_BACKEND"

    debug "PWD=$(pwd)"
    debug "SCRIPT_PARENT_DIR=$SCRIPT_PARENT_DIR"
    debug "TEMPLATE_PARENT_DIR=$TEMPLATE_PARENT_DIR"
    debug "resolved TEMPLATE_PARENT_DIR=$(realpath "$TEMPLATE_PARENT_DIR")"

    if [[ ! -d "$frontend_dest" ]]; then
        git clone "https://github.com/Saravasha/website-frontend-template.git" "$frontend_dest"
    fi

    if [[ ! -d "$backend_dest" ]]; then
        git clone "https://github.com/Saravasha/website-backend-template.git" "$backend_dest"
    fi

    success "Templates ready at $TEMPLATE_PARENT_DIR"
}

setup_project_structure() {

    info "📁 Setting up project structure from profile"

    [[ -z "${PROFILE_JSON:-}" ]] && {
        error "No profile selected"
        return 1
    }

    # ✅ SINGLE SOURCE OF TRUTH
    local PROJECT_DIR FRONTEND_NAME BACKEND_NAME

    PROJECT_DIR=$(jq -r '.project_dir' "$PROFILE_JSON")
    FRONTEND_NAME=$(jq -r '.frontend' "$PROFILE_JSON")
    BACKEND_NAME=$(jq -r '.backend' "$PROFILE_JSON")
    PROJECT_NAME=$(jq -r '.project_name' "$PROFILE_JSON")

    debug "setup_project_structure.project_dir = $PROJECT_DIR"
    debug "setup_project_structure.frontend = $FRONTEND_NAME"
    debug "setup_project_structure.backend = $BACKEND_NAME"

    # Guard rails
    [[ -z "$PROJECT_DIR" || "$PROJECT_DIR" == "null" ]] && {
        error "project_dir missing in profile"
        return 1
    }

    [[ -z "$FRONTEND_NAME" || "$FRONTEND_NAME" == "null" ]] && {
        error "frontend missing in profile"
        return 1
    }

    [[ -z "$BACKEND_NAME" || "$BACKEND_NAME" == "null" ]] && {
        error "backend missing in profile"
        return 1
    }

    # Handle overwrite safely
    if [[ -d "$PROJECT_DIR" ]]; then
        warn "Project directory already exists: $PROJECT_DIR"
        read -rp "Do you want to overwrite it? (y/N): " confirm

        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            error "Aborting project setup"
            return 1
        fi

        info "⚡ Removing existing directory..."
        rm -rf "$PROJECT_DIR"
    fi

    mkdir -p "$PROJECT_DIR"

    # Template copy (still constant, no globals involved)
    rsync -a --exclude='.git' \
        "$TEMPLATE_PARENT_DIR/$TEMPLATE_FRONTEND/" \
        "$PROJECT_DIR/$FRONTEND_NAME/"

    rsync -a --exclude='.git' \
        "$TEMPLATE_PARENT_DIR/$TEMPLATE_BACKEND/" \
        "$PROJECT_DIR/$BACKEND_NAME/"

    info "📁 Project structure created at $PROJECT_DIR"
}

# setup_project_structure() {

#     # Setup project directory structure on the local machine and cloning the templates.
#     # local base_dir
#     # if [[ -n "$GITHUB_ORG" ]]; then
#     #     base_dir="$SCRIPT_PARENT_DIR/$GITHUB_ORG"
#     # else
#     #     base_dir="$SCRIPT_PARENT_DIR"
#     # fi

#     # PROJECT_DIR="$base_dir/$PROJECT_NAME"

#     PROJECT_DIR="$(jq -r '.project_dir' "$PROFILE_JSON")"

#     # if [[ "$APP_PROFILE" ]]; then
#     #     PROJECT_DIR="$base_dir/$PROJECT_NAME"
#     # fi


#     if [[ -d "$PROJECT_DIR" ]]; then
#         warn "Project directory already exists: $PROJECT_DIR"
#         debug "setup_project_structure error: Directory $PROJECT_DIR already exists, potential overwrite risk."
#         read -rp "Do you want to overwrite it? (y/N): " confirm
#         if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
#             error "Aborting project setup to avoid overwriting existing directory."
#             return 1
#         else
#             info "⚡ Overwriting existing directory..."
#             rm -rf "$PROJECT_DIR"
#         fi
#     fi

#     debug "setup_project_structure.project_dir = $PROJECT_DIR"

#     mkdir -p "$PROJECT_DIR"
#     rsync -a --exclude='.git' "$TEMPLATE_PARENT_DIR/$TEMPLATE_FRONTEND/" "$PROJECT_DIR/$FRONTEND_NAME/"
#     rsync -a --exclude='.git' "$TEMPLATE_PARENT_DIR/$TEMPLATE_BACKEND/" "$PROJECT_DIR/$BACKEND_NAME/"
#     info "📁 Project structure created at $PROJECT_DIR"
# }

# Refactor the app env, app-name paths to be dynamic from hard coded paths etc, start with Clone-Website-template then move onto setup-vps and setup-app

# === Function: Initialize Frontend Repo ===
init_frontend_repo() {

    info "Initating Frontend Repo"
    dump_state

    PROFILE_TYPE="$(jq -r '.profile_type // ""' "$PROFILE_JSON")"

    local domain_name=""
    local route_base=""
    local deploy_project_name=""

    # -------------------------
    # Resolve domain + routing
    # -------------------------
    if [[ "$PROFILE_TYPE" == "apps" ]]; then
        local parent_name
        parent_name="$(jq -r '.parent_project' "$PROFILE_JSON")"

        local parent_profile="$PROFILE_DIR/${parent_name}.json"

        domain_name="$(jq -r '.domain // ""' "$parent_profile")"
        deploy_project_name="$parent_name"

        route_base="/myapps/$(jq -r '.project_name' "$PROFILE_JSON")"

    else
        domain_name="$(jq -r '.domain // ""' "$PROFILE_JSON")"
        deploy_project_name="$(jq -r '.project_name' "$PROFILE_JSON")"
        route_base=""
    fi

    # -------------------------
    # Build final API base
    # -------------------------
    local api_base="${domain_name}${route_base}"

    debug "domain_name = $domain_name"
    debug "route_base = $route_base"
    debug "api_base = $api_base"
    debug "deploy_project_name = $deploy_project_name"

    # -------------------------
    # Deploy paths
    # -------------------------
    local STAGING_BASE="/opt/apps/${deploy_project_name}-staging"
    local PRODUCTION_BASE="/opt/apps/${deploy_project_name}-production"

    local STAGING_DEPLOY_PATH="${STAGING_BASE}${route_base}"
    local PRODUCTION_DEPLOY_PATH="${PRODUCTION_BASE}${route_base}"

    debug "staging = $STAGING_DEPLOY_PATH"
    debug "production = $PRODUCTION_DEPLOY_PATH"

    # -------------------------
    # Repo path
    # -------------------------
    local frontend_path="$PROJECT_DIR/$FRONTEND_NAME"
    cd "$frontend_path" || exit 1

    # -------------------------
    # Workflow replacements
    # -------------------------
    for file in .github/workflows/*.yml; do
        [[ -f "$file" ]] || continue

        safe_staging=$(printf '%s\n' "$STAGING_DEPLOY_PATH" | sed 's/[\/&]/\\&/g')
        safe_production=$(printf '%s\n' "$PRODUCTION_DEPLOY_PATH" | sed 's/[\/&]/\\&/g')

        sed -i \
            -e "s@__FRONTEND_DEPLOY_PATH_STAGING__@$safe_staging@g" \
            -e "s@__FRONTEND_DEPLOY_PATH_PRODUCTION__@$safe_production@g" \
            "$file"
    done

    # -------------------------
    # Vite / env replacement
    # -------------------------
    local sed_safe_api_base
    sed_safe_api_base=$(printf '%s\n' "$api_base" | sed 's/[\/&]/\\&/g')

    local frontend_name_lower
    frontend_name_lower=$(echo "$FRONTEND_NAME" | tr '[:upper:]' '[:lower:]')

    # ONLY ONE SOURCE OF TRUTH
    sed -i "s|__API_BASE__|$sed_safe_api_base|g" vite.config.js
    sed -i "s/\"name\": \".*\"/\"name\": \"${frontend_name_lower}\"/" package.json

    # optional: only if still present in templates
    find . \( -name "*.jsx" -o -name "*.html" \) -type f \
        -exec sed -i "s/__PROJECT_NAME__/${PROJECT_NAME}/g" {} +

    for file in .env.staging .env.production; do
        [[ -f "$file" ]] || continue
        sed -i "s/__API_BASE__/$sed_safe_api_base/g" "$file"
    done

    GH_TARGET="${GITHUB_ORG:-$REPO_OWNER}"

    if [[ -z "$GH_TARGET" || -z "$FRONTEND_NAME" ]]; then
        error "GH_TARGET or FRONTEND_NAME is empty!"
        return 1
    fi

    [[ "$DEBUG" == true ]] && debug "escape point reached before git init." && return 0

    git init -b main
    git config user.name "$REPO_OWNER"
    git config user.email "$EMAIL"

    git add .
    git commit -m "Initial commit for frontend ${PROJECT_NAME} [skip ci]" || {
        error "Git commit failed"
        return 1
    }

    gh repo create "$GH_TARGET/$FRONTEND_NAME" --private --source="$frontend_path" --push \
    || { error "GitHub repo creation failed (frontend)"; return 1; }

    for branch in dev stage; do
        git checkout -b "$branch"
        git push -u origin "$branch"
    done

    git checkout main
    cd - >/dev/null

    success "Frontend repo initialized: $FRONTEND_NAME"
}

# === Function: Initialize Backend Repo ===
init_backend_repo() {
    info "🚀 Initiating Backend Repo"

    dump_state

    local domain_name=""
    local route_base=""
    local api_base=""
    local deploy_project_name=""

    if [[ "$PROFILE_TYPE" == "apps" ]]; then
        local parent_project
        parent_project="$(jq -r '.parent_project' "$PROFILE_JSON")"

        local parent_profile="$PROFILE_DIR/${parent_project}.json"

        domain_name="$(jq -r '.domain // ""' "$parent_profile")"
        deploy_project_name="$parent_project"

        route_base="/myapps/$(jq -r '.project_name' "$PROFILE_JSON")"
    else
        domain_name="$(jq -r '.domain // ""' "$PROFILE_JSON")"
        deploy_project_name="$(jq -r '.project_name' "$PROFILE_JSON")"
        route_base=""
    fi  

    api_base="${domain_name}${route_base}"

    debug "domain_name = $domain_name"
    debug "route_base = $route_base"
    debug "api_base = $api_base"

    local backend_path="$PROJECT_DIR/$BACKEND_NAME"
    cd "$backend_path" || exit 1

    # ------------------------------------------------------------------
    # Workflow token replacement (PM2 names, paths, backend name)
    # ------------------------------------------------------------------
    for file in .github/workflows/deploy-*.yml; do
        [[ -f "$file" ]] || continue

        local ENV_NAME
        if [[ "$file" == *"deploy-staging.yml" ]]; then
            ENV_NAME="production"
        elif [[ "$file" == *"deploy-dev.yml" ]]; then
            ENV_NAME="staging"
        fi

        local RUNNER_BASE="/opt/actions-runners/$BACKEND_NAME-${ENV_NAME}/_work"
        local BACKEND_ROOT="$RUNNER_BASE/$BACKEND_NAME/$BACKEND_NAME"
        local DLL_PATH="$BACKEND_ROOT/WebAppBackend.dll"

        # PM2 app name
        local PM2_APP_NAME="${deploy_project_name}-backend-${ENV_NAME}"
        debug "init_backend_repo.deploy_project_name = ${DEPLOY_PROJECT_NAME}"
        debug "init_backend_repo.pm2_app_name = ${PM2_APP_NAME}"
        if [[ "$PROFILE_TYPE" == "apps" ]]; then
            PM2_APP_NAME="${BACKEND_NAME}-${ENV_NAME}"
        fi

        sed -i \
            -e "s@__BACKEND_NAME__@$BACKEND_NAME@g" \
            -e "s@__BACKEND_PUBLISH_PATH__@$(printf '%s' "$BACKEND_ROOT" | sed 's/[\/&]/\\&/g')@g" \
            -e "s@__BACKEND_DLL_PATH__@$(printf '%s' "$DLL_PATH" | sed 's/[\/&]/\\&/g')@g" \
            -e "s@__PM2_APP_NAME__@$PM2_APP_NAME@g" \
            "$file"
    done

    # ------------------------------------------------------------------
    # Replace tokens in code & config
    # ------------------------------------------------------------------
    debug "API_BASE_PATH = ${API_BASE_PATH}"

    declare -A TOKEN_REPLACEMENTS=(
        ["__PROJECT_NAME__"]="$PROJECT_NAME"
        ["__API_BASE__"]="$api_base"
    )

    local FILES_TO_REPLACE
    FILES_TO_REPLACE=$(find . -type f \( -name "*.cs" -o -name "*.cshtml" -o -name "*.json" \))

    for file in $FILES_TO_REPLACE; do
        for token in "${!TOKEN_REPLACEMENTS[@]}"; do
            local replacement="${TOKEN_REPLACEMENTS[$token]}"
            local safe_replacement
            safe_replacement=$(printf '%s\n' "$replacement" | sed 's/[\/&]/\\&/g')
            sed -i "s@$token@$safe_replacement@g" "$file"
        done
    done

    # ------------------------------------------------------------------
    # Conditional UsePathBase
    # ------------------------------------------------------------------
    if [[ -n "$API_BASE_PATH" ]]; then
        sed -i "/app.UsePathBase(__API_BASE__)/c\\
if (!string.IsNullOrEmpty(builder.Configuration[\"BasePath\"])) {\\
    app.UsePathBase(builder.Configuration[\"BasePath\"]);\\
}" Program.cs
    else
        sed -i "/app.UsePathBase(__API_BASE__)/d" Program.cs
    fi

    
    # ------------------------------------------------------------------
    # EF Core migrations
    # ------------------------------------------------------------------
    
    migrations_dotnet "$backend_path"

    # ------------------------------------------------------------------
    # GitHub repo
    # ------------------------------------------------------------------
    GH_TARGET="${GITHUB_ORG:-$REPO_OWNER}"
    [[ -z "$GH_TARGET" || -z "$BACKEND_NAME" ]] && error "Missing repo info" && return 1
    [[ "$DEBUG" == true ]] && debug "escape point reached before git init." && return 0

    git init -b main
    git config user.name "$REPO_OWNER"
    git config user.email "$EMAIL"

    git add .
    git commit -m "Initial commit for backend ${PROJECT_NAME} [skip ci]" || {
       error "Git commit failed"
        return 1
    }

    gh repo create "$GH_TARGET/$BACKEND_NAME" --private --source="$backend_path" --push \
    || { error "GitHub repo creation failed (backend)"; return 1; }

    for branch in dev stage; do
        git checkout -b "$branch"
        git push -u origin "$branch"
    done

    git checkout main
    cd - >/dev/null
    success "✅ Backend repo initialized: $BACKEND_NAME"
}


# === Function: Initialize Both Repos ===
init_github_repos() {
    init_frontend_repo
    init_backend_repo
    success "🎉 All repos initialized for project $PROJECT_NAME"
}

require_profile() {
    if [[ -z "${PROFILE_JSON:-}" ]]; then
        error "No profile selected. Use 'Use existing profile' first."
        return 1
    fi
}

resolve_project_dir() {
    if [[ -n "${GITHUB_ORG:-}" ]]; then
        echo "$SCRIPT_PARENT_DIR/$GITHUB_ORG/$PROJECT_NAME"
    else
        echo "$SCRIPT_PARENT_DIR/$PROJECT_NAME"
    fi
}

detect_runtimes() {
    [[ -z "${PROFILE_JSON:-}" ]] && { error "Select a profile first"; return; }

    local frontend_dir="$PROJECT_DIR/$FRONTEND_NAME"
    local backend_dir="$PROJECT_DIR/$BACKEND_NAME"

    # Check existence
    [[ ! -d "$frontend_dir" ]] && { warn "Frontend folder not found at $frontend_dir"; }
    [[ ! -d "$backend_dir" ]] && { warn "Backend folder not found at $backend_dir"; }

    # --- FRONTEND (Node) ---
    local node_version="unknown"

    # Attempt 1: system Node (WSL)
    if command -v node &>/dev/null; then
        node_version=$(cd "$frontend_dir" && node --version 2>/dev/null || echo "")
    fi

    # Attempt 2: Windows Node binary (if WSL Node fails)
    if [[ -z "$node_version" || "$node_version" == "" ]]; then
        local win_node="/mnt/c/Program Files/nodejs/node.exe"
        if [[ -x "$win_node" ]]; then
            node_version=$("$win_node" --version 2>/dev/null || echo "")
        fi
    fi

    # Strip trailing newlines/spaces
    node_version=$(echo -n "$node_version" | tr -d '\r\n')

    # Optional debug
    debug "Node version detected: '$node_version'"

    # --- BACKEND (.NET) ---
    local dotnet_version="unknown"
    local backend_global="$backend_dir/global.json"
    local backend_csproj
    backend_csproj=$(find "$backend_dir" -maxdepth 1 -name "*.csproj" | head -n1 || echo "")
    if [[ -f "$backend_global" ]]; then
        dotnet_version=$(jq -r '.sdk.version // empty' "$backend_global" 2>/dev/null || echo "")
    elif [[ -n "$backend_csproj" ]]; then
        dotnet_version=$(grep -oPm1 "(?<=<TargetFramework>).*?(?=</TargetFramework>)" "$backend_csproj" || echo "")
    fi
    dotnet_version=$(echo -n "$dotnet_version" | tr -d '\r\n')

    # Persist runtimes
    jq --arg node "$node_version" --arg dotnet "$dotnet_version" \
      '.runtimes.node = $node | .runtimes.dotnet = $dotnet' \
      "$PROFILE_JSON" > "$PROFILE_JSON.tmp" && mv "$PROFILE_JSON.tmp" "$PROFILE_JSON"

    success "🧠 Detected runtimes for $(basename "$PROFILE_JSON") → Node=$node_version, .NET=$dotnet_version"

}

setup_project() {

    validate_state || return 1
    dump_state
    install_tools
    install_dotnet
    clone_templates
    
    if ! gh auth status &>/dev/null; then
      warn "GitHub CLI not authenticated. Logging in..."
        if ! echo "$GITHUB_PAT" | gh auth login --with-token; then
            error "GitHub authentication failed"
            return 1
        fi      
        success "GitHub CLI authenticated"    
    fi

    load_profile "$PROFILE_JSON"
    GH_TARGET="${GITHUB_ORG:-$REPO_OWNER}"

    debug "setup_project.repo_owner = $REPO_OWNER"
    debug "setup_project.email = $EMAIL"
    debug "setup_project.github_org = $GITHUB_ORG"
    setup_project_structure
    init_github_repos
    success "🎉 Project [$PROJECT_NAME] setup complete under owner [$GH_TARGET]."
}

setup_routed_app() {
    # Applets that are bound to the route path of the domain website i.e saravasha.com/applet. Part of option 4
    
    debug "setup_routed_app.Profile_type  = $PROFILE_TYPE"
    dump_state
    
    [[ "$PROFILE_TYPE" != "domain" ]] && {
        error "Select a parent domain profile. Only routed app profiles can be set up here."
        debug "setup_routed_app error: Invalid profile type. Expected 'domain', got '$PROFILE_TYPE'"
        return 1
    }

    debug "setup_routed_app.app_profile = $APP_PROFILE"
    debug "setup_routed_app.profile_dir = $PROFILE_DIR"
    debug "setup_routed_app.profile_json = $PROFILE_JSON"

    # Ensure parent project info is loaded
    local parent_profile="$PROFILE_DIR/$(jq -r .parent_project "$PROFILE_JSON").json"
    debug "setup_routed_app.parent_profile = $parent_profile"
    if [[ ! -f "$parent_profile" ]]; then
        error "Parent domain profile not found: $parent_profile"
        return 1
    fi

    local effective_domain
    effective_domain=$(jq -r .domain "$parent_profile")

    # Clone templates
    # clone_templates

    # Setup project structure
    #setup_project_structure

    # Initialize frontend & backend
    # init_github_repos

    success "🎉 Routed app [$PROJECT_NAME] setup complete under parent [$effective_domain]"
}

return_to_menu() { info "Returning to Main Menu."; exit 0; }

# === Header Menu UI ===
print_header() {
    local text="===== ZigiProjectManager >> Clone Website Wizard ====="
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
options=("Create new profile" "Remove a profile" "Use existing profile" "Create Routed App" "Detect Runtimes" "Setup Project from Profile" $'\033[1;33mReturn to Menu\033[0m')

# === Main Menu Loop ===
while true; do
    print_header
    debug "Debug mode engaged!"
    debug "Using profile: ${PROJECT_NAME:-None}"
    info "Current profile: ${PROJECT_NAME:-None}"

    PS3="Choose an option: "
    set +u
    select opt in "${options[@]}"; do
        case $REPLY in
            1) create_new_profile ;;
            2) remove_profile ;;
            3) use_profile ;;
            4) require_profile && create_routed_app ;;
            5) require_profile && detect_runtimes ;;
            6) require_profile && setup_project ;;
            7) return_to_menu ;;
            *) warn "Invalid option, choose 1-${#options[@]}" ;;
        esac
        break
    done
    set -u
done
