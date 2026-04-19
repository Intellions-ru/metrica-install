#!/usr/bin/env bash
set -Eeuo pipefail

INSTALLER_VERSION="v1"
DEFAULT_INSTALL_DIR="/opt/intellion-metrica"
DEFAULT_IMAGE_VERSION="v0.1.0"
DEFAULT_BUNDLE_REF="$DEFAULT_IMAGE_VERSION"
DEFAULT_IMAGE_REGISTRY="ghcr.io/intellions-ru"
DEFAULT_PRODUCT_BUNDLE_URL_BASE="https://github.com/Intellions-ru/metrica-install/releases/download"
SOURCE_FALLBACK_BUNDLE_URL_BASE="https://codeload.github.com/intellions/intellions_io/tar.gz/refs/heads"
MIN_MEMORY_MB=2048
WARN_MEMORY_MB=4096
MIN_DISK_GB=8
WARN_DISK_GB=15

INSTALLATION_NAME=""
INSTALLATION_ID=""
PUBLISH_MODE=""
PUBLIC_HOST=""
ENTRY_PATH="/analytics"
OWNER_EMAIL=""
OWNER_NAME="Владелец Метрики"
OWNER_PASSWORD=""
IMAGE_REGISTRY="$DEFAULT_IMAGE_REGISTRY"
ACME_EMAIL=""
INSTALL_DIR="$DEFAULT_INSTALL_DIR"
IMAGE_VERSION="$DEFAULT_IMAGE_VERSION"
METRICA_API_IMAGE=""
METRICA_WORKER_IMAGE=""
METRICA_CONTROL_PLANE_IMAGE=""
ENTITLEMENT_FILE=""
DB_NAME="intellion_metrica"
DB_USER="metrica"
DB_PASSWORD=""
DB_PORT="55432"
CONTROL_PLANE_PORT="3300"
MAX_BOT_TOKEN=""
MAX_TARGET_KIND="none"
MAX_TARGET_VALUE=""
PRECHECK_ONLY=0
NON_INTERACTIVE=0
DRY_RUN=0
AUTO_INSTALL_DOCKER=1
SKIP_DNS_CHECK=0
BUNDLE_REF="$DEFAULT_BUNDLE_REF"
BUNDLE_URL=""

SCRIPT_SOURCE="${BASH_SOURCE[0]:-}"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SOURCE")" 2>/dev/null && pwd || pwd)"
LOCAL_ANALYTICS_ROOT="$(cd "$SCRIPT_DIR/.." 2>/dev/null && pwd || true)"

BOOT_TS="$(date -u +%Y%m%dT%H%M%SZ)"
BOOT_LOG_DIR="/tmp/intellion-metrica-install"
mkdir -p "$BOOT_LOG_DIR"
LOG_FILE="$BOOT_LOG_DIR/install-${BOOT_TS}.log"
exec > >(tee -a "$LOG_FILE") 2>&1

WARNINGS=()
BUNDLE_ROOT=""
DOWNLOADED_BUNDLE_DIR=""
FINAL_STATUS="passed"
FINAL_REPORT_PATH=""
FINAL_LOG_PATH=""
FINAL_ENTITLEMENT_STATUS="unknown"
OWNER_ACTIVATION_URL=""
OWNER_ACTIVATION_PATH=""

on_exit() {
  local exit_code="$1"
  if [[ -n "$DOWNLOADED_BUNDLE_DIR" && -d "$DOWNLOADED_BUNDLE_DIR" ]]; then
    rm -rf "$DOWNLOADED_BUNDLE_DIR"
  fi
  if [[ "$exit_code" -ne 0 ]]; then
    printf '[install] failed, log: %s\n' "$LOG_FILE" >&2
  fi
}
trap 'on_exit $?' EXIT

usage() {
  cat <<'EOF'
Usage:
  install_metrica.sh [options]

Main modes:
  --publish-mode subdomain|path
  --domain <host>
  --installation-name <name>
  --owner-email <email>

Optional:
  --owner-name <name>
  --owner-password <password>   # legacy fallback only
  --install-dir <path>
  --image-version <tag>
  --image-registry <registry>
  --api-image <ref>
  --worker-image <ref>
  --control-plane-image <ref>
  --entry-path </analytics>
  --entitlement-file <path>
  --acme-email <email>
  --max-bot-token <token>
  --max-target-kind none|user|chat
  --max-target-value <value>
  --bundle-ref <git-ref>
  --bundle-url <tar.gz url>
  --non-interactive
  --preflight-only
  --dry-run
  --skip-dns-check
  --no-docker-install
  --help

Examples:
  sudo bash ./scripts/install_metrica.sh \
    --publish-mode subdomain \
    --domain analytics.example.com \
    --installation-name "Example Analytics" \
    --owner-email owner@example.com

  curl -fsSL https://raw.githubusercontent.com/Intellions-ru/metrica-install/main/install_metrica.sh \
    | sudo bash -s -- \
      --publish-mode path \
      --domain example.com \
      --installation-name "Example Analytics" \
      --owner-email owner@example.com
EOF
}

log() {
  printf '[install] %s\n' "$*"
}

warn() {
  WARNINGS+=("$*")
  printf '[install][warn] %s\n' "$*" >&2
}

die() {
  printf '[install][error] %s\n' "$*" >&2
  exit 1
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "Installer must run as root. Use sudo bash install_metrica.sh ..."
  fi
}

