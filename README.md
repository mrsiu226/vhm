# VHM — PostgreSQL Ultra Management Tool

**VHM** là một công cụ CLI mạnh mẽ giúp quản lý PostgreSQL trên Linux server (Ubuntu/Debian).  
Tích hợp đầy đủ:

- Tạo / xoá user & database
- Phân quyền schema & default privileges
- Bật remote access (pg_hba.conf + listen_addresses)
- Liệt kê user/database
- Backup PostgreSQL → B2 (Backblaze) bằng rclone
- Tự cấu hình RCLONE_REMOTE
- Test remote B2 có hoạt động không
- Thiết lập cron backup tự động
- Tắt / xem cron backup
- Auto-update từ GitHub
- Menu UI đẹp, rõ ràng, nhiều màu sắc

---

## 🚀 Cài đặt VHM

```bash
curl -fsSL https://raw.githubusercontent.com/<USERNAME>/vhm/main/install.sh | sudo bash
```

Sau khi cài:

```bash
vhm
```

---

## 📁 Cấu trúc thư mục

```
vhm/
 ├── README.md
 ├── install.sh
 ├── vhm.sh
 ├── pg_backup_b2.sh
 └── version.txt
```

---

# 🧩 Chức năng chính của VHM

## 1) Tạo User + Database
- Tự kiểm tra user/database có tồn tại chưa
- Tự cấp:
  - GRANT ALL ON DATABASE
  - GRANT ALL ON SCHEMA public
  - Default privileges (table + sequence)
- Test đăng nhập sau khi tạo

---

## 2) Xoá User + Database
- Tự terminate connection đang chạy
- Xoá schema privileges
- Xoá rule trong `pg_hba.conf`

---

## 3) Liệt kê User & Database (UI đẹp)
- Không cần gõ `\q`
- Format aligned + border
- Tắt pager để không bị kẹt trong psql

---

## 4) Backup PostgreSQL → B2
- Backup tất cả DB hoặc 1 DB
- Gzip file
- Tự xoá file cũ theo số ngày giữ (default 7 ngày)
- Tự sync toàn bộ backup lên B2 bằng rclone
- Log lưu tại `/var/log/pg_backup_b2_rclone.log`

---

## 5) Cấu hình RCLONE_REMOTE
- Nhập tên remote dạng:
  ```bash
  b2backup:postgres-backup
  ```
- Tự validate bằng `rclone ls`
- Lưu vào `/etc/vhm-backup.conf`

---

## 6) Kiểm tra remote B2
- Test kết nối
- Hiện dung lượng bucket (`rclone size`)

---

## 7) Thiết lập cron backup tự động
- Hỏi DB cần backup
- Hỏi giờ và phút
- Tự thêm vào crontab root
- Không phá cron hiện có

---

## 8) Tắt cron backup
- Xoá tất cả dòng cron chứa `pg_backup_b2.sh`
- Không đụng cron khác

---

## 🔄 Auto-update

```bash
vhm update
```

VHM sẽ tự kiểm tra `version.txt` trên GitHub và update file `/usr/local/bin/vhm`.

---

# 🧪 Test backup nhanh

```bash
sudo pg_backup_b2.sh mydb
```

Hoặc backup tất cả DB:

```bash
sudo pg_backup_b2.sh
```

---

# ❤️ Open-source

Repo public để chạy auto-install/update.  
Không chứa dữ liệu nhạy cảm.

---
