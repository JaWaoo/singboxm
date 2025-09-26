# ==== 自动检测 acme.sh 路径 ====
if [ -x "/root/.acme.sh/acme.sh" ]; then
  ACME_BIN="/root/.acme.sh/acme.sh"
else
  ACME_BIN=""
fi

set_feedback() {
  local code=$1
  local success_msg=$2
  local fail_msg=$3
  if [[ $code -eq 0 ]]; then
    LAST_MSG="$(yellow "✅ $success_msg")"
  else
    LAST_MSG="$(red "❌ $fail_msg")"
  fi
}


LAST_MSG="每天都是快乐开心健康富足的一天！！！~O(∩_∩)O哈哈~"


#!/bin/bash
set -euo pipefail

# ========= Colors =========
red(){ echo -e "\033[31m\033[01m$1\033[0m";}
green(){ echo -e "\033[32m\033[01m$1\033[0m";}
yellow(){ echo -e "\033[33m\033[01m$1\033[0m";}
blue(){ echo -e "\033[36m\033[01m$1\033[0m";}
readp(){ read -p "$(yellow "$1")" "${2:-}";}

# ========= Paths =========
SB_DIR="/etc/s-box"
SB_BIN="$SB_DIR/sing-box"
SB_CFG="$SB_DIR/sb.json"
CERT_DIR="/root/cert"
CERT_CRT=""
CERT_KEY=""

[[ $EUID -ne 0 ]] && { red "请以 root 权限运行此脚本"; exit 1; }

# ========= Helpers =========
ensure_deps(){
  apt-get update -y
  apt-get install -y curl jq openssl tar iptables-persistent socat qrencode xxd
}

install_singbox(){
  mkdir -p "$SB_DIR"
  local latest ver input
  latest="$(curl -fsSL https://data.jsdelivr.com/v1/package/gh/SagerNet/sing-box | grep -Eo '\"[0-9]+\.[0-9]+\.[0-9]+\"' | tr -d '\"' | head -n1)"
  [[ -z "$latest" ]] && { red "获取 sing-box 最新版本失败"; exit 1; }
  yellow "最新版本：$latest"
  readp "输入要安装的 sing-box 版本号（留空则安装最新）：" input
  ver="${input:-$latest}"

  local arch
  case "$(uname -m)" in
    aarch64) arch="arm64";;
    armv7l)  arch="armv7";;
    x86_64)  arch="amd64";;
    *) red "暂不支持架构: $(uname -m)"; exit 1;;
  esac
  local tgz="sing-box-$ver-linux-$arch.tar.gz"
  curl -L -o "$SB_DIR/sing-box.tar.gz" "https://github.com/SagerNet/sing-box/releases/download/v$ver/$tgz" || { red "下载 sing-box 失败，请检查版本号"; exit 1; }
  tar xzf "$SB_DIR/sing-box.tar.gz" -C "$SB_DIR"
  mv "$SB_DIR/sing-box-$ver-linux-$arch/sing-box" "$SB_BIN"
  rm -rf "$SB_DIR/sing-box.tar.gz" "$SB_DIR/sing-box-$ver-linux-$arch"
  chmod +x "$SB_BIN"
  green "Sing-box 已安装: $($SB_BIN version | awk '/version/{print $NF}')"
  LAST_MSG="✅ Sing-box 安装/更新完成"
  set_feedback $? "Sing-box 安装/更新完成" "Sing-box 安装/更新失败"
}

gen_certificate_selfsigned(){
  local dir="$CERT_DIR/selfsigned"
  mkdir -p "$dir"
  CERT_CRT="$dir/cert.pem"
  CERT_KEY="$dir/private.key"
  openssl ecparam -genkey -name prime256v1 -out "$CERT_KEY"
  openssl req -new -x509 -days 36500 -key "$CERT_KEY" -out "$CERT_CRT" -subj "/CN=www.bing.com"
  green "已生成自签证书：$CERT_CRT"
  rm -f "$SB_DIR/cert.pem" "$SB_DIR/private.key"
}

