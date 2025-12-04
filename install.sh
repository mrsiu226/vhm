#!/usr/bin/env bash
set -euo pipefail

# ĐỔI <USERNAME> THÀNH repo thật, ví dụ: luongdai/vhm
REPO_PATH="mrsiu226/vhm"
REPO_BASE="https://raw.githubusercontent.com/${REPO_PATH}/main"

echo "==> Cài đặt VHM Ultra Tool từ ${REPO_BASE}"

if ! command -v curl >/dev/null 2>&1; then
  echo "❌ Cần cài curl (apt install curl -y)"
  exit 1
fi

# Install main CLI
sudo curl -fsSL "${REPO_BASE}/vhm.sh" -o /usr/local/bin/vhm
sudo chmod +x /usr/local/bin/vhm

# Install backup script
sudo curl -fsSL "${REPO_BASE}/pg_backup_b2.sh" -o /usr/local/bin/pg_backup_b2.sh
sudo chmod +x /usr/local/bin/pg_backup_b2.sh

echo ""
echo "✔ VHM đã cài đặt xong!"
echo "Chạy VHM: vhm"
echo "Backup B2: sudo pg_backup_b2.sh"