have_command() {
  command -v "$1" >/dev/null 2>&1
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

escape_sed() {
  printf '%s' "$1" | sed 's/[\/&|]/\\&/g'
}

random_hex() {
  local bytes="$1"
  od -An -N "$bytes" -tx1 /dev/urandom | tr -d ' \n'
}

random_alnum() {
  local length="$1"
  LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$length"
}

fetch_url() {
  local url="$1"
  local destination="$2"

  if have_command curl; then
    curl -fsSL "$url" -o "$destination"
    return
  fi

  if have_command wget; then
    wget -qO "$destination" "$url"
    return
  fi

  die "Neither curl nor wget is available."
}

prompt_value() {
  local var_name="$1"
  local prompt_text="$2"
  local default_value="${3:-}"
  local value="${!var_name:-}"

  if [[ -n "$value" || "$NON_INTERACTIVE" -eq 1 ]]; then
    return
  fi

  if [[ -n "$default_value" ]]; then
    read -r -p "$prompt_text [$default_value]: " value || true
    value="${value:-$default_value}"
  else
    read -r -p "$prompt_text: " value || true
  fi

  printf -v "$var_name" '%s' "$value"
}

validate_email() {
  [[ "$1" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]
}

validate_host() {
  [[ "$1" =~ ^[A-Za-z0-9.-]+$ ]]
}

validate_entry_path() {
  [[ "$1" =~ ^/[-A-Za-z0-9/_]+$ ]]
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --publish-mode)
        PUBLISH_MODE="${2:-}"
        shift 2
        ;;
      --domain|--host)
        PUBLIC_HOST="${2:-}"
        shift 2
        ;;
      --installation-name)
        INSTALLATION_NAME="${2:-}"
        shift 2
        ;;
      --owner-email)
        OWNER_EMAIL="${2:-}"
        shift 2
        ;;
      --owner-name)
        OWNER_NAME="${2:-}"
        shift 2
        ;;
      --owner-password)
        OWNER_PASSWORD="${2:-}"
        shift 2
        ;;
      --install-dir)
        INSTALL_DIR="${2:-}"
        shift 2
        ;;
      --image-version)
        IMAGE_VERSION="${2:-}"
        shift 2
        ;;
      --image-registry)
        IMAGE_REGISTRY="${2:-}"
        shift 2
        ;;
      --api-image)
        METRICA_API_IMAGE="${2:-}"
        shift 2
        ;;
      --worker-image)
        METRICA_WORKER_IMAGE="${2:-}"
        shift 2
        ;;
      --control-plane-image)
        METRICA_CONTROL_PLANE_IMAGE="${2:-}"
        shift 2
        ;;
      --entry-path)
        ENTRY_PATH="${2:-}"
        shift 2
        ;;
      --entitlement-file)
        ENTITLEMENT_FILE="${2:-}"
        shift 2
        ;;
      --acme-email)
        ACME_EMAIL="${2:-}"
        shift 2
        ;;
      --max-bot-token)
        MAX_BOT_TOKEN="${2:-}"
        shift 2
        ;;
      --max-target-kind)
        MAX_TARGET_KIND="${2:-}"
        shift 2
        ;;
      --max-target-value)
        MAX_TARGET_VALUE="${2:-}"
        shift 2
        ;;
      --bundle-ref)
        BUNDLE_REF="${2:-}"
        shift 2
        ;;
      --bundle-url)
        BUNDLE_URL="${2:-}"
        shift 2
        ;;
      --preflight-only)
        PRECHECK_ONLY=1
        shift
        ;;
      --non-interactive)
        NON_INTERACTIVE=1
        shift
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --skip-dns-check)
        SKIP_DNS_CHECK=1
        shift
        ;;
      --no-docker-install)
        AUTO_INSTALL_DOCKER=0
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done
}

collect_inputs() {
  if [[ -z "$PUBLISH_MODE" && "$NON_INTERACTIVE" -eq 0 ]]; then
    read -r -p "Publication mode (subdomain/path) [subdomain]: " PUBLISH_MODE || true
    PUBLISH_MODE="${PUBLISH_MODE:-subdomain}"
  fi

  prompt_value PUBLIC_HOST "Public domain for Metrica"
  prompt_value INSTALLATION_NAME "Installation name"
  prompt_value OWNER_EMAIL "Owner email"
  prompt_value OWNER_NAME "Owner full name" "$OWNER_NAME"
  prompt_value ACME_EMAIL "Email for TLS notifications" "${ACME_EMAIL:-$OWNER_EMAIL}"

  if [[ -z "$MAX_BOT_TOKEN" && "$NON_INTERACTIVE" -eq 0 ]]; then
    local use_max=""
    read -r -p "Configure MAX bot now? [y/N]: " use_max || true
    if [[ "$use_max" =~ ^[Yy]$ ]]; then
      prompt_value MAX_BOT_TOKEN "MAX bot token"
    fi
  fi

  if [[ "$PUBLISH_MODE" == "path" ]]; then
    prompt_value ENTRY_PATH "Entry path on the main domain" "$ENTRY_PATH"
  fi

  [[ -n "$PUBLISH_MODE" ]] || die "Publication mode is required."
  [[ "$PUBLISH_MODE" == "subdomain" || "$PUBLISH_MODE" == "path" ]] || die "Publication mode must be subdomain or path."
  [[ -n "$PUBLIC_HOST" ]] || die "Public domain is required."
  validate_host "$PUBLIC_HOST" || die "Invalid public domain: $PUBLIC_HOST"
  [[ -n "$INSTALLATION_NAME" ]] || die "Installation name is required."
  [[ -n "$OWNER_EMAIL" ]] || die "Owner email is required."
  validate_email "$OWNER_EMAIL" || die "Invalid owner email: $OWNER_EMAIL"
  [[ -n "$ACME_EMAIL" ]] || die "TLS contact email is required."
  validate_email "$ACME_EMAIL" || die "Invalid TLS contact email: $ACME_EMAIL"
  validate_entry_path "$ENTRY_PATH" || die "Invalid entry path: $ENTRY_PATH"
  [[ -z "$ENTITLEMENT_FILE" || -f "$ENTITLEMENT_FILE" ]] || die "Entitlement file was not found: $ENTITLEMENT_FILE"
  [[ "$MAX_TARGET_KIND" == "none" || "$MAX_TARGET_KIND" == "user" || "$MAX_TARGET_KIND" == "chat" ]] || die "MAX target kind must be none, user or chat."
  if [[ "$MAX_TARGET_KIND" != "none" && -z "$MAX_TARGET_VALUE" ]]; then
    die "MAX target value is required when MAX target kind is set."
  fi
}