apply_certificate_menu(){


  if [[ -s "$SB_CFG" ]]; then
    local cpath
    cpath="$(jq -r '.inbounds[]? | select(.type=="hysteria2") | .tls.certificate_path' "$SB_CFG" 2>/dev/null | head -n1 || true)"
    if [[ -n "$cpath" && -s "$cpath" ]]; then
      local enddate end_ts now_ts days
      enddate="$(openssl x509 -in "$cpath" -noout -enddate 2>/dev/null | cut -d= -f2 || true)"
      if [[ -n "$enddate" ]]; then
        end_ts=$(date -d "$enddate" +%s 2>/dev/null || echo 0)
        now_ts=$(date +%s)
        days=$(( (end_ts - now_ts) / 86400 ))
      fi
    fi
  fi
  while true; do
    yellow "证书选项："
    yellow "1）自签证书（默认）"
    yellow "2）使用 Acme-yg 申请域名证书"
    yellow "3）使用已有证书"
        readp "请选择【1-3】：" sel
    sel="${sel:-1}"
    case "$sel" in
      1) gen_certificate_selfsigned; break;;
      2) bash <(curl -fsSL https://raw.githubusercontent.com/yonggekkk/acme-yg/main/acme.sh)
         if [[ -s /root/ygkkkca/cert.crt && -s /root/ygkkkca/private.key ]]; then
           local domain="unknown"
           [[ -s /root/ygkkkca/ca.log ]] && domain="$(cat /root/ygkkkca/ca.log)"
           local dir="$CERT_DIR/$domain"
           mkdir -p "$dir"
           CERT_CRT="$dir/cert.pem"
           CERT_KEY="$dir/private.key"
           mv /root/ygkkkca/cert.crt "$CERT_CRT"
           mv /root/ygkkkca/private.key "$CERT_KEY"
           green "已使用 Acme-yg 证书，存放于 $dir"
           rm -rf /root/ygkkkca
           break
         else
           yellow "Acme 申请失败，回退自签"
           gen_certificate_selfsigned; break
         fi;;
      3) if compgen -G "$CERT_DIR/*/cert.pem" > /dev/null; then
           echo "可用的证书目录："
           select choice in $(ls -1 "$CERT_DIR"); do
             if [[ -n "$choice" && -s "$CERT_DIR/$choice/cert.pem" && -s "$CERT_DIR/$choice/private.key" ]]; then
               CERT_CRT="$CERT_DIR/$choice/cert.pem"
               CERT_KEY="$CERT_DIR/$choice/private.key"
               green "已选择证书目录：$CERT_DIR/$choice"
               break 2
             else
               red "无效选择"
             fi
           done
         else
           red "未检测到已有证书"; continue
         fi;;
      *) yellow "无效输入";;
    esac
  done
}

replace_certificate(){
  if ! apply_certificate_menu; then
    yellow "已返回主菜单"; return
  fi
  systemctl restart sing-box || true
  green "证书已替换并重启 sing-box"
}

choose_port(){
  while true; do
    local p
    readp "设置 Hysteria2 端口[1-65535]（回车随机）：" p || true
    echo "VLESS使用默认443端口，若需要修改，请修改脚本！"
    if [[ -z "$p" ]]; then
      p="$(shuf -i 10000-65535 -n 1)"
    fi
    if ! [[ "$p" =~ ^[0-9]+$ ]] || ((p<1||p>65535)); then
      yellow "端口无效"; continue
    fi
    if ss -tunlp | awk '{print $5}' | sed -n 's/.*://p' | grep -qw "$p"; then
      yellow "端口 $p 已占用"; continue
    fi
    echo "$p"; return 0
  done
}

ensure_service(){
  cat >/etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=Sing-box Service
After=network.target nss-lookup.target
[Service]
User=root
ExecStart=$SB_BIN run -c $SB_CFG
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable sing-box >/dev/null 2>&1 || true
}

