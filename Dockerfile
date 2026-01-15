# Cloud189 Auto Save (Nginx保活版)
FROM xia1307/cloud189-auto-save:latest

USER root

# 1. 安装基础工具 + Nginx (用来保活)
# 自动判断系统类型
RUN if [ -f /etc/alpine-release ]; then \
  apk update && \
  apk add --no-cache curl unzip bash ca-certificates procps sed python3 rclone nginx openssh-server; \
  sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config; \
  echo "PermitRootLogin yes" >> /etc/ssh/sshd_config; \
  ssh-keygen -A; \
  mkdir -p /run/nginx /var/lib/nginx /var/log/nginx && \
  chmod -R 777 /var/lib/nginx /var/log/nginx; \
  else \
  apt-get update && \
  apt-get install -y curl unzip bash ca-certificates procps sed python3 rclone nginx openssh-server && \
  mkdir -p /run/sshd; \
  sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config; \
  rm -rf /var/lib/apt/lists/*; \
  mkdir -p /run/nginx /var/lib/nginx /var/log/nginx && \
  chmod -R 777 /var/lib/nginx /var/log/nginx; \
  fi
# 2. 安装 tailscale (使用静态二进制文件，更稳定)
# 提示: 如果需要升级，修改下面的 TS_VERSION 即可
ARG TS_VERSION=1.92.3
ENV TS_ARCH=amd64
RUN curl -fsSL https://pkgs.tailscale.com/stable/tailscale_${TS_VERSION}_${TS_ARCH}.tgz -o tailscale.tgz && \
  tar xzf tailscale.tgz && \
  mv tailscale_${TS_VERSION}_${TS_ARCH}/tailscaled /usr/sbin/tailscaled && \
  mv tailscale_${TS_VERSION}_${TS_ARCH}/tailscale /usr/bin/tailscale && \
  rm -rf tailscale.tgz tailscale_${TS_VERSION}_${TS_ARCH}
# 3. 注入启动脚本
COPY entrypoint.sh /entrypoint.sh
RUN sed -i 's/\r$//' /entrypoint.sh && chmod +x /entrypoint.sh

# 4. 设置入口
ENTRYPOINT ["/entrypoint.sh"]