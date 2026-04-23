#!/usr/bin/env bash
set -Eeuo pipefail

DEFAULT_INSTALL_DIR="/opt/intellion-metrica"
INSTALL_DIR="$DEFAULT_INSTALL_DIR"
YES=0
PURGE_ALL=0
REMOVE_IMAGES=0
FORCE=0
BACKUP_DIR=""
TS="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_FILE="/tmp/intellion-metrica-uninstall-${TS}.log"
exec > >(tee -a "$LOG_FILE") 2>&1

INSTALL_ENV_FILE=""
MANAGED_STATE_FILE=""
UNINSTALL_BACKUP_DIR=""

PUBLISH_MODE=""
PUBLIC_HOST=""
ENTRY_PATH=""
AUTO_ATTACH_PROXY_APPLIED=0
AUTO_ATTACH_PROXY_KIND=""
AUTO_ATTACH_PROXY_TARGET_FILE=""
AUTO_ATTACH_PROXY_SNIPPET=""

usage() {
  cat <<'EOF'
Usage:
  uninstall_metrica.sh [options]

Options:
  --install-dir <path>     # default /opt/intellion-metrica
  --yes                    # required for non-interactive uninstall
  --purge-all              # remove containers, volumes, install dir, and auto-managed proxy
  --remove-images          # also remove product images referenced by this install
  --backup-dir <path>      # where backups should be written
  --force                  # continue even if optional backup steps fail
  --help

Examples:
  sudo bash /opt/intellion-metrica/scripts/uninstall_metrica.sh --yes
  sudo bash /opt/intellion-metrica/scripts/uninstall_metrica.sh --yes --purge-all
EOF
}

log() {
  printf '[uninstall] %s\n' "$*"
}

warn() {
  printf '[uninstall][warn] %s\n' "$*" >&2
}

die() {
  printf '[uninstall][error] %s\n' "$*" >&2
  exit 1
}

have_command() {
  command -v "$1" >/dev/null 2>&1
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --install-dir)
        INSTALL_DIR="${2:-}"
        shift 2
        ;;
      --yes)
        YES=1
        shift
        ;;
      --purge-all)
        PURGE_ALL=1
        shift
        ;;
      --remove-images)
        REMOVE_IMAGES=1
        shift
        ;;
      --backup-dir)
        BACKUP_DIR="${2:-}"
        shift 2
        ;;
      --force)
        FORCE=1
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

require_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run uninstall_metrica.sh as root or via sudo."
}