load_cert_from_config(){
  if [[ -s "$SB_CFG" ]]; then
    local cpath kpath
    cpath="$(jq -r '.inbounds[]? | select(.type=="hysteria2") | .tls.certificate_path' "$SB_CFG" | head -n1 2>/dev/null || true)"
    kpath="$(jq -r '.inbounds[0].tls.key_path // empty' "$SB_CFG")"
    if [[ -n "$cpath" && -n "$kpath" ]]; then
      CERT_CRT="$cpath"; CERT_KEY="$kpath"
    fi
  fi
}

make_hy2_config(){
  local port="$1"
  local passwd
  if "$SB_BIN" >/dev/null 2>&1; then passwd="$($SB_BIN generate uuid)"
  else passwd="$(cat /proc/sys/kernel/random/uuid)"; fi
  green "已生成 Hysteria2 UUID（密码）：$passwd"
  cat >"$SB_CFG" <<JSON
{
  "inbounds": [{
    "type": "hysteria2","listen": "::","listen_port": $port,
    "users":[{"password":"$passwd"}],
    "up_mbps": 1000,
    "down_mbps": 1000,
    "tls":{"enabled":true,"alpn":["h3"],
    "certificate_path":"$CERT_CRT","key_path":"$CERT_KEY"}
  }],
  "outbounds":[{"type":"direct"},{"type":"block"}]
}
JSON
  jq . "$SB_CFG" >/dev/null || { red "配置生成失败"; return 0; }
  local domain
if [[ "$CERT_CRT" == *"/selfsigned/"* ]]; then
    domain="www.bing.com"
    insecure="true"
else
    domain="$(basename "$(dirname "$CERT_CRT")")"
    insecure="false"
fi

echo "hysteria2://$passwd@$domain:$port?security=tls&alpn=h3&insecure=$insecure&sni=$domain&upmbps=1000&downmbps=1000#$mname-Hy2" > "$SB_DIR/hy2.txt"

}

# ==== 新增 VLESS 相关函数（仅增加，不修改原有逻辑） ====
make_vless_config(){
  local port="443"
  local uuid
  if "$SB_BIN" >/dev/null 2>&1; then
    uuid="$($SB_BIN generate uuid)"
  else
    uuid="$(cat /proc/sys/kernel/random/uuid)"
  fi
  green "已生成 VLESS UUID：$uuid"

  # 构造 VLESS inbound
  local vless_inbound=$(cat <<JSON
{
  "type": "vless",
  "listen": "::",
  "listen_port": $port,
  "users": [
    {"uuid": "$uuid"}
  ],
  "tls": {
    "enabled": true,
    "certificate_path": "$CERT_CRT",
    "key_path": "$CERT_KEY",
    "alpn": ["http/1.1"]
  },
  "transport": {
    "type": "ws",
    "path": "/files/transfer"
  }
}
JSON
)

  # 使用 jq 追加到原 config.json
  tmpfile=$(mktemp)
  jq --argjson inbound "$vless_inbound" '.inbounds += [$inbound]' "$SB_CFG" > "$tmpfile" && mv "$tmpfile" "$SB_CFG"

  # 节点链接
  local serip="$(curl -s4m5 icanhazip.com || curl -s6m5 icanhazip.com)"
  local sni
  if [[ "$CERT_CRT" == *"/selfsigned/"* ]]; then
    sni="www.bing.com"
  else
    sni="$(basename "$(dirname "$CERT_CRT")")"
  fi
local domain
if [[ "$CERT_CRT" == *"/selfsigned/"* ]]; then
    domain="www.bing.com"
else
    domain="$(basename "$(dirname "$CERT_CRT")")"
fi

echo "vless://$uuid@$domain:$port?encryption=none&security=tls&alpn=h2%2Chttp%2F1.1&fp=chrome&type=ws&path=/files/transfer&sni=$domain#$mname-WS" > "$SB_DIR/vless.txt"
}

