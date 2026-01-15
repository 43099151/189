#!/bin/bash
set -x # 开启调试模式

# ==========================================
# 🟢【配置区】(变量值将优先读取系统环境变量)
# ==========================================
export PROJECT_NAME="cloud189-auto-save"
export APP_INTERNAL_PORT=3000
export TS_NAME="189"
# 备份路径 (加上 /var/lib/tailscale)
export BACKUP_PATH="/home/data /var/lib/tailscale"
export R2_ACCESS_KEY="75e72cddecc51b32deab13873c967000"
export R2_ENDPOINT="https://6e84f688bfe062834470070a2d946be5.r2.cloudflarestorage.com"
export R2_BUCKET_NAME="hf--backups"

# 环境变量
export PUID=0
export PGID=0
# ==========================================

# --- 0. 变量自检 ---
echo "==> [Check] 检查环境变量..."
if [ -z "$R2_SECRET_KEY" ]; then echo "⚠️ 警告: 未检测到 R2_SECRET_KEY"; else echo "✅ R2_SECRET_KEY 已加载"; fi
if [ -z "$FRPS_IP" ]; then echo "⚠️ 警告: 未检测到 FRPS_IP"; else echo "✅ FRPS_IP 已加载: $FRPS_IP"; fi

# --- 1. 系统优化 ---
echo "==> [System] 优化 DNS..."
if echo "nameserver 8.8.8.8" > /etc/resolv.conf 2>/dev/null; then
    echo "nameserver 1.1.1.1" >> /etc/resolv.conf
fi

# 确保目录存在
mkdir -p /home/data /home/strm /root/.config/rclone/

# --- 2. 配置文件生成 ---

# Rclone
cat > /root/.config/rclone/rclone.conf <<EOF
[r2]
type = s3
provider = Cloudflare
access_key_id = ${R2_ACCESS_KEY}
secret_access_key = ${R2_SECRET_KEY}
endpoint = ${R2_ENDPOINT}
acl = private
EOF

# --- 4. 恢复数据 ---
echo "==> [Restore] 尝试恢复数据..."
if [ -n "$R2_SECRET_KEY" ]; then
    rclone copy "r2:${R2_BUCKET_NAME}/${PROJECT_NAME}_backup" / --verbose || echo "恢复跳过"
fi
chmod -R 777 /home/data /home/strm

# --- 5. 配置 SSH (Root 登录) ---
echo "==> [SSH] 配置 Root 密码..."
if [ -n "$WEBUI_PASSWORD" ]; then
    echo "root:$WEBUI_PASSWORD" | chpasswd
    echo "Root 密码已设置为 WEBUI_PASSWORD"
else
    echo "Root 密码未设置 (使用默认值: admin123)"
    echo "root:admin123" | chpasswd
fi

echo "==> [SSH] 启动 sshd..."
/usr/sbin/sshd -D &

# --- 6. 启动服务 ---

# [新增] 启动端口转发 (7860 -> 3000)
# HF 访问 7860 时，Socat 会将其无缝转发到本地的 3000 (主程序)
echo "==> [Network] 启动 Socat 转发 (7860 -> 3000)..."
socat TCP-LISTEN:7860,fork,bind=0.0.0.0 TCP:127.0.0.1:3000 &

# --- B. 启动 Tailscale (Userspace 模式) ---
echo "==> [Tailscale] 初始化..."

# 检查 path (调试用)
echo "==> [Tailscale] PATH: $PATH"
echo "==> [Tailscale] Version:"
tailscale version

# 创建状态目录 (防止部分环境报错)
mkdir -p /var/lib/tailscale

# 启动后台进程 (tun=userspace-networking 是关键，不需要 root 权限)
# 将日志输出到文件以便调试
/usr/sbin/tailscaled --tun=userspace-networking --socket=/tmp/tailscaled.sock --state=/var/lib/tailscale/tailscaled.state > /tmp/tailscaled.log 2>&1 &

# 等待 socket 文件生成 (最多等待 10 秒)
TRIES=0
while [ ! -S /tmp/tailscaled.sock ] && [ $TRIES -lt 20 ]; do
    sleep 0.5
    TRIES=$((TRIES + 1))
done

if [ ! -S /tmp/tailscaled.sock ]; then
    echo "❌ Tailscale socket 未生成，tailscaled 启动失败！"
    echo "=== Tailscale Logs ==="
    cat /tmp/tailscaled.log
    echo "======================"
else
    echo "✅ Tailscale socket 已就绪 (耗时 $((TRIES * 500))ms)"
fi

# 登录
if [ -n "$TS_AUTH_KEY" ]; then
    # 尝试 Up，如果失败则输出日志
    # 去掉绝对路径，直接使用 tailscale
    if tailscale --socket=/tmp/tailscaled.sock up --authkey="${TS_AUTH_KEY}" --hostname="${TS_NAME}" --ssh --accept-routes --advertise-exit-node; then
        # 获取 Tailscale IP 方便调试
        TS_IP=$(tailscale --socket=/tmp/tailscaled.sock ip -4)
        echo "✅ Tailscale 启动成功! IP: $TS_IP"
        # ======================================================
        (
            sleep 5
            echo "==> [Tailscale] Enabling Funnel for Port 8008..."
            # 将公网 HTTPS (443) 流量转发到本地 8008
            tailscale --socket=/tmp/tailscaled.sock funnel --bg --yes 3000
            echo "✅ Funnel enabled."
        ) &
        # ======================================================
    else
        echo "❌ Tailscale up 失败！"
        echo "=== Tailscale Logs (tailscaled) ==="
        cat /tmp/tailscaled.log
        echo "==================================="
    fi
else
    echo "⚠️ 未检测到 TS_AUTH_KEY，跳过 Tailscale 启动"
fi

# C. 启动定时备份
echo "==> [System] 启动定时备份..."
(
  while true; do
    # 首次启动等待 60 秒后备份一次，确保 State 文件已生成
    sleep 60
    if [ -n "$R2_SECRET_KEY" ]; then
        echo "==> [Backup] 执行同步..."
        for DIR in ${BACKUP_PATH}; do
            [ -d "$DIR" ] && rclone sync "$DIR" "r2:${R2_BUCKET_NAME}/${PROJECT_NAME}_backup$DIR" --verbose 2>/dev/null
        done
    fi
    # 之后每 12 小时循环
    sleep 43200
  done
) &

# --- 6. 启动主程序 ---
echo "==> [System] 定位并启动主程序..."

# 智能查找项目目录
if [ -f "/app/package.json" ]; then
    cd /app
    echo "Workdir set to: /app"
elif [ -f "/home/package.json" ]; then
    cd /home
    echo "Workdir set to: /home"
else
    # 最后的尝试
    TARGET_DIR=$(find / -name "yarn.lock" -type f -print -quit | xargs dirname)
    if [ -n "$TARGET_DIR" ]; then
        cd "$TARGET_DIR"
        echo "Workdir found and set to: $TARGET_DIR"
    else
        echo "❌ 找不到项目目录，停留在根目录"
    fi
fi

# 尝试启动
if [ -f "./docker-entrypoint.sh" ]; then
    echo "Running docker-entrypoint.sh..."
    chmod +x ./docker-entrypoint.sh
    ./docker-entrypoint.sh yarn start || {
        echo "❌ 主程序崩溃 (Script Mode)"
        tail -f /dev/null
    }
else
    echo "Running yarn start..."
    yarn start || {
        echo "❌ 主程序崩溃 (Yarn Mode)"
        tail -f /dev/null
    }

fi
