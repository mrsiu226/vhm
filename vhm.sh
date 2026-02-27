#!/usr/bin/env bash
set -euo pipefail
cd /  # tránh warning could not change directory to /root

########################################
# CẤU HÌNH CƠ BẢN
########################################

VHM_VERSION="1.3.3"

REPO_PATH="mrsiu226/vhm"
REPO_BASE="https://raw.githubusercontent.com/${REPO_PATH}/main"

SYSTEM_PG_USER="postgres"
MONGO_ADMIN_USER="admin"
LOG_FILE="/var/log/vhm_tool.log"

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
    echo -e "${RED}⚠ VHM nên chạy với quyền root (sudo).${RESET}"
    exit 1
  fi
}

header() {
  echo -e "${CYAN}"
  echo "========================================================"
  echo "   🔥 VHM — DATABASE MANAGEMENT TOOL (v${VHM_VERSION})"
  echo "========================================================"
  echo "   Hỗ trợ quản lý PostgreSQL & MongoDB"
  echo "   Tác giả: MrSiu"
  echo "========================================================"
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

  echo -e "${YELLOW}⚠ Có bản mới: ${LATEST_VERSION} (hiện tại: ${VHM_VERSION}).${RESET}"
  echo -e "${BLUE}→ Đang cập nhật...${RESET}"

  # Cập nhật vhm.sh
  TMP_VHM=$(mktemp)
  if ! curl -fsSL "${REPO_BASE}/vhm.sh" -o "$TMP_VHM"; then
    echo -e "${RED}❌ Tải vhm.sh thất bại, giữ nguyên bản hiện tại.${RESET}"
    rm -f "$TMP_VHM"
    exit 1
  fi
  sudo mv "$TMP_VHM" /usr/local/bin/vhm
  sudo chmod +x /usr/local/bin/vhm
  echo -e "${GREEN}✔ Đã cập nhật /usr/local/bin/vhm${RESET}"

  # Cập nhật / cài mới pg_backup_b2.sh
  TMP_BKP=$(mktemp)
  if curl -fsSL "${REPO_BASE}/pg_backup_b2.sh" -o "$TMP_BKP"; then
    sudo mv "$TMP_BKP" /usr/local/bin/pg_backup_b2.sh
    sudo chmod +x /usr/local/bin/pg_backup_b2.sh
    echo -e "${GREEN}✔ Đã cập nhật /usr/local/bin/pg_backup_b2.sh${RESET}"
  else
    rm -f "$TMP_BKP"
    echo -e "${YELLOW}⚠ Không tải được pg_backup_b2.sh (nhưng vhm đã được cập nhật).${RESET}"
  fi

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
  
  # Hiển thị danh sách users dạng bảng
  echo -e "${YELLOW}Danh sách USER hiện có:${RESET}"
  sudo -u "$SYSTEM_PG_USER" psql \
    -P pager=off -P "format=aligned" -P "border=2" \
    -c "\du"
  
  echo ""
  
  # Hiển thị danh sách databases dạng bảng
  echo -e "${YELLOW}Danh sách DATABASE hiện có:${RESET}"
  sudo -u "$SYSTEM_PG_USER" psql \
    -P pager=off -P "format=aligned" -P "border=2" \
    -c "
      SELECT
        d.datname AS database,
        pg_catalog.pg_get_userbyid(d.datdba) AS owner,
        pg_size_pretty(pg_database_size(d.datname)) AS size
      FROM pg_database d
      WHERE d.datistemplate = false
      ORDER BY d.datname;
    "
  
  echo ""
  read -rp "👉 Nhập tên user PostgreSQL cần xoá: " PG_USER
  read -rp "👉 Nhập tên database cần xoá: " PG_DB

  echo ""
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
# CHỨC NĂNG: CLONE DATABASE
########################################

clone_database() {
  echo -e "${BLUE}=== CLONE DATABASE ===${RESET}"
  
  # Liệt kê databases hiện có
  echo -e "${YELLOW}Danh sách database hiện có:${RESET}"
  sudo -u "$SYSTEM_PG_USER" psql -tAc "
    SELECT datname FROM pg_database 
    WHERE datistemplate = false 
    ORDER BY datname;
  " | while read -r db; do
    echo "  - $db"
  done
  echo ""
  
  read -rp "👉 Nhập tên database nguồn (cần clone): " SOURCE_DB
  read -rp "👉 Nhập tên database đích (tên DB mới sẽ được tạo): " TARGET_DB
  
  if [[ -z "$SOURCE_DB" || -z "$TARGET_DB" ]]; then
    echo -e "${RED}❌ Tên database không được để trống.${RESET}"
    return
  fi
  
  # Kiểm tra database nguồn có tồn tại không
  local SOURCE_EXISTS
  SOURCE_EXISTS=$(sudo -u "$SYSTEM_PG_USER" psql -tAc "SELECT 1 FROM pg_database WHERE datname='${SOURCE_DB}'" || true)
  if [[ -z "$SOURCE_EXISTS" ]]; then
    echo -e "${RED}❌ Database nguồn '${SOURCE_DB}' không tồn tại.${RESET}"
    return
  fi
  
  # Kiểm tra database đích đã tồn tại chưa
  local TARGET_EXISTS
  TARGET_EXISTS=$(sudo -u "$SYSTEM_PG_USER" psql -tAc "SELECT 1 FROM pg_database WHERE datname='${TARGET_DB}'" || true)
  if [[ -n "$TARGET_EXISTS" ]]; then
    echo -e "${RED}❌ Database đích '${TARGET_DB}' đã tồn tại. Vui lòng chọn tên khác.${RESET}"
    return
  fi
  
  # Hỏi về user
  echo ""
  echo -e "${YELLOW}=== CẤU HÌNH USER CHO DATABASE MỚI ===${RESET}"
  echo "1) Tạo user mới cho database này"
  echo "2) Dùng user hiện có"
  echo "3) Dùng user postgres (mặc định)"
  read -rp "👉 Chọn (1-3): " USER_CHOICE
  
  local TARGET_USER=""
  local TARGET_PASS=""
  local CREATE_NEW_USER=false
  
  case "$USER_CHOICE" in
    1)
      read -rp "👉 Nhập tên user mới: " TARGET_USER
      read -rsp "👉 Nhập password cho user mới (ẩn): " TARGET_PASS
      echo ""
      
      if [[ -z "$TARGET_USER" || -z "$TARGET_PASS" ]]; then
        echo -e "${RED}❌ Tên user và password không được để trống.${RESET}"
        return
      fi
      
      # Kiểm tra user đã tồn tại chưa
      local USER_EXISTS
      USER_EXISTS=$(sudo -u "$SYSTEM_PG_USER" psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${TARGET_USER}'" || true)
      if [[ -n "$USER_EXISTS" ]]; then
        echo -e "${RED}❌ User '${TARGET_USER}' đã tồn tại. Vui lòng chọn tên khác.${RESET}"
        return
      fi
      CREATE_NEW_USER=true
      ;;
    2)
      echo -e "${YELLOW}Danh sách user hiện có:${RESET}"
      sudo -u "$SYSTEM_PG_USER" psql -tAc "SELECT rolname FROM pg_roles WHERE rolcanlogin = true ORDER BY rolname;" | while read -r user; do
        echo "  - $user"
      done
      read -rp "👉 Nhập tên user hiện có: " TARGET_USER
      
      if [[ -z "$TARGET_USER" ]]; then
        echo -e "${RED}❌ Tên user không được để trống.${RESET}"
        return
      fi
      
      # Kiểm tra user có tồn tại không
      local USER_EXISTS
      USER_EXISTS=$(sudo -u "$SYSTEM_PG_USER" psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${TARGET_USER}'" || true)
      if [[ -z "$USER_EXISTS" ]]; then
        echo -e "${RED}❌ User '${TARGET_USER}' không tồn tại.${RESET}"
        return
      fi
      ;;
    3|"")
      TARGET_USER="$SYSTEM_PG_USER"
      echo -e "${GREEN}✔ Sẽ dùng user postgres${RESET}"
      ;;
    *)
      echo -e "${RED}❌ Lựa chọn không hợp lệ${RESET}"
      return
      ;;
  esac
  
  echo ""
  echo -e "${YELLOW}Chuẩn bị clone:${RESET}"
  echo "  Database nguồn: $SOURCE_DB"
  echo "  Database mới (sẽ tạo): $TARGET_DB"
  echo "  Owner: $TARGET_USER"
  if [[ "$CREATE_NEW_USER" == true ]]; then
    echo "  → Sẽ tạo user mới: $TARGET_USER"
  fi
  echo ""
  echo -e "${CYAN}💡 Chức năng này sẽ:${RESET}"
  echo "  - Tạo database mới '${TARGET_DB}'"
  echo "  - Clone toàn bộ cấu trúc và dữ liệu từ '${SOURCE_DB}'"
  echo "  - Ngắt kết nối tạm thời đến DB nguồn trong quá trình clone"
  if [[ "$CREATE_NEW_USER" == true ]]; then
    echo "  - Tạo user mới '${TARGET_USER}' và cấp quyền"
  fi
  echo ""
  read -rp "👉 Xác nhận clone? (y/n): " CONFIRM
  [[ "$CONFIRM" == "y" ]] || { echo -e "${RED}❌ Hủy thao tác${RESET}"; return; }
  
  local STEP=1
  local TOTAL_STEPS=4
  if [[ "$CREATE_NEW_USER" == true ]]; then
    TOTAL_STEPS=6
  fi
  
  # Tạo user mới nếu cần
  if [[ "$CREATE_NEW_USER" == true ]]; then
    echo -e "${BLUE}[${STEP}/${TOTAL_STEPS}] Tạo user mới...${RESET}"
    sudo -u "$SYSTEM_PG_USER" psql -c "CREATE USER ${TARGET_USER} WITH PASSWORD '${TARGET_PASS}';"
    log "Tạo user ${TARGET_USER} cho clone database"
    echo -e "${GREEN}✔ Đã tạo user${RESET}"
    ((STEP++))
  fi
  
  echo -e "${BLUE}[${STEP}/${TOTAL_STEPS}] Ngắt kết nối đến database nguồn...${RESET}"
  sudo -u "$SYSTEM_PG_USER" psql -c "
    SELECT pg_terminate_backend(pid) 
    FROM pg_stat_activity 
    WHERE datname='${SOURCE_DB}' AND pid <> pg_backend_pid();
  " >/dev/null 2>&1 || true
  echo -e "${GREEN}✔ Đã ngắt các kết nối${RESET}"
  ((STEP++))
  
  echo -e "${BLUE}[${STEP}/${TOTAL_STEPS}] Đang tạo database mới và clone dữ liệu...${RESET}"
  if sudo -u "$SYSTEM_PG_USER" psql -c "CREATE DATABASE ${TARGET_DB} WITH TEMPLATE ${SOURCE_DB} OWNER ${TARGET_USER};"; then
    log "Clone database từ ${SOURCE_DB} sang ${TARGET_DB} với owner ${TARGET_USER}"
    echo -e "${GREEN}✔ Clone thành công - database mới đã được tạo${RESET}"
  else
    echo -e "${RED}❌ Clone thất bại${RESET}"
    log "Clone database FAILED: ${SOURCE_DB} -> ${TARGET_DB}"
    return
  fi
  ((STEP++))
  
  # Cấp quyền cho user (cả user mới lẫn user hiện có)
  if [[ "$CREATE_NEW_USER" == true ]] || [[ "$TARGET_USER" != "$SYSTEM_PG_USER" ]]; then
    echo -e "${BLUE}[${STEP}/${TOTAL_STEPS}] Chuyển ownership và cấp quyền cho user...${RESET}"
    
    # Chuyển ownership của tất cả tables sang user mới
    echo -e "${BLUE}  → Chuyển ownership của tables...${RESET}"
    for tbl in $(sudo -u "$SYSTEM_PG_USER" psql -d "$TARGET_DB" -tAc "SELECT tablename FROM pg_tables WHERE schemaname='public';"); do
      sudo -u "$SYSTEM_PG_USER" psql -d "$TARGET_DB" -c "ALTER TABLE public.${tbl} OWNER TO ${TARGET_USER};" 2>/dev/null || true
    done
    
    # Chuyển ownership của tất cả sequences sang user mới
    echo -e "${BLUE}  → Chuyển ownership của sequences...${RESET}"
    for seq in $(sudo -u "$SYSTEM_PG_USER" psql -d "$TARGET_DB" -tAc "SELECT sequencename FROM pg_sequences WHERE schemaname='public';"); do
      sudo -u "$SYSTEM_PG_USER" psql -d "$TARGET_DB" -c "ALTER SEQUENCE public.${seq} OWNER TO ${TARGET_USER};" 2>/dev/null || true
    done
    
    # Chuyển ownership của views (nếu có)
    echo -e "${BLUE}  → Chuyển ownership của views...${RESET}"
    for view in $(sudo -u "$SYSTEM_PG_USER" psql -d "$TARGET_DB" -tAc "SELECT viewname FROM pg_views WHERE schemaname='public';"); do
      sudo -u "$SYSTEM_PG_USER" psql -d "$TARGET_DB" -c "ALTER VIEW public.${view} OWNER TO ${TARGET_USER};" 2>/dev/null || true
    done
    
    # Quyền database
    sudo -u "$SYSTEM_PG_USER" psql -c "GRANT ALL PRIVILEGES ON DATABASE ${TARGET_DB} TO ${TARGET_USER};"
    sudo -u "$SYSTEM_PG_USER" psql -c "GRANT CREATE ON DATABASE ${TARGET_DB} TO ${TARGET_USER};"
    
    # Quyền schema
    sudo -u "$SYSTEM_PG_USER" psql -d "$TARGET_DB" -c "GRANT ALL ON SCHEMA public TO ${TARGET_USER};"
    sudo -u "$SYSTEM_PG_USER" psql -d "$TARGET_DB" -c "GRANT USAGE ON SCHEMA public TO ${TARGET_USER};"
    
    # Quyền cho các objects ĐÃ TỒN TẠI
    sudo -u "$SYSTEM_PG_USER" psql -d "$TARGET_DB" -c "GRANT ALL ON ALL TABLES IN SCHEMA public TO ${TARGET_USER};"
    sudo -u "$SYSTEM_PG_USER" psql -d "$TARGET_DB" -c "GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO ${TARGET_USER};"
    sudo -u "$SYSTEM_PG_USER" psql -d "$TARGET_DB" -c "GRANT ALL ON ALL FUNCTIONS IN SCHEMA public TO ${TARGET_USER};"
    
    # Quyền mặc định cho các objects SẼ TẠO SAU NÀY
    sudo -u "$SYSTEM_PG_USER" psql -d "$TARGET_DB" -c "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO ${TARGET_USER};"
    sudo -u "$SYSTEM_PG_USER" psql -d "$TARGET_DB" -c "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO ${TARGET_USER};"
    sudo -u "$SYSTEM_PG_USER" psql -d "$TARGET_DB" -c "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO ${TARGET_USER};"
    
    log "Chuyển ownership và cấp quyền đầy đủ cho user ${TARGET_USER} trên database ${TARGET_DB}"
    echo -e "${GREEN}✔ Đã chuyển ownership và cấp quyền cho tất cả objects${RESET}"
    ((STEP++))
    
    if [[ "$CREATE_NEW_USER" == true ]]; then
      echo -e "${BLUE}[${STEP}/${TOTAL_STEPS}] Cấu hình remote access...${RESET}"
      enable_remote_for_user "$TARGET_USER"
      open_ufw_5432_if_needed
      ((STEP++))
    fi
  fi
  
  echo -e "${BLUE}[${STEP}/${TOTAL_STEPS}] Lấy thông tin database mới...${RESET}"
  sudo -u "$SYSTEM_PG_USER" psql -c "
    SELECT 
      datname AS database,
      pg_catalog.pg_get_userbyid(datdba) AS owner,
      pg_size_pretty(pg_database_size(datname)) AS size
    FROM pg_database 
    WHERE datname='${TARGET_DB}';
  "
  
  echo ""
  echo -e "${GREEN}🎉 HOÀN TẤT CLONE DATABASE${RESET}"
  echo "Database nguồn: $SOURCE_DB"
  echo "Database mới   : $TARGET_DB"
  echo "Owner          : $TARGET_USER"
  
  if [[ "$CREATE_NEW_USER" == true ]]; then
    echo ""
    echo -e "${CYAN}📝 Thông tin kết nối:${RESET}"
    echo "Host     : <server_ip>"
    echo "Port     : 5432"
    echo "Database : $TARGET_DB"
    echo "User     : $TARGET_USER"
    echo "Password : **** (đã nhập)"
  fi
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
  echo "👉 Gợi ý: dùng full-screen để xem bảng đẹp hơn."
}