# ==== 新增结束 ====

start_singbox(){
  systemctl restart sing-box || systemctl start sing-box
  sleep 1
  systemctl is-active --quiet sing-box && green "Sing-box 已启动" || red "Sing-box 启动失败"
}

show_result(){

  if [[ -s "$SB_DIR/hy2.txt" ]]; then
    echo
    green "================================================="
    echo
    yellow "Hysteria2 节点二维码："
    echo

    if command -v qrencode >/dev/null 2>&1; then
      qrencode -o - -t ANSIUTF8 "$(cat "$SB_DIR/hy2.txt")"
    fi

    echo
    yellow "Hysteria2 节点链接："
    echo
    cat "$SB_DIR/hy2.txt"
    echo
    green "================================================"
    echo
     # ==== 新增：显示 VLESS 节点信息（仅增加输出，不改原有 Hy2 部分） ====
  if [[ -s "$SB_DIR/vless.txt" ]]; then
    echo
    echo
    yellow "VLESS 节点二维码："
    echo
    if command -v qrencode >/dev/null 2>&1; then
      qrencode -o - -t ANSIUTF8 "$(cat "$SB_DIR/vless.txt")"
    fi
    echo
    yellow "VLESS 节点链接："
    echo
    cat "$SB_DIR/vless.txt"
    echo
    green "=============================================="
    echo
  fi
  # ==== 新增结束 ====

    if [[ -s "$SB_CFG" ]]; then
      local cpath kpath
      cpath="$(jq -r '.inbounds[]? | select(.type=="hysteria2") | .tls.certificate_path' "$SB_CFG" 2>/dev/null | head -n1 || true)"
      kpath="$(jq -r '.inbounds[]? | select(.type=="hysteria2") | .tls.key_path' "$SB_CFG" 2>/dev/null | head -n1 || true)"
      blue "当前证书路径："
      echo " cert.pem: $cpath"
      echo " key.pem:  $kpath"
      echo
    fi

    LAST_MSG="✅ Hy2 和 Vless 节点信息已输出"
  else
    yellow "未检测到 Hy2 和 Vless 节点"
    LAST_MSG="❌ 未检测到 Hy2 和 Vless 节点"
  fi

 

  if [[ -s "$SB_CFG" ]]; then
    local cpath kpath
    cpath="$(jq -r '.inbounds[]? | select(.type=="hysteria2") | .tls.certificate_path' "$SB_CFG" 2>/dev/null | head -n1 || true)"
    kpath="$(jq -r '.inbounds[0].tls.key_path // empty' "$SB_CFG")"
    if [[ -n "$cpath" && -n "$kpath" ]]; then
      CERT_CRT="$cpath"; CERT_KEY="$kpath"
    fi
  fi
}

uninstall_all(){
  systemctl stop sing-box 2>/dev/null || true
  systemctl disable sing-box 2>/dev/null || true
  rm -f /etc/systemd/system/sing-box.service
  systemctl daemon-reload || true
  rm -rf "$SB_DIR"
  green "已卸载 sing-box 与配置目录"

  clear
  history -c
  LAST_MSG="✅ 已完成卸载 sing-box 与配置目录"
  set_feedback $? "已完成卸载 sing-box 与配置目录" "卸载失败"
}

install_prepare(){
  ensure_deps
  install_singbox
}