resolve_image_refs() {
  if [[ -z "$METRICA_API_IMAGE" ]]; then
    METRICA_API_IMAGE="${IMAGE_REGISTRY}/intellion-metrica-api:${IMAGE_VERSION}"
  fi
  if [[ -z "$METRICA_WORKER_IMAGE" ]]; then
    METRICA_WORKER_IMAGE="${IMAGE_REGISTRY}/intellion-metrica-worker:${IMAGE_VERSION}"
  fi
  if [[ -z "$METRICA_CONTROL_PLANE_IMAGE" ]]; then
    METRICA_CONTROL_PLANE_IMAGE="${IMAGE_REGISTRY}/intellion-metrica-control-plane:${IMAGE_VERSION}"
  fi
}

install_fetch_tool() {
  if have_command curl || have_command wget; then
    return
  fi

  log "Installing curl because neither curl nor wget is available."
  if [[ -f /etc/debian_version ]]; then
    apt-get update -y
    apt-get install -y curl ca-certificates
    return
  fi
  if [[ -f /etc/redhat-release ]]; then
    if have_command dnf; then
      dnf install -y curl ca-certificates
    else
      yum install -y curl ca-certificates
    fi
    return
  fi

  die "Neither curl nor wget is available, and the installer does not know how to install curl on this OS."
}

install_docker_if_needed() {
  if have_command docker && docker compose version >/dev/null 2>&1; then
    return
  fi

  [[ "$AUTO_INSTALL_DOCKER" -eq 1 ]] || die "Docker or docker compose plugin is missing."

  install_fetch_tool
  log "Installing Docker via the official convenience script."
  if have_command curl; then
    curl -fsSL https://get.docker.com | sh
  else
    wget -qO- https://get.docker.com | sh
  fi

  if have_command systemctl; then
    systemctl enable --now docker || true
  fi

  have_command docker || die "Docker installation did not finish successfully."
  docker compose version >/dev/null 2>&1 || die "Docker Compose plugin is not available after Docker installation."
}

port_is_busy() {
  local port="$1"
  ss -ltn "( sport = :${port} )" 2>/dev/null | awk 'NR > 1 {print}' | grep -q .
}

preflight_checks() {
  log "Running preflight checks."

  [[ "$(uname -s)" == "Linux" ]] || die "This installer supports Linux only."
  require_root

  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64|aarch64|arm64)
      ;;
    *)
      warn "Architecture $arch is not in the validated list for current published images."
      ;;
  esac

  local mem_mb
  mem_mb="$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)"
  if (( mem_mb < MIN_MEMORY_MB )); then
    die "Not enough memory: ${mem_mb}MB. Minimum supported memory is ${MIN_MEMORY_MB}MB."
  fi
  if (( mem_mb < WARN_MEMORY_MB )); then
    warn "Available memory is ${mem_mb}MB. Recommended memory is at least ${WARN_MEMORY_MB}MB."
  fi

  local disk_target free_kb free_gb
  disk_target="$INSTALL_DIR"
  mkdir -p "$disk_target"
  free_kb="$(df -Pk "$disk_target" | awk 'NR==2 {print $4}')"
  free_gb="$(( free_kb / 1024 / 1024 ))"
  if (( free_gb < MIN_DISK_GB )); then
    die "Not enough free disk space: ${free_gb}GB. Minimum required free space is ${MIN_DISK_GB}GB."
  fi
  if (( free_gb < WARN_DISK_GB )); then
    warn "Free disk space is ${free_gb}GB. Recommended free space is at least ${WARN_DISK_GB}GB."
  fi

  have_command tar || die "tar is required."
  have_command awk || die "awk is required."
  have_command sed || die "sed is required."
  have_command ss || die "ss is required."

  install_fetch_tool
  install_docker_if_needed

  if port_is_busy 80; then
    die "Port 80 is already in use."
  fi
  if port_is_busy 443; then
    die "Port 443 is already in use."
  fi
  if port_is_busy "$CONTROL_PLANE_PORT"; then
    die "Local control-plane port ${CONTROL_PLANE_PORT} is already in use."
  fi
  if port_is_busy "$DB_PORT"; then
    die "Local database port ${DB_PORT} is already in use."
  fi

  if [[ -d "$INSTALL_DIR" && -f "$INSTALL_DIR/.env" ]]; then
    die "Install directory $INSTALL_DIR already contains an installation."
  fi

  local existing_names
  existing_names="$(docker ps -a --format '{{.Names}}' | grep '^intellion-metrica-' || true)"
  if [[ -n "$existing_names" ]]; then
    die "Conflicting containers already exist: $(printf '%s' "$existing_names" | tr '\n' ' ')"
  fi

  if [[ "$SKIP_DNS_CHECK" -eq 0 ]]; then
    if ! getent ahosts "$PUBLIC_HOST" >/dev/null 2>&1; then
      die "Domain $PUBLIC_HOST does not resolve yet."
    fi
  else
    warn "DNS readiness check is skipped."
  fi

  if ! docker manifest inspect "$METRICA_API_IMAGE" >/dev/null 2>&1; then
    die "Failed to reach image registry or image ref is invalid: $METRICA_API_IMAGE"
  fi
  if ! docker manifest inspect "$METRICA_WORKER_IMAGE" >/dev/null 2>&1; then
    die "Failed to reach image registry or image ref is invalid: $METRICA_WORKER_IMAGE"
  fi
  if ! docker manifest inspect "$METRICA_CONTROL_PLANE_IMAGE" >/dev/null 2>&1; then
    die "Failed to reach image registry or image ref is invalid: $METRICA_CONTROL_PLANE_IMAGE"
  fi

  log "Preflight checks passed."
}

resolve_bundle_root() {
  if [[ -f "$LOCAL_ANALYTICS_ROOT/install/docker-compose.install.yml" && -d "$LOCAL_ANALYTICS_ROOT/db/migrations" ]]; then
    BUNDLE_ROOT="$LOCAL_ANALYTICS_ROOT"
    return
  fi

  local work_dir archive candidate
  work_dir="$(mktemp -d)"
  DOWNLOADED_BUNDLE_DIR="$work_dir"
  archive="$work_dir/install-bundle.tar.gz"

  if [[ -z "$BUNDLE_URL" ]]; then
    if [[ "$DEFAULT_PRODUCT_BUNDLE_URL_BASE" == *"/releases/download" ]]; then
      BUNDLE_URL="${DEFAULT_PRODUCT_BUNDLE_URL_BASE}/${BUNDLE_REF}/intellion-metrica-install-bundle-${BUNDLE_REF}.tar.gz"
    else
      BUNDLE_URL="${DEFAULT_PRODUCT_BUNDLE_URL_BASE}/intellion-metrica-install-bundle-${BUNDLE_REF}.tar.gz"
    fi
  fi

  log "Downloading install bundle from $BUNDLE_URL"
  if ! fetch_url "$BUNDLE_URL" "$archive"; then
    local fallback_url
    fallback_url="${SOURCE_FALLBACK_BUNDLE_URL_BASE}/${BUNDLE_REF}"
    warn "Product install bundle was not downloaded. Falling back to source bundle: $fallback_url"
    fetch_url "$fallback_url" "$archive"
  fi
  tar -xzf "$archive" -C "$work_dir"

  candidate="$(find "$work_dir" -path '*/intellions-analytics/install/docker-compose.install.yml' -print | head -n 1 || true)"
  [[ -n "$candidate" ]] || die "Failed to locate install bundle contents after download."
  BUNDLE_ROOT="$(cd "$(dirname "$(dirname "$candidate")")" && pwd)"
}

