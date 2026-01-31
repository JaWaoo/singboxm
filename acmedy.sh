#!/usr/bin/env bash
set -e

# ========= 基础检查 =========
[[ $EUID -ne 0 ]] && echo "❌ 请以 root 用户运行" && exit 1

command -v curl >/dev/null || { echo "❌ 未安装 curl"; exit 1; }
command -v socat >/dev/null || { echo "❌ 未安装 socat"; exit 1; }

# ========= 用户输入 =========
read -rp "请输入要申请证书的域名（已解析到本机IP）: " DOMAIN
[[ -z "$DOMAIN" ]] && echo "❌ 域名不能为空" && exit 1

read -rp "请输入注册邮箱（回车自动生成）: " EMAIL
if [[ -z "$EMAIL" ]]; then
  EMAIL="$(date +%s | sha256sum | cut -c1-6)@gmail.com"
fi

CERT_DIR="/root/ygkkkca"
mkdir -p "$CERT_DIR"

echo "✔ 域名: $DOMAIN"
echo "✔ 邮箱: $EMAIL"
echo

# ========= 安装并【完整初始化】 acme.sh =========
if [[ ! -d ~/.acme.sh ]]; then
  echo "▶ 安装 acme.sh ..."
  curl -fsSL https://get.acme.sh | sh
fi

# ========= 显式注册账号（关键修复点） =========
~/.acme.sh/acme.sh --register-account -m "$EMAIL"

# ========= 申请证书（HTTP-01） =========
echo "▶ 开始申请证书（HTTP-01 / 80端口）"
~/.acme.sh/acme.sh --issue \
  -d "$DOMAIN" \
  --standalone \
  -k ec-256 \
  --server letsencrypt
  --force
# ========= 安装证书 =========
echo "▶ 安装证书到 $CERT_DIR"
~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
  --key-file       "$CERT_DIR/private.key" \
  --fullchain-file "$CERT_DIR/cert.crt" \
  --ecc
echo "$DOMAIN" > /root/ygkkkca/ca.log
# ========= 完成 =========
echo
echo "✅ 证书申请完成"
echo "📄 公钥: $CERT_DIR/cert.crt"
echo "🔑 私钥: $CERT_DIR/private.key"
echo
echo "ℹ️ 自动续期已由 acme.sh cron 接管，无需再次运行本脚本"
