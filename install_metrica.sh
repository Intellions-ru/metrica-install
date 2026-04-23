#!/usr/bin/env bash
set -Eeuo pipefail

INSTALLER_VERSION="v2"
DEFAULT_INSTALL_DIR="/opt/intellion-metrica"
DEFAULT_IMAGE_VERSION="v0.2.12"
DEFAULT_BUNDLE_REF="v0.2.12"
DEFAULT_IMAGE_REGISTRY="ghcr.io/intellions-ru"
DEFAULT_PRODUCT_BUNDLE_URL_BASE="https://github.com/Intellions-ru/metrica-install/releases/download"
DEFAULT_INSTALLER_HELPERS_URL_BASE="https://raw.githubusercontent.com/Intellions-ru/metrica-install/main/scripts"
SOURCE_FALLBACK_BUNDLE_URL_BASE="${SOURCE_FALLBACK_BUNDLE_URL_BASE:-}"
MIN_MEMORY_MB=2048
WARN_MEMORY_MB=4096
MIN_DISK_GB=8
WARN_DISK_GB=15

INSTALLATION_NAME=""
INSTALLATION_ID=""
PUBLISH_MODE=""
PUBLIC_HOST=""
ENTRY_PATH="/metrica"
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
METRICA_CONTROL_PLANE_PATH_IMAGE=""
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
AUTO_ATTACH_PROXY=1
SKIP_DNS_CHECK=0
BUNDLE_REF="$DEFAULT_BUNDLE_REF"
BUNDLE_URL=""

SCRIPT_SOURCE="${BASH_SOURCE[0]:-}"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SOURCE")" 2>/dev/null && pwd || pwd)"
LOCAL_ANALYTICS_ROOT="$(cd "$SCRIPT_DIR/.." 2>/dev/null && pwd || true)"

BOOT_TS="$(date -u +%Y%m%dT%H%M%SZ)"
BOOT_ISO_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
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
AUTO_ATTACH_PROXY_APPLIED=0
AUTO_ATTACH_PROXY_KIND=""
AUTO_ATTACH_PROXY_MODE=""
AUTO_ATTACH_PROXY_TARGET_FILE=""
AUTO_ATTACH_PROXY_SNIPPET=""
AUTO_ATTACH_PROXY_INCLUDE_PATH=""
AUTO_ATTACH_PROXY_CONTAINER_NAME=""
AUTO_ATTACH_PROXY_CHECK_URL=""
AUTO_ATTACH_PROXY_BLOCK_BEGIN=""
AUTO_ATTACH_PROXY_BLOCK_END=""
MANAGED_STATE_FILE=""
MAX_DIGEST_TIMER_INSTALLED=0

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
  --publish-mode attach-path|attach-subdomain|standalone
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
  --entry-path </metrica>        # for attach-path only, default /metrica
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
  --no-auto-attach-proxy
  --no-docker-install
  --help

Examples:
  sudo bash ./scripts/install_metrica.sh \
    --publish-mode attach-subdomain \
    --domain analytics.example.com \
    --installation-name "Example Analytics" \
    --owner-email owner@example.com

  curl -fsSL https://raw.githubusercontent.com/Intellions-ru/metrica-install/main/install_metrica.sh \
    | sudo bash -s -- \
      --publish-mode attach-path \
      --domain example.com \
      --entry-path /metrica \
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

have_command() {
  command -v "$1" >/dev/null 2>&1
}

image_ref_available() {
  local image_ref="$1"
  docker manifest inspect "$image_ref" >/dev/null 2>&1 \
    || docker image inspect "$image_ref" >/dev/null 2>&1
}

image_ref_remote_available() {
  local image_ref="$1"
  docker manifest inspect "$image_ref" >/dev/null 2>&1
}

image_ref_local_available() {
  local image_ref="$1"
  docker image inspect "$image_ref" >/dev/null 2>&1
}

ensure_runtime_permissions() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    return
  fi

  local docker_ready=0
  if have_command docker && docker compose version >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    docker_ready=1
  fi

  if [[ "$AUTO_INSTALL_DOCKER" -eq 1 && "$docker_ready" -eq 0 ]]; then
    die "Root or sudo is required because Docker is not ready for the current user."
  fi

  mkdir -p "$INSTALL_DIR" 2>/dev/null || die "Install directory is not writable: $INSTALL_DIR. Use sudo or choose a writable --install-dir."
  [[ -w "$INSTALL_DIR" ]] || die "Install directory is not writable: $INSTALL_DIR. Use sudo or choose a writable --install-dir."

  if [[ "$docker_ready" -ne 1 ]]; then
    die "Docker is installed but the current user cannot access it. Use sudo or add the user to the docker group."
  fi

  warn "Installer is running without root. Docker is already available and install directory is writable."
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
  local value
  set +o pipefail
  value="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$length")"
  set -o pipefail
  printf '%s' "$value"
}

slugify_identifier() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9]/-/g; s/--*/-/g; s/^-//; s/-$//'
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
    read_prompt_value "$prompt_text [$default_value]: " value
    value="${value:-$default_value}"
  else
    read_prompt_value "$prompt_text: " value
  fi

  printf -v "$var_name" '%s' "$value"
}

read_prompt_value() {
  local prompt_text="$1"
  local __resultvar="$2"
  local prompt_input=""

  if [[ -t 0 ]]; then
    read -r -p "$prompt_text" prompt_input || true
  elif [[ -r /dev/tty ]]; then
    read -r -p "$prompt_text" prompt_input < /dev/tty || true
  fi

  printf -v "$__resultvar" '%s' "$prompt_input"
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

normalize_publish_mode() {
  case "$1" in
    path|attach-path)
      printf 'attach-path'
      ;;
    subdomain|attach-subdomain)
      printf 'attach-subdomain'
      ;;
    managed|standalone)
      printf 'standalone'
      ;;
    *)
      printf '%s' "$1"
      ;;
  esac
}

is_attach_mode() {
  [[ "$PUBLISH_MODE" == "attach-path" || "$PUBLISH_MODE" == "attach-subdomain" ]]
}

control_plane_base_path() {
  if [[ "$PUBLISH_MODE" == "attach-path" ]]; then
    printf '%s' "$ENTRY_PATH"
  else
    printf ''
  fi
}

fetch_bundle_archive() {
  local destination="$1"
  local release_url="$BUNDLE_URL"
  local source_tag_url=""
  local source_head_url=""

  if [[ -z "$release_url" ]]; then
    if [[ "$DEFAULT_PRODUCT_BUNDLE_URL_BASE" == *"/releases/download" ]]; then
      release_url="${DEFAULT_PRODUCT_BUNDLE_URL_BASE}/${BUNDLE_REF}/intellion-metrica-install-bundle-${BUNDLE_REF}.tar.gz"
    else
      release_url="${DEFAULT_PRODUCT_BUNDLE_URL_BASE}/intellion-metrica-install-bundle-${BUNDLE_REF}.tar.gz"
    fi
  fi

  log "Downloading install bundle from $release_url"
  if fetch_url "$release_url" "$destination"; then
    return 0
  fi

  if [[ -z "$SOURCE_FALLBACK_BUNDLE_URL_BASE" ]]; then
    return 1
  fi

  source_tag_url="${SOURCE_FALLBACK_BUNDLE_URL_BASE}/refs/tags/${BUNDLE_REF}"
  source_head_url="${SOURCE_FALLBACK_BUNDLE_URL_BASE}/refs/heads/${BUNDLE_REF}"

  warn "Product install bundle was not downloaded. Falling back to tag source bundle: $source_tag_url"
  if fetch_url "$source_tag_url" "$destination"; then
    return 0
  fi

  warn "Tag source bundle was not downloaded. Falling back to branch source bundle: $source_head_url"
  if fetch_url "$source_head_url" "$destination"; then
    return 0
  fi

  return 1
}

control_plane_local_path() {
  local suffix="$1"
  printf '%s%s' "$(control_plane_base_path)" "$suffix"
}

control_plane_local_url() {
  local suffix="$1"
  printf 'http://127.0.0.1:%s%s' "$CONTROL_PLANE_PORT" "$(control_plane_local_path "$suffix")"
}

control_plane_public_root_url() {
  printf 'https://%s%s' "$PUBLIC_HOST" "$(control_plane_base_path)"
}

managed_proxy_marker_id() {
  slugify_identifier "${PUBLIC_HOST}-${ENTRY_PATH}-attach-path"
}

managed_proxy_begin_marker() {
  printf '# BEGIN INTELLION METRICA AUTO ATTACH %s' "$(managed_proxy_marker_id)"
}

managed_proxy_end_marker() {
  printf '# END INTELLION METRICA AUTO ATTACH %s' "$(managed_proxy_marker_id)"
}

control_plane_public_referer() {
  if [[ "$PUBLISH_MODE" == "attach-path" ]]; then
    printf 'https://%s%s/' "$PUBLIC_HOST" "$ENTRY_PATH"
  else
    printf 'https://%s/' "$PUBLIC_HOST"
  fi
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
      --control-plane-path-image)
        METRICA_CONTROL_PLANE_PATH_IMAGE="${2:-}"
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
      --no-auto-attach-proxy)
        AUTO_ATTACH_PROXY=0
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
    PUBLISH_MODE="attach-path"
  fi

  PUBLISH_MODE="$(normalize_publish_mode "$PUBLISH_MODE")"

  prompt_value PUBLIC_HOST "Введите домен, где будет открываться Метрика"
  prompt_value INSTALLATION_NAME "Введите имя установки"
  prompt_value OWNER_EMAIL "Введите почту владельца"
  prompt_value OWNER_NAME "Введите имя владельца" "$OWNER_NAME"
  prompt_value ACME_EMAIL "Введите почту для TLS-уведомлений" "${ACME_EMAIL:-$OWNER_EMAIL}"

  if [[ -z "$MAX_BOT_TOKEN" && "$NON_INTERACTIVE" -eq 0 ]]; then
    local use_max=""
    read_prompt_value "Настроить MAX-бота сейчас? [y/N]: " use_max
    if [[ "$use_max" =~ ^[Yy]$ ]]; then
      prompt_value MAX_BOT_TOKEN "Введите токен MAX-бота (Enter чтобы пропустить)"
      if [[ -z "$MAX_BOT_TOKEN" ]]; then
        log "MAX bot setup skipped. Installation will continue without MAX bot."
      fi
    fi
  fi

  [[ -n "$PUBLISH_MODE" ]] || die "Publication mode is required."
  [[ "$PUBLISH_MODE" == "attach-path" || "$PUBLISH_MODE" == "attach-subdomain" || "$PUBLISH_MODE" == "standalone" ]] \
    || die "Publication mode must be attach-path, attach-subdomain, or standalone."
  [[ -n "$PUBLIC_HOST" ]] || die "Public domain is required."
  validate_host "$PUBLIC_HOST" || die "Invalid public domain: $PUBLIC_HOST"
  [[ -n "$INSTALLATION_NAME" ]] || die "Installation name is required."
  [[ -n "$OWNER_EMAIL" ]] || die "Owner email is required."
  validate_email "$OWNER_EMAIL" || die "Invalid owner email: $OWNER_EMAIL"
  [[ -n "$ACME_EMAIL" ]] || die "TLS contact email is required."
  validate_email "$ACME_EMAIL" || die "Invalid TLS contact email: $ACME_EMAIL"
  validate_entry_path "$ENTRY_PATH" || die "Invalid entry path: $ENTRY_PATH"
  if [[ "$PUBLISH_MODE" == "attach-path" && "$ENTRY_PATH" != "/metrica" ]]; then
    die "attach-path currently supports the product base path /metrica only."
  fi
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
  if [[ -z "$METRICA_CONTROL_PLANE_PATH_IMAGE" ]]; then
    METRICA_CONTROL_PLANE_PATH_IMAGE="${IMAGE_REGISTRY}/intellion-metrica-control-plane-path:${IMAGE_VERSION}"
  fi
  if [[ -z "$METRICA_CONTROL_PLANE_IMAGE" ]]; then
    if [[ "$PUBLISH_MODE" == "attach-path" ]]; then
      METRICA_CONTROL_PLANE_IMAGE="$METRICA_CONTROL_PLANE_PATH_IMAGE"
    else
      METRICA_CONTROL_PLANE_IMAGE="${IMAGE_REGISTRY}/intellion-metrica-control-plane:${IMAGE_VERSION}"
    fi
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
    docker info >/dev/null 2>&1 || die "Docker is installed but the current user cannot access it."
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
  ensure_runtime_permissions

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

  if [[ "$PUBLISH_MODE" == "standalone" ]]; then
    if port_is_busy 80; then
      die "Port 80 is already in use."
    fi
    if port_is_busy 443; then
      die "Port 443 is already in use."
    fi
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

  if ! image_ref_available "$METRICA_API_IMAGE"; then
    die "Failed to reach image registry or image ref is invalid: $METRICA_API_IMAGE"
  fi
  if ! image_ref_available "$METRICA_WORKER_IMAGE"; then
    die "Failed to reach image registry or image ref is invalid: $METRICA_WORKER_IMAGE"
  fi
  if ! image_ref_available "$METRICA_CONTROL_PLANE_IMAGE"; then
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

  fetch_bundle_archive "$archive" || die "Failed to download install bundle for ref: $BUNDLE_REF. If you need emergency source fallback, set SOURCE_FALLBACK_BUNDLE_URL_BASE explicitly."
  tar -xzf "$archive" -C "$work_dir"

  candidate="$(find "$work_dir" \( -path '*/install/docker-compose.install.yml' -o -path '*/intellions-analytics/install/docker-compose.install.yml' \) -print | head -n 1 || true)"
  [[ -n "$candidate" ]] || die "Failed to locate install bundle contents after download."
  if [[ "$candidate" == *"/intellions-analytics/install/docker-compose.install.yml" ]]; then
    BUNDLE_ROOT="$(cd "$(dirname "$(dirname "$candidate")")" && pwd)"
  else
    BUNDLE_ROOT="$(cd "$(dirname "$(dirname "$candidate")")" && pwd)"
  fi
}