render_template() {
  local source="$1"
  local destination="$2"
  local rendered
  rendered="$(cat "$source")"

  rendered="$(printf '%s' "$rendered" | sed "s|{{DB_NAME}}|$(escape_sed "$DB_NAME")|g")"
  rendered="$(printf '%s' "$rendered" | sed "s|{{DB_USER}}|$(escape_sed "$DB_USER")|g")"
  rendered="$(printf '%s' "$rendered" | sed "s|{{DB_PASSWORD}}|$(escape_sed "$DB_PASSWORD")|g")"
  rendered="$(printf '%s' "$rendered" | sed "s|{{DB_PORT}}|$(escape_sed "$DB_PORT")|g")"
  rendered="$(printf '%s' "$rendered" | sed "s|{{METRICA_API_IMAGE}}|$(escape_sed "$METRICA_API_IMAGE")|g")"
  rendered="$(printf '%s' "$rendered" | sed "s|{{METRICA_WORKER_IMAGE}}|$(escape_sed "$METRICA_WORKER_IMAGE")|g")"
  rendered="$(printf '%s' "$rendered" | sed "s|{{METRICA_CONTROL_PLANE_IMAGE}}|$(escape_sed "$METRICA_CONTROL_PLANE_IMAGE")|g")"
  rendered="$(printf '%s' "$rendered" | sed "s|{{BOOTSTRAP_TOKEN}}|$(escape_sed "$BOOTSTRAP_TOKEN")|g")"
  rendered="$(printf '%s' "$rendered" | sed "s|{{SECRET_ENCRYPTION_KEY}}|$(escape_sed "$SECRET_ENCRYPTION_KEY")|g")"
  rendered="$(printf '%s' "$rendered" | sed "s|{{CSRF_SECRET}}|$(escape_sed "$CSRF_SECRET")|g")"
  rendered="$(printf '%s' "$rendered" | sed "s|{{ALLOWED_ORIGINS}}|$(escape_sed "$ALLOWED_ORIGIN")|g")"
  rendered="$(printf '%s' "$rendered" | sed "s|{{CONTROL_PLANE_PORT}}|$(escape_sed "$CONTROL_PLANE_PORT")|g")"
  rendered="$(printf '%s' "$rendered" | sed "s|{{MAX_BOT_TOKEN}}|$(escape_sed "$MAX_BOT_TOKEN")|g")"
  rendered="$(printf '%s' "$rendered" | sed "s|{{MAX_WEBHOOK_SECRET}}|$(escape_sed "$MAX_WEBHOOK_SECRET")|g")"
  rendered="$(printf '%s' "$rendered" | sed "s|{{MAX_REPORT_DELIVERY_MODE}}|$(escape_sed "$MAX_REPORT_DELIVERY_MODE")|g")"
  rendered="$(printf '%s' "$rendered" | sed "s|{{MAX_REPORT_ENABLED}}|$(escape_sed "$MAX_REPORT_ENABLED")|g")"
  rendered="$(printf '%s' "$rendered" | sed "s|{{PUBLIC_HOST}}|$(escape_sed "$PUBLIC_HOST")|g")"
  rendered="$(printf '%s' "$rendered" | sed "s|{{PUBLISH_MODE}}|$(escape_sed "$PUBLISH_MODE")|g")"
  rendered="$(printf '%s' "$rendered" | sed "s|{{ENTRY_PATH}}|$(escape_sed "$ENTRY_PATH")|g")"
  rendered="$(printf '%s' "$rendered" | sed "s|{{INSTALLATION_ID}}|$(escape_sed "$INSTALLATION_ID")|g")"
  rendered="$(printf '%s' "$rendered" | sed "s|{{INSTALLATION_NAME}}|$(escape_sed "$INSTALLATION_NAME")|g")"
  rendered="$(printf '%s' "$rendered" | sed "s|{{OWNER_EMAIL}}|$(escape_sed "$OWNER_EMAIL")|g")"
  rendered="$(printf '%s' "$rendered" | sed "s|{{OWNER_NAME}}|$(escape_sed "$OWNER_NAME")|g")"
  rendered="$(printf '%s' "$rendered" | sed "s|{{ACME_EMAIL}}|$(escape_sed "$ACME_EMAIL")|g")"
  rendered="$(printf '%s' "$rendered" | sed "s|{{MAX_TARGET_KIND}}|$(escape_sed "$MAX_TARGET_KIND")|g")"
  rendered="$(printf '%s' "$rendered" | sed "s|{{MAX_TARGET_VALUE}}|$(escape_sed "$MAX_TARGET_VALUE")|g")"

  printf '%s' "$rendered" >"$destination"
}