install_flow() {
  if ! install_prepare; then
    yellow "安装流程取消，返回主菜单"
    LAST_MSG="❌ 安装流程取消"
    return 0
  fi
  
# =========================
# 定义颜色
GREEN='\033[0;32m'
NC='\033[0m' # 无颜色
# =========================
# 输入节点备注
echo -e "${GREEN}请输入机器名称 (默认: vps):${NC}"
read mname
mname=${mname:-vps}

  # 选择端口
  readp "设置 Hysteria2 端口[1-65535]（回车随机）： " port
  if [[ -z "$port" ]]; then
    port=$(shuf -i 2000-65000 -n 1)
  elif ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
    red "端口输入无效，使用随机端口"
    port=$(shuf -i 2000-65000 -n 1)
  fi
  if [[ -z "$port" ]]; then
    port=$(shuf -i 2000-65000 -n 1)
  elif ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
    red "端口输入无效，使用随机端口"
    port=$(shuf -i 2000-65000 -n 1)
  fi
  echo "$port" > "$SB_DIR/last_port.log"

  # 生成 UUID
  if command -v uuidgen >/dev/null 2>&1; then
    uuid=$(uuidgen)
  else
    uuid=$(cat /proc/sys/kernel/random/uuid)
  fi
  echo "$uuid" > "$SB_DIR/last_uuid.log"

  # 选择证书
  if ! apply_certificate_menu; then
    yellow "用户放弃证书选择，返回主菜单"
    LAST_MSG="❌ 用户放弃证书选择，返回主菜单"
    return 0
  fi

  # 是否立即生成节点
  readp "是否立即生成 Hysteria2 和 Vless 节点？(y/n)： " ans
  clear
  history -c
  if [[ "$ans" =~ [yY] ]]; then
    make_hy2_config "$port" "$uuid"
    # ==== 新增：在 Hy2 生成后追加生成 VLESS 配置（不改动原有 Hy2 逻辑） ====
    make_vless_config "$port" "$uuid" || true
    # ==== 新增结束 ====
    ensure_service
    start_singbox
    show_result
    LAST_MSG="✅ 安装完成并生成节点"
  else
    yellow "节点未生成"
    LAST_MSG="ℹ️ 安装完成，但未生成节点"
  fi
}