load_bundled_images_if_present() {
  local image_dir image_archive
  image_dir="$BUNDLE_ROOT/images"
  [[ -d "$image_dir" ]] || return 0

  shopt -s nullglob
  for image_archive in "$image_dir"/*.tar; do
    log "Loading bundled image $(basename "$image_archive")"
    docker load -i "$image_archive" >/dev/null
  done
  shopt -u nullglob
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
  rendered="$(printf '%s' "$rendered" | sed "s|{{CONTROL_PLANE_HEALTH_PATH}}|$(escape_sed "$(control_plane_local_path "/api/health")")|g")"
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

write_proxy_templates() {
  mkdir -p "$INSTALL_DIR/runtime/proxy/nginx" "$INSTALL_DIR/runtime/proxy/caddy"

  if [[ "$PUBLISH_MODE" == "attach-path" ]]; then
    render_template "$BUNDLE_ROOT/install/nginx_attach_path_v1.conf.tpl" \
      "$INSTALL_DIR/runtime/proxy/nginx/attach-path.conf"
    render_template "$BUNDLE_ROOT/install/caddy_attach_path_v1.tpl" \
      "$INSTALL_DIR/runtime/proxy/caddy/attach-path.Caddyfile"
  elif [[ "$PUBLISH_MODE" == "attach-subdomain" ]]; then
    render_template "$BUNDLE_ROOT/install/nginx_attach_subdomain_v1.conf.tpl" \
      "$INSTALL_DIR/runtime/proxy/nginx/attach-subdomain.conf"
    render_template "$BUNDLE_ROOT/install/caddy_attach_subdomain_v1.tpl" \
      "$INSTALL_DIR/runtime/proxy/caddy/attach-subdomain.Caddyfile"
  fi

  if is_attach_mode; then
    cat >"$INSTALL_DIR/runtime/proxy/README.txt" <<EOF
Интеллион Метрика развернута во внутреннем режиме и не занимает 80/443.

Режим публикации: ${PUBLISH_MODE}
Домен: ${PUBLIC_HOST}
Точка входа: $(control_plane_public_root_url)
Локальный порт control-plane: ${CONTROL_PLANE_PORT}

Готовые шаблоны:
- nginx: $INSTALL_DIR/runtime/proxy/nginx
- caddy: $INSTALL_DIR/runtime/proxy/caddy

Что сделать дальше:
1. Выберите nginx или caddy.
2. Возьмите соответствующий шаблон для режима ${PUBLISH_MODE}.
3. Подключите его в существующий reverse proxy.
4. Перезагрузите proxy.
5. Откройте $(control_plane_public_root_url)
EOF
    chmod 600 "$INSTALL_DIR/runtime/proxy/README.txt"
  fi
}

persist_managed_state() {
  MANAGED_STATE_FILE="$INSTALL_DIR/state/installer-managed.env"
  cat >"$MANAGED_STATE_FILE" <<EOF
INSTALL_DIR=$(printf '%q' "$INSTALL_DIR")
PUBLISH_MODE=$(printf '%q' "$PUBLISH_MODE")
PUBLIC_HOST=$(printf '%q' "$PUBLIC_HOST")
ENTRY_PATH=$(printf '%q' "$ENTRY_PATH")
AUTO_ATTACH_PROXY=$(printf '%q' "$AUTO_ATTACH_PROXY")
AUTO_ATTACH_PROXY_APPLIED=$(printf '%q' "$AUTO_ATTACH_PROXY_APPLIED")
AUTO_ATTACH_PROXY_KIND=$(printf '%q' "$AUTO_ATTACH_PROXY_KIND")
AUTO_ATTACH_PROXY_MODE=$(printf '%q' "$AUTO_ATTACH_PROXY_MODE")
AUTO_ATTACH_PROXY_TARGET_FILE=$(printf '%q' "$AUTO_ATTACH_PROXY_TARGET_FILE")
AUTO_ATTACH_PROXY_SNIPPET=$(printf '%q' "$AUTO_ATTACH_PROXY_SNIPPET")
AUTO_ATTACH_PROXY_INCLUDE_PATH=$(printf '%q' "$AUTO_ATTACH_PROXY_INCLUDE_PATH")
AUTO_ATTACH_PROXY_CONTAINER_NAME=$(printf '%q' "$AUTO_ATTACH_PROXY_CONTAINER_NAME")
AUTO_ATTACH_PROXY_CHECK_URL=$(printf '%q' "$AUTO_ATTACH_PROXY_CHECK_URL")
AUTO_ATTACH_PROXY_BLOCK_BEGIN=$(printf '%q' "$AUTO_ATTACH_PROXY_BLOCK_BEGIN")
AUTO_ATTACH_PROXY_BLOCK_END=$(printf '%q' "$AUTO_ATTACH_PROXY_BLOCK_END")
MAX_DIGEST_TIMER_INSTALLED=$(printf '%q' "$MAX_DIGEST_TIMER_INSTALLED")
EOF
  chmod 600 "$MANAGED_STATE_FILE"
}

find_nginx_attach_target() {
  python3 "$INSTALL_DIR/scripts/manage_nginx_site.py" \
    find-target \
    --host "$PUBLIC_HOST" \
    --search-root /etc/nginx/sites-enabled \
    --search-root /etc/nginx/conf.d
}

docker_nginx_mounts() {
  local container_name="$1"
  docker inspect --format '{{range .Mounts}}{{if eq .Type "bind"}}{{printf "%s\t%s\n" .Source .Destination}}{{end}}{{end}}' "$container_name"
}

docker_container_networks() {
  local container_name="$1"
  docker inspect --format '{{range $name, $network := .NetworkSettings.Networks}}{{println $name}}{{end}}' "$container_name"
}

find_docker_nginx_container() {
  local name image ports
  local -a matches=()
  while IFS=$'\t' read -r name image ports; do
    [[ -n "$name" ]] || continue
    if [[ "$name" == *nginx* || "$image" == *nginx* ]]; then
      if [[ "$ports" == *":80->"* || "$ports" == *":443->"* ]]; then
        matches+=("$name")
      fi
    fi
  done < <(docker ps --format '{{.Names}}\t{{.Image}}\t{{.Ports}}')

  if [[ "${#matches[@]}" -eq 1 ]]; then
    printf '%s' "${matches[0]}"
    return 0
  fi
  if [[ "${#matches[@]}" -gt 1 ]]; then
    printf '%s\n' "multiple docker nginx containers expose 80/443: ${matches[*]}" >&2
    return 1
  fi
  printf '%s\n' "no docker nginx container exposes 80/443" >&2
  return 1
}

find_docker_nginx_attach_network() {
  local container_name="$1"
  local network_name
  local -a matches=()

  while IFS= read -r network_name; do
    [[ -n "$network_name" ]] || continue
    case "$network_name" in
      bridge|host|none)
        continue
        ;;
    esac
    matches+=("$network_name")
  done < <(docker_container_networks "$container_name")

  if [[ "${#matches[@]}" -eq 1 ]]; then
    printf '%s' "${matches[0]}"
    return 0
  fi
  if [[ "${#matches[@]}" -gt 1 ]]; then
    printf '%s\n' "multiple docker networks are attached to $container_name: ${matches[*]}" >&2
    return 1
  fi
  printf '%s\n' "no user-defined docker network found for $container_name" >&2
  return 1
}

ensure_control_plane_on_network() {
  local network_name="$1"
  if docker_container_networks intellion-metrica-control-plane | grep -Fxq "$network_name"; then
    return 0
  fi
  docker network connect --alias intellion-metrica-control-plane "$network_name" intellion-metrica-control-plane >/dev/null
}

render_docker_nginx_attach_block() {
  local upstream="$1"
  local destination="$2"
  sed "s|http://127.0.0.1:${CONTROL_PLANE_PORT}|http://${upstream}|g" \
    "$INSTALL_DIR/runtime/proxy/nginx/attach-path.conf" >"$destination"
}

resolve_docker_nginx_attach_paths() {
  local container_name="$1"
  local target_file=""
  local mount_source mount_target candidate_source candidate_target
  local -a search_roots=() root_specs=()
  local -a find_args=()

  while IFS=$'\t' read -r mount_source mount_target; do
    [[ -n "$mount_source" && -n "$mount_target" ]] || continue

    if [[ "$mount_target" == "/etc/nginx/conf.d" || "$mount_target" == "/etc/nginx/sites-enabled" ]]; then
      [[ -d "$mount_source" ]] || continue
      search_roots+=("$mount_source")
      root_specs+=("$mount_source|$mount_target")
      continue
    fi

    if [[ "$mount_target" == "/etc/nginx" && -d "$mount_source" ]]; then
      if [[ -d "$mount_source/conf.d" ]]; then
        search_roots+=("$mount_source/conf.d")
        root_specs+=("$mount_source/conf.d|/etc/nginx/conf.d")
      fi
      if [[ -d "$mount_source/sites-enabled" ]]; then
        search_roots+=("$mount_source/sites-enabled")
        root_specs+=("$mount_source/sites-enabled|/etc/nginx/sites-enabled")
      fi
    fi
  done < <(docker_nginx_mounts "$container_name")

  [[ "${#search_roots[@]}" -gt 0 ]] || {
    printf '%s\n' "docker nginx container $container_name does not expose a bind-mounted /etc/nginx config root" >&2
    return 1
  }

  find_args=(find-target --host "$PUBLIC_HOST")
  for mount_source in "${search_roots[@]}"; do
    find_args+=(--search-root "$mount_source")
  done

  if ! target_file="$(python3 "$INSTALL_DIR/scripts/manage_nginx_site.py" "${find_args[@]}")"; then
    return 1
  fi

  candidate_source=""
  candidate_target=""
  for root_spec in "${root_specs[@]}"; do
    mount_source="${root_spec%%|*}"
    mount_target="${root_spec#*|}"
    if [[ "$target_file" == "$mount_source"* ]]; then
      candidate_source="$mount_source"
      candidate_target="$mount_target"
      break
    fi
  done

  [[ -n "$candidate_source" && -n "$candidate_target" ]] || {
    printf '%s\n' "failed to map docker nginx config path for $target_file" >&2
    return 1
  }

  local snippet_name="intellion-metrica-$(slugify_identifier "${PUBLIC_HOST}-${ENTRY_PATH}-attach-path").conf"
  local snippet_host_dir=""
  local snippet_include_path=""

  if [[ "$candidate_target" == "/etc/nginx/conf.d" || "$candidate_target" == "/etc/nginx/sites-enabled" ]]; then
    snippet_host_dir="$candidate_source"
    snippet_include_path="$candidate_target/$snippet_name"
  else
    snippet_host_dir="$candidate_source/snippets"
    snippet_include_path="/etc/nginx/snippets/$snippet_name"
  fi

  mkdir -p "$snippet_host_dir"
  printf '%s\n%s\n%s\n' "$target_file" "$snippet_host_dir/$snippet_name" "$snippet_include_path"
}

resolve_docker_nginx_inline_attach_target() {
  local container_name="$1"
  local mount_source mount_target target_file=""
  local -a search_roots=() find_args=()

  while IFS=$'\t' read -r mount_source mount_target; do
    [[ -n "$mount_source" && -n "$mount_target" ]] || continue
    if [[ "$mount_target" == /etc/nginx/*.conf && -f "$mount_source" ]]; then
      search_roots+=("$mount_source")
    fi
  done < <(docker_nginx_mounts "$container_name")

  [[ "${#search_roots[@]}" -gt 0 ]] || {
    printf '%s\n' "docker nginx container $container_name does not expose a bind-mounted nginx.conf file" >&2
    return 1
  }

  find_args=(find-target --host "$PUBLIC_HOST")
  for mount_source in "${search_roots[@]}"; do
    find_args+=(--search-root "$mount_source")
  done

  python3 "$INSTALL_DIR/scripts/manage_nginx_site.py" "${find_args[@]}"
}

try_apply_nginx_attach() {
  local target_file="$1"
  local snippet_host_path="$2"
  local include_path="$3"
  local validate_cmd="$4"
  local reload_cmd="$5"
  local kind="$6"
  local container_name="${7:-}"
  local block_file="${8:-$INSTALL_DIR/runtime/proxy/nginx/attach-path.conf}"
  local backup_dir backup_path snippet_backup_path="" insert_status=""

  backup_dir="$INSTALL_DIR/artifacts/install/${BOOT_TS}-one-command-install/nginx-backups"
  backup_path="$backup_dir/$(basename "$target_file").bak"

  mkdir -p "$backup_dir"
  if [[ -f "$snippet_host_path" ]]; then
    snippet_backup_path="$backup_dir/$(basename "$snippet_host_path").bak"
    cp "$snippet_host_path" "$snippet_backup_path"
  fi
  cp "$block_file" "$snippet_host_path"
  chmod 644 "$snippet_host_path"
  cp "$target_file" "$backup_path"

  if ! insert_status="$(
    python3 "$INSTALL_DIR/scripts/manage_nginx_site.py" \
      insert-include \
      --host "$PUBLIC_HOST" \
      --file "$target_file" \
      --include-path "$include_path"
  )"; then
    if [[ -n "$snippet_backup_path" && -f "$snippet_backup_path" ]]; then
      cp "$snippet_backup_path" "$snippet_host_path"
    else
      rm -f "$snippet_host_path"
    fi
    return 1
  fi

  if ! eval "$validate_cmd" >/dev/null 2>&1; then
    cp "$backup_path" "$target_file"
    if [[ -n "$snippet_backup_path" && -f "$snippet_backup_path" ]]; then
      cp "$snippet_backup_path" "$snippet_host_path"
    else
      rm -f "$snippet_host_path"
    fi
    return 1
  fi

  if ! eval "$reload_cmd" >/dev/null 2>&1; then
    if [[ "$insert_status" != "already-present" ]]; then
      cp "$backup_path" "$target_file"
    fi
    if [[ -n "$snippet_backup_path" && -f "$snippet_backup_path" ]]; then
      cp "$snippet_backup_path" "$snippet_host_path"
    elif [[ "$insert_status" != "already-present" ]]; then
      rm -f "$snippet_host_path"
    fi
    return 1
  fi

  AUTO_ATTACH_PROXY_APPLIED=1
  AUTO_ATTACH_PROXY_KIND="$kind"
  AUTO_ATTACH_PROXY_MODE="include"
  AUTO_ATTACH_PROXY_TARGET_FILE="$target_file"
  AUTO_ATTACH_PROXY_SNIPPET="$snippet_host_path"
  AUTO_ATTACH_PROXY_INCLUDE_PATH="$include_path"
  AUTO_ATTACH_PROXY_CONTAINER_NAME="$container_name"
  AUTO_ATTACH_PROXY_CHECK_URL="$(control_plane_public_root_url)"
  AUTO_ATTACH_PROXY_BLOCK_BEGIN=""
  AUTO_ATTACH_PROXY_BLOCK_END=""
  persist_managed_state
  log "nginx auto-attach applied (${insert_status}) for $(control_plane_public_root_url)"
  return 0
}

try_apply_nginx_attach_inline() {
  local target_file="$1"
  local validate_cmd="$2"
  local reload_cmd="$3"
  local kind="$4"
  local container_name="${5:-}"
  local begin_marker="$6"
  local end_marker="$7"
  local block_file="${8:-$INSTALL_DIR/runtime/proxy/nginx/attach-path.conf}"
  local backup_dir backup_path insert_status=""

  backup_dir="$INSTALL_DIR/artifacts/install/${BOOT_TS}-one-command-install/nginx-backups"
  backup_path="$backup_dir/$(basename "$target_file").bak"

  mkdir -p "$backup_dir"
  cp "$target_file" "$backup_path"

  if ! insert_status="$(
    python3 "$INSTALL_DIR/scripts/manage_nginx_site.py" \
      insert-block \
      --host "$PUBLIC_HOST" \
      --file "$target_file" \
      --block-file "$block_file" \
      --begin-marker "$begin_marker" \
      --end-marker "$end_marker"
  )"; then
    return 1
  fi

  if ! eval "$validate_cmd" >/dev/null 2>&1; then
    cp "$backup_path" "$target_file"
    return 1
  fi

  if ! eval "$reload_cmd" >/dev/null 2>&1; then
    if [[ "$insert_status" != "already-present" ]]; then
      cp "$backup_path" "$target_file"
    fi
    return 1
  fi

  AUTO_ATTACH_PROXY_APPLIED=1
  AUTO_ATTACH_PROXY_KIND="$kind"
  AUTO_ATTACH_PROXY_MODE="inline"
  AUTO_ATTACH_PROXY_TARGET_FILE="$target_file"
  AUTO_ATTACH_PROXY_SNIPPET=""
  AUTO_ATTACH_PROXY_INCLUDE_PATH=""
  AUTO_ATTACH_PROXY_CONTAINER_NAME="$container_name"
  AUTO_ATTACH_PROXY_CHECK_URL="$(control_plane_public_root_url)"
  AUTO_ATTACH_PROXY_BLOCK_BEGIN="$begin_marker"
  AUTO_ATTACH_PROXY_BLOCK_END="$end_marker"
  persist_managed_state
  log "nginx auto-attach applied (${insert_status}, inline) for $(control_plane_public_root_url)"
  return 0
}

try_auto_attach_host_nginx_path_proxy() {
  local target_file="" err_file
  err_file="$(mktemp)"
  if ! target_file="$(find_nginx_attach_target 2>"$err_file")"; then
    rm -f "$err_file"
    return 1
  fi
  rm -f "$err_file"

  mkdir -p /etc/nginx/snippets
  try_apply_nginx_attach \
    "$target_file" \
    "/etc/nginx/snippets/intellion-metrica-$(slugify_identifier "${PUBLIC_HOST}-${ENTRY_PATH}-attach-path").conf" \
    "/etc/nginx/snippets/intellion-metrica-$(slugify_identifier "${PUBLIC_HOST}-${ENTRY_PATH}-attach-path").conf" \
    "nginx -t" \
    "$(have_command systemctl && printf 'systemctl reload nginx' || printf 'nginx -s reload')" \
    "nginx"
}

try_auto_attach_docker_nginx_path_proxy() {
  local container_name="" target_file="" snippet_host_path="" include_path="" resolved_paths=""
  local network_name="" docker_upstream="intellion-metrica-control-plane:3000" block_file=""
  local begin_marker="" end_marker=""
  local err_file
  err_file="$(mktemp)"
  if ! container_name="$(find_docker_nginx_container 2>"$err_file")"; then
    rm -f "$err_file"
    return 1
  fi
  if ! network_name="$(find_docker_nginx_attach_network "$container_name" 2>"$err_file")"; then
    rm -f "$err_file"
    return 1
  fi
  if ! ensure_control_plane_on_network "$network_name" 2>"$err_file"; then
    rm -f "$err_file"
    return 1
  fi

  block_file="$INSTALL_DIR/runtime/proxy/nginx/attach-path-docker-nginx.conf"
  render_docker_nginx_attach_block "$docker_upstream" "$block_file"

  if resolved_paths="$(resolve_docker_nginx_attach_paths "$container_name" 2>"$err_file")"; then
    rm -f "$err_file"
    target_file="$(printf '%s\n' "$resolved_paths" | sed -n '1p')"
    snippet_host_path="$(printf '%s\n' "$resolved_paths" | sed -n '2p')"
    include_path="$(printf '%s\n' "$resolved_paths" | sed -n '3p')"

    if try_apply_nginx_attach \
      "$target_file" \
      "$snippet_host_path" \
      "$include_path" \
      "docker exec $container_name nginx -t" \
      "docker exec $container_name nginx -s reload" \
      "docker-nginx" \
      "$container_name" \
      "$block_file"; then
      return 0
    fi
    err_file="$(mktemp)"
  fi

  # Some stacks mount a single nginx.conf file into the container instead of a config dir.
  if target_file="$(resolve_docker_nginx_inline_attach_target "$container_name" 2>"$err_file")"; then
    rm -f "$err_file"
    begin_marker="$(managed_proxy_begin_marker)"
    end_marker="$(managed_proxy_end_marker)"
    try_apply_nginx_attach_inline \
      "$target_file" \
      "docker exec $container_name nginx -t" \
      "docker exec $container_name nginx -s reload" \
      "docker-nginx-inline" \
      "$container_name" \
      "$begin_marker" \
      "$end_marker" \
      "$block_file"
    return $?
  fi

  rm -f "$err_file"
  return 1
}

auto_attach_nginx_path_proxy() {
  [[ "$AUTO_ATTACH_PROXY" -eq 1 ]] || return 0
  [[ "$PUBLISH_MODE" == "attach-path" ]] || return 0

  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    warn "Автоподключение reverse proxy пропущено: нужны root-права."
    return 0
  fi
  if ! have_command python3; then
    warn "Автоподключение reverse proxy пропущено: на сервере нет python3."
    return 0
  fi

  if have_command nginx; then
    if try_auto_attach_host_nginx_path_proxy; then
      return 0
    fi
    warn "Автоподключение host-nginx не удалось. Пробую найти dockerized nginx."
  fi

  if have_command docker && try_auto_attach_docker_nginx_path_proxy; then
    return 0
  fi

  if ! have_command nginx && have_command docker; then
    warn "На этом сервере нет host-nginx. Если сайт опубликован через dockerized nginx, его конфиг не удалось безопасно изменить автоматически. Публичная ссылка пока может отдавать 404."
    return 0
  fi

  warn "Путь /metrica еще не опубликован наружу автоматически. Подключите reverse proxy вручную, иначе публичный URL будет отдавать 404."
}

copy_or_fetch_script() {
  local source_path="$1"
  local destination_path="$2"
  local remote_name="$3"

  if [[ -f "$source_path" ]]; then
    cp "$source_path" "$destination_path"
    return 0
  fi

  fetch_url "${DEFAULT_INSTALLER_HELPERS_URL_BASE}/${remote_name}" "$destination_path"
}

prepare_install_tree() {
  log "Preparing install tree at $INSTALL_DIR"
  mkdir -p "$INSTALL_DIR"/db "$INSTALL_DIR"/runtime "$INSTALL_DIR"/artifacts/install "$INSTALL_DIR"/logs "$INSTALL_DIR"/state "$INSTALL_DIR"/scripts
  chmod 700 "$INSTALL_DIR"/state "$INSTALL_DIR"/logs "$INSTALL_DIR"/artifacts/install

  cp "$BUNDLE_ROOT/install/docker-compose.install.yml" "$INSTALL_DIR/docker-compose.yml"
  rm -rf "$INSTALL_DIR/db/migrations"
  cp -R "$BUNDLE_ROOT/db/migrations" "$INSTALL_DIR/db/migrations"
  cp "$BUNDLE_ROOT/scripts/install_metrica.sh" "$INSTALL_DIR/scripts/install_metrica.sh"
  copy_or_fetch_script "$BUNDLE_ROOT/scripts/uninstall_metrica.sh" "$INSTALL_DIR/scripts/uninstall_metrica.sh" "uninstall_metrica.sh"
  copy_or_fetch_script "$BUNDLE_ROOT/scripts/manage_nginx_site.py" "$INSTALL_DIR/scripts/manage_nginx_site.py" "manage_nginx_site.py"
  if [[ -f "$BUNDLE_ROOT/scripts/preflight_metrica.sh" ]]; then
    cp "$BUNDLE_ROOT/scripts/preflight_metrica.sh" "$INSTALL_DIR/scripts/preflight_metrica.sh"
  fi
  if [[ -f "$BUNDLE_ROOT/scripts/issue_metrica_entitlement.mjs" ]]; then
    cp "$BUNDLE_ROOT/scripts/issue_metrica_entitlement.mjs" "$INSTALL_DIR/scripts/issue_metrica_entitlement.mjs"
  fi
  if [[ -f "$BUNDLE_ROOT/scripts/send-max-digest-host.py" ]]; then
    cp "$BUNDLE_ROOT/scripts/send-max-digest-host.py" "$INSTALL_DIR/scripts/send-max-digest-host.py"
  fi
  chmod 700 "$INSTALL_DIR/scripts/install_metrica.sh"
  [[ -f "$INSTALL_DIR/scripts/uninstall_metrica.sh" ]] && chmod 700 "$INSTALL_DIR/scripts/uninstall_metrica.sh"
  [[ -f "$INSTALL_DIR/scripts/manage_nginx_site.py" ]] && chmod 700 "$INSTALL_DIR/scripts/manage_nginx_site.py"
  [[ -f "$INSTALL_DIR/scripts/preflight_metrica.sh" ]] && chmod 700 "$INSTALL_DIR/scripts/preflight_metrica.sh"
  [[ -f "$INSTALL_DIR/scripts/issue_metrica_entitlement.mjs" ]] && chmod 700 "$INSTALL_DIR/scripts/issue_metrica_entitlement.mjs"
  [[ -f "$INSTALL_DIR/scripts/send-max-digest-host.py" ]] && chmod 700 "$INSTALL_DIR/scripts/send-max-digest-host.py"

  DB_PASSWORD="${DB_PASSWORD:-$(random_alnum 24)}"
  BOOTSTRAP_TOKEN="$(random_alnum 48)"
  SECRET_ENCRYPTION_KEY="$(random_hex 32)"
  CSRF_SECRET="$(random_alnum 48)"
  MAX_WEBHOOK_SECRET="$(random_alnum 48)"
  INSTALLATION_ID="${INSTALLATION_ID:-$(cat /proc/sys/kernel/random/uuid)}"
  ALLOWED_ORIGIN="https://${PUBLIC_HOST}"
  if [[ -n "$MAX_BOT_TOKEN" ]]; then
    MAX_REPORT_ENABLED="false"
    MAX_REPORT_DELIVERY_MODE="bot_api"
    MAX_MODE="host_timer"
  else
    MAX_REPORT_ENABLED="false"
    MAX_REPORT_DELIVERY_MODE="stdout"
    MAX_MODE="disabled"
  fi

  render_template "$BUNDLE_ROOT/install/install.env.template" "$INSTALL_DIR/.env"
  chmod 600 "$INSTALL_DIR/.env"

  if [[ "$PUBLISH_MODE" == "standalone" ]]; then
    render_template "$BUNDLE_ROOT/install/Caddyfile.standalone.tpl" "$INSTALL_DIR/runtime/Caddyfile"
  fi
  write_proxy_templates

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
  "issueTime": "$(json_escape "$BOOT_ISO_TS")",
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

  persist_managed_state

}

systemd_available() {
  command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]
}

install_max_digest_host_timer() {
  [[ -n "$MAX_BOT_TOKEN" ]] || return 0

  if [[ ! -f "$INSTALL_DIR/scripts/send-max-digest-host.py" ]]; then
    warn "MAX host digest fallback script is missing in install tree."
    return 0
  fi

  if ! have_command python3; then
    warn "python3 is not available, so MAX host digest timer was not configured."
    return 0
  fi

  local runtime_systemd_dir="$INSTALL_DIR/runtime/systemd"
  local python_bin
  python_bin="$(command -v python3)"
  mkdir -p "$runtime_systemd_dir"

  cat >"$runtime_systemd_dir/intellion-metrica-max-digest-host.service" <<EOF
[Unit]
Description=Intellion Metrica MAX Digest Host Fallback
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
WorkingDirectory=$INSTALL_DIR
Environment=MAX_DIGEST_WORKER_CONTAINER=intellion-metrica-worker
Environment=MAX_DIGEST_DB_CONTAINER=intellion-metrica-db
ExecStart=$python_bin $INSTALL_DIR/scripts/send-max-digest-host.py
EOF

  cat >"$runtime_systemd_dir/intellion-metrica-max-digest-host.timer" <<'EOF'
[Unit]
Description=Run Intellion Metrica MAX Digest Host Fallback every 5 minutes

[Timer]
OnCalendar=*-*-* *:00/5:00
Persistent=true
Unit=intellion-metrica-max-digest-host.service

[Install]
WantedBy=timers.target
EOF

  chmod 600 \
    "$runtime_systemd_dir/intellion-metrica-max-digest-host.service" \
    "$runtime_systemd_dir/intellion-metrica-max-digest-host.timer"

  if ! systemd_available || [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    warn "MAX host digest timer files were generated in $runtime_systemd_dir. Install them manually if you want automatic MAX digests on this host."
    return 0
  fi

  cp "$runtime_systemd_dir/intellion-metrica-max-digest-host.service" /etc/systemd/system/intellion-metrica-max-digest-host.service
  cp "$runtime_systemd_dir/intellion-metrica-max-digest-host.timer" /etc/systemd/system/intellion-metrica-max-digest-host.timer
  systemctl daemon-reload
  systemctl enable --now intellion-metrica-max-digest-host.timer >/dev/null 2>&1 || \
    warn "Failed to enable intellion-metrica-max-digest-host.timer automatically."
  MAX_DIGEST_TIMER_INSTALLED=1
  persist_managed_state
}

compose() {
  local args=(docker compose -f "$INSTALL_DIR/docker-compose.yml" --env-file "$INSTALL_DIR/.env")
  if [[ "$PUBLISH_MODE" == "standalone" ]]; then
    args+=(--profile standalone)
  fi
  "${args[@]}" "$@"
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
  local services=(metrica-db metrica-migrate metrica-api metrica-worker metrica-control-plane)
  local images=("postgres:16-alpine" "$METRICA_API_IMAGE" "$METRICA_WORKER_IMAGE" "$METRICA_CONTROL_PLANE_IMAGE")
  local image seen_images=()
  if [[ "$PUBLISH_MODE" == "standalone" ]]; then
    services+=(metrica-proxy)
    images+=("caddy:2.10-alpine")
  fi

  log "Preparing images."
  for image in "${images[@]}"; do
    if printf '%s\n' "${seen_images[@]}" | grep -Fxq "$image"; then
      continue
    fi
    seen_images+=("$image")

    if image_ref_remote_available "$image"; then
      docker pull "$image" >/dev/null
    elif image_ref_local_available "$image"; then
      log "Using local image $image"
    else
      die "Image ref is unavailable: $image"
    fi
  done

  log "Starting Metrica stack."
  compose up -d "${services[@]}"

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
    -H "Referer: $(control_plane_public_referer)" \
    "$(control_plane_local_url "/api/metrica/auth/csrf")")"
  token="$(printf '%s' "$response" | extract_json_value "csrfToken")"
  [[ -n "$token" ]] || die "Failed to obtain CSRF token from control-plane."
  printf '%s' "$token"
}

bootstrap_owner() {
  local csrf_token payload body_file http_code activation_token activation_path activation_expires_at bootstrap_mode display_panel_url
  bootstrap_mode="activation_link"
  if [[ -n "$OWNER_PASSWORD" ]]; then
    bootstrap_mode="password"
  fi
  if [[ "$PUBLISH_MODE" == "attach-path" ]]; then
    display_panel_url="$(control_plane_public_root_url)"
  elif [[ "$PUBLISH_MODE" == "attach-subdomain" ]]; then
    display_panel_url="https://${PUBLIC_HOST}"
  else
    display_panel_url="https://${PUBLIC_HOST}"
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
    -H "Referer: $(control_plane_public_referer)" \
    -H 'Content-Type: application/json' \
    -H "x-intellion-metrica-csrf: ${csrf_token}" \
    -H "Cookie: intellion_metrica_csrf=${csrf_token}" \
    --data "$payload" \
    "$(control_plane_local_url "/api/metrica/auth/bootstrap")")"

  if [[ "$http_code" == "200" ]]; then
    if [[ "$bootstrap_mode" == "password" ]]; then
      cat >"$INSTALL_DIR/state/owner-credentials.txt" <<EOF
Owner email: ${OWNER_EMAIL}
Owner name: ${OWNER_NAME}
Owner password: ${OWNER_PASSWORD}
Panel URL: ${display_panel_url}
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
    -H "Referer: $(control_plane_public_referer)" \
    -H 'Content-Type: application/json' \
    -H "x-intellion-metrica-csrf: ${csrf_token}" \
    -H "Cookie: intellion_metrica_csrf=${csrf_token}" \
    --data "$payload" \
    "$(control_plane_local_url "/api/metrica/auth/login")")"

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

  health_response="$(curl -fsS "$(control_plane_local_url "/api/health")")" \
    || die "Local control-plane health check failed."
  FINAL_ENTITLEMENT_STATUS="$(printf '%s' "$health_response" | extract_json_value "entitlementStatus")"
  FINAL_ENTITLEMENT_STATUS="${FINAL_ENTITLEMENT_STATUS:-unknown}"

  if [[ "$PUBLISH_MODE" == "standalone" ]] && \
     curl -kfsS --resolve "${PUBLIC_HOST}:443:127.0.0.1" "https://${PUBLIC_HOST}/api/health" >/dev/null; then
    log "Public HTTPS health endpoint is reachable."
  elif [[ "$PUBLISH_MODE" == "standalone" ]]; then
    warn "Public HTTPS health smoke did not pass yet. Internal health is healthy, but TLS/public routing still needs confirmation."
  elif [[ "$AUTO_ATTACH_PROXY_APPLIED" == "1" ]] && \
       curl -kfsS --resolve "${PUBLIC_HOST}:443:127.0.0.1" "$(control_plane_public_root_url)" >/dev/null; then
    log "Attach-path proxy was applied automatically and local ingress check passed."
  elif [[ "$AUTO_ATTACH_PROXY_APPLIED" == "1" ]]; then
    warn "Attach-path auto-attach was applied, but the public ingress check still needs confirmation."
  else
    warn "Путь /metrica еще не опубликован наружу. Сначала подключите reverse proxy, иначе публичный URL будет отдавать 404."
  fi

  verify_owner_login
}

write_final_report() {
  local credentials_path install_status_dir status_text panel_url login_url entry_url internal_panel_url next_step_one max_digest_mode
  local activation_path
  install_status_dir="$INSTALL_DIR/artifacts/install/${BOOT_TS}-one-command-install"
  mkdir -p "$install_status_dir"
  FINAL_LOG_PATH="$INSTALL_DIR/logs/install-${BOOT_TS}.log"
  cp "$LOG_FILE" "$FINAL_LOG_PATH"

  internal_panel_url="$(control_plane_public_root_url)/"
  if [[ "$PUBLISH_MODE" == "attach-path" ]]; then
    entry_url="$(control_plane_public_root_url)"
    panel_url="$entry_url"
    login_url="$entry_url"
  elif [[ "$PUBLISH_MODE" == "attach-subdomain" ]]; then
    entry_url="https://${PUBLIC_HOST}"
    panel_url="$entry_url"
    login_url="$entry_url"
  else
    panel_url="https://${PUBLIC_HOST}"
    login_url="$panel_url"
    entry_url="$panel_url"
  fi

  if [[ "${#WARNINGS[@]}" -gt 0 ]]; then
    FINAL_STATUS="passed_with_warnings"
  fi
  if [[ -n "$MAX_BOT_TOKEN" ]]; then
    max_digest_mode="host_timer"
  else
    max_digest_mode="disabled"
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
  elif [[ "$AUTO_ATTACH_PROXY_APPLIED" == "1" ]]; then
    next_step_one="Откройте $(control_plane_public_root_url) и завершите активацию владельца"
  elif is_attach_mode && ! have_command nginx; then
    next_step_one="На этом сервере нет nginx. Подключите reverse proxy для ${entry_url} на сервере сайта, иначе ссылка будет отдавать 404"
  elif is_attach_mode; then
    next_step_one="Примените proxy-конфиг из ${INSTALL_DIR}/runtime/proxy и откройте ${entry_url}"
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
  "proxyTemplatesPath": "$(json_escape "$INSTALL_DIR/runtime/proxy")",
  "logPath": "$(json_escape "$FINAL_LOG_PATH")",
  "serviceFilesPath": "$(json_escape "$INSTALL_DIR")",
  "maxBotConfigured": $( [[ -n "$MAX_BOT_TOKEN" ]] && printf 'true' || printf 'false' ),
  "maxDigestMode": "$(json_escape "$max_digest_mode")",
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
Режим MAX digest: ${max_digest_mode}
Служебный каталог: ${INSTALL_DIR}
Журнал установки: ${FINAL_LOG_PATH}
Каталог proxy-шаблонов: ${INSTALL_DIR}/runtime/proxy

Следующий шаг:
1. ${next_step_one}
2. После активации войдите в ${entry_url}
3. Проверьте, что первый сайт для домена установки появился автоматически в Управление -> Сайты
4. Откройте основной сайт в браузере и проверьте, что события начинают появляться в Обзоре
5. Если сайт опубликован нестандартно, проверьте collect / consent и автоподключение loader через reverse proxy
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
  resolve_bundle_root
  load_bundled_images_if_present
  preflight_checks

  if [[ "$PRECHECK_ONLY" -eq 1 ]]; then
    log "Preflight completed successfully."
    exit 0
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "Dry-run finished after preflight."
    exit 0
  fi

  prepare_install_tree
  deploy_stack
  auto_attach_nginx_path_proxy
  install_max_digest_host_timer
  bootstrap_owner
  post_install_smoke
  log "Installation completed."
  write_final_report

  printf '\n'
  cat "$FINAL_REPORT_PATH"
}

if [[ "${BASH_SOURCE[0]-$0}" == "$0" ]]; then
  main "$@"
fi