prepare_install_tree() {
  log "Preparing install tree at $INSTALL_DIR"
  mkdir -p "$INSTALL_DIR"/db "$INSTALL_DIR"/runtime "$INSTALL_DIR"/artifacts/install "$INSTALL_DIR"/logs "$INSTALL_DIR"/state "$INSTALL_DIR"/scripts
  chmod 700 "$INSTALL_DIR"/state "$INSTALL_DIR"/logs "$INSTALL_DIR"/artifacts/install

  cp "$BUNDLE_ROOT/install/docker-compose.install.yml" "$INSTALL_DIR/docker-compose.yml"
  rm -rf "$INSTALL_DIR/db/migrations"
  cp -R "$BUNDLE_ROOT/db/migrations" "$INSTALL_DIR/db/migrations"
  cp "$BUNDLE_ROOT/scripts/install_metrica.sh" "$INSTALL_DIR/scripts/install_metrica.sh"
  if [[ -f "$BUNDLE_ROOT/scripts/preflight_metrica.sh" ]]; then
    cp "$BUNDLE_ROOT/scripts/preflight_metrica.sh" "$INSTALL_DIR/scripts/preflight_metrica.sh"
  fi
  if [[ -f "$BUNDLE_ROOT/scripts/issue_metrica_entitlement.mjs" ]]; then
    cp "$BUNDLE_ROOT/scripts/issue_metrica_entitlement.mjs" "$INSTALL_DIR/scripts/issue_metrica_entitlement.mjs"
  fi
  chmod 700 "$INSTALL_DIR/scripts/install_metrica.sh"
  [[ -f "$INSTALL_DIR/scripts/preflight_metrica.sh" ]] && chmod 700 "$INSTALL_DIR/scripts/preflight_metrica.sh"
  [[ -f "$INSTALL_DIR/scripts/issue_metrica_entitlement.mjs" ]] && chmod 700 "$INSTALL_DIR/scripts/issue_metrica_entitlement.mjs"

  DB_PASSWORD="${DB_PASSWORD:-$(random_alnum 24)}"
  BOOTSTRAP_TOKEN="$(random_alnum 48)"
  SECRET_ENCRYPTION_KEY="$(random_hex 32)"
  CSRF_SECRET="$(random_alnum 48)"
  MAX_WEBHOOK_SECRET="$(random_alnum 48)"
  INSTALLATION_ID="${INSTALLATION_ID:-$(cat /proc/sys/kernel/random/uuid)}"
  ALLOWED_ORIGIN="https://${PUBLIC_HOST}"
  if [[ -n "$MAX_BOT_TOKEN" ]]; then
    MAX_REPORT_ENABLED="true"
    MAX_REPORT_DELIVERY_MODE="bot_api"
    MAX_MODE="bot_api"
  else
    MAX_REPORT_ENABLED="false"
    MAX_REPORT_DELIVERY_MODE="stdout"
    MAX_MODE="disabled"
  fi

  render_template "$BUNDLE_ROOT/install/install.env.template" "$INSTALL_DIR/.env"
  chmod 600 "$INSTALL_DIR/.env"

  if [[ "$PUBLISH_MODE" == "subdomain" ]]; then
    render_template "$BUNDLE_ROOT/install/Caddyfile.subdomain.tpl" "$INSTALL_DIR/runtime/Caddyfile"
  else
    render_template "$BUNDLE_ROOT/install/Caddyfile.path.tpl" "$INSTALL_DIR/runtime/Caddyfile"
  fi

  cat >"$INSTALL_DIR/state/installation-identity.json" <<EOF
{
  "kind": "intellion_metrica_installation_identity_v1",
  "installationId": "$(json_escape "$INSTALLATION_ID")",
  "installationName": "$(json_escape "$INSTALLATION_NAME")",
  "ownerEmail": "$(json_escape "$OWNER_EMAIL")",
  "ownerStatus": "$( [[ -n "$OWNER_PASSWORD" ]] && printf 'active' || printf 'pending_activation' )",
  "deploymentMode": "$(json_escape "$PUBLISH_MODE")",
  "publicHost": "$(json_escape "$PUBLIC_HOST")",
  "entryPath": "$(json_escape "$ENTRY_PATH")",
  "productVersion": "$(json_escape "$IMAGE_VERSION")",
  "issueTime": "$(json_escape "$BOOT_TS")",
  "activationTime": null,
  "issuer": "intellions",
  "issuedBy": "install_metrica.sh",
  "maxMode": "$(json_escape "$MAX_MODE")",
  "notes": null
}
EOF
  chmod 600 "$INSTALL_DIR/state/installation-identity.json"

  if [[ -n "$ENTITLEMENT_FILE" ]]; then
    cp "$ENTITLEMENT_FILE" "$INSTALL_DIR/state/installation-entitlement.jwt"
    chmod 600 "$INSTALL_DIR/state/installation-entitlement.jwt"
  fi

}

compose() {
  docker compose -f "$INSTALL_DIR/docker-compose.yml" --env-file "$INSTALL_DIR/.env" "$@"
}

wait_for_container_health() {
  local container_name="$1"
  local timeout_seconds="$2"
  local started_at status running

  started_at="$(date +%s)"
  while true; do
    running="$(docker inspect --format '{{.State.Running}}' "$container_name" 2>/dev/null || true)"
    status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container_name" 2>/dev/null || true)"
    if [[ "$running" == "true" && ( "$status" == "healthy" || "$status" == "none" ) ]]; then
      return 0
    fi
    if (( $(date +%s) - started_at >= timeout_seconds )); then
      return 1
    fi
    sleep 3
  done
}

deploy_stack() {
  log "Pulling images."
  compose pull metrica-db metrica-migrate metrica-api metrica-worker metrica-control-plane metrica-proxy

  log "Starting Metrica stack."
  compose up -d metrica-db metrica-migrate metrica-api metrica-worker metrica-control-plane metrica-proxy

  wait_for_container_health intellion-metrica-db 120 || die "Database container did not become healthy."
  wait_for_container_health intellion-metrica-api 180 || die "API container did not become healthy."
  wait_for_container_health intellion-metrica-control-plane 180 || die "Control-plane container did not become healthy."
}

extract_json_value() {
  local key="$1"
  sed -n "s/.*\"${key}\":\"\\([^\"]*\\)\".*/\\1/p"
}

fetch_csrf_token() {
  local response token
  response="$(curl -fsS \
    -H "Origin: https://${PUBLIC_HOST}" \
    -H "Referer: https://${PUBLIC_HOST}/ru/analytics" \
    "http://127.0.0.1:${CONTROL_PLANE_PORT}/api/metrica/auth/csrf")"
  token="$(printf '%s' "$response" | extract_json_value "csrfToken")"
  [[ -n "$token" ]] || die "Failed to obtain CSRF token from control-plane."
  printf '%s' "$token"
}

