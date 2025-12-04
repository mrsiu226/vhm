#!/usr/bin/env bash
set -euo pipefail

SYSTEM_PG_USER="postgres"
BACKUP_ROOT="/opt/pg_backups"
RETENTION_DAYS=7

# Remote mặc định (override bằng /etc/vhm-backup.conf)
RCLONE_REMOTE="b2backup:postgres-backup"

LOG_FILE="/var/log/pg_backup_b2_rclone.log"

# Allow override từ file config
if [[ -f /etc/vhm-backup.conf ]]; then
  # shellcheck disable=SC1091
  source /etc/vhm-backup.conf
fi

DB_NAME="${1:-}"
TS=$(date +"%Y-%m-%d_%H-%M-%S")

mkdir -p "$BACKUP_ROOT"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" | tee -a "$LOG_FILE"
}

backup_db() {
  local DB="$1"
  local TARGET="${BACKUP_ROOT}/${DB}"
  mkdir -p "$TARGET"
  local FILE="${TARGET}/${DB}_${TS}.sql.gz"

  echo "→ Backup: $DB"
  sudo -u "$SYSTEM_PG_USER" pg_dump "$DB" | gzip > "$FILE"

  echo "→ Xoá file quá ${RETENTION_DAYS} ngày"
  find "$TARGET" -type f -name "*.sql.gz" -mtime +${RETENTION_DAYS} -delete || true
}

echo "=== PostgreSQL Backup → B2 ==="
log "Start backup. Remote=${RCLONE_REMOTE}"

if [[ -n "$DB_NAME" ]]; then
  backup_db "$DB_NAME"
else
  DBS=$(sudo -u "$SYSTEM_PG_USER" psql -tAc "SELECT datname FROM pg_database WHERE datistemplate = false;")
  for d in $DBS; do backup_db "$d"; done
fi

echo "→ Sync lên B2: $RCLONE_REMOTE"
if ! command -v rclone >/dev/null 2>&1; then
  echo "❌ rclone chưa cài"
  exit 1
fi

rclone sync "$BACKUP_ROOT" "$RCLONE_REMOTE" \
  --fast-list \
  --create-empty-src-dirs \
  --log-file "$LOG_FILE" \
  --log-level INFO

log "DONE"
echo "✔ Backup + sync B2 xong."
