#!/usr/bin/env bash
set -euo pipefail
cd /  # tránh warning could not change directory to /root

########################################
# CẤU HÌNH CƠ BẢN
########################################

VHM_VERSION="1.0.0"

REPO_PATH="mrsiu226/vhm"
REPO_BASE="https://raw.githubusercontent.com/${REPO_PATH}/main"

SYSTEM_PG_USER="postgres"
LOG_FILE="/var/log/pg_ultra_tool.log"

########################################
# MÀU
########################################

GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
BLUE="\e[34m"
CYAN="\e[36m"
RESET="\e[0m"

########################################
# HÀM TIỆN ÍCH
########################################

log() {
  echo -e "$(date '+%Y-%m-%d %H:%M:%S') | $1" | tee -a "$LOG_FILE"
}

require_root() {
  if [[ "$EUID" -ne 0 ]]; then
    echo -e "${RED}⚠ Script này nên chạy với quyền root (sudo).${RESET}"
    exit 1
  fi
}

header() {
  echo -e "${CYAN}"
  echo "=============================================="
  echo "   🔥 VHM — POSTGRESQL ULTRA TOOL (v${VHM_VERSION})"
  echo "=============================================="
  echo "   Hỗ trợ tạo/xoá user và database PostgreSQL"
  echo "   Tác giả: MrSiu"
  echo "=============================================="
  echo -e "${RESET}"
}

pause() {
  read -rp "Nhấn Enter để tiếp tục..." _
}

########################################
# AUTO UPDATE
########################################

self_update() {
  if ! command -v curl >/dev/null 2>&1; then
    echo -e "${RED}❌ Cần cài curl trước (apt install curl -y).${RESET}"
    exit 1
  fi

  echo -e "${BLUE}🔍 Kiểm tra bản cập nhật...${RESET}"
  LATEST_VERSION=$(curl -fsSL "${REPO_BASE}/version.txt" 2>/dev/null || echo "")

  if [[ -z "$LATEST_VERSION" ]]; then
    echo -e "${RED}❌ Không lấy được version.txt từ repo.${RESET}"
    exit 1
  fi

  if [[ "$LATEST_VERSION" == "$VHM_VERSION" ]]; then
    echo -e "${GREEN}✅ VHM đang là bản mới nhất (${VHM_VERSION}).${RESET}"
    exit 0
  fi

  echo -e "${YELLOW}⚠ Có bản mới: ${LATEST_VERSION} (bạn đang dùng ${VHM_VERSION}).${RESET}"
  echo -e "${BLUE}→ Đang cập nhật...${RESET}"

  TMP_FILE=$(mktemp)
  curl -fsSL "${REPO_BASE}/vhm.sh" -o "$TMP_FILE"
  sudo mv "$TMP_FILE" /usr/local/bin/vhm
  sudo chmod +x /usr/local/bin/vhm

  echo -e "${GREEN}✅ Cập nhật thành công lên v${LATEST_VERSION}.${RESET}"
  exit 0
}

check_for_update_hint() {
  if ! command -v curl >/dev/null 2>&1; then
    return
  fi

  LATEST=$(curl -fsSL "${REPO_BASE}/version.txt" 2>/dev/null || echo "")
  if [[ -n "$LATEST" && "$LATEST" != "$VHM_VERSION" ]]; then
    echo -e "${YELLOW}🔔 Có bản VHM mới: ${LATEST} (hiện tại: ${VHM_VERSION})"
    echo -e "   Gõ '${CYAN}vhm update${YELLOW}' để cập nhật.${RESET}"
    echo ""
  fi
}

print_help() {
  cat <<EOF
VHM — PostgreSQL Ultra Tool (v${VHM_VERSION})

Cách dùng:
  vhm           # chạy menu tương tác
  vhm update    # cập nhật VHM lên bản mới nhất
  vhm version   # in version hiện tại
  vhm help      # xem trợ giúp

EOF
}

########################################
# LẤY ĐƯỜNG DẪN CONFIG POSTGRES
########################################