bootstrap_owner() {
  local csrf_token payload body_file http_code activation_token activation_path activation_expires_at bootstrap_mode
  bootstrap_mode="activation_link"
  if [[ -n "$OWNER_PASSWORD" ]]; then
    bootstrap_mode="password"
  fi

  csrf_token="$(fetch_csrf_token)"
  if [[ "$bootstrap_mode" == "password" ]]; then
    payload="$(printf '{"token":"%s","email":"%s","fullName":"%s","password":"%s","mode":"password"}' \
      "$(json_escape "$BOOTSTRAP_TOKEN")" \
      "$(json_escape "$OWNER_EMAIL")" \
      "$(json_escape "$OWNER_NAME")" \
      "$(json_escape "$OWNER_PASSWORD")")"
  else
    payload="$(printf '{"token":"%s","email":"%s","fullName":"%s","mode":"activation_link"}' \
      "$(json_escape "$BOOTSTRAP_TOKEN")" \
      "$(json_escape "$OWNER_EMAIL")" \
      "$(json_escape "$OWNER_NAME")")"
  fi

  body_file="$(mktemp)"
  http_code="$(curl -sS -o "$body_file" -w '%{http_code}' \
    -H "Origin: https://${PUBLIC_HOST}" \
    -H "Referer: https://${PUBLIC_HOST}/ru/analytics" \
    -H 'Content-Type: application/json' \
    -H "x-intellion-metrica-csrf: ${csrf_token}" \
    -H "Cookie: intellion_metrica_csrf=${csrf_token}" \
    --data "$payload" \
    "http://127.0.0.1:${CONTROL_PLANE_PORT}/api/metrica/auth/bootstrap")"

  if [[ "$http_code" == "200" ]]; then
    if [[ "$bootstrap_mode" == "password" ]]; then
      cat >"$INSTALL_DIR/state/owner-credentials.txt" <<EOF
Owner email: ${OWNER_EMAIL}
Owner name: ${OWNER_NAME}
Owner password: ${OWNER_PASSWORD}
Panel URL: https://${PUBLIC_HOST}/ru/analytics
Generated at: ${BOOT_TS}
EOF
      chmod 600 "$INSTALL_DIR/state/owner-credentials.txt"
    else
      activation_token="$(cat "$body_file" | extract_json_value "token")"
      activation_path="$(cat "$body_file" | extract_json_value "path")"
      activation_expires_at="$(cat "$body_file" | extract_json_value "expiresAt")"
      [[ -n "$activation_path" ]] || die "Activation bootstrap succeeded but activation path is missing."
      OWNER_ACTIVATION_PATH="$activation_path"
      OWNER_ACTIVATION_URL="https://${PUBLIC_HOST}${activation_path}"
      cat >"$INSTALL_DIR/state/owner-activation.txt" <<EOF
Owner email: ${OWNER_EMAIL}
Owner name: ${OWNER_NAME}
Activation URL: ${OWNER_ACTIVATION_URL}
Activation path: ${OWNER_ACTIVATION_PATH}
Activation token: ${activation_token}
Expires at: ${activation_expires_at}
Generated at: ${BOOT_TS}
EOF
      chmod 600 "$INSTALL_DIR/state/owner-activation.txt"
    fi
    rm -f "$body_file"
    return 0
  fi

  if [[ "$http_code" == "409" ]]; then
    warn "Owner bootstrap was skipped because the installation already contains users."
    OWNER_PASSWORD=""
    rm -f "$body_file"
    return 0
  fi

  warn "Bootstrap response body:"
  cat "$body_file" || true
  rm -f "$body_file"
  die "Owner bootstrap failed with HTTP ${http_code}."
}

verify_owner_login() {
  [[ -n "$OWNER_PASSWORD" ]] || return 0

  local csrf_token payload body_file http_code
  csrf_token="$(fetch_csrf_token)"
  payload="$(printf '{"email":"%s","password":"%s"}' \
    "$(json_escape "$OWNER_EMAIL")" \
    "$(json_escape "$OWNER_PASSWORD")")"
  body_file="$(mktemp)"

  http_code="$(curl -sS -o "$body_file" -w '%{http_code}' \
    -H "Origin: https://${PUBLIC_HOST}" \
    -H "Referer: https://${PUBLIC_HOST}/ru/analytics" \
    -H 'Content-Type: application/json' \
    -H "x-intellion-metrica-csrf: ${csrf_token}" \
    -H "Cookie: intellion_metrica_csrf=${csrf_token}" \
    --data "$payload" \
    "http://127.0.0.1:${CONTROL_PLANE_PORT}/api/metrica/auth/login")"

  if [[ "$http_code" != "200" ]]; then
    warn "Owner login verification response body:"
    cat "$body_file" || true
    rm -f "$body_file"
    die "Owner login verification failed with HTTP ${http_code}."
  fi

  rm -f "$body_file"
}

post_install_smoke() {
  local health_response
  log "Running post-install smoke checks."

  health_response="$(curl -fsS "http://127.0.0.1:${CONTROL_PLANE_PORT}/api/health")" \
    || die "Local control-plane health check failed."
  FINAL_ENTITLEMENT_STATUS="$(printf '%s' "$health_response" | extract_json_value "entitlementStatus")"
  FINAL_ENTITLEMENT_STATUS="${FINAL_ENTITLEMENT_STATUS:-unknown}"

  if curl -kfsS --resolve "${PUBLIC_HOST}:443:127.0.0.1" "https://${PUBLIC_HOST}/api/health" >/dev/null; then
    log "Public HTTPS health endpoint is reachable."
  else
    warn "Public HTTPS health smoke did not pass yet. Internal health is healthy, but TLS/public routing still needs confirmation."
  fi

  verify_owner_login
}

