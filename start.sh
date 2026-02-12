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

# === Helper Function ===
confirm() {
    local r
    read -rp "⏳ $1 (y/n): " r || return 1
    [[ $r =~ ^[Yy]$ ]]
}

# === Colored Output Functions ===
info()    { echo -e "\033[1;34m[INFO]:🔍 $*\033[0m"; }
warn()    { echo -e "\033[1;33m[WARN]:⚠️ $*\033[0m"; }
error()   { echo -e "\033[1;31m[ERROR]:❌ $*\033[0m"; }
success() { echo -e "\033[1;32m[SUCCESS]:✅ $*\033[0m"; }
help()    { echo -e "\033[1;36m[HELP:]💡 $*\033[0m"; }
debug() {
  if [[ "$DEBUG" == true && "$DEBUG_VERBOSE" == false ]]; then
    echo -e "\033[38;5;208m[DEBUG]:⚙️ $*\033[0m"
  fi
}


clone_website_template() {

    info "Running Project Cloning Service..."
    read -rp "Press Enter to continue..."
    bash "./clone-website-template.sh"

}

setup_vps() {

    info "Running Setup a Domain VPS with Project Service..."
    warn "You must have already configured a template website (option 1) before using this service."

    if confirm "Are you sure?"; then
        bash "./setup-vps.sh"
    else
        warn "Cancelled."
    fi

}

setup_app() {

    info "Running Setup a Routed App on existing Domain VPS (Experimental)..."
    warn "You must have already configured a VPS with a working Domain site (option 2) before using this service."
    
    if confirm "Are you sure?"; then
        bash "./setup-app.sh"
    else
        warn "Cancelled."
    fi

}

multi_committer() {

    info "Running Project Manager..."
    warn "This service expects you to have multiple apps in your (organization OR user) to work with."

    if confirm "Are you sure?"; then
        bash "./multi-committer.sh"
    else
        warn "Cancelled."
    fi

}

halp() {

    help "How to use this thing:"
    help "1. Start by cloning the template into a new project by supplying the form with information."
    help "2. Setup your VPS for your Domain App Project that you made using the previous step."
    help "*. When you are done with the implementation of Domain App Project, you may use this service to host multiple apps on your Domain/VPS (Optional)."
    help "*. If you have several projects that you are managing, you may use this service to push similar updates to the other projects of your choosing (Optional)."
    read -rp "Press Enter to continue..."

}

exit_program() { info "Exiting program."; exit 0; }

# === Header Menu UI ===
print_header() {
    local text="===== ZigiProjectManager ====="
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
signature() {
    name="By Saravasha"
    echo -e "\033[1;36m"$name"\033[0m";
}
options=("Run Clone Project Service" "Setup a VPS with a Domain Project" "Setup Applets for your Domain" \
         "Projects Manager Service" "Halp" $'\033[1;31mExit\033[0m')

# === Main Menu Loop ===
while true; do
    print_header
    signature
    debug "Debug mode engaged!"

    PS3="Choose an option: "
    set +u
    select opt in "${options[@]}"; do
        case $REPLY in
            1) clone_website_template ;;
            2) setup_vps ;;
            3) setup_app ;;
            4) multi_committer ;;
            5) halp ;;
            6) exit_program ;;
            *) warn "Invalid option, choose 1-${#options[@]}" ;;
        esac
        break
    done
    set -u
done
