#!/usr/bin/env bash

REPO="https://raw.githubusercontent.com/luongdai/vhm/main"

echo "Tải VHM Ultra Tool..."
sudo curl -fsSL "$REPO/vhm.sh" -o /usr/local/bin/vhm
sudo chmod +x /usr/local/bin/vhm

echo "Cài đặt thành công!"
echo "Chạy tool bằng lệnh: vhm"
