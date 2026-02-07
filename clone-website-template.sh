#!/usr/bin/env bash
set -euo pipefail

# === Colored Output Functions ===
info()    { echo -e "\033[1;34m[INFO]:🔍 $*\033[0m"; }
warn()    { echo -e "\033[1;33m[WARN]:⚠️ $*\033[0m"; }
error()   { echo -e "\033[1;31m[ERROR]:❌ $*\033[0m"; }
success() { echo -e "\033[1;32m[SUCCESS]:✅ $*\033[0m"; }
debug()   { echo -e "\033[38;5;208m[DEBUG]:⚙️ $*\033[0m"; }

# === Global Paths & Constants ===
SCRIPT_PARENT_DIR="$(pwd)/../"
PROFILE_DIR="$HOME/.clone-website-profiles"
TEMPLATE_PARENT_DIR="../website-templates"
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

# === Profile Management ===
create_new_profile() {

    read -rp "📦 Project name: " PROJECT_NAME
    PROJECT_SLUG="${PROJECT_NAME}"

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

    read -rp "Profile Type - Enter choice [1) Domain, 2) App]: " PROFILE_TYPE_CHOICE

    if [[ "$PROFILE_TYPE_CHOICE" == "1" ]]; then
        PROFILE_TYPE="domain"

        read -rp "🌐 Domain name (example.com): " DOMAIN_NAME

        FRONTEND_NAME="${PROJECT_NAME}-frontend"
        BACKEND_NAME="${PROJECT_NAME}-backend"

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
            runtimes: {}
          }' > "$profile_path"

    elif [[ "$PROFILE_TYPE_CHOICE" == "2" ]]; then
        PROFILE_TYPE="apps"

        info "📂 Select parent domain project:"
        select parent_profile in "$PROFILE_DIR"/*.json; do
            [[ -n "$parent_profile" ]] || { warn "Invalid selection"; continue; }
            PARENT_PROJECT="$(jq -r .project_name "$parent_profile")"
            PARENT_DOMAIN="$(jq -r .domain "$parent_profile")"
            break
        done

        FRONTEND_NAME="${PROJECT_NAME}-frontend"
        BACKEND_NAME="${PROJECT_NAME}-backend"
        API_BASE_PATH="/apps/$PROJECT_SLUG"

        jq -n \
          --arg project_name "$PROJECT_NAME" \
          --arg parent_project "$PARENT_PROJECT" \
          --arg api_base_path "$API_BASE_PATH" \
          --arg frontend "$FRONTEND_NAME" \
          --arg backend "$BACKEND_NAME" \
          --arg github_pat "$GITHUB_PAT" \
          --arg github_org "$GITHUB_ORG" \
          --arg repo_owner "$REPO_OWNER" \
          --arg email "$EMAIL" \
          --arg profile_type "$PROFILE_TYPE" \
          '{
            project_name: $project_name,
            domain: "",
            frontend: $frontend,
            backend: $backend,
            parent_project: $parent_project,
            api_base_path: $api_base_path,
            github_pat: $github_pat,
            github_org: $github_org,
            repo_owner: $repo_owner,
            email: $email,
            profile_type: $profile_type,
            runtimes: {}
          }' > "$profile_path"

    else
        error "Invalid selection."
        return 1
    fi

    chmod 600 "$profile_path"
    success "Profile saved: $profile_path"
}

create_routed_app() {
    require_profile || return 1

    [[ "$profile_type" == "apps" && -z "$parent_project" ]] && {
        read -rp "Enter parent project for routed app '$project_name': " parent_project
        info "✅ parent_project set to '$parent_project'"
    }

    # Ensure parent is a domain profile
    if [[ "$PROFILE_TYPE" != "domain" ]]; then
        error "Routed apps can only be added under a domain profile."
        return 1
    fi

    read -rp "📦 App name: " APP_NAME
    FRONTEND_NAME="${PROJECT_NAME}-${APP_NAME}-frontend"
    BACKEND_NAME="${PROJECT_NAME}-${APP_NAME}-backend"
    API_BASE_PATH="/apps/$APP_NAME"
    API_BASE_PATH=$(normalize_api_path "$API_BASE_PATH")

    APP_PROFILE="$PROFILE_DIR/$APP_NAME.json"
    if [[ -f "$APP_PROFILE" ]]; then
        error "Profile for app '$APP_NAME' already exists."
        return 1
    fi

    jq -n \
    --arg project_name "$APP_NAME" \
    --arg frontend "$FRONTEND_NAME" \
    --arg backend "$BACKEND_NAME" \
    --arg parent_project "$PROJECT_NAME" \
    --arg api_base_path "$API_BASE_PATH" \
    --arg github_pat "$GITHUB_PAT" \
    --arg github_org "$GITHUB_ORG" \
    --arg repo_owner "$REPO_OWNER" \
    --arg email "$EMAIL" \
    --arg profile_type "apps" \
    '{
        project_name: $project_name,
        frontend: $frontend,
        backend: $backend,
        parent_project: $parent_project,
        api_base_path: $api_base_path,
        github_pat: $github_pat,
        github_org: $github_org,
        repo_owner: $repo_owner,
        email: $email,
        profile_type: $profile_type,
        runtimes: {}
    }' > "$APP_PROFILE"

    chmod 600 "$APP_PROFILE"
    success "Routed app profile saved: $APP_PROFILE"
}

remove_profile() {
    local profiles=("$PROFILE_DIR"/*.json)
    [[ ${#profiles[@]} -eq 0 ]] && { error "No profiles to remove."; return; }

    # Add a "Cancel" option at the end
    local options=("${profiles[@]}" "❌ Cancel")

    info "📁 Select a profile to remove:"
    select profile_file in "${options[@]}"; do
        if [[ "$profile_file" == "❌ Cancel" ]]; then
            info "Cancelled profile removal."
            break
        elif [[ -n "$profile_file" ]]; then
            read -rp "Delete '$profile_file'? (y/n): " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                rm -f "$profile_file"
                success "Removed $profile_file"
            else
                info "Cancelled"
            fi
            break
        else
            warn "Invalid selection, try again."
        fi
    done
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
        api_base_path="/apps/$project_name"
        info "🔗 Adding missing api_base_path to $project_name"
    }

    [[ "$profile_type" == "apps" && -z "$parent_project" ]] && {
        read -rp "Enter parent project for routed app '$project_name': " parent_project
        info "✅ parent_project set to '$parent_project'"
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

use_profile() {
    local profiles=("$PROFILE_DIR"/*.json)
    [[ ${#profiles[@]} -eq 0 ]] && { error "No profiles found."; return; }

    # Add a "Cancel" option at the end
    local options=("${profiles[@]}" "❌ Cancel")

    info "📁 Available profiles:"
    select profile_file in "${options[@]}"; do
        if [[ "$profile_file" == "❌ Cancel" ]]; then
            info "Cancelled profile selection."
            return
        elif [[ -n "$profile_file" ]]; then
            PROFILE_JSON="$profile_file"
            # Automatically normalize
            normalize_profile "$PROFILE_JSON"

            PROJECT_NAME=$(jq -r .project_name "$PROFILE_JSON")
            DOMAIN_NAME=$(jq -r .domain "$PROFILE_JSON")
            FRONTEND_NAME=$(jq -r .frontend "$PROFILE_JSON")
            BACKEND_NAME=$(jq -r .backend "$PROFILE_JSON")
            GITHUB_PAT=$(jq -r .github_pat "$PROFILE_JSON")
            GITHUB_ORG=$(jq -r .github_org "$PROFILE_JSON")
            PROFILE_TYPE=$(jq -r .profile_type "$PROFILE_JSON")
            REPO_OWNER=$(jq -r .repo_owner "$PROFILE_JSON")
            EMAIL=$(jq -r .email "$PROFILE_JSON")
            PROJECT_DIR=$(jq -r .project_dir "$PROFILE_JSON")

            info "Using profile: $PROJECT_NAME"
            break
        else
            warn "Invalid selection, try again."
        fi
    done
}

clone_templates() {
    mkdir -p "$TEMPLATE_PARENT_DIR"
    [[ ! -d "$TEMPLATE_PARENT_DIR/$TEMPLATE_FRONTEND" ]] && \
        git clone "https://github.com/Saravasha/website-frontend-template.git" "$TEMPLATE_PARENT_DIR/$TEMPLATE_FRONTEND"
    [[ ! -d "$TEMPLATE_PARENT_DIR/$TEMPLATE_BACKEND" ]] && \
        git clone "https://github.com/Saravasha/website-backend-template.git" "$TEMPLATE_PARENT_DIR/$TEMPLATE_BACKEND"
    success "Templates ready at $TEMPLATE_PARENT_DIR"
}

setup_project_structure() {
    local base_dir
    if [[ -n "$GITHUB_ORG" ]]; then
        base_dir="$SCRIPT_PARENT_DIR/$GITHUB_ORG"
    else
        base_dir="$SCRIPT_PARENT_DIR"
    fi

    PROJECT_DIR="$base_dir/$PROJECT_NAME"

    if [[ -d "$PROJECT_DIR" ]]; then
        warn "Project directory already exists: $PROJECT_DIR"
        read -rp "Do you want to overwrite it? (y/N): " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            error "Aborting project setup to avoid overwriting existing directory."
            return 1
        else
            info "⚡ Overwriting existing directory..."
            rm -rf "$PROJECT_DIR"
        fi
    fi

    mkdir -p "$PROJECT_DIR"
    rsync -a --exclude='.git' "$TEMPLATE_PARENT_DIR/$TEMPLATE_FRONTEND/" "$PROJECT_DIR/$FRONTEND_NAME/"
    rsync -a --exclude='.git' "$TEMPLATE_PARENT_DIR/$TEMPLATE_BACKEND/" "$PROJECT_DIR/$BACKEND_NAME/"
    info "📁 Project structure created at $PROJECT_DIR"
}

# === Function: Initialize Frontend Repo ===
init_frontend_repo() {

    info "Initating Frontend Repo"

    local API_BASE_PATH=""
    
    # If this is a routed app, use api_base_path from profile
    if [[ "$PROFILE_TYPE" == "apps" ]]; then
        API_BASE_PATH=$(jq -r '.api_base_path // "/apps/'"$PROJECT_NAME"'"' "$PROFILE_JSON")
        DEPLOY_PROJECT_NAME="$(jq -r .parent_project "$PROFILE_JSON")"
        # Determine parent project domain
        local parent_profile="$PROFILE_DIR/$(jq -r .parent_project "$PROFILE_JSON").json"
        DOMAIN_NAME=$(jq -r '.domain // ""' "$parent_profile")
    fi

    local STAGING_BASE="/opt/apps/${DEPLOY_PROJECT_NAME}-staging"
    local PRODUCTION_BASE="/opt/apps/${DEPLOY_PROJECT_NAME}-production"

    local STAGING_DEPLOY_PATH="$STAGING_BASE"
    local PRODUCTION_DEPLOY_PATH="$PRODUCTION_BASE"

    if [[ "$PROFILE_TYPE" == "apps" ]]; then
        STAGING_DEPLOY_PATH="$STAGING_BASE$API_BASE_PATH"
        PRODUCTION_DEPLOY_PATH="$PRODUCTION_BASE$API_BASE_PATH"
    fi

    # guarding empty vars
    [[ -z "$STAGING_DEPLOY_PATH" ]] && error "Staging deploy path is empty"
    [[ -z "$PRODUCTION_DEPLOY_PATH" ]] && error "Production deploy path is empty"
    
    # change workflow file paths
    for file in .github/workflows/*.yml; do
        [[ -f "$file" ]] || continue

        safe_staging=$(printf '%s\n' "$STAGING_DEPLOY_PATH" | sed 's/[\/&]/\\&/g')
        safe_production=$(printf '%s\n' "$PRODUCTION_DEPLOY_PATH" | sed 's/[\/&]/\\&/g')

        sed -i \
            -e "s@__FRONTEND_DEPLOY_PATH_STAGING__@$safe_staging@g" \
            -e "s@__FRONTEND_DEPLOY_PATH_PRODUCTION__@$safe_production@g" \
            "$file"
    done

    local frontend_path="$PROJECT_DIR/$FRONTEND_NAME"
    cd "$frontend_path" || exit 1

    # Prepare token replacements
    local sed_safe_domain
    sed_safe_domain=$(printf '%s\n' "$DOMAIN_NAME" | sed 's/[][\/.*^$]/\\&/g')

    local sed_safe_api_path
    sed_safe_api_path=$(printf '%s\n' "$API_BASE_PATH" | sed 's/[][\/.*^$]/\\&/g')

    local frontend_name_lower
    frontend_name_lower=$(echo "$FRONTEND_NAME" | tr '[:upper:]' '[:lower:]')

    # Replace tokens in files
    sed -i "s/__DOMAIN__/${sed_safe_domain}/g" vite.config.js
    sed -i "s/\"name\": \".*\"/\"name\": \"${frontend_name_lower}\"/" package.json
    sed -i "s/__FRONTEND_NAME__/${FRONTEND_NAME}/g" package-lock.json

    find . \( -name "*.jsx" -o -name "*.html" \) -type f \
        -exec sed -i "s/__PROJECT_NAME__/${PROJECT_NAME}/g" {} +

    # Replace env tokens
    for file in .env.staging .env.production; do
        [[ -f "$file" ]] || continue
        sed -i "s/__DOMAIN__/${sed_safe_domain}/g" "$file"
        sed -i "s/__API_BASE_PATH__/${sed_safe_api_path}/g" "$file"
    done

    GH_TARGET="${GITHUB_ORG:-$REPO_OWNER}"

    if [[ -z "$GH_TARGET" || -z "$FRONTEND_NAME" ]]; then
        error "GH_TARGET or FRONTEND_NAME is empty! Cannot create repo."
        return 1
    fi

    # Git init & commit
    git init -b main
    git config user.name "$REPO_OWNER"
    git config user.email "$EMAIL"

    git add .
    git commit -m "Initial commit for frontend ${PROJECT_NAME} [skip ci]"

    # GitHub repo creation & push 
    gh repo create "$GH_TARGET/$FRONTEND_NAME" --private --source="$frontend_path" --push

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

    local API_BASE_PATH=""
    local DEPLOY_PROJECT_NAME="$PROJECT_NAME"
    local DOMAIN_NAME=""

    if [[ "$PROFILE_TYPE" == "apps" ]]; then
        API_BASE_PATH=$(jq -r '.api_base_path // "/apps/'"$PROJECT_NAME"'"' "$PROFILE_JSON")
        DEPLOY_PROJECT_NAME="$(jq -r .parent_project "$PROFILE_JSON")"
        DEPLOY_PROJECT_NAME="${DEPLOY_PROJECT_NAME}"

        local parent_profile="$PROFILE_DIR/${DEPLOY_PROJECT_NAME}.json"
        DOMAIN_NAME=$(jq -r '.domain // ""' "$parent_profile")
    fi

    local backend_path="$PROJECT_DIR/$BACKEND_NAME"
    cd "$backend_path" || exit 1

    # ------------------------------------------------------------------
    # Workflow token replacement (PM2 names, paths, backend name)
    # ------------------------------------------------------------------
    for file in .github/workflows/*.yml; do
        [[ -f "$file" ]] || continue

        local ENV_NAME="staging"
        [[ "$file" == *"production"* ]] && ENV_NAME="production"

        local RUNNER_BASE="/opt/actions-runners/backend-${ENV_NAME}/_work"
        local BACKEND_ROOT="$RUNNER_BASE/$BACKEND_NAME/$BACKEND_NAME"
        local DLL_PATH="$BACKEND_ROOT/WebAppBackend.dll"

        # PM2 app name
        local PM2_APP_NAME="${DEPLOY_PROJECT_NAME}-backend"
        if [[ "$PROFILE_TYPE" == "apps" ]]; then
            PM2_APP_NAME="${PM2_APP_NAME}-${PROJECT_NAME}"
        fi
        PM2_APP_NAME="${PM2_APP_NAME}-${ENV_NAME}"

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
    declare -A TOKEN_REPLACEMENTS=(
        ["__PROJECT_NAME__"]="$PROJECT_NAME"
        ["__DOMAIN_NAME__"]="$DOMAIN_NAME"
        ["__API_BASE_PATH__"]="$API_BASE_PATH"
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
        sed -i "/app.UsePathBase(__API_BASE_PATH__)/c\\
if (!string.IsNullOrEmpty(builder.Configuration[\"BasePath\"])) {\\
    app.UsePathBase(builder.Configuration[\"BasePath\"]);\\
}" Program.cs
    else
        sed -i "/app.UsePathBase(__API_BASE_PATH__)/d" Program.cs
    fi

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

    # ------------------------------------------------------------------
    # GitHub repo
    # ------------------------------------------------------------------
    GH_TARGET="${GITHUB_ORG:-$REPO_OWNER}"
    [[ -z "$GH_TARGET" || -z "$BACKEND_NAME" ]] && error "Missing repo info" && return 1

    git init -b main
    git config user.name "$REPO_OWNER"
    git config user.email "$EMAIL"

    git add .
    git commit -m "Initial commit for backend ${PROJECT_NAME} [skip ci]"

    gh repo create "$GH_TARGET/$BACKEND_NAME" --private --source="$backend_path" --push

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

    REPO_OWNER=$(jq -r .repo_owner "$PROFILE_JSON")
    EMAIL=$(jq -r .email "$PROFILE_JSON")
    GITHUB_ORG=$(jq -r .github_org "$PROFILE_JSON")
    GH_TARGET="${GITHUB_ORG:-$REPO_OWNER}"

    debug "$REPO_OWNER"
    debug "$EMAIL"
    

    setup_project_structure
    init_frontend_repo
    init_backend_repo
    success "🎉 Project [$PROJECT_NAME] setup complete under owner [$GH_TARGET]."
}

setup_routed_app() {
    require_profile || return 1

    [[ "$PROFILE_TYPE" != "apps" ]] && {
        error "Only routed app profiles can be set up here."
        return 1
    }

    # Ensure parent project info is loaded
    local parent_profile="$PROFILE_DIR/$(jq -r .parent_project "$PROFILE_JSON").json"
    if [[ ! -f "$parent_profile" ]]; then
        error "Parent domain profile not found: $parent_profile"
        return 1
    fi

    DOMAIN_NAME=$(jq -r .domain "$parent_profile")

    # Clone templates
    clone_templates

    # Setup project structure
    setup_project_structure

    # Initialize frontend & backend
    init_frontend_repo
    init_backend_repo

    success "🎉 Routed app [$PROJECT_NAME] setup complete under parent [$DOMAIN_NAME]"
}

exit_program() { info "Exiting program."; exit 0; }

# === Header Menu UI ===
print_header() {
    local text="===== Clone Website Wizard ====="
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
options=("Create new profile" "Remove a profile" "Use existing profile" "Create Routed App" "Detect Runtimes" "Setup Project from Profile" "Exit")

# === Main Menu Loop ===
while true; do
    print_header

    PS3="Choose an option: "
    set +u
    select opt in "${options[@]}"; do
        case $REPLY in
            1) create_new_profile ;;
            2) remove_profile ;;
            3) use_profile ;;
            4) require_profile && create_routed_app && use_profile && setup_routed_app ;;
            5) require_profile && detect_runtimes ;;
            6) require_profile && setup_project ;;
            7) exit_program ;;
            *) warn "Invalid choice" ;;
        esac
        break
    done
    set -u
done
