
debug "Seting environment file"
PROJECT_NAME="${PROFILE_NAME}"
SAFE_PROJECT_NAME=$(echo "$PROJECT_NAME" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]_-')
ENV_FILE="/etc/myapp_${SAFE_REPO_OWNER}-${PROFILE_NAME}.env"

# db names
DB_NAME_PRODUCTION="${SAFE_PROJECT_NAME}_production"
DB_NAME_STAGING="${SAFE_PROJECT_NAME}_staging"