########################################
# MONGODB FUNCTIONS
########################################

MONGO_CONFIG_FILE="/etc/vhm-mongo.conf"

# Kiểm tra MongoDB có được cài đặt không
check_mongodb() {
  if ! command -v mongosh >/dev/null 2>&1 && ! command -v mongo >/dev/null 2>&1; then
    echo -e "${RED}❌ MongoDB chưa được cài đặt hoặc mongosh/mongo không có trong PATH.${RESET}"
    echo "   Cài đặt: apt install mongodb-mongosh -y"
    return 1
  fi
  return 0
}

# Lưu MongoDB admin password
save_mongo_password() {
  local PASS="$1"
  echo "MONGO_ADMIN_PASS=\"${PASS}\"" | sudo tee "$MONGO_CONFIG_FILE" >/dev/null
  sudo chmod 600 "$MONGO_CONFIG_FILE"
  log "Đã lưu MongoDB admin password vào ${MONGO_CONFIG_FILE}"
}

# Load MongoDB admin password từ file
load_mongo_password() {
  if [[ -f "$MONGO_CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$MONGO_CONFIG_FILE"
    if [[ -n "${MONGO_ADMIN_PASS:-}" ]]; then
      export MONGO_ADMIN_PASS
      return 0
    fi
  fi
  return 1
}

# Lấy MongoDB admin password
get_mongo_admin_password() {
  # Thử load password đã lưu
  if load_mongo_password; then
    echo -e "${GREEN}✔ Đã load password từ file cấu hình${RESET}"
    read -rp "👉 Sử dụng password đã lưu? (y/n, Enter=y): " USE_SAVED
    USE_SAVED=${USE_SAVED:-y}
    
    if [[ "$USE_SAVED" == "y" ]]; then
      return 0
    fi
  fi
  
  # Nhập password mới
  read -rsp "👉 Nhập password của user admin MongoDB: " MONGO_ADMIN_PASS
  echo ""
  export MONGO_ADMIN_PASS
  
  # Hỏi có muốn lưu không
  read -rp "👉 Lưu password này để lần sau không phải nhập lại? (y/n): " SAVE_PASS
  if [[ "$SAVE_PASS" == "y" ]]; then
    save_mongo_password "$MONGO_ADMIN_PASS"
    echo -e "${GREEN}✔ Đã lưu password vào ${MONGO_CONFIG_FILE}${RESET}"
  fi
}

# Kiểm tra kết nối MongoDB
test_mongo_connection() {
  local MONGO_CMD="mongosh"
  if ! command -v mongosh >/dev/null 2>&1; then
    MONGO_CMD="mongo"
  fi
  
  if echo "db.version()" | $MONGO_CMD "mongodb://${MONGO_ADMIN_USER}:${MONGO_ADMIN_PASS}@localhost:27017/admin?authSource=admin" --quiet >/dev/null 2>&1; then
    return 0
  else
    return 1
  fi
}

########################################
# MONGODB: TẠO USER + DATABASE
########################################

mongo_create_user_and_db() {
  echo -e "${BLUE}=== TẠO USER + DATABASE MONGODB ===${RESET}"
  
  check_mongodb || return
  get_mongo_admin_password
  
  if ! test_mongo_connection; then
    echo -e "${RED}❌ Không thể kết nối MongoDB với user admin. Kiểm tra lại password.${RESET}"
    return
  fi
  
  read -rp "👉 Nhập tên database MongoDB: " MONGO_DB
  read -rp "👉 Nhập tên user MongoDB: " MONGO_USER
  read -rsp "👉 Nhập password cho user (ẩn): " MONGO_PASS
  echo ""
  
  echo -e "${YELLOW}Bạn đã nhập:${RESET}"
  echo "Database : $MONGO_DB"
  echo "User     : $MONGO_USER"
  echo "Password : **** (ẩn)"
  read -rp "👉 Xác nhận tạo? (y/n): " CONFIRM
  [[ "$CONFIRM" == "y" ]] || { echo -e "${RED}❌ Hủy thao tác${RESET}"; return; }
  
  local MONGO_CMD="mongosh"
  if ! command -v mongosh >/dev/null 2>&1; then
    MONGO_CMD="mongo"
  fi
  
  echo -e "${BLUE}[1/2] Tạo database và user...${RESET}"
  
  $MONGO_CMD "mongodb://${MONGO_ADMIN_USER}:${MONGO_ADMIN_PASS}@localhost:27017/admin?authSource=admin" --quiet <<EOF
use ${MONGO_DB}
db.createUser({
  user: "${MONGO_USER}",
  pwd: "${MONGO_PASS}",
  roles: [
    { role: "dbOwner", db: "${MONGO_DB}" }
  ]
})
EOF
  
  if [ $? -eq 0 ]; then
    log "Tạo MongoDB user ${MONGO_USER} và database ${MONGO_DB}"
    echo -e "${GREEN}✔ Đã tạo database và user${RESET}"
  else
    echo -e "${RED}❌ Tạo thất bại${RESET}"
    return
  fi
  
  echo -e "${BLUE}[2/2] Test kết nối...${RESET}"
  if echo "db.stats()" | $MONGO_CMD "mongodb://${MONGO_USER}:${MONGO_PASS}@localhost:27017/${MONGO_DB}?authSource=${MONGO_DB}" --quiet >/dev/null 2>&1; then
    log "Test kết nối OK cho MongoDB user ${MONGO_USER} / db ${MONGO_DB}"
    echo -e "${GREEN}✔ Test kết nối thành công${RESET}"
  else
    echo -e "${RED}❌ Test kết nối thất bại${RESET}"
  fi
  
  echo -e "${GREEN}🎉 HOÀN TẤT TẠO USER + DB MONGODB${RESET}"
  echo "Database : $MONGO_DB"
  echo "User     : $MONGO_USER"
  echo ""
  echo -e "${CYAN}📝 Connection String:${RESET}"
  echo "mongodb://${MONGO_USER}:${MONGO_PASS}@localhost:27017/${MONGO_DB}?authSource=${MONGO_DB}"
}

########################################
# MONGODB: XÓA USER + DATABASE
########################################

mongo_delete_user_and_db() {
  echo -e "${BLUE}=== XÓA USER + DATABASE MONGODB ===${RESET}"
  
  check_mongodb || return
  get_mongo_admin_password
  
  if ! test_mongo_connection; then
    echo -e "${RED}❌ Không thể kết nối MongoDB với user admin. Kiểm tra lại password.${RESET}"
    return
  fi
  
  local MONGO_CMD="mongosh"
  if ! command -v mongosh >/dev/null 2>&1; then
    MONGO_CMD="mongo"
  fi
  
  # Hiển thị danh sách databases
  echo -e "${YELLOW}Danh sách database hiện có:${RESET}"
  $MONGO_CMD "mongodb://${MONGO_ADMIN_USER}:${MONGO_ADMIN_PASS}@localhost:27017/admin?authSource=admin" --quiet --eval "db.adminCommand('listDatabases').databases.forEach(function(d) { if (d.name != 'admin' && d.name != 'config' && d.name != 'local') print('  - ' + d.name) })" 2>/dev/null
  echo ""
  
  read -rp "👉 Nhập tên database cần xóa: " MONGO_DB
  read -rp "👉 Nhập tên user cần xóa (có thể bỏ trống): " MONGO_USER
  
  echo ""
  echo -e "${YELLOW}Bạn chuẩn bị XÓA:${RESET}"
  echo "Database : $MONGO_DB"
  [[ -n "$MONGO_USER" ]] && echo "User     : $MONGO_USER"
  echo -e "${RED}⚠ Cảnh báo: thao tác không thể hoàn tác!${RESET}"
  read -rp "👉 Gõ CHAPNHAN để xác nhận: " CONFIRM
  [[ "$CONFIRM" == "CHAPNHAN" ]] || { echo -e "${RED}❌ Hủy thao tác xóa${RESET}"; return; }
  
  # Xóa user nếu có
  if [[ -n "$MONGO_USER" ]]; then
    echo -e "${BLUE}→ Xóa user ${MONGO_USER}...${RESET}"
    $MONGO_CMD "mongodb://${MONGO_ADMIN_USER}:${MONGO_ADMIN_PASS}@localhost:27017/admin?authSource=admin" --quiet --eval "use ${MONGO_DB}; db.dropUser('${MONGO_USER}')" 2>/dev/null
    log "DROP MongoDB user ${MONGO_USER}"
    echo -e "${GREEN}✔ Đã xóa user${RESET}"
  fi
  
  # Xóa database
  echo -e "${BLUE}→ Xóa database ${MONGO_DB}...${RESET}"
  $MONGO_CMD "mongodb://${MONGO_ADMIN_USER}:${MONGO_ADMIN_PASS}@localhost:27017/admin?authSource=admin" --quiet --eval "use ${MONGO_DB}; db.dropDatabase()" 2>/dev/null
  log "DROP MongoDB database ${MONGO_DB}"
  echo -e "${GREEN}✔ Đã xóa database${RESET}"
  
  echo -e "${GREEN}🎉 HOÀN TẤT XÓA DATABASE MONGODB${RESET}"
}

########################################
# MONGODB: LIỆT KÊ DATABASES
########################################

mongo_list_dbs() {
  echo -e "${BLUE}=== DANH SÁCH MONGODB DATABASES ===${RESET}"
  
  check_mongodb || return
  get_mongo_admin_password
  
  if ! test_mongo_connection; then
    echo -e "${RED}❌ Không thể kết nối MongoDB với user admin. Kiểm tra lại password.${RESET}"
    return
  fi
  
  local MONGO_CMD="mongosh"
  if ! command -v mongosh >/dev/null 2>&1; then
    MONGO_CMD="mongo"
  fi
  
  echo ""
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  
  $MONGO_CMD "mongodb://${MONGO_ADMIN_USER}:${MONGO_ADMIN_PASS}@localhost:27017/admin?authSource=admin" --quiet --norc 2>/dev/null <<'EOF' | grep -v "^admin>" | grep -v "^\.\.\."
db.adminCommand('listDatabases').databases.forEach(function(d) {
  if (d.name != 'config' && d.name != 'local') {
    print('Database: \x1b[33m' + d.name + '\x1b[0m');
    print('Size    : ' + (d.sizeOnDisk / 1024 / 1024).toFixed(2) + ' MB');
    
    var currentDb = db.getSiblingDB(d.name);
    try {
      var users = currentDb.getUsers();
      if (users.users && users.users.length > 0) {
        users.users.forEach(function(u) {
          print('User    : ' + u.user + ' (roles: ' + u.roles.map(r => r.role).join(', ') + ')');
        });
      }
    } catch(e) {}
    print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  }
});
EOF

  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
}

########################################
# MONGODB: CLONE DATABASE
########################################

mongo_clone_database() {
  echo -e "${BLUE}=== CLONE MONGODB DATABASE ===${RESET}"
  
  check_mongodb || return
  get_mongo_admin_password
  
  if ! test_mongo_connection; then
    echo -e "${RED}❌ Không thể kết nối MongoDB với user admin. Kiểm tra lại password.${RESET}"
    return
  fi
  
  local MONGO_CMD="mongosh"
  if ! command -v mongosh >/dev/null 2>&1; then
    MONGO_CMD="mongo"
  fi
  
  # Hiển thị danh sách databases
  echo -e "${YELLOW}Danh sách database hiện có:${RESET}"
  $MONGO_CMD "mongodb://${MONGO_ADMIN_USER}:${MONGO_ADMIN_PASS}@localhost:27017/admin?authSource=admin" --quiet --eval "db.adminCommand('listDatabases').databases.forEach(function(d) { if (d.name != 'admin' && d.name != 'config' && d.name != 'local') print('  - ' + d.name) })" 2>/dev/null
  echo ""
  
  read -rp "👉 Nhập tên database nguồn: " SOURCE_DB
  read -rp "👉 Nhập tên database đích (mới): " TARGET_DB
  
  if [[ -z "$SOURCE_DB" || -z "$TARGET_DB" ]]; then
    echo -e "${RED}❌ Tên database không được để trống.${RESET}"
    return
  fi
  
  echo ""
  echo -e "${YELLOW}=== TẠO USER CHO DATABASE MỚI ===${RESET}"
  echo "1) Tạo user mới"
  echo "2) Không tạo user (chỉ clone data)"
  read -rp "👉 Chọn (1-2): " USER_CHOICE
  
  local CREATE_USER=false
  local NEW_USER=""
  local NEW_PASS=""
  
  if [[ "$USER_CHOICE" == "1" ]]; then
    read -rp "👉 Nhập tên user mới: " NEW_USER
    read -rsp "👉 Nhập password: " NEW_PASS
    echo ""
    CREATE_USER=true
  fi
  
  echo ""
  echo -e "${YELLOW}Chuẩn bị clone:${RESET}"
  echo "  Database nguồn: $SOURCE_DB"
  echo "  Database đích: $TARGET_DB"
  [[ "$CREATE_USER" == true ]] && echo "  User mới: $NEW_USER"
  read -rp "👉 Xác nhận clone? (y/n): " CONFIRM
  [[ "$CONFIRM" == "y" ]] || { echo -e "${RED}❌ Hủy thao tác${RESET}"; return; }
  
  echo -e "${BLUE}[1/3] Clone database bằng mongodump...${RESET}"
  
  # Tạo thư mục tạm
  local TEMP_DIR="/tmp/mongo_clone_$$"
  mkdir -p "$TEMP_DIR"
  
  # Dump database nguồn
  mongodump --uri="mongodb://${MONGO_ADMIN_USER}:${MONGO_ADMIN_PASS}@localhost:27017/${SOURCE_DB}?authSource=admin" --out="$TEMP_DIR" --quiet
  
  if [ $? -ne 0 ]; then
    echo -e "${RED}❌ Dump database thất bại${RESET}"
    rm -rf "$TEMP_DIR"
    return
  fi
  
  echo -e "${GREEN}✔ Dump thành công${RESET}"
  
  echo -e "${BLUE}[2/3] Restore vào database mới...${RESET}"
  
  # Restore vào database mới
  mongorestore --uri="mongodb://${MONGO_ADMIN_USER}:${MONGO_ADMIN_PASS}@localhost:27017/${TARGET_DB}?authSource=admin" --nsFrom="${SOURCE_DB}.*" --nsTo="${TARGET_DB}.*" "$TEMP_DIR/${SOURCE_DB}" --quiet
  
  if [ $? -ne 0 ]; then
    echo -e "${RED}❌ Restore database thất bại${RESET}"
    rm -rf "$TEMP_DIR"
    return
  fi
  
  echo -e "${GREEN}✔ Restore thành công${RESET}"
  
  # Xóa thư mục tạm
  rm -rf "$TEMP_DIR"
  
  # Tạo user nếu cần
  if [[ "$CREATE_USER" == true ]]; then
    echo -e "${BLUE}[3/3] Tạo user mới...${RESET}"
    
    $MONGO_CMD "mongodb://${MONGO_ADMIN_USER}:${MONGO_ADMIN_PASS}@localhost:27017/admin?authSource=admin" --quiet <<EOF
use ${TARGET_DB}
db.createUser({
  user: "${NEW_USER}",
  pwd: "${NEW_PASS}",
  roles: [
    { role: "dbOwner", db: "${TARGET_DB}" }
  ]
})
EOF
    
    if [ $? -eq 0 ]; then
      echo -e "${GREEN}✔ Đã tạo user${RESET}"
      log "Clone MongoDB database ${SOURCE_DB} -> ${TARGET_DB} với user ${NEW_USER}"
    else
      echo -e "${YELLOW}⚠ Tạo user thất bại nhưng database đã được clone${RESET}"
    fi
  else
    log "Clone MongoDB database ${SOURCE_DB} -> ${TARGET_DB}"
  fi
  
  echo ""
  echo -e "${GREEN}🎉 HOÀN TẤT CLONE DATABASE MONGODB${RESET}"
  echo "Database nguồn: $SOURCE_DB"
  echo "Database mới: $TARGET_DB"
  
  if [[ "$CREATE_USER" == true ]]; then
    echo ""
    echo -e "${CYAN}📝 Connection String:${RESET}"
    echo "mongodb://${NEW_USER}:${NEW_PASS}@localhost:27017/${TARGET_DB}?authSource=${TARGET_DB}"
  fi
}

########################################
# MONGODB: BACKUP DATABASE
########################################

mongo_backup_database() {
  echo -e "${BLUE}=== BACKUP MONGODB DATABASE ===${RESET}"
  
  check_mongodb || return
  get_mongo_admin_password
  
  if ! test_mongo_connection; then
    echo -e "${RED}❌ Không thể kết nối MongoDB với user admin. Kiểm tra lại password.${RESET}"
    return
  fi
  
  local BACKUP_DIR="/opt/mongo_backups"
  mkdir -p "$BACKUP_DIR"
  
  local MONGO_CMD="mongosh"
  if ! command -v mongosh >/dev/null 2>&1; then
    MONGO_CMD="mongo"
  fi
  
  # Hiển thị danh sách databases
  echo -e "${YELLOW}Danh sách database hiện có:${RESET}"
  $MONGO_CMD "mongodb://${MONGO_ADMIN_USER}:${MONGO_ADMIN_PASS}@localhost:27017/admin?authSource=admin" --quiet --eval "db.adminCommand('listDatabases').databases.forEach(function(d) { if (d.name != 'admin' && d.name != 'config' && d.name != 'local') print('  - ' + d.name) })" 2>/dev/null
  echo ""
  
  read -rp "👉 Nhập tên database cần backup (bỏ trống = backup tất cả): " MONGO_DB
  
  local TIMESTAMP=$(date +%Y%m%d_%H%M%S)
  
  if [[ -n "$MONGO_DB" ]]; then
    local BACKUP_PATH="${BACKUP_DIR}/${MONGO_DB}_${TIMESTAMP}"
    echo -e "${BLUE}→ Đang backup database ${MONGO_DB}...${RESET}"
    
    mongodump --uri="mongodb://${MONGO_ADMIN_USER}:${MONGO_ADMIN_PASS}@localhost:27017/${MONGO_DB}?authSource=admin" --out="$BACKUP_PATH"
    
    if [ $? -eq 0 ]; then
      echo -e "${GREEN}✔ Backup thành công${RESET}"
      log "Backup MongoDB database ${MONGO_DB} to ${BACKUP_PATH}"
      
      # Nén backup
      echo -e "${BLUE}→ Đang nén backup...${RESET}"
      cd "$BACKUP_DIR"
      tar -czf "${MONGO_DB}_${TIMESTAMP}.tar.gz" "$(basename "$BACKUP_PATH")"
      rm -rf "$BACKUP_PATH"
      
      echo -e "${GREEN}✔ Đã nén backup${RESET}"
      echo -e "${GREEN}📦 File backup: ${BACKUP_DIR}/${MONGO_DB}_${TIMESTAMP}.tar.gz${RESET}"
    else
      echo -e "${RED}❌ Backup thất bại${RESET}"
    fi
  else
    local BACKUP_PATH="${BACKUP_DIR}/all_dbs_${TIMESTAMP}"
    echo -e "${BLUE}→ Đang backup tất cả databases...${RESET}"
    
    mongodump --uri="mongodb://${MONGO_ADMIN_USER}:${MONGO_ADMIN_PASS}@localhost:27017/?authSource=admin" --out="$BACKUP_PATH"
    
    if [ $? -eq 0 ]; then
      echo -e "${GREEN}✔ Backup thành công${RESET}"
      log "Backup all MongoDB databases to ${BACKUP_PATH}"
      
      # Nén backup
      echo -e "${BLUE}→ Đang nén backup...${RESET}"
      cd "$BACKUP_DIR"
      tar -czf "all_dbs_${TIMESTAMP}.tar.gz" "$(basename "$BACKUP_PATH")"
      rm -rf "$BACKUP_PATH"
      
      echo -e "${GREEN}✔ Đã nén backup${RESET}"
      echo -e "${GREEN}📦 File backup: ${BACKUP_DIR}/all_dbs_${TIMESTAMP}.tar.gz${RESET}"
    else
      echo -e "${RED}❌ Backup thất bại${RESET}"
    fi
  fi
}

########################################
# MONGODB: EXPORT DATABASE
########################################

mongo_export_database() {
  echo -e "${BLUE}=== EXPORT MONGODB DATABASE ===${RESET}"
  
  check_mongodb || return
  get_mongo_admin_password
  
  if ! test_mongo_connection; then
    echo -e "${RED}❌ Không thể kết nối MongoDB với user admin. Kiểm tra lại password.${RESET}"
    return
  fi
  
  local EXPORT_DIR="/opt/mongo_exports"
  mkdir -p "$EXPORT_DIR"
  
  local MONGO_CMD="mongosh"
  if ! command -v mongosh >/dev/null 2>&1; then
    MONGO_CMD="mongo"
  fi
  
  # Hiển thị danh sách databases
  echo -e "${YELLOW}Danh sách database hiện có:${RESET}"
  $MONGO_CMD "mongodb://${MONGO_ADMIN_USER}:${MONGO_ADMIN_PASS}@localhost:27017/admin?authSource=admin" --quiet --eval "db.adminCommand('listDatabases').databases.forEach(function(d) { if (d.name != 'admin' && d.name != 'config' && d.name != 'local') print('  - ' + d.name + ' (' + (d.sizeOnDisk / 1024 / 1024).toFixed(2) + ' MB)') })" 2>/dev/null
  echo ""
  
  read -rp "👉 Nhập tên database cần export: " MONGO_DB
  
  if [[ -z "$MONGO_DB" ]]; then
    echo -e "${RED}❌ Tên database không được để trống.${RESET}"
    return
  fi
  
  local TIMESTAMP=$(date +%Y%m%d_%H%M%S)
  local DUMP_DIR="/tmp/mongo_export_$$"
  local EXPORT_FILE="${EXPORT_DIR}/${MONGO_DB}_${TIMESTAMP}.tar.gz"
  
  mkdir -p "$DUMP_DIR"
  
  echo -e "${BLUE}[1/2] Đang dump database ${MONGO_DB}...${RESET}"
  
  if mongodump --uri="mongodb://${MONGO_ADMIN_USER}:${MONGO_ADMIN_PASS}@localhost:27017/${MONGO_DB}?authSource=admin" --out="$DUMP_DIR" --quiet; then
    echo -e "${GREEN}✔ Dump thành công${RESET}"
  else
    echo -e "${RED}❌ Dump database thất bại${RESET}"
    rm -rf "$DUMP_DIR"
    return
  fi
  
  echo -e "${BLUE}[2/2] Đang nén file export...${RESET}"
  cd "$DUMP_DIR"
  tar -czf "$EXPORT_FILE" "$MONGO_DB"
  rm -rf "$DUMP_DIR"
  
  local FILE_SIZE
  FILE_SIZE=$(du -h "$EXPORT_FILE" | cut -f1)
  
  log "Export MongoDB database ${MONGO_DB} to ${EXPORT_FILE}"
  
  echo ""
  echo -e "${GREEN}🎉 HOÀN TẤT EXPORT${RESET}"
  echo -e "📦 File : ${CYAN}${EXPORT_FILE}${RESET}"
  echo -e "📏 Size : ${FILE_SIZE}"
  echo ""
  echo -e "${CYAN}💡 Để tải về máy local dùng:${RESET}"
  echo "   scp root@<server_ip>:${EXPORT_FILE} ."
}

########################################
# MONGODB: IMPORT DATABASE
########################################

mongo_import_database() {
  echo -e "${BLUE}=== IMPORT MONGODB DATABASE ===${RESET}"
  
  check_mongodb || return
  get_mongo_admin_password
  
  if ! test_mongo_connection; then
    echo -e "${RED}❌ Không thể kết nối MongoDB với user admin. Kiểm tra lại password.${RESET}"
    return
  fi
  
  local MONGO_CMD="mongosh"
  if ! command -v mongosh >/dev/null 2>&1; then
    MONGO_CMD="mongo"
  fi
  
  # Liệt kê các file export có sẵn
  local EXPORT_DIR="/opt/mongo_exports"
  if [[ -d "$EXPORT_DIR" ]] && ls "${EXPORT_DIR}"/*.tar.gz 2>/dev/null | head -1 > /dev/null 2>&1; then
    echo -e "${YELLOW}Các file export có sẵn trong ${EXPORT_DIR}:${RESET}"
    ls -lh "${EXPORT_DIR}"/*.tar.gz 2>/dev/null | awk '{print "  " $NF " (" $5 ")"}'
    echo ""
  fi
  
  read -rp "👉 Nhập đường dẫn đầy đủ file import (.tar.gz): " IMPORT_FILE
  
  if [[ -z "$IMPORT_FILE" ]]; then
    echo -e "${RED}❌ Đường dẫn file không được để trống.${RESET}"
    return
  fi
  
  if [[ ! -f "$IMPORT_FILE" ]]; then
    echo -e "${RED}❌ File '${IMPORT_FILE}' không tồn tại.${RESET}"
    return
  fi
  
  # Hiển thị databases hiện có
  echo ""
  echo -e "${YELLOW}Danh sách database hiện có:${RESET}"
  $MONGO_CMD "mongodb://${MONGO_ADMIN_USER}:${MONGO_ADMIN_PASS}@localhost:27017/admin?authSource=admin" --quiet --eval "db.adminCommand('listDatabases').databases.forEach(function(d) { if (d.name != 'admin' && d.name != 'config' && d.name != 'local') print('  - ' + d.name) })" 2>/dev/null
  echo ""
  
  read -rp "👉 Nhập tên database đích (sẽ tạo mới nếu chưa có): " TARGET_DB
  
  if [[ -z "$TARGET_DB" ]]; then
    echo -e "${RED}❌ Tên database không được để trống.${RESET}"
    return
  fi
  
  # Kiểm tra database đã tồn tại
  local DB_EXISTS
  DB_EXISTS=$($MONGO_CMD "mongodb://${MONGO_ADMIN_USER}:${MONGO_ADMIN_PASS}@localhost:27017/admin?authSource=admin" --quiet --eval "db.adminCommand('listDatabases').databases.filter(function(d) { return d.name == '${TARGET_DB}' }).length" 2>/dev/null)
  
  local DROP_FIRST=false
  if [[ "$DB_EXISTS" == "1" ]]; then
    echo -e "${YELLOW}⚠ Database '${TARGET_DB}' đã tồn tại.${RESET}"
    echo "1) Xóa database cũ trước rồi import"
    echo "2) Import ghi đè (merge) vào database hiện có"
    echo "3) Hủy"
    read -rp "👉 Chọn (1-3): " OVERWRITE_CHOICE
    
    case "$OVERWRITE_CHOICE" in
      1) DROP_FIRST=true ;;
      2) ;;
      3|*) echo -e "${RED}❌ Hủy thao tác${RESET}"; return ;;
    esac
  fi
  
  # Hỏi tạo user
  echo ""
  echo -e "${YELLOW}=== TẠO USER CHO DATABASE ===${RESET}"
  echo "1) Tạo user mới"
  echo "2) Không tạo user"
  read -rp "👉 Chọn (1-2): " USER_CHOICE
  
  local CREATE_USER=false
  local NEW_USER=""
  local NEW_PASS=""
  
  if [[ "$USER_CHOICE" == "1" ]]; then
    read -rp "👉 Nhập tên user mới: " NEW_USER
    read -rsp "👉 Nhập password: " NEW_PASS
    echo ""
    CREATE_USER=true
  fi
  
  echo ""
  local FILE_SIZE
  FILE_SIZE=$(du -h "$IMPORT_FILE" | cut -f1)
  echo -e "${YELLOW}Chuẩn bị import:${RESET}"
  echo "  File     : $IMPORT_FILE ($FILE_SIZE)"
  echo "  Database : $TARGET_DB"
  [[ "$DROP_FIRST" == true ]] && echo -e "  ${RED}⚠ Database cũ sẽ bị xóa trước!${RESET}"
  [[ "$CREATE_USER" == true ]] && echo "  User mới : $NEW_USER"
  read -rp "👉 Xác nhận import? (y/n): " CONFIRM
  [[ "$CONFIRM" == "y" ]] || { echo -e "${RED}❌ Hủy thao tác${RESET}"; return; }
  
  # Drop database cũ nếu cần
  if [[ "$DROP_FIRST" == true ]]; then
    echo -e "${BLUE}→ Xóa database cũ...${RESET}"
    $MONGO_CMD "mongodb://${MONGO_ADMIN_USER}:${MONGO_ADMIN_PASS}@localhost:27017/admin?authSource=admin" --quiet --eval "use ${TARGET_DB}; db.dropDatabase()" 2>/dev/null
    echo -e "${GREEN}✔ Đã xóa database cũ${RESET}"
  fi
  
  # Giải nén file
  echo -e "${BLUE}[1/2] Đang giải nén file import...${RESET}"
  local TEMP_DIR="/tmp/mongo_import_$$"
  mkdir -p "$TEMP_DIR"
  tar -xzf "$IMPORT_FILE" -C "$TEMP_DIR"
  
  # Tìm thư mục data (tên database gốc)
  local SOURCE_DIR
  SOURCE_DIR=$(ls -d "$TEMP_DIR"/*/ 2>/dev/null | head -1)
  
  if [[ -z "$SOURCE_DIR" ]]; then
    echo -e "${RED}❌ Không tìm thấy dữ liệu trong file import.${RESET}"
    rm -rf "$TEMP_DIR"
    return
  fi
  
  local SOURCE_DB_NAME
  SOURCE_DB_NAME=$(basename "$SOURCE_DIR")
  
  echo -e "${BLUE}[2/2] Đang restore vào database ${TARGET_DB}...${RESET}"
  
  if mongorestore --uri="mongodb://${MONGO_ADMIN_USER}:${MONGO_ADMIN_PASS}@localhost:27017/${TARGET_DB}?authSource=admin" --nsFrom="${SOURCE_DB_NAME}.*" --nsTo="${TARGET_DB}.*" "$SOURCE_DIR" --quiet --drop; then
    echo -e "${GREEN}✔ Import thành công${RESET}"
    log "Import MongoDB database from ${IMPORT_FILE} to ${TARGET_DB}"
  else
    echo -e "${YELLOW}⚠ Import hoàn tất (có thể có warning)${RESET}"
    log "Import MongoDB database from ${IMPORT_FILE} to ${TARGET_DB} (with warnings)"
  fi
  
  # Xóa thư mục tạm
  rm -rf "$TEMP_DIR"
  
  # Tạo user nếu cần
  if [[ "$CREATE_USER" == true ]]; then
    echo -e "${BLUE}→ Tạo user mới...${RESET}"
    
    $MONGO_CMD "mongodb://${MONGO_ADMIN_USER}:${MONGO_ADMIN_PASS}@localhost:27017/admin?authSource=admin" --quiet <<EOF
use ${TARGET_DB}
db.createUser({
  user: "${NEW_USER}",
  pwd: "${NEW_PASS}",
  roles: [
    { role: "dbOwner", db: "${TARGET_DB}" }
  ]
})
EOF
    
    if [ $? -eq 0 ]; then
      echo -e "${GREEN}✔ Đã tạo user${RESET}"
    else
      echo -e "${YELLOW}⚠ Tạo user thất bại nhưng dữ liệu đã được import${RESET}"
    fi
  fi
  
  echo ""
  echo -e "${GREEN}🎉 HOÀN TẤT IMPORT DATABASE MONGODB${RESET}"
  echo "Database : $TARGET_DB"
  
  if [[ "$CREATE_USER" == true ]]; then
    echo ""
    echo -e "${CYAN}📝 Connection String:${RESET}"
    echo "mongodb://${NEW_USER}:${NEW_PASS}@localhost:27017/${TARGET_DB}?authSource=${TARGET_DB}"
  fi
}

########################################
# CHỨC NĂNG: EXPORT DATABASE (PostgreSQL)
########################################

pg_export_database() {
  echo -e "${BLUE}=== EXPORT DATABASE PostgreSQL ===${RESET}"

  local EXPORT_DIR="/opt/pg_exports"
  mkdir -p "$EXPORT_DIR"

  # Hiển thị danh sách databases
  echo -e "${YELLOW}Danh sách database hiện có:${RESET}"
  sudo -u "$SYSTEM_PG_USER" psql \
    -P pager=off -P "format=aligned" -P "border=2" \
    -c "
      SELECT
        d.datname AS database,
        pg_catalog.pg_get_userbyid(d.datdba) AS owner,
        pg_size_pretty(pg_database_size(d.datname)) AS size
      FROM pg_database d
      WHERE d.datistemplate = false
      ORDER BY d.datname;
    "
  echo ""

  read -rp "👉 Nhập tên database cần export: " PG_DB

  if [[ -z "$PG_DB" ]]; then
    echo -e "${RED}❌ Tên database không được để trống.${RESET}"
    return
  fi

  # Kiểm tra database có tồn tại
  local DB_EXISTS
  DB_EXISTS=$(sudo -u "$SYSTEM_PG_USER" psql -tAc "SELECT 1 FROM pg_database WHERE datname='${PG_DB}'" || true)
  if [[ -z "$DB_EXISTS" ]]; then
    echo -e "${RED}❌ Database '${PG_DB}' không tồn tại.${RESET}"
    return
  fi

  # Hỏi format export
  echo ""
  echo -e "${YELLOW}Chọn format export:${RESET}"
  echo "1) SQL text (nén .sql.gz) — dễ đọc, tương thích cao"
  echo "2) Custom format (.dump) — nhỏ hơn, hỗ trợ restore chọn lọc"
  read -rp "👉 Chọn (1-2, mặc định 1): " FORMAT_CHOICE
  FORMAT_CHOICE=${FORMAT_CHOICE:-1}

  local TIMESTAMP=$(date +%Y%m%d_%H%M%S)
  local EXPORT_FILE

  echo -e "${BLUE}→ Đang export database ${PG_DB}...${RESET}"

  case "$FORMAT_CHOICE" in
    2)
      EXPORT_FILE="${EXPORT_DIR}/${PG_DB}_${TIMESTAMP}.dump"
      if sudo -u "$SYSTEM_PG_USER" pg_dump -Fc "$PG_DB" -f "$EXPORT_FILE"; then
        echo -e "${GREEN}✔ Export thành công (custom format)${RESET}"
        log "Export PostgreSQL database ${PG_DB} to ${EXPORT_FILE}"
      else
        echo -e "${RED}❌ Export thất bại${RESET}"
        return
      fi
      ;;
    *)
      EXPORT_FILE="${EXPORT_DIR}/${PG_DB}_${TIMESTAMP}.sql.gz"
      if sudo -u "$SYSTEM_PG_USER" pg_dump "$PG_DB" | gzip > "$EXPORT_FILE"; then
        echo -e "${GREEN}✔ Export thành công (SQL text nén)${RESET}"
        log "Export PostgreSQL database ${PG_DB} to ${EXPORT_FILE}"
      else
        echo -e "${RED}❌ Export thất bại${RESET}"
        rm -f "$EXPORT_FILE"
        return
      fi
      ;;
  esac

  local FILE_SIZE
  FILE_SIZE=$(du -h "$EXPORT_FILE" | cut -f1)

  echo ""
  echo -e "${GREEN}🎉 HOÀN TẤT EXPORT${RESET}"
  echo -e "📦 File : ${CYAN}${EXPORT_FILE}${RESET}"
  echo -e "📏 Size : ${FILE_SIZE}"
  echo ""
  echo -e "${CYAN}💡 Để tải về máy local dùng:${RESET}"
  echo "   scp root@<server_ip>:${EXPORT_FILE} ."
}

