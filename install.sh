#!/usr/bin/env bash
set -euo pipefail

# ĐỔI <USERNAME> THÀNH owner/repo của bạn, ví dụ: "luongdai/vhm"
REPO_PATH="mrsiu226/vhm"
REPO_BASE="https://raw.githubusercontent.com/${REPO_PATH}/main"

echo "==> Cài đặt VHM Ultra Tool từ ${REPO_BASE}"

if ! command -v curl >/dev/null 2>&1; then
  echo "❌ Cần cài curl trước (apt install curl -y)."
  exit 1
fi

sudo curl -fsSL "${REPO_BASE}/vhm.sh" -o /usr/local/bin/vhm
sudo chmod +x /usr/local/bin/vhm

echo ""
echo "✅ Cài đặt xong!"
echo "Chạy lệnh:  vhm"
echo "Cập nhật:   vhm update"