get_pg_conf_paths() {
  CONFIG_FILE=$(sudo -u "$SYSTEM_PG_USER" psql -tAc "SHOW config_file;" | xargs)
  HBA_FILE=$(sudo -u "$SYSTEM_PG_USER" psql -tAc "SHOW hba_file;" | xargs)
}

enable_remote_for_user() {
  local PG_USER="$1"
  get_pg_conf_paths

  echo -e "${BLUE}→ Bật listen_addresses = '*' trong ${CONFIG_FILE}${RESET}"
  sudo sed -i "s/^[#]*listen_addresses.*/listen_addresses = '*'/" "$CONFIG_FILE"

  echo -e "${BLUE}→ Thêm rule pg_hba.conf cho user ${PG_USER}${RESET}"
  local HBA_LINE="host    all    ${PG_USER}    0.0.0.0/0    md5"

  if ! grep -q "$PG_USER" "$HBA_FILE"; then
    printf "\n# Allow %s from any IPv4\n%s\n" "$PG_USER" "$HBA_LINE" | sudo tee -a "$HBA_FILE" >/dev/null
    log "Thêm pg_hba rule cho user ${PG_USER}"
  else
    echo -e "${YELLOW}⚠ Đã có rule cho user này trong pg_hba.conf${RESET}"
  fi

  echo -e "${BLUE}→ Restart PostgreSQL...${RESET}"
  sudo systemctl restart postgresql
}

open_ufw_5432_if_needed() {
  if command -v ufw >/dev/null 2>&1; then
    if ufw status | grep -q "Status: active"; then
      echo -e "${BLUE}→ UFW đang bật, mở port 5432...${RESET}"
      sudo ufw allow 5432/tcp >/dev/null || true
      log "Mở port 5432 qua UFW"
      echo -e "${GREEN}✔ Đã mở port 5432 (UFW)${RESET}"
    else
      echo -e "${YELLOW}⚠ UFW chưa bật, bỏ qua mở port${RESET}"
    fi
  else
    echo -e "${YELLOW}⚠ Không tìm thấy ufw, bỏ qua mở port${RESET}"
  fi
}

test_connection() {
  local PG_USER="$1"
  local PG_DB="$2"
  local PG_PASS="$3"

  echo -e "${BLUE}→ Test kết nối user mới...${RESET}"
  local TEST_CMD
  TEST_CMD=$(PGPASSWORD="$PG_PASS" psql -U "$PG_USER" -d "$PG_DB" -h localhost -tAc "SELECT 1;" 2>/dev/null || true)

  if [[ "$TEST_CMD" == "1" ]]; then
    log "Test kết nối OK cho user ${PG_USER} / db ${PG_DB}"
    echo -e "${GREEN}✔ Test kết nối thành công${RESET}"
  else
    log "Test kết nối FAILED cho user ${PG_USER} / db ${PG_DB}"
    echo -e "${RED}❌ Test kết nối thất bại${RESET}"
  fi
}

########################################
# CHỨC NĂNG: TẠO USER + DB
########################################