########################################
# CHỨC NĂNG: IMPORT DATABASE (PostgreSQL)
########################################

pg_import_database() {
  echo -e "${BLUE}=== IMPORT DATABASE PostgreSQL ===${RESET}"

  # Liệt kê các file export có sẵn
  local EXPORT_DIR="/opt/pg_exports"
  if [[ -d "$EXPORT_DIR" ]] && ls "${EXPORT_DIR}"/*.sql.gz "${EXPORT_DIR}"/*.dump 2>/dev/null | head -1 > /dev/null 2>&1; then
    echo -e "${YELLOW}Các file export có sẵn trong ${EXPORT_DIR}:${RESET}"
    ls -lh "${EXPORT_DIR}"/*.sql.gz "${EXPORT_DIR}"/*.dump 2>/dev/null | awk '{print "  " $NF " (" $5 ")"}'
    echo ""
  fi

  read -rp "👉 Nhập đường dẫn đầy đủ file import (.sql.gz hoặc .dump): " IMPORT_FILE

  if [[ -z "$IMPORT_FILE" ]]; then
    echo -e "${RED}❌ Đường dẫn file không được để trống.${RESET}"
    return
  fi

  if [[ ! -f "$IMPORT_FILE" ]]; then
    echo -e "${RED}❌ File '${IMPORT_FILE}' không tồn tại.${RESET}"
    return
  fi

  # Hiển thị danh sách databases hiện có
  echo ""
  echo -e "${YELLOW}Danh sách database hiện có:${RESET}"
  sudo -u "$SYSTEM_PG_USER" psql -tAc "
    SELECT datname FROM pg_database
    WHERE datistemplate = false
    ORDER BY datname;
  " | while read -r db; do
    echo "  - $db"
  done
  echo ""

  echo -e "${YELLOW}=== CHỌN DATABASE ĐÍCH ===${RESET}"
  echo "1) Import vào database đã tồn tại (sẽ xóa toàn bộ dữ liệu cũ trước)"
  echo "2) Tạo database mới rồi import"
  read -rp "👉 Chọn (1-2): " DB_CHOICE

  local TARGET_DB
  local TARGET_USER

  case "$DB_CHOICE" in
    1)
      read -rp "👉 Nhập tên database đích: " TARGET_DB
      if [[ -z "$TARGET_DB" ]]; then
        echo -e "${RED}❌ Tên database không được để trống.${RESET}"
        return
      fi

      local DB_EXISTS
      DB_EXISTS=$(sudo -u "$SYSTEM_PG_USER" psql -tAc "SELECT 1 FROM pg_database WHERE datname='${TARGET_DB}'" || true)
      if [[ -z "$DB_EXISTS" ]]; then
        echo -e "${RED}❌ Database '${TARGET_DB}' không tồn tại.${RESET}"
        return
      fi

      TARGET_USER=$(sudo -u "$SYSTEM_PG_USER" psql -tAc "SELECT pg_catalog.pg_get_userbyid(datdba) FROM pg_database WHERE datname='${TARGET_DB}'" | xargs)
      ;;
    2)
      read -rp "👉 Nhập tên database mới: " TARGET_DB
      if [[ -z "$TARGET_DB" ]]; then
        echo -e "${RED}❌ Tên database không được để trống.${RESET}"
        return
      fi

      local DB_EXISTS
      DB_EXISTS=$(sudo -u "$SYSTEM_PG_USER" psql -tAc "SELECT 1 FROM pg_database WHERE datname='${TARGET_DB}'" || true)
      if [[ -n "$DB_EXISTS" ]]; then
        echo -e "${RED}❌ Database '${TARGET_DB}' đã tồn tại. Vui lòng chọn tên khác.${RESET}"
        return
      fi

      echo -e "${YELLOW}Chọn owner cho database mới:${RESET}"
      sudo -u "$SYSTEM_PG_USER" psql -tAc "SELECT rolname FROM pg_roles WHERE rolcanlogin = true ORDER BY rolname;" | while read -r user; do
        echo "  - $user"
      done
      read -rp "👉 Nhập tên owner (bỏ trống = postgres): " TARGET_USER
      TARGET_USER=${TARGET_USER:-$SYSTEM_PG_USER}

      echo -e "${BLUE}→ Đang tạo database ${TARGET_DB} (owner: ${TARGET_USER})...${RESET}"
      sudo -u "$SYSTEM_PG_USER" psql -c "CREATE DATABASE ${TARGET_DB} OWNER ${TARGET_USER};"
      echo -e "${GREEN}✔ Đã tạo database${RESET}"
      ;;
    *)
      echo -e "${RED}❌ Lựa chọn không hợp lệ${RESET}"
      return
      ;;
  esac

  echo ""
  local FILE_SIZE
  FILE_SIZE=$(du -h "$IMPORT_FILE" | cut -f1)
  echo -e "${YELLOW}Chuẩn bị import:${RESET}"
  echo "  File     : $IMPORT_FILE ($FILE_SIZE)"
  echo "  Database : $TARGET_DB"
  if [[ "$DB_CHOICE" == "1" ]]; then
    echo -e "  ${RED}⚠ Dữ liệu cũ trong database sẽ bị ghi đè!${RESET}"
  fi
  read -rp "👉 Xác nhận import? (y/n): " CONFIRM
  [[ "$CONFIRM" == "y" ]] || { echo -e "${RED}❌ Hủy thao tác${RESET}"; return; }

  # Ngắt kết nối tới database đích
  echo -e "${BLUE}[1/2] Ngắt kết nối tới database...${RESET}"
  sudo -u "$SYSTEM_PG_USER" psql -c "
    SELECT pg_terminate_backend(pid)
    FROM pg_stat_activity
    WHERE datname='${TARGET_DB}' AND pid <> pg_backend_pid();
  " > /dev/null 2>&1 || true

  echo -e "${BLUE}[2/2] Đang import dữ liệu...${RESET}"

  # Xác định loại file và import
  if [[ "$IMPORT_FILE" == *.dump ]]; then
    # Custom format — dùng pg_restore
    if sudo -u "$SYSTEM_PG_USER" pg_restore --clean --if-exists -d "$TARGET_DB" "$IMPORT_FILE" 2>&1; then
      echo -e "${GREEN}✔ Import thành công (custom format)${RESET}"
      log "Import PostgreSQL database from ${IMPORT_FILE} to ${TARGET_DB}"
    else
      echo -e "${YELLOW}⚠ Import hoàn tất (có thể có warning nhưng dữ liệu đã được import)${RESET}"
      log "Import PostgreSQL database from ${IMPORT_FILE} to ${TARGET_DB} (with warnings)"
    fi
  elif [[ "$IMPORT_FILE" == *.sql.gz ]]; then
    # SQL text nén — giải nén + pipe vào psql
    if gunzip -c "$IMPORT_FILE" | sudo -u "$SYSTEM_PG_USER" psql -d "$TARGET_DB" > /dev/null 2>&1; then
      echo -e "${GREEN}✔ Import thành công (SQL text)${RESET}"
      log "Import PostgreSQL database from ${IMPORT_FILE} to ${TARGET_DB}"
    else
      echo -e "${YELLOW}⚠ Import hoàn tất (có thể có warning nhưng dữ liệu đã được import)${RESET}"
      log "Import PostgreSQL database from ${IMPORT_FILE} to ${TARGET_DB} (with warnings)"
    fi
  elif [[ "$IMPORT_FILE" == *.sql ]]; then
    # SQL text không nén
    if sudo -u "$SYSTEM_PG_USER" psql -d "$TARGET_DB" -f "$IMPORT_FILE" > /dev/null 2>&1; then
      echo -e "${GREEN}✔ Import thành công (SQL text)${RESET}"
      log "Import PostgreSQL database from ${IMPORT_FILE} to ${TARGET_DB}"
    else
      echo -e "${YELLOW}⚠ Import hoàn tất (có thể có warning nhưng dữ liệu đã được import)${RESET}"
      log "Import PostgreSQL database from ${IMPORT_FILE} to ${TARGET_DB} (with warnings)"
    fi
  else
    echo -e "${RED}❌ Không nhận diện được format file. Hỗ trợ: .sql.gz, .dump, .sql${RESET}"
    return
  fi

  # Cấp lại quyền nếu có owner
  if [[ -n "${TARGET_USER:-}" && "$TARGET_USER" != "$SYSTEM_PG_USER" ]]; then
    echo -e "${BLUE}→ Cấp lại quyền cho user ${TARGET_USER}...${RESET}"
    sudo -u "$SYSTEM_PG_USER" psql -c "GRANT ALL PRIVILEGES ON DATABASE ${TARGET_DB} TO ${TARGET_USER};" 2>/dev/null || true
    sudo -u "$SYSTEM_PG_USER" psql -d "$TARGET_DB" -c "GRANT ALL ON SCHEMA public TO ${TARGET_USER};" 2>/dev/null || true
    sudo -u "$SYSTEM_PG_USER" psql -d "$TARGET_DB" -c "GRANT ALL ON ALL TABLES IN SCHEMA public TO ${TARGET_USER};" 2>/dev/null || true
    sudo -u "$SYSTEM_PG_USER" psql -d "$TARGET_DB" -c "GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO ${TARGET_USER};" 2>/dev/null || true
    echo -e "${GREEN}✔ Đã cấp lại quyền${RESET}"
  fi

  echo ""
  echo -e "${GREEN}🎉 HOÀN TẤT IMPORT DATABASE${RESET}"
  echo "Database : $TARGET_DB"

  # Hiển thị thông tin database sau import
  sudo -u "$SYSTEM_PG_USER" psql -c "
    SELECT
      datname AS database,
      pg_catalog.pg_get_userbyid(datdba) AS owner,
      pg_size_pretty(pg_database_size(datname)) AS size
    FROM pg_database
    WHERE datname='${TARGET_DB}';
  "
}

########################################
# BACKUP → B2 (gọi pg_backup_b2.sh)
########################################

backup_to_b2_menu() {
  echo -e "${BLUE}=== BACKUP PostgreSQL → B2 (rclone) ===${RESET}"

  if ! command -v rclone >/dev/null 2>&1; then
    echo -e "${RED}❌ Chưa cài rclone. Cài: apt install rclone${RESET}"
    return
  fi

  if [[ ! -x /usr/local/bin/pg_backup_b2.sh ]]; then
    echo -e "${RED}❌ Không tìm thấy /usr/local/bin/pg_backup_b2.sh hoặc chưa chmod +x.${RESET}"
    echo "   Đảm bảo đã cài bằng install.sh mới."
    return
  fi

  read -rp "👉 Nhập tên DB (bỏ trống = backup tất cả DB non-template): " DB_NAME

  if [[ -n "$DB_NAME" ]]; then
    /usr/local/bin/pg_backup_b2.sh "$DB_NAME"
  else
    /usr/local/bin/pg_backup_b2.sh
  fi

  echo -e "${GREEN}✔ Backup + sync B2 hoàn tất.${RESET}"
  echo -e "  ➜ Local: /opt/pg_backups"
  echo -e "  ➜ Log  : /var/log/pg_backup_b2_rclone.log"
}

########################################
# CẤU HÌNH RCLONE_REMOTE
########################################

setup_rclone_remote() {
  echo -e "${BLUE}=== CẤU HÌNH RCLONE_REMOTE (B2) ===${RESET}"
  echo "File cấu hình: /etc/vhm-backup.conf"

  if ! command -v rclone >/dev/null 2>&1; then
    echo -e "${RED}❌ Chưa cài rclone. Cài: apt install rclone${RESET}"
    return
  fi

  while true; do
    read -rp "👉 Nhập remote + path B2 (ví dụ: b2backup:postgres-backup): " NEW_REMOTE

    if [[ -z "$NEW_REMOTE" ]]; then
      echo -e "${RED}❌ RCLONE_REMOTE không được để trống.${RESET}"
      continue
    fi

    echo -e "${BLUE}→ Đang kiểm tra remote: ${NEW_REMOTE}${RESET}"
    echo "   (test: rclone ls \"${NEW_REMOTE}\" --max-depth 1 --max-size 1b)"

    if rclone ls "${NEW_REMOTE}" --max-depth 1 --max-size 1b >/dev/null 2>&1; then
      echo -e "${GREEN}✔ Remote hợp lệ, truy cập được.${RESET}"
      echo "RCLONE_REMOTE=\"${NEW_REMOTE}\"" | sudo tee /etc/vhm-backup.conf >/dev/null

      echo -e "${GREEN}✔ Đã lưu cấu hình vào /etc/vhm-backup.conf${RESET}"
      echo -e "${GREEN}✔ pg_backup_b2.sh sẽ dùng remote này${RESET}"
      echo ""
      echo "Nội dung /etc/vhm-backup.conf:"
      cat /etc/vhm-backup.conf
      break
    else
      echo -e "${RED}❌ Remote không truy cập được.${RESET}"
      echo "   Kiểm tra:"
      echo "   - 'rclone config' đã tạo remote chưa"
      echo "   - Tên remote/bucket/path có đúng không"
      read -rp "👉 Nhập lại remote? (y/n): " AGAIN
      if [[ "$AGAIN" != "y" ]]; then
        echo -e "${YELLOW}⚠ Giữ nguyên cấu hình cũ (nếu có).${RESET}"
        break
      fi
    fi
  done
}

check_current_remote() {
  echo -e "${BLUE}=== KIỂM TRA RCLONE_REMOTE HIỆN TẠI ===${RESET}"

  if ! command -v rclone >/dev/null 2>&1; then
    echo -e "${RED}❌ Chưa cài rclone. Cài: apt install rclone${RESET}"
    return
  fi

  if [[ ! -f /etc/vhm-backup.conf ]]; then
    echo -e "${YELLOW}⚠ Chưa có /etc/vhm-backup.conf.${RESET}"
    echo "   Vào menu 'Cấu hình RCLONE_REMOTE' để thiết lập."
    return
  fi

  # shellcheck disable=SC1091
  source /etc/vhm-backup.conf

  if [[ -z "${RCLONE_REMOTE:-}" ]]; then
    echo -e "${RED}❌ RCLONE_REMOTE trong /etc/vhm-backup.conf đang trống.${RESET}"
    return
  fi

  echo "RCLONE_REMOTE hiện tại: ${RCLONE_REMOTE}"
  echo -e "${BLUE}→ Test truy cập remote...${RESET}"

  if rclone ls "${RCLONE_REMOTE}" --max-depth 1 --max-size 1b >/dev/null 2>&1; then
    echo -e "${GREEN}✔ Remote truy cập được.${RESET}"
    echo -e "${BLUE}→ Dung lượng remote (rclone size)...${RESET}"
    rclone size "${RCLONE_REMOTE}" || true
  else
    echo -e "${RED}❌ Remote không truy cập được.${RESET}"
    echo "   Kiểm tra rclone config."
  fi
}

########################################
# CRON BACKUP
########################################

setup_backup_cron() {
  echo -e "${BLUE}=== THIẾT LẬP CRON BACKUP TỰ ĐỘNG → B2 ===${RESET}"
  echo "Cron chạy dưới user root."

  if [[ ! -x /usr/local/bin/pg_backup_b2.sh ]]; then
    echo -e "${RED}❌ Không tìm thấy /usr/local/bin/pg_backup_b2.sh hoặc chưa chmod +x.${RESET}"
    return
  fi

  read -rp "👉 Nhập tên DB (bỏ trống = backup tất cả DB non-template): " CRON_DB
  echo ""
  echo "⏰ Thời gian chạy (theo giờ server)"
  read -rp "👉 Giờ (0-23, mặc định 3): " HOUR
  read -rp "👉 Phút (0-59, mặc định 0): " MINUTE

  HOUR=${HOUR:-3}
  MINUTE=${MINUTE:-0}

  if ! [[ "$HOUR" =~ ^[0-9]+$ ]] || ! [[ "$MINUTE" =~ ^[0-9]+$ ]] || [ "$HOUR" -lt 0 ] || [ "$HOUR" -gt 23 ] || [ "$MINUTE" -lt 0 ] || [ "$MINUTE" -gt 59 ]; then
    echo -e "${RED}❌ Giờ/phút không hợp lệ.${RESET}"
    return
  fi

  if [[ -n "$CRON_DB" ]]; then
    CRON_CMD="/usr/local/bin/pg_backup_b2.sh ${CRON_DB} >> /var/log/pg_backup_b2_cron_${CRON_DB}.log 2>&1"
  else
    CRON_CMD="/usr/local/bin/pg_backup_b2.sh >> /var/log/pg_backup_b2_cron_all.log 2>&1"
  fi

  CRON_EXPR="${MINUTE} ${HOUR} * * * ${CRON_CMD}"

  echo ""
  echo -e "${YELLOW}Cron sẽ được thiết lập:${RESET}"
  echo "  ${CRON_EXPR}"
  echo ""
  read -rp "👉 Xác nhận tạo cron này? (y/n): " CONFIRM
  if [[ "$CONFIRM" != "y" ]]; then
    echo -e "${RED}❌ Hủy thiết lập cron.${RESET}"
    return
  fi

  EXISTING_CRON=$(sudo crontab -l 2>/dev/null | sed '/pg_backup_b2.sh/d' || true)

  {
    echo "$EXISTING_CRON"
    echo "$CRON_EXPR"
  } | sudo crontab -

  echo ""
  echo -e "${GREEN}✔ Đã cập nhật cron backup tự động.${RESET}"
  echo "Xem bằng: sudo crontab -l | grep pg_backup_b2.sh"
}

show_backup_cron() {
  echo -e "${BLUE}=== CRON BACKUP HIỆN TẠI (root) ===${RESET}"

  CRON_CONTENT=$(sudo crontab -l 2>/dev/null | grep 'pg_backup_b2.sh' || true)

  if [[ -z "$CRON_CONTENT" ]]; then
    echo -e "${YELLOW}⚠ Chưa có cron nào chứa 'pg_backup_b2.sh' trong crontab root.${RESET}"
  else
    echo "Các dòng cron backup:"
    echo "$CRON_CONTENT"
  fi
}

disable_backup_cron() {
  echo -e "${BLUE}=== TẮT CRON BACKUP TỰ ĐỘNG ===${RESET}"
  echo "Xử lý crontab của user root."

  CURRENT_CRON=$(sudo crontab -l 2>/dev/null || true)

  if [[ -z "$CURRENT_CRON" ]] || ! echo "$CURRENT_CRON" | grep -q 'pg_backup_b2.sh'; then
    echo -e "${YELLOW}⚠ Không có dòng cron nào chứa 'pg_backup_b2.sh'.${RESET}"
    return
  fi

  echo "Các dòng cron backup hiện có:"
  echo "--------------------------------"
  echo "$CURRENT_CRON" | grep 'pg_backup_b2.sh'
  echo "--------------------------------"
  echo
  read -rp "👉 Xác nhận XOÁ TẤT CẢ các dòng cron chứa 'pg_backup_b2.sh'? (y/n): " CONFIRM
  if [[ "$CONFIRM" != "y" ]]; then
    echo -e "${RED}❌ Hủy thao tác tắt cron backup.${RESET}"
    return
  fi

  NEW_CRON=$(echo "$CURRENT_CRON" | sed '/pg_backup_b2.sh/d' || true)

  if [[ -z "$NEW_CRON" ]]; then
    sudo crontab -r
    echo -e "${GREEN}✔ Đã xoá toàn bộ crontab của root (vì chỉ còn cron backup).${RESET}"
  else
    printf "%s\n" "$NEW_CRON" | sudo crontab -
    echo -e "${GREEN}✔ Đã xoá các dòng cron backup, giữ nguyên cron khác.${RESET}"
  fi

  echo "Kiểm tra lại bằng: sudo crontab -l"
}

########################################
# POSTGRESQL MENU
########################################

postgresql_menu() {
  while true; do
    echo ""
    echo -e "${CYAN}===== MENU POSTGRESQL =====${RESET}"
    echo "1) Tạo user + database"
    echo "2) Xoá user + database"
    echo "3) Liệt kê user & database"
    echo "4) Clone database"
    echo "5) 📤 Export database"
    echo "6) 📥 Import database"
    echo "7) Backup DB → B2 (pg_dump + rclone)"
    echo "8) Cấu hình RCLONE_REMOTE (B2)"
    echo "9) Kiểm tra RCLONE_REMOTE hiện tại"
    echo "10) Thiết lập cron backup tự động"
    echo "11) Xem cron backup hiện tại"
    echo "12) Tắt cron backup"
    echo "0) Quay lại menu chính"
    read -rp "👉 Chọn (0-12): " CHOICE

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
        clone_database
        pause
        ;;
      5)
        pg_export_database
        pause
        ;;
      6)
        pg_import_database
        pause
        ;;
      7)
        backup_to_b2_menu
        pause
        ;;
      8)
        setup_rclone_remote
        pause
        ;;
      9)
        check_current_remote
        pause
        ;;
      10)
        setup_backup_cron
        pause
        ;;
      11)
        show_backup_cron
        pause
        ;;
      12)
        disable_backup_cron
        pause
        ;;
      0)
        return
        ;;
      *)
        echo -e "${RED}❌ Lựa chọn không hợp lệ${RESET}"
        ;;
    esac
  done
}

########################################
# MONGODB: XÓA PASSWORD ĐÃ LƯU
########################################

mongo_clear_saved_password() {
  echo -e "${BLUE}=== XÓA PASSWORD ĐÃ LƯU ===${RESET}"
  
  if [[ ! -f "$MONGO_CONFIG_FILE" ]]; then
    echo -e "${YELLOW}⚠ Chưa có password nào được lưu.${RESET}"
    return
  fi
  
  echo -e "${YELLOW}File cấu hình: ${MONGO_CONFIG_FILE}${RESET}"
  read -rp "👉 Xác nhận xóa password đã lưu? (y/n): " CONFIRM
  
  if [[ "$CONFIRM" == "y" ]]; then
    sudo rm -f "$MONGO_CONFIG_FILE"
    echo -e "${GREEN}✔ Đã xóa password đã lưu${RESET}"
    log "Xóa MongoDB password đã lưu"
  else
    echo -e "${RED}❌ Hủy thao tác${RESET}"
  fi
}

########################################
# MONGODB MENU
########################################

mongodb_menu() {
  while true; do
    echo ""
    echo -e "${CYAN}===== MENU MONGODB =====${RESET}"
    echo "1) Tạo user + database"
    echo "2) Xoá user + database"
    echo "3) Liệt kê databases"
    echo "4) Clone database"
    echo "5) Backup database"
    echo "6) 📤 Export database"
    echo "7) 📥 Import database"
    echo "8) Xóa password admin đã lưu"
    echo "0) Quay lại menu chính"
    read -rp "👉 Chọn (0-8): " CHOICE

    case "$CHOICE" in
      1)
        mongo_create_user_and_db
        pause
        ;;
      2)
        mongo_delete_user_and_db
        pause
        ;;
      3)
        mongo_list_dbs
        pause
        ;;
      4)
        mongo_clone_database
        pause
        ;;
      5)
        mongo_backup_database
        pause
        ;;
      6)
        mongo_export_database
        pause
        ;;
      7)
        mongo_import_database
        pause
        ;;
      8)
        mongo_clear_saved_password
        pause
        ;;
      0)
        return
        ;;
      *)
        echo -e "${RED}❌ Lựa chọn không hợp lệ${RESET}"
        ;;
    esac
  done
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
    echo -e "${CYAN}===== MENU CHÍNH VHM =====${RESET}"
    echo "1) 🐘 Quản lý PostgreSQL"
    echo "2) 🍃 Quản lý MongoDB"
    echo "3) 🔄 Cập nhật VHM"
    echo "4) ❌ Thoát"
    read -rp "👉 Chọn (1-4): " CHOICE

    case "$CHOICE" in
      1)
        postgresql_menu
        ;;
      2)
        mongodb_menu
        ;;
      3)
        self_update
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
# ENTRYPOINT — SUBCOMMAND
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