generate_node(){
  # 未安装 sing-box 的处理
  if [[ ! -x "$SB_BIN" ]]; then
    yellow "未检测到 sing-box"
    readp "是否进入安装流程？(y=是 / n=否 )：" go
    case "$go" in
      y|Y) install_flow; return $? ;;
      n|N) yellow "取消安装"; LAST_MSG="❌ 取消安装"; return 0 ;;
      *)   yellow "取消安装"; LAST_MSG="❌ 取消安装"; return 0 ;;
    esac
  fi

  # 检查 /root/cert 下证书
  cert_dirs=($(find "$CERT_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null))
  valid_certs=()
  for d in "${cert_dirs[@]}"; do
    if [[ -s "$d/cert.pem" && -s "$d/private.key" ]]; then
      valid_certs+=("$d")
    fi
  done

  if [[ ${#valid_certs[@]} -eq 1 ]]; then
    readp "检测到证书目录：${valid_certs[0]} 是否使用？(y/n/m): " use_cert
    case "$use_cert" in
      y|Y) CERT_CRT="${valid_certs[0]}/cert.pem"; CERT_KEY="${valid_certs[0]}/private.key";;
      *) LAST_MSG="❌ 用户拒绝使用检测到的证书"; return 0;;
    esac
  elif [[ ${#valid_certs[@]} -gt 1 ]]; then
    echo "检测到多个证书目录，请选择："
    # 仅展示域名（目录名），不展示完整路径
    labels=()
    for d in "${valid_certs[@]}"; do
      labels+=("$(basename "$d")")
    done
    select label in "${labels[@]}" "取消"; do
      if [[ "$label" == "取消" || -z "$label" ]]; then
        yellow "用户放弃证书续期，返回主菜单"
        LAST_MSG="❌ 用户放弃证书续期，返回主菜单"
        return 0
      fi
      # 通过 label 找到对应的目录
      choice=""
      for i in "${!labels[@]}"; do
        if [[ "${labels[$i]}" == "$label" ]]; then
          choice="${valid_certs[$i]}"
          break
        fi
      done
      if [[ -z "$choice" ]]; then
        red "选择无效，请重试"
        continue
      fi
      base="$(basename "$choice")"
      if [[ "$base" == "selfsigned" ]]; then
        gen_certificate_selfsigned
        green "自签证书已重新生成：$choice"
        LAST_MSG="✅ 自签证书已重新生成"
      else
        if [[ -z "$ACME_BIN" ]]; then
          yellow "未检测到 acme.sh，正在自动安装到 /root/.acme.sh ..."
          bash <(curl -fsSL https://raw.githubusercontent.com/yonggekkk/acme-yg/main/acme.sh)
          if [ -x "/root/.acme.sh/acme.sh" ]; then
            ACME_BIN="/root/.acme.sh/acme.sh"
          else
            red "acme.sh 安装失败，请手动检查"
            LAST_MSG="❌ 续期失败，acme.sh 安装失败"
            return 0
          fi
        fi
        if $ACME_BIN --renew -d "$base" --force; then
          green "证书续期完成：$choice"
          LAST_MSG="✅ 证书手动续期完成"
        else
          red "证书续期失败：$choice"
          LAST_MSG="❌ 证书手动续期失败"
        fi
      fi
      break
    done
  else
    readp "未检测到证书，是否申请证书？(y/n)： " ans
    case "$ans" in
      y|Y) if ! apply_certificate_menu; then LAST_MSG="❌ 证书申请失败"; return 0; fi;;
      *) LAST_MSG="❌ 用户未申请证书，返回主菜单"; return 0;;
    esac
  fi

  # 端口选择/读取
  local port
  if [[ -s "$SB_DIR/last_port.log" ]]; then
    port="$(cat "$SB_DIR/last_port.log")"
  else
    readp "请输入 Hysteria2 端口（默认 2688）：" port
    port="${port:-2688}"
    echo "$port" > "$SB_DIR/last_port.log"
  fi

  # 生成配置并启动服务
  make_hy2_config "$port"
  # ==== 新增：生成 VLESS（在主配置已经存在后追加） ====
  make_vless_config "$port" || true
  # ==== 新增结束 ====
  ensure_service
  if start_singbox; then
    show_result
    LAST_MSG="✅ 节点生成成功"
    return 0
  else
    red "Sing-box 启动失败"
    LAST_MSG="❌ 节点生成失败（singbox服务启动失败）"
    return 0
  fi
}

# ====== Renew & Auto-Renew Functions ======

# 入口参数：自动续期（供 systemd timer 调用）
if [[ "${1:-}" == "--autorenew" ]]; then
  autorenew_check
  exit 0
fi

# ====== End Renew Functions ======


show_status(){
  local lines=()

  # Sing-box 安装/运行状态
  if [[ -x /usr/local/bin/sing-box || -x "$SB_BIN" ]]; then
    if systemctl is-active --quiet sing-box 2>/dev/null; then
      lines+=("$(green "Sing-box 已安装 | 运行中")")
    else
      lines+=("$(green "Sing-box 已安装") | $(red "未运行")")
    fi
  else
    lines+=("$(red "Sing-box 未安装")")
  fi

  # 证书到期状态（中文）
  if [[ -s "$SB_CFG" ]] && command -v jq >/dev/null 2>&1; then
    local cpath enddate end_ts now_ts days enddate_cn
    cpath="$(jq -r '.inbounds[]? | select(.type=="hysteria2") | .tls.certificate_path' "$SB_CFG" 2>/dev/null | head -n1 || true)"
    if [[ -n "$cpath" && -s "$cpath" ]]; then
      enddate="$(openssl x509 -in "$cpath" -noout -enddate 2>/dev/null | cut -d= -f2 || true)"
      if [[ -n "$enddate" ]]; then
        end_ts=$(date -d "$enddate" +%s 2>/dev/null || echo 0)
        now_ts=$(date +%s)
        if (( end_ts > 0 )); then
          days=$(( (end_ts - now_ts) / 86400 ))
          enddate_cn=$(date -d "$enddate" "+%Y年%m月%d日" 2>/dev/null)
          if (( days < 0 )); then
            lines+=("$(red "证书已过期（到期日：$enddate_cn）")")
          elif (( days <= 30 )); then
            lines+=("$(yellow "证书即将过期（到期日：$enddate_cn，剩余 $days 天）")")
          else
            lines+=("$(green "证书有效期至 $enddate_cn，剩余 $days 天")")
          fi
        else
          lines+=("$(red "无法解析证书到期时间")")
        fi
      else
        lines+=("$(red "无法读取证书到期时间")")
      fi
    else
      lines+=("$(red "未检测到证书（未在配置中找到 Hysteria2 证书路径）")")
    fi
  else
    lines+=("$(red "未检测到配置文件，无法获取证书信息")")
  fi




  # Sing-box 版本信息
  if [[ -x "$SB_BIN" ]]; then
    local local_ver="$($SB_BIN version 2>/dev/null | awk '/version/{print $NF}')"
  else
    local_ver="未安装"
  fi

  local latest_ver="$(curl -fsSL https://data.jsdelivr.com/v1/package/gh/SagerNet/sing-box | grep -Eo '\"[0-9]+\.[0-9]+\.[0-9]+\"' | tr -d '\"' | head -n1 || echo "未知")"

  lines+=("$(green "当前 Sing-box 版本：$local_ver") ｜ $(yellow "最新版本：$latest_ver")")
  # 当前节点生成时间（+8区）
  if [[ -f "$SB_CFG" ]]; then
    local gen_time
    gen_time="$(TZ='Asia/Shanghai' date -r "$SB_CFG" '+%Y-%m-%d %H:%M:%S %Z(+08:00)')"
    lines+=("$(yellow "当前节点生成时间：$gen_time")")
  else
    lines+=("$(red "未找到节点配置文件")")
  fi

  # 刷新时间
  # VPS状态信息
  bbr=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
  ipv4=$(curl -s4m5 icanhazip.com || echo "无IPv4")
  ipv6=$(curl -s6m5 icanhazip.com || echo "无IPv6")
  lines+=("$(yellow "BBR算法:$bbr")" )
  lines+=("本地IPV4地址：$ipv4   本地IPV6地址：$ipv6")
  if [[ "$ipv4" != "无IPv4" ]]; then
    lines+=("代理IP优先级：IPv4优先出站($ipv4)")
  elif [[ "$ipv6" != "无IPv6" ]]; then
    lines+=("代理IP优先级：IPv6优先出站($ipv6)")
  else
    lines+=("代理IP优先级：未知")
  fi
    # 当前证书
  if [[ -s "$SB_CFG" ]] && command -v jq >/dev/null 2>&1; then
    local cert_path
    cert_path="$(jq -r '.inbounds[]? | select(.type=="hysteria2") | .tls.certificate_path' "$SB_CFG" 2>/dev/null | head -n1 || true)"
    if [[ -n "$cert_path" && "$cert_path" != "null" ]]; then
      cert_dir="$(dirname "$cert_path")"
      lines+=("$(green "当前使用的证书：$cert_dir")")
    else
      lines+=("$(red "未检测到证书路径")")
    fi
  fi

  # 节点配置文件目录
  lines+=("$(green "节点配置文件目录：$SB_DIR")")

    # 刷新时间（本地时区 + 固定展示 UTC+8）
  local local_time cn_time
  local_time="$(date '+%Y-%m-%d %H:%M:%S %Z(%z)')"
  cn_time="$(TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M:%S %Z(+08:00)')"
  lines+=("$(yellow "状态刷新时间：$cn_time")")


  # ASCII 边框（仅上下边框）
  local W=72
  local purple="[35m"; local reset="[0m"
  local line; line=$(printf "%*s" "$W" "" | tr " " "-")

  printf "%b%s%b
" "$purple" "$line" "$reset"
  for ln in "${lines[@]}"; do
    echo -e " $ln"
  done
  printf "%b%s%b

" "$purple" "$line" "$reset"
}



enable_bbr(){
  modprobe tcp_bbr 2>/dev/null || true
  echo "tcp_bbr" >> /etc/modules-load.d/modules.conf
  sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
  sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
  echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
  echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
  sysctl -p >/dev/null 2>&1
  algo=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
  if [[ "$algo" == "bbr" ]]; then
    green "✅ 已启用 BBR 拥塞控制算法"
  else
    red "❌ 启用 BBR 失败"
  fi
}

update_singbox_kernel(){
  readp "是否更新 Sing-box 内核版本？(y/n): " ans
  case "$ans" in
    y|Y)
      install_singbox
      ;;
    *)
      yellow "已取消更新，返回主菜单"
      LAST_MSG="❌ 已取消更新，返回主菜单"
      return
      ;;
  esac
}
menu(){

  while true; do
    clear
    show_status
  if [[ -n "$LAST_MSG" ]]; then
    if [[ "$LAST_MSG" == *"✅"* ]]; then
      yellow "操作提示：${LAST_MSG#* }"
    elif [[ "$LAST_MSG" == *"❌"* ]]; then
      red "操作提示：${LAST_MSG#* }"
    else
      yellow "$LAST_MSG"
    fi
    echo
    echo -e "\033[31m$(printf "%*s" "72" "" | tr " " "-")\033[0m"
  fi
green "============ Sing-box (Hysteria2 & Vless) ============"
echo

    if [[ -s "$SB_CFG" ]]; then
      local cpath
      cpath="$(jq -r '.inbounds[]? | select(.type=="hysteria2") | .tls.certificate_path' "$SB_CFG" 2>/dev/null | head -n1 || true)"
      if [[ -n "$cpath" && -s "$cpath" ]]; then
        local enddate end_ts now_ts days
        enddate="$(openssl x509 -in "$cpath" -noout -enddate 2>/dev/null | cut -d= -f2 || true)"
        if [[ -n "$enddate" ]]; then
          end_ts=$(date -d "$enddate" +%s 2>/dev/null || echo 0)
          now_ts=$(date +%s)
          days=$(( (end_ts - now_ts) / 86400  ))
          (( days < 0 )) && red "❌ 证书已过期"
          (( days >=0 && days <= 30 )) && yellow "⚠️ 证书即将过期"
        fi
      fi
    fi

echo -e "[35m1)[0m [32m安装 / 更新 Sing-box[0m"
echo -e "[35m2)[0m [32m查看节点信息[0m"
echo -e "[35m3)[0m [32m卸载 Sing-box 及配置[0m"
echo -e "[35m4)[0m [32m一键开启 BBR+FQ 加速[0m"
echo -e "[35m5)[0m [32m更新 Sing-box 内核版本[0m"

    echo -e "\033[35m0)\033[0m \033[32m退出 (退出脚本)\033[0m"
    echo

    readp "请选择【0-5】： " sel
    case "${sel:-}" in
      1)
        install_flow
        ;;
      2)
        show_result
        ;;
      3)
        uninstall_all
        ;;
      4)
        # 捕获功能4（启用加速/一键开启等）的实际输出并记录为上次操作结果
        {
          output="$(enable_bbr 2>&1)"
          ret=$?
          # 先将输出打印到终端
          if [[ -n "$output" ]]; then
            echo "$output"
          fi
          # 将实际输出写入 LAST_MSG（若输出为空则用状态提示）
          if [[ $ret -eq 0 ]]; then
            LAST_MSG="${output:-✅ 操作已完成}"
          else
            LAST_MSG="${output:-❌ 操作失败}"
          fi
        }
        ;;

      5)
        update_singbox_kernel
        ;;
      0)
        exit 0
        ;;
      *)
        yellow "输入无效"
         LAST_MSG="输入无效"
        ;;
    esac

  done
}

menu