write_final_report() {
  local credentials_path install_status_dir status_text panel_url login_url entry_url internal_panel_url next_step_one
  local activation_path
  install_status_dir="$INSTALL_DIR/artifacts/install/${BOOT_TS}-one-command-install"
  mkdir -p "$install_status_dir"
  FINAL_LOG_PATH="$INSTALL_DIR/logs/install-${BOOT_TS}.log"
  cp "$LOG_FILE" "$FINAL_LOG_PATH"

  internal_panel_url="https://${PUBLIC_HOST}/ru/analytics"
  if [[ "$PUBLISH_MODE" == "path" ]]; then
    entry_url="https://${PUBLIC_HOST}${ENTRY_PATH}"
    panel_url="$entry_url"
    login_url="$entry_url"
  else
    panel_url="$internal_panel_url"
    login_url="$internal_panel_url"
    entry_url="$internal_panel_url"
  fi

  if [[ "${#WARNINGS[@]}" -gt 0 ]]; then
    FINAL_STATUS="passed_with_warnings"
  fi

  credentials_path=""
  if [[ -f "$INSTALL_DIR/state/owner-credentials.txt" ]]; then
    credentials_path="$INSTALL_DIR/state/owner-credentials.txt"
  fi
  activation_path=""
  if [[ -f "$INSTALL_DIR/state/owner-activation.txt" ]]; then
    activation_path="$INSTALL_DIR/state/owner-activation.txt"
  fi
  if [[ -n "$OWNER_ACTIVATION_URL" ]]; then
    next_step_one="Откройте ссылку активации владельца: ${OWNER_ACTIVATION_URL}"
  else
    next_step_one="Откройте ${entry_url} и войдите под владельцем"
  fi

  cat >"$install_status_dir/install-summary.json" <<EOF
{
  "kind": "metrica_one_command_install_result_v1",
  "status": "$(json_escape "$FINAL_STATUS")",
  "installedAt": "$(json_escape "$BOOT_TS")",
  "publishMode": "$(json_escape "$PUBLISH_MODE")",
  "publicHost": "$(json_escape "$PUBLIC_HOST")",
  "entryUrl": "$(json_escape "$entry_url")",
  "panelUrl": "$(json_escape "$panel_url")",
  "loginUrl": "$(json_escape "$login_url")",
  "installationId": "$(json_escape "$INSTALLATION_ID")",
  "installationName": "$(json_escape "$INSTALLATION_NAME")",
  "ownerEmail": "$(json_escape "$OWNER_EMAIL")",
  "ownerCredentialsPath": "$(json_escape "$credentials_path")",
  "ownerActivationPath": "$(json_escape "$activation_path")",
  "ownerActivationUrl": "$(json_escape "$OWNER_ACTIVATION_URL")",
  "entitlementStatus": "$(json_escape "$FINAL_ENTITLEMENT_STATUS")",
  "maxTargetKind": "$(json_escape "$MAX_TARGET_KIND")",
  "maxTargetValue": "$(json_escape "$MAX_TARGET_VALUE")",
  "installDir": "$(json_escape "$INSTALL_DIR")",
  "logPath": "$(json_escape "$FINAL_LOG_PATH")",
  "serviceFilesPath": "$(json_escape "$INSTALL_DIR")",
  "maxBotConfigured": $( [[ -n "$MAX_BOT_TOKEN" ]] && printf 'true' || printf 'false' ),
  "warnings": [
$(for item in "${WARNINGS[@]}"; do printf '    "%s"\n' "$(json_escape "$item")"; done | sed '$!s/$/,/')
  ]
}
EOF

  status_text="passed"
  [[ "$FINAL_STATUS" == "passed_with_warnings" ]] && status_text="passed_with_warnings"
  printf '%s\n' "$status_text" >"$install_status_dir/install-status.txt"

  cat >"$install_status_dir/install-report.txt" <<EOF
Интеллион Метрика установлена.

Статус: ${FINAL_STATUS}
Установка: ${INSTALLATION_NAME}
Installation ID: ${INSTALLATION_ID}
Режим публикации: ${PUBLISH_MODE}
Адрес панели: ${panel_url}
Точка входа: ${entry_url}
Почта владельца: ${OWNER_EMAIL}
Файл с учетными данными: ${credentials_path:-не создан}
Файл с активацией владельца: ${activation_path:-не создан}
Ссылка активации владельца: ${OWNER_ACTIVATION_URL:-не создана}
Статус entitlement: ${FINAL_ENTITLEMENT_STATUS}
MAX target intent: ${MAX_TARGET_KIND}${MAX_TARGET_VALUE:+:${MAX_TARGET_VALUE}}
Служебный каталог: ${INSTALL_DIR}
Журнал установки: ${FINAL_LOG_PATH}

Следующий шаг:
1. ${next_step_one}
2. После активации войдите в ${entry_url}
3. Добавьте первый сайт в Управление -> Сайты
4. Получите ingest secret и подключите same-site proxy на сайте клиента
5. Проверьте collect / consent и первые события
EOF

  FINAL_REPORT_PATH="$install_status_dir/install-report.txt"
}

main() {
  parse_args "$@"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "Dry-run mode enabled."
  fi

  collect_inputs
  resolve_image_refs
  preflight_checks

  if [[ "$PRECHECK_ONLY" -eq 1 ]]; then
    log "Preflight completed successfully."
    exit 0
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "Dry-run finished after preflight."
    exit 0
  fi

  resolve_bundle_root
  prepare_install_tree
  deploy_stack
  bootstrap_owner
  post_install_smoke
  log "Installation completed."
  write_final_report

  printf '\n'
  cat "$FINAL_REPORT_PATH"
}

main "$@"
