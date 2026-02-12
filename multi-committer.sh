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

# === Config Management ===
CONFIG_FILE="$HOME/.multi-committer.cfg"
CLONE_PROFILE_DIR="$HOME/.clone-website-profiles"
WORKING_REPO=""
TARGET_REPOS=()

save_config() {
    {
        echo "WORKING_REPO=\"$WORKING_REPO\""
        echo -n "TARGET_REPOS=("
        for repo in "${TARGET_REPOS[@]}"; do
            printf "'%s' " "$repo"
        done
        echo ")"
    } > "$CONFIG_FILE"
}

load_config() {
    [[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"
}



# === Github Authentication Helpers (Token-based) ===
TOKEN_FILE="$HOME/.multi-committer.token"

save_gh_token() {
    read -sp "Enter GitHub Personal Access Token: " token
    echo
    echo "$token" > "$TOKEN_FILE"
    chmod 600 "$TOKEN_FILE"
    success "Token saved securely for future use."
}

# Make sure Git reuses GitHub CLI credentials
ensure_git_auth() {
    local current_helper
    current_helper=$(git config --global credential.helper || echo "")

    if [[ "$current_helper" != "!gh auth git-credential" ]]; then
        info "Configuring Git to use GitHub CLI credentials..."
        git config --global credential.helper '!gh auth git-credential'
        success "Git credential helper configured."
    fi
}

ensure_gh_auth() {
    if ! gh auth status >/dev/null 2>&1; then
        if [[ ! -f "$TOKEN_FILE" ]]; then
            info "GitHub CLI not authenticated. Please provide a token."
            save_gh_token
        fi

        info "Logging in with stored token..."
        gh auth login --with-token < "$TOKEN_FILE"
        success "GitHub CLI authenticated successfully."
    fi

    ensure_git_auth
}

# === Core Functions ===
set_working_repo() {
    local current_dir repo
    current_dir="$(pwd)"

    while true; do
        echo "=== Select Working Repository ==="
        echo "Current directory: $current_dir"
        echo

        # List folders in the current directory
        local dirs=()
        local count=0
        for d in "$current_dir"/*/; do
            [[ -d "$d" ]] || continue
            count=$((count+1))
            dirs+=("$d")
            printf "%2d) %s\n" "$count" "$(basename "$d")"
        done

        echo
        echo "  0) .. (go up)"
        echo "  s) Select this directory"
        echo "  q) Cancel"
        echo

        read -p "Enter choice: " choice

        if [[ "$choice" == "q" ]]; then
            warn "Operation cancelled."
            return
        elif [[ "$choice" == "0" ]]; then
            current_dir="$(dirname "$current_dir")"
        elif [[ "$choice" == "s" ]]; then
            if [[ -d "$current_dir/.git" ]]; then
                WORKING_REPO="$(realpath "$current_dir")"
                success "Set working repo to: $WORKING_REPO"
                save_config
                return
            else
                error "This directory is not a valid git repository."
            fi
        elif [[ "$choice" =~ ^[0-9]+$ && "$choice" -le "$count" && "$choice" -gt 0 ]]; then
            current_dir="${dirs[$((choice-1))]%/}"
        else
            warn "Invalid selection."
        fi
    done
}

select_targets() {
    if [[ -z "${WORKING_REPO:-}" ]]; then
        error "Set a working repo first."
        return
    fi

    local working_name project_dir grandparent_dir
    working_name=$(basename "$WORKING_REPO")   # e.g. projectA-backend
    project_dir=$(dirname "$WORKING_REPO")     # .../SaravashaSites/projectA
    grandparent_dir=$(dirname "$project_dir")  # .../SaravashaSites

    info "Scanning for sibling projects under: $grandparent_dir"
    local repos=()

    # suffix is the part after the first hyphen: "backend" from "projectA-backend"
    local suffix="${working_name#*-}"

    # iterate each project directory directly under grandparent_dir
    for proj in "$grandparent_dir"/*; do
        [[ -d "$proj" ]] || continue
        local candidate="$proj/$(basename "$proj")-$suffix"
        if [[ -d "$candidate/.git" ]] && [[ "$candidate" != "$WORKING_REPO" ]]; then
            # Use realpath to preserve spaces and absolute path
            repos+=("$(realpath "$candidate")")
        fi
    done

    if [[ ${#repos[@]} -eq 0 ]]; then
        warn "No matching sibling repositories found for suffix '-$suffix'."
        return
    fi

    info "Found ${#repos[@]} sibling repositories with suffix '-$suffix':"
    for i in "${!repos[@]}"; do
        printf "  %2d) %s\n" $((i+1)) "${repos[$i]}"
    done

    read -p "Enter numbers (space-separated) of target repos: " -a selection
    TARGET_REPOS=()
    for num in "${selection[@]}"; do
        if [[ $num =~ ^[0-9]+$ ]] && (( num >= 1 && num <= ${#repos[@]} )); then
            TARGET_REPOS+=("${repos[$((num-1))]}")
        else
            warn "Ignoring invalid selection: $num"
        fi
    done

    if [[ ${#TARGET_REPOS[@]} -eq 0 ]]; then
        warn "No target repos selected."
        return
    fi

    success "Selected target repos:"
    for repo in "${TARGET_REPOS[@]}"; do
        echo "  $repo"
    done

    save_config
}

backup_repo() {
    local target="$1"
    [[ -z "$target" ]] && { warn "No target repo specified for backup."; return; }

    local backup_dir="$target/$BACKUP_DIR_NAME"
    mkdir -p "$backup_dir"

    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_path="$backup_dir/backup_$timestamp"

    info "Backing up $target to $backup_path"
    # Copy the target repo, excluding its own backups
    rsync -a --exclude "$BACKUP_DIR_NAME" "$target"/ "$backup_path"/
}


# === Ensure we don't include backups into source control ===
ensure_gitignore_backup_exclusion() {
    local repo="$1"
    local ignore_file="$repo/.gitignore"

    # Only operate on valid git repos
    if [[ -d "$repo/.git" ]]; then
        if [[ ! -f "$ignore_file" ]]; then
            echo ".multi-committer-backup/" > "$ignore_file"
            info "Created .gitignore and added .multi-committer-backup/ in $repo"
        elif ! grep -qxF ".multi-committer-backup/" "$ignore_file" 2>/dev/null; then
            echo ".multi-committer-backup/" >> "$ignore_file"
            info "Added .multi-committer-backup/ to $ignore_file"
        fi
    fi
}

# === Rsync with backup ===

BACKUP_DIR_NAME=".multi-committer-backup"

# === Get list of changed files relative to WORKING_REPO ===
# === Get list of locally changed files (tracked only) ===
# === Get list of locally changed files ===
get_changed_files() {
    [[ -z "${WORKING_REPO:-}" ]] && { error "No working repo set."; return 1; }
    cd "$WORKING_REPO" || return 1
    {
        # 1. Unstaged changes (ignore whitespace/line endings)
        git diff -w --name-only

        # 2. Staged changes (ignore whitespace/line endings)
        git diff --cached -w --name-only

        # 3. Untracked files
        git ls-files --others --exclude-standard
    } | sort -u \
      | grep -Ev '^(bin/|obj/|Migrations/|\.cache/|\.props|\.targets|\.git/|node_modules/|build/|dist/|\.eslintcache|.*\.log|.*\.lock|$BACKUP_DIR_NAME/)'
}
# === Dry-run: preview which files would be synced ===
apply_changes_rsync_dry() {
    [[ -z "${WORKING_REPO:-}" ]] && { error "No working repo set."; return; }
    [[ ${#TARGET_REPOS[@]} -eq 0 ]] && { warn "No target repos selected."; return; }

    mapfile -t files < <(get_changed_files)
    [[ ${#files[@]} -eq 0 ]] && { info "No local changes to sync."; return; }

    info "Dry-run: rsync would sync the following files:"
    printf '%s\n' "${files[@]}"

    for repo in "${TARGET_REPOS[@]}"; do
        printf "\n--- Dry-run for %s ---\n" "$repo"
        rsync -avn \
            --files-from=<(printf '%s\n' "${files[@]}") \
            --relative \
            --exclude '.git' \
            "$WORKING_REPO"/ "$repo"/
            
        success "Dry-run complete for $repo"
    done
}

# === Apply changes: actually sync local edits ===
apply_changes_rsync() {
    [[ -z "${WORKING_REPO:-}" ]] && { error "No working repo set."; return; }
    [[ ${#TARGET_REPOS[@]} -eq 0 ]] && { warn "No target repos selected."; return; }

    # Get the list of changed files (staged, unstaged, untracked)
    mapfile -t files < <(get_changed_files)
    [[ ${#files[@]} -eq 0 ]] && { info "No local changes to sync."; return; }

    ensure_gitignore_backup_exclusion "$WORKING_REPO" 
    for repo in "${TARGET_REPOS[@]}"; do
        ensure_gitignore_backup_exclusion "$repo"
        printf "\n--- Applying changes to %s ---\n" "$repo"

        # Backup target repo first
        backup_repo "$repo"

        # Use NUL-delimited file list to safely handle spaces in filenames
        printf '%s\0' "${files[@]}" | rsync -av --files-from=- --from0 \
            --relative \
            --exclude '.git' \
            "$WORKING_REPO"/ "$repo"/

        success "Changes applied to $repo"
    done
}

commit_changes_local() {
    [[ -z "${WORKING_REPO:-}" ]] && { error "No working repo set."; return; }
    [[ ${#TARGET_REPOS[@]} -eq 0 ]] && { warn "No target repos selected."; return; }

    read -p "Enter commit message: " commit_msg
    [[ -z "$commit_msg" ]] && { warn "Commit message cannot be empty."; return; }

    # Commit working repo
    cd "$WORKING_REPO"
    git add .
    git commit -m "$commit_msg" || info "Nothing to commit in working repo."

    # Commit target repos
    for repo in "${TARGET_REPOS[@]}"; do
        cd "$repo"
        git add .
        git commit -m "$commit_msg" || info "Nothing to commit in $repo."
    done

    success "All repositories committed locally."
}

push_changes_with_pr_to_stage() {
    [[ -z "${WORKING_REPO:-}" ]] && { error "No working repo set."; return; }
    [[ ${#TARGET_REPOS[@]} -eq 0 ]] && { warn "No target repos selected."; return; }

    local local_branch="dev"
    local remote_branch="dev"
    local pr_base_branch="stage"

    ensure_gh_auth

    # Push working repo
    pushd "$WORKING_REPO" >/dev/null || return
    git push origin "$local_branch:$remote_branch"
    success "Working repo pushed to remote '$remote_branch'."
    popd >/dev/null

    # Push target repos
    for repo in "${TARGET_REPOS[@]}"; do
        pushd "$repo" >/dev/null || continue
        git push origin "$local_branch:$remote_branch"
        success "Target repo pushed to remote '$remote_branch'."
        popd >/dev/null
    done

    # Create PRs
    if command -v gh &>/dev/null; then
        info "Creating PRs from '$local_branch' → '$pr_base_branch'..."
        for repo in "$WORKING_REPO" "${TARGET_REPOS[@]}"; do
            pushd "$repo" >/dev/null || continue
            gh pr create --base "$pr_base_branch" --head "$local_branch" \
                --title "Sync changes from multi-committer" \
                --body "Automated PR from multi-committer script." \
                || warn "PR may already exist for $(basename "$repo")"
            popd >/dev/null
        done
        success "PR creation complete for all repos."
    else
        warn "GitHub CLI not found. Please create PRs manually."
    fi
}


# === Cleanup and Ctrl+C Handling ===
trap 'echo; warn "Aborted by user."; exit 1' SIGINT

exit_program() { info "Exiting program."; exit 0; }

load_config
# === Header Menu UI ===
print_header() {
    local text="===== ZigiProjectManager >>  Multi-Committer Wizard ====="
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
options=("Set current working repo" "Select target repositories" "Rsync dry run (preview sync)" "Rsync apply changes" "Commit all changes locally" "Push all commits to remote" $'\033[1;33mReturn to Menu\033[0m')

# === Main Menu Loop ===
while true; do
    print_header
    debug "Debug mode engaged!"

    PS3="Choose an option: "
    set +u
    select opt in "${options[@]}"; do
        case $REPLY in
            1) set_working_repo ;;
            2) select_targets ;;
            3) apply_changes_rsync_dry ;;
            4) apply_changes_rsync ;;
            5) commit_changes_local ;;
            6) push_changes_with_pr_to_stage ;;
            7) exit_program ;;
            *) warn "Invalid choice, try again." ;;
        esac
        break
    done
    set -u
done