trim_ascii_whitespace() {
  local value="${1:-}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

load_dotenv_file() {
  local env_file="${1:-}" line key value
  [[ -n "$env_file" ]] || die "load_dotenv_file requires a file path."
  [[ -f "$env_file" ]] || die "Env file was not found: $env_file"

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -n "$line" ]] || continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" == *=* ]] || continue

    key="$(trim_ascii_whitespace "${line%%=*}")"
    value="${line#*=}"

    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue

    if [[ "$value" =~ ^\".*\"$ ]] || [[ "$value" =~ ^\'.*\'$ ]]; then
      value="${value:1:${#value}-2}"
    fi

    printf -v "$key" '%s' "$value"
    export "$key"
  done < "$env_file"
}

load_install_context() {
  INSTALL_ENV_FILE="$INSTALL_DIR/.env"
  MANAGED_STATE_FILE="$INSTALL_DIR/state/installer-managed.env"

  [[ -f "$INSTALL_ENV_FILE" ]] || die "Install env file was not found: $INSTALL_ENV_FILE"
  [[ -f "$INSTALL_DIR/docker-compose.yml" ]] || die "docker-compose.yml was not found in $INSTALL_DIR"

  # Read docker-style env-file values as data, not as shell code.
  load_dotenv_file "$INSTALL_ENV_FILE"

  if [[ -f "$MANAGED_STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$MANAGED_STATE_FILE"
  fi

  PUBLISH_MODE="${PUBLISH_MODE:-}"
  PUBLIC_HOST="${PUBLIC_HOST:-}"
  ENTRY_PATH="${ENTRY_PATH:-/metrica}"
  AUTO_ATTACH_PROXY_APPLIED="${AUTO_ATTACH_PROXY_APPLIED:-0}"
  AUTO_ATTACH_PROXY_KIND="${AUTO_ATTACH_PROXY_KIND:-}"
  AUTO_ATTACH_PROXY_TARGET_FILE="${AUTO_ATTACH_PROXY_TARGET_FILE:-}"
  AUTO_ATTACH_PROXY_SNIPPET="${AUTO_ATTACH_PROXY_SNIPPET:-}"
}

compose() {
  docker compose -f "$INSTALL_DIR/docker-compose.yml" --env-file "$INSTALL_ENV_FILE" "$@"
}

prepare_backup_dir() {
  if [[ -n "$BACKUP_DIR" ]]; then
    UNINSTALL_BACKUP_DIR="$BACKUP_DIR/uninstall-$TS"
  else
    UNINSTALL_BACKUP_DIR="/var/backups/intellion-metrica/uninstall-$TS"
  fi

  mkdir -p "$UNINSTALL_BACKUP_DIR"
  chmod 700 "$UNINSTALL_BACKUP_DIR"
  log "Backup directory: $UNINSTALL_BACKUP_DIR"
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

confirm_or_exit() {
  local summary="This will stop Intellion Metrica containers"
  if [[ "$PURGE_ALL" -eq 1 ]]; then
    summary="${summary}, remove volumes, remove the install directory, and delete only installer-managed proxy attachments"
  else
    summary="${summary} and remove only installer-managed proxy attachments, while preserving data and the install directory"
  fi

  if [[ "$REMOVE_IMAGES" -eq 1 ]]; then
    summary="${summary}, and remove product images"
  fi

  if [[ "$YES" -eq 1 ]]; then
    log "$summary."
    return
  fi

  printf '%s\n' "$summary."
  read_prompt_value "Continue? [y/N]: " answer
  [[ "$answer" =~ ^[Yy]$ ]] || die "Uninstall cancelled."
}

backup_database_if_needed() {
  [[ "$PURGE_ALL" -eq 1 ]] || return 0

  local dump_path="$UNINSTALL_BACKUP_DIR/postgres.sql"
  if ! docker ps --format '{{.Names}}' | grep -Fxq 'intellion-metrica-db'; then
    warn "Database container is not running, skipping pg_dump backup."
    return 0
  fi

  log "Creating logical PostgreSQL backup."
  if docker exec \
    -e PGPASSWORD="${INTELLIONS_ANALYTICS_DB_PASSWORD}" \
    intellion-metrica-db \
    pg_dump -U "${INTELLIONS_ANALYTICS_DB_USER}" -d "${INTELLIONS_ANALYTICS_DB_NAME}" >"$dump_path"; then
    chmod 600 "$dump_path"
    return 0
  fi

  rm -f "$dump_path"
  if [[ "$FORCE" -eq 1 ]]; then
    warn "pg_dump backup failed, continuing because --force is set."
    return 0
  fi

  die "pg_dump backup failed. Re-run with --force only if you are sure you do not need a database backup."
}

backup_install_tree_if_needed() {
  [[ "$PURGE_ALL" -eq 1 ]] || return 0

  local archive_path="$UNINSTALL_BACKUP_DIR/install-dir.tar.gz"
  log "Archiving install directory."
  tar -czf "$archive_path" -C "$(dirname "$INSTALL_DIR")" "$(basename "$INSTALL_DIR")"
  chmod 600 "$archive_path"
}

remove_auto_managed_nginx_proxy() {
  [[ "$AUTO_ATTACH_PROXY_APPLIED" == "1" ]] || return 0
  [[ "$AUTO_ATTACH_PROXY_KIND" == "nginx" ]] || return 0
  [[ -n "$AUTO_ATTACH_PROXY_TARGET_FILE" ]] || return 0
  [[ -n "$AUTO_ATTACH_PROXY_SNIPPET" ]] || return 0

  if [[ ! -f "$AUTO_ATTACH_PROXY_TARGET_FILE" ]]; then
    warn "Managed nginx target file is missing: $AUTO_ATTACH_PROXY_TARGET_FILE"
    return 0
  fi

  log "Removing installer-managed nginx attach block."
  mkdir -p "$UNINSTALL_BACKUP_DIR/nginx"
  cp "$AUTO_ATTACH_PROXY_TARGET_FILE" "$UNINSTALL_BACKUP_DIR/nginx/$(basename "$AUTO_ATTACH_PROXY_TARGET_FILE").bak"

  python3 "$INSTALL_DIR/scripts/manage_nginx_site.py" \
    remove-include \
    --file "$AUTO_ATTACH_PROXY_TARGET_FILE" \
    --include-path "$AUTO_ATTACH_PROXY_SNIPPET" >/dev/null

  rm -f "$AUTO_ATTACH_PROXY_SNIPPET"

  if nginx -t >/dev/null 2>&1; then
    if have_command systemctl; then
      systemctl reload nginx >/dev/null 2>&1 || warn "Failed to reload nginx after removing the managed snippet."
    else
      nginx -s reload >/dev/null 2>&1 || warn "Failed to reload nginx after removing the managed snippet."
    fi
    return 0
  fi

  warn "nginx -t failed after removing the managed snippet. Restoring previous config."
  cp "$UNINSTALL_BACKUP_DIR/nginx/$(basename "$AUTO_ATTACH_PROXY_TARGET_FILE").bak" "$AUTO_ATTACH_PROXY_TARGET_FILE"
  nginx -t >/dev/null 2>&1 || die "Restored nginx config still does not validate. Inspect the server manually."
  if have_command systemctl; then
    systemctl reload nginx >/dev/null 2>&1 || true
  else
    nginx -s reload >/dev/null 2>&1 || true
  fi
  die "Managed nginx snippet removal was reverted because nginx validation failed."
}

remove_max_digest_timer() {
  local service_name="intellion-metrica-max-digest-host.service"
  local timer_name="intellion-metrica-max-digest-host.timer"

  if have_command systemctl; then
    systemctl disable --now "$timer_name" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/$service_name" "/etc/systemd/system/$timer_name"
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi
}

bring_down_stack() {
  log "Stopping Metrica containers."
  if [[ "$PURGE_ALL" -eq 1 ]]; then
    compose down --remove-orphans -v || warn "docker compose down -v returned non-zero."
  else
    compose down --remove-orphans || warn "docker compose down returned non-zero."
  fi
}

remove_install_dir_if_needed() {
  [[ "$PURGE_ALL" -eq 1 ]] || return 0
  log "Removing install directory."
  rm -rf "$INSTALL_DIR"
}

remove_images_if_requested() {
  [[ "$REMOVE_IMAGES" -eq 1 ]] || return 0

  local images=(
    "${METRICA_API_IMAGE:-}"
    "${METRICA_WORKER_IMAGE:-}"
    "${METRICA_CONTROL_PLANE_IMAGE:-}"
  )

  for image in "${images[@]}"; do
    [[ -n "$image" ]] || continue
    docker image rm -f "$image" >/dev/null 2>&1 || true
  done
}

main() {
  parse_args "$@"
  require_root
  load_install_context
  prepare_backup_dir
  confirm_or_exit
  backup_database_if_needed
  backup_install_tree_if_needed
  bring_down_stack
  remove_max_digest_timer
  remove_auto_managed_nginx_proxy
  remove_images_if_requested
  remove_install_dir_if_needed

  printf '\n'
  printf 'Intellion Metrica uninstall finished.\n'
  printf 'Install dir: %s\n' "$INSTALL_DIR"
  printf 'Backup dir: %s\n' "$UNINSTALL_BACKUP_DIR"
  printf 'Log file: %s\n' "$LOG_FILE"
  if [[ "$PURGE_ALL" -eq 1 ]]; then
    printf 'Mode: full purge with backup\n'
  else
    printf 'Mode: safe stop, data preserved\n'
  fi
}

if [[ "${BASH_SOURCE[0]-$0}" == "$0" ]]; then
  main "$@"
fi