create_user_and_db() {
  echo -e "${BLUE}=== TẠO USER + DATABASE MỚI ===${RESET}"
  read -rp "👉 Nhập tên user PostgreSQL: " PG_USER
  read -rp "👉 Nhập tên database: " PG_DB
  read -rsp "👉 Nhập password (ẩn): " PG_PASS
  echo ""

  echo -e "${YELLOW}Bạn đã nhập:${RESET}"
  echo "User     : $PG_USER"
  echo "Database : $PG_DB"
  echo "Password : **** (ẩn)"
  read -rp "👉 Xác nhận tạo? (y/n): " CONFIRM
  [[ "$CONFIRM" == "y" ]] || { echo -e "${RED}❌ Hủy thao tác${RESET}"; return; }

  # USER
  echo -e "${BLUE}[1/5] Kiểm tra user...${RESET}"
  local USER_EXISTS
  USER_EXISTS=$(sudo -u "$SYSTEM_PG_USER" psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${PG_USER}'" || true)
  if [[ -z "$USER_EXISTS" ]]; then
    sudo -u "$SYSTEM_PG_USER" psql -c "CREATE USER ${PG_USER} WITH PASSWORD '${PG_PASS}';"
    log "Tạo user ${PG_USER}"
    echo -e "${GREEN}✔ Đã tạo user${RESET}"
  else
    echo -e "${YELLOW}⚠ User đã tồn tại, bỏ qua${RESET}"
  fi

  # DB
  echo -e "${BLUE}[2/5] Kiểm tra database...${RESET}"
  local DB_EXISTS
  DB_EXISTS=$(sudo -u "$SYSTEM_PG_USER" psql -tAc "SELECT 1 FROM pg_database WHERE datname='${PG_DB}'" || true)
  if [[ -z "$DB_EXISTS" ]]; then
    sudo -u "$SYSTEM_PG_USER" psql -c "CREATE DATABASE ${PG_DB} OWNER ${PG_USER};"
    log "Tạo database ${PG_DB}"
    echo -e "${GREEN}✔ Đã tạo database${RESET}"
  else
    echo -e "${YELLOW}⚠ Database đã tồn tại, bỏ qua tạo mới${RESET}"
  fi

  # GRANTS
  echo -e "${BLUE}[3/5] Cấp quyền trên database...${RESET}"
  sudo -u "$SYSTEM_PG_USER" psql -c "GRANT ALL PRIVILEGES ON DATABASE ${PG_DB} TO ${PG_USER};"
  log "GRANT ALL ON DB ${PG_DB} cho ${PG_USER}"
  echo -e "${GREEN}✔ Cấp quyền DB xong${RESET}"

  echo -e "${BLUE}[4/5] Cấp quyền schema & default privileges...${RESET}"
  sudo -u "$SYSTEM_PG_USER" psql -d "$PG_DB" -c "GRANT ALL ON SCHEMA public TO ${PG_USER};"
  sudo -u "$SYSTEM_PG_USER" psql -d "$PG_DB" -c "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO ${PG_USER};"
  sudo -u "$SYSTEM_PG_USER" psql -d "$PG_DB" -c "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO ${PG_USER};"
  sudo -u "$SYSTEM_PG_USER" psql -c "GRANT CREATE ON DATABASE ${PG_DB} TO ${PG_USER};"
  log "Cấp quyền schema public & default privileges cho ${PG_USER} trên ${PG_DB}"
  echo -e "${GREEN}✔ Schema OK${RESET}"

  echo -e "${BLUE}[5/5] Cấu hình remote access & firewall...${RESET}"
  enable_remote_for_user "$PG_USER"
  open_ufw_5432_if_needed
  test_connection "$PG_USER" "$PG_DB" "$PG_PASS"

  echo -e "${GREEN}🎉 HOÀN TẤT TẠO USER + DB${RESET}"
  echo "User     : $PG_USER"
  echo "Database : $PG_DB"
}

########################################
# CHỨC NĂNG: XOÁ USER + DB
########################################

delete_user_and_db() {
  echo -e "${BLUE}=== XOÁ USER + DATABASE ===${RESET}"
  read -rp "👉 Nhập tên user PostgreSQL cần xoá: " PG_USER
  read -rp "👉 Nhập tên database cần xoá: " PG_DB

  echo -e "${YELLOW}Bạn chuẩn bị XOÁ:${RESET}"
  echo "User     : $PG_USER"
  echo "Database : $PG_DB"
  echo -e "${RED}⚠ Cảnh báo: thao tác không thể hoàn tác!${RESET}"
  read -rp "👉 Gõ CHAPNHAN để xác nhận: " CONFIRM
  [[ "$CONFIRM" == "CHAPNHAN" ]] || { echo -e "${RED}❌ Hủy thao tác xoá${RESET}"; return; }

  # DROP DB
  local DB_EXISTS
  DB_EXISTS=$(sudo -u "$SYSTEM_PG_USER" psql -tAc "SELECT 1 FROM pg_database WHERE datname='${PG_DB}'" || true)
  if [[ -n "$DB_EXISTS" ]]; then
    sudo -u "$SYSTEM_PG_USER" psql -c "REVOKE CONNECT ON DATABASE ${PG_DB} FROM PUBLIC, ${PG_USER};" || true
    sudo -u "$SYSTEM_PG_USER" psql -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${PG_DB}';" || true
    sudo -u "$SYSTEM_PG_USER" psql -c "DROP DATABASE ${PG_DB};"
    log "DROP DATABASE ${PG_DB}"
    echo -e "${GREEN}✔ Đã xoá database ${PG_DB}${RESET}"
  else
    echo -e "${YELLOW}⚠ Database không tồn tại, bỏ qua${RESET}"
  fi

  # DROP USER
  local USER_EXISTS
  USER_EXISTS=$(sudo -u "$SYSTEM_PG_USER" psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${PG_USER}'" || true)
  if [[ -n "$USER_EXISTS" ]]; then
    sudo -u "$SYSTEM_PG_USER" psql -c "DROP ROLE ${PG_USER};"
    log "DROP ROLE ${PG_USER}"
    echo -e "${GREEN}✔ Đã xoá user ${PG_USER}${RESET}"
  else
    echo -e "${YELLOW}⚠ User không tồn tại, bỏ qua${RESET}"
  fi

  # Xoá rule pg_hba.conf
  get_pg_conf_paths
  if [[ -f "$HBA_FILE" ]]; then
    sudo sed -i "/${PG_USER}/d" "$HBA_FILE"
    log "Xoá rule pg_hba.conf liên quan tới ${PG_USER}"
    echo -e "${BLUE}→ Đã xoá rule trong pg_hba.conf (nếu có)${RESET}"
    sudo systemctl restart postgresql
  fi

  echo -e "${GREEN}🎉 HOÀN TẤT XOÁ USER + DB${RESET}"
}

########################################
# CHỨC NĂNG: LIỆT KÊ USER & DB
########################################

list_users_and_dbs() {
  echo -e "${BLUE}=== DANH SÁCH USER (ROLES) ===${RESET}"
  sudo -u "$SYSTEM_PG_USER" psql \
    -P pager=off -P "format=aligned" -P "border=2" \
    -c "\du"

  echo ""
  echo -e "${BLUE}=== DANH SÁCH DATABASES (non-template) ===${RESET}"
  sudo -u "$SYSTEM_PG_USER" psql \
    -P pager=off -P "format=aligned" -P "border=2" \
    -c "
      SELECT
        d.datname AS database,
        pg_catalog.pg_get_userbyid(d.datdba) AS owner,
        pg_catalog.pg_encoding_to_char(d.encoding) AS encoding,
        d.datcollate AS collate,
        d.datctype AS ctype
      FROM pg_database d
      WHERE d.datistemplate = false
      ORDER BY d.datname;
    "

  echo ""
  echo "👉 Gợi ý: dùng full-screen (Alt+Enter / tmux) để xem bảng đẹp hơn."
}

########################################
# MENU CHÍNH
########################################

main_menu() {
  require_root
  header
  check_for_update_hint
  echo "Log file: $LOG_FILE"
  echo ""

  while true; do
    echo -e "${CYAN}===== MENU =====${RESET}"
    echo "1) Tạo user + database"
    echo "2) Xoá user + database"
    echo "3) Liệt kê user & database"
    echo "4) Thoát"
    read -rp "👉 Chọn (1-4): " CHOICE

    case "$CHOICE" in
      1)
        create_user_and_db
        pause
        ;;
      2)
        delete_user_and_db
        pause
        ;;
      3)
        list_users_and_dbs
        pause
        ;;
      4)
        echo -e "${GREEN}Tạm biệt!${RESET}"
        exit 0
        ;;
      *)
        echo -e "${RED}❌ Lựa chọn không hợp lệ${RESET}"
        ;;
    esac
  done
}

########################################
# ENTRYPOINT — XỬ LÝ SUBCOMMAND
########################################

case "${1:-}" in
  update)
    self_update
    ;;
  version)
    echo "VHM version ${VHM_VERSION}"
    ;;
  help|-h|--help)
    print_help
    ;;
  *)
    main_menu
    ;;
esac
