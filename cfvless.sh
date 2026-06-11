#!/usr/bin/env bash

# =========================
# 修订版 二合一脚本 (全功能保留 + 终端交互还原 + Acme深度优化版 + 独立UUID及版本选择)
# Vless优质+Hy2
# =========================

export LANG=en_US.UTF-8

# 基础依赖预检查
if ! command -v jq >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
    echo -e "\e[1;33m正在安装基础依赖 jq, curl...\033[0m"
    if command -v apt >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt update -y && apt install -y jq curl
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y jq curl
    elif command -v yum >/dev/null 2>&1; then
        yum install -y jq curl epel-release
    elif command -v apk >/dev/null 2>&1; then
        apk update && apk add jq curl
    fi
fi

# =========================
# 定义颜色与常量
# =========================
re="\033[0m"
red="\033[1;91m"
green="\e[1;32m"
yellow="\e[1;33m"
purple="\e[1;35m"
skyblue="\e[1;36m"
red() { echo -e "\e[1;91m$1\033[0m"; }
green() { echo -e "\e[1;32m$1\033[0m"; }
yellow() { echo -e "\e[1;33m$1\033[0m"; }
purple() { echo -e "\e[1;35m$1\033[0m"; }
skyblue() { echo -e "\e[1;36m$1\033[0m"; }
reading() { read -p "$(red "$1")" "$2"; }

server_name="sing-box"
export work_dir="/etc/sing-box"
client_dir="${work_dir}/url.txt"
export config_dir="${work_dir}/config.json"
export hy2_port=${PORT:-$(shuf -i 1000-65000 -n 1)}
export CFIP=${CFIP:-'cf.877774.xyz'} 
export CFPORT=${CFPORT:-'443'} 
export CERT_DIR="/root/cert"
export CERT_CRT=""
export CERT_KEY=""

# 检查是否为root下运行
[[ $EUID -ne 0 ]] && red "请在root用户下运行脚本" && exit 1

# 生成随机WS路径
generate_ws_path() {
    local roots=("api" "v1" "assets" "static" "graphql" "system" "web" "data" "cloud")
    local subs=("user" "query" "status" "update" "config" "media" "sync" "metrics" "files")
    local actions=("info" "data" "fetch" "push" "handle" "main" "task")

    local r1=${roots[$RANDOM % ${#roots[@]}]}
    local r2=${subs[$RANDOM % ${#subs[@]}]}
    local r3=${actions[$RANDOM % ${#actions[@]}]}
    
    local hash=$(date +%s%N | sha256sum | head -c 5)
    echo "/${r1}/${r2}/${r3}/${hash}"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

check_service() {
    local service_name=$1
    local service_file=$2
    
    [[ ! -f "${service_file}" ]] && { red "not installed"; return 2; }
        
    if command_exists apk; then
        rc-service "${service_name}" status | grep -q "started" && green "running" || yellow "not running"
    else
        systemctl is-active "${service_name}" | grep -q "^active$" && green "running" || yellow "not running"
    fi
    return $?
}

check_singbox() { check_service "sing-box" "${work_dir}/${server_name}"; }
check_argo() { check_service "argo" "${work_dir}/argo"; }

manage_packages() {
    if [ $# -lt 2 ]; then
        red "Unspecified package name or action" 
        return 1
    fi

    action=$1
    shift

    for package in "$@"; do
        if [ "$action" == "install" ]; then
            if command_exists "$package"; then
                green "${package} already installed"
                continue
            fi
            yellow "正在安装 ${package}..."
            if command_exists apt; then
                DEBIAN_FRONTEND=noninteractive apt install -y "$package"
            elif command_exists dnf; then
                dnf install -y "$package"
            elif command_exists yum; then
                yum install -y "$package"
            elif command_exists apk; then
                apk update
                apk add "$package"
            else
                red "Unknown system!"
                return 1
            fi
        elif [ "$action" == "uninstall" ]; then
            if ! command_exists "$package"; then
                yellow "${package} is not installed"
                continue
            fi
            yellow "正在卸载 ${package}..."
            if command_exists apt; then
                apt remove -y "$package" && apt autoremove -y
            elif command_exists dnf; then
                dnf remove -y "$package" && dnf autoremove -y
            elif command_exists yum; then
                yum remove -y "$package" && yum autoremove -y
            elif command_exists apk; then
                apk del "$package"
            else
                red "Unknown system!"
                return 1
            fi
        else
            red "Unknown action: $action"
            return 1
        fi
    done
    return 0
}

allow_port() {
    has_ufw=0
    has_firewalld=0
    has_iptables=0
    has_ip6tables=0

    command_exists ufw && has_ufw=1
    command_exists firewall-cmd && systemctl is-active firewalld >/dev/null 2>&1 && has_firewalld=1
    command_exists iptables && has_iptables=1
    command_exists ip6tables && has_ip6tables=1

    if [ "$has_ufw" -eq 1 ]; then ufw --force default allow outgoing >/dev/null 2>&1; fi
    if [ "$has_firewalld" -eq 1 ]; then firewall-cmd --permanent --zone=public --set-target=ACCEPT >/dev/null 2>&1; fi
    
    if [ "$has_iptables" -eq 1 ]; then
        iptables -C INPUT -i lo -j ACCEPT 2>/dev/null || iptables -I INPUT 3 -i lo -j ACCEPT
        iptables -C INPUT -p icmp -j ACCEPT 2>/dev/null || iptables -I INPUT 4 -p icmp -j ACCEPT
        iptables -P FORWARD DROP 2>/dev/null || true
        iptables -P OUTPUT ACCEPT 2>/dev/null || true
    fi
    
    if [ "$has_ip6tables" -eq 1 ]; then
        ip6tables -C INPUT -i lo -j ACCEPT 2>/dev/null || ip6tables -I INPUT 3 -i lo -j ACCEPT
        ip6tables -C INPUT -p icmp -j ACCEPT 2>/dev/null || ip6tables -I INPUT 4 -p icmp -j ACCEPT
        ip6tables -P FORWARD DROP 2>/dev/null || true
        ip6tables -P OUTPUT ACCEPT 2>/dev/null || true
    fi

    for rule in "$@"; do
        port=${rule%/*}
        proto=${rule#*/}
        if [ "$has_ufw" -eq 1 ]; then ufw allow in ${port}/${proto} >/dev/null 2>&1; fi
        if [ "$has_firewalld" -eq 1 ]; then firewall-cmd --permanent --add-port=${port}/${proto} >/dev/null 2>&1; fi
        if [ "$has_iptables" -eq 1 ]; then
            iptables -C INPUT -p ${proto} --dport ${port} -j ACCEPT 2>/dev/null || iptables -I INPUT 4 -p ${proto} --dport ${port} -j ACCEPT
        fi
        if [ "$has_ip6tables" -eq 1 ]; then
            ip6tables -C INPUT -p ${proto} --dport ${port} -j ACCEPT 2>/dev/null || ip6tables -I INPUT 4 -p ${proto} --dport ${port} -j ACCEPT
        fi
    done

    if [ "$has_firewalld" -eq 1 ]; then firewall-cmd --reload >/dev/null 2>&1; fi

    if command_exists rc-service 2>/dev/null; then
        [ "$has_iptables" -eq 1 ] && iptables-save > /etc/iptables/rules.v4 2>/dev/null
        [ "$has_ip6tables" -eq 1 ] && ip6tables-save > /etc/iptables/rules.v6 2>/dev/null
    else
        if ! command_exists netfilter-persistent; then
            manage_packages install iptables-persistent >/dev/null 2>&1 || true
            netfilter-persistent save >/dev/null 2>&1 || true
        elif command_exists service; then
            service iptables save 2>/dev/null
            service ip6tables save 2>/dev/null
        fi
    fi
}

apply_acme_cert() {
    clear
    green "=== 正在申请并配置 Acme.sh 域名证书 ==="
    manage_packages install socat openssl

    read -rp "$(yellow '请输入要申请证书的域名（请确保已解析到本机IP）: ')" acme_domain
    [[ -z "$acme_domain" ]] && red "❌ 域名不能为空" && return 1

    read -rp "$(yellow '请输入注册邮箱（回车自动生成）: ')" acme_email
    if [[ -z "$acme_email" ]]; then
        acme_email="$(date +%s | sha256sum | head -c 12)@gmail.com"
    fi

    local dir="${CERT_DIR}/${acme_domain}"
    mkdir -p "$dir"

    if [[ ! -f /root/.acme.sh/acme.sh ]]; then
        yellow "▶ 正在安装 acme.sh ..."
        curl -fsSL https://get.acme.sh | sh
    fi

    /root/.acme.sh/acme.sh --register-account -m "$acme_email"

    manage_service "sing-box" "stop" > /dev/null 2>&1 || true
    
    yellow "▶ 开始申请证书（HTTP-01 / 80端口）..."
    if /root/.acme.sh/acme.sh --issue -d "$acme_domain" --standalone -k ec-256 --server letsencrypt --force; then
        yellow "▶ 正在将证书安装至统一目录: $dir"
        
        local reload_cmd=""
        if command_exists systemctl; then
            reload_cmd="systemctl restart sing-box"
        elif command_exists rc-service; then
            reload_cmd="rc-service sing-box restart"
        fi

        /root/.acme.sh/acme.sh --install-cert -d "$acme_domain" \
            --key-file       "$dir/private.key" \
            --fullchain-file "$dir/cert.pem" \
            --reloadcmd      "$reload_cmd" \
            --ecc

        CERT_CRT="$dir/cert.pem"
        CERT_KEY="$dir/private.key"
        
        green "✅ 证书申请成功！"
        green "📄 统一公钥路径: $CERT_CRT"
        green "🔑 统一私钥路径: $CERT_KEY"
        green "ℹ️ 自动续期已配置完毕，证书更新后将自动重启服务。"
        sleep 3
    else
        red "❌ 证书申请失败，请检查域名解析或80端口占用情况。"
        sleep 3
        return 1
    fi
}

apply_certificate_menu(){
  while true; do
    yellow "证书选项回车默认选择1："
    yellow "1）使用 Acme 自动申请或更新域名证书 (深度修复目录问题版)"
    yellow "2）使用已有证书"
    yellow "0）返回主菜单"
    reading "请选择【0-2】：" sel
    sel="${sel:-1}"
    case "$sel" in
      1) apply_acme_cert && break ;;
      2) if compgen -G "$CERT_DIR/*/cert.pem" > /dev/null; then
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
      0)  menu ;;
    esac
  done
}

install_singbox() {
    clear
    apply_certificate_menu
    
    echo ""
    yellow "=== 请选择核心组件的安装版本 ==="
    yellow "1. 个人维护版本 (JaWaoo/singboxm 优化版 - 推荐)"
    yellow "2. 官方最新版本 (SagerNet/sing-box & Cloudflare/cloudflared)"
    reading "请输入选择 [1-2] (默认 1): " install_source_choice
    install_source_choice=${install_source_choice:-1}
    
    purple "\n正在安装核心组件，请稍后..."
    ARCH_RAW=$(uname -m)
    case "${ARCH_RAW}" in
        'x86_64') ARCH='amd64'; CF_ARCH='amd64' ;;
        'x86' | 'i686' | 'i386') ARCH='386'; CF_ARCH='386' ;;
        'aarch64' | 'arm64') ARCH='arm64'; CF_ARCH='arm64' ;;
        'armv7l') ARCH='armv7'; CF_ARCH='arm' ;;
        's390x') ARCH='s390x'; CF_ARCH='amd64' ;;
        *) red "不支持的架构: ${ARCH_RAW}"; exit 1 ;;
    esac

    [ ! -d "${work_dir}" ] && mkdir -p "${work_dir}" && chmod 755 "${work_dir}"
    
    if [ "$install_source_choice" == "1" ]; then
        yellow "正在下载个人维护版本..."
        curl -sLo "${work_dir}/sing-box" "https://github.com/JaWaoo/singboxm/releases/latest/download/sb$ARCH"
        curl -sLo "${work_dir}/argo" "https://github.com/JaWaoo/singboxm/releases/latest/download/cf$ARCH"
    else
        yellow "正在获取官方最新版本..."
        
        # 处理 sing-box
        LATEST_TAG=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | jq -r '.tag_name // empty')
        if [ -z "$LATEST_TAG" ]; then
            LATEST_TAG=$(curl -fsSL https://data.jsdelivr.com/v1/package/gh/SagerNet/sing-box | jq -r '.versions[0] // empty')
            [[ -n "$LATEST_TAG" ]] && LATEST_TAG="v${LATEST_TAG}"
        fi
        VERSION=${LATEST_TAG#v}
        TAR_NAME="sing-box-${VERSION}-linux-${ARCH}"
        SB_URL="https://github.com/SagerNet/sing-box/releases/download/${LATEST_TAG}/${TAR_NAME}.tar.gz"
        
        curl -fsSL -o "/tmp/${TAR_NAME}.tar.gz" "${SB_URL}"
        tar -xzf "/tmp/${TAR_NAME}.tar.gz" -C /tmp/
        cp -f "/tmp/${TAR_NAME}/sing-box" "${work_dir}/sing-box"
        rm -rf "/tmp/${TAR_NAME}" "/tmp/${TAR_NAME}.tar.gz"
        
        # 处理 Argo (cloudflared)
        ARGO_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}"
        curl -sLo "${work_dir}/argo" "${ARGO_URL}"
    fi

    chown root:root ${work_dir} && chmod +x ${work_dir}/${server_name} ${work_dir}/argo

    # 生成相互独立的 UUID
    uuid_vless=$(cat /proc/sys/kernel/random/uuid)
    uuid_hy2=$(cat /proc/sys/kernel/random/uuid)
    
    WS_PATH=$(generate_ws_path)
    allow_port  $hy2_port/udp > /dev/null 2>&1

cat > "${config_dir}" << EOF
{
  "log": { "level": "error" },
  "ntp": {
    "enabled": true,
    "server": "time.apple.com",
    "server_port": 123,
    "interval": "30m"
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-ws",
      "listen": "::",
      "listen_port": 8001,
      "users": [{ "uuid": "$uuid_vless" }],
      "transport": { "type": "ws", "path": "$WS_PATH" }
    },
    {
      "type": "hysteria2",
      "listen": "::",
      "listen_port": $hy2_port,
      "users": [{ "password": "$uuid_hy2" }],
      "ignore_client_bandwidth": true,
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "$CERT_CRT",
        "key_path": "$CERT_KEY"
      }
    }
  ],
  "outbounds": [{ "type": "direct", "tag": "direct" }],
  "route": { "final": "direct" }
}
EOF
}

main_systemd_services() {
    cat > /etc/systemd/system/sing-box.service << EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
User=root
WorkingDirectory=/etc/sing-box
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=/etc/sing-box/sing-box run -c /etc/sing-box/config.json
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/argo.service << EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
Type=simple
NoNewPrivileges=yes
TimeoutStartSec=0
ExecStart=/bin/sh -c "/etc/sing-box/argo tunnel --url http://localhost:8001 --no-autoupdate --edge-ip-version auto --protocol http2 > /etc/sing-box/argo.log 2>&1"
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    if [ -f /etc/centos-release ]; then
        yum install -y chrony
        systemctl start chronyd
        systemctl enable chronyd
        chronyc -a makestep
        yum update -y ca-certificates
        bash -c 'echo "0 0" > /proc/sys/net/ipv4/ping_group_range'
    fi
    systemctl daemon-reload 
    systemctl enable sing-box
    systemctl start sing-box
    systemctl enable argo
    systemctl start argo
}

alpine_openrc_services() {
    cat > /etc/init.d/sing-box << 'EOF'
#!/sbin/openrc-run
description="sing-box service"
command="/etc/sing-box/sing-box"
command_args="run -c /etc/sing-box/config.json"
command_background=true
pidfile="/var/run/sing-box.pid"
EOF

    cat > /etc/init.d/argo << 'EOF'
#!/sbin/openrc-run
description="Cloudflare Tunnel"
command="/bin/sh"
command_args="-c '/etc/sing-box/argo tunnel --url http://localhost:8001 --no-autoupdate --edge-ip-version auto --protocol http2 > /etc/sing-box/argo.log 2>&1'"
command_background=true
pidfile="/var/run/argo.pid"
EOF

    chmod +x /etc/init.d/sing-box /etc/init.d/argo
    rc-update add sing-box default > /dev/null 2>&1
    rc-update add argo default > /dev/null 2>&1
}

change_hosts() {
    sh -c 'echo "0 0" > /proc/sys/net/ipv4/ping_group_range'
    sed -i '1s/.*/127.0.0.1   localhost/' /etc/hosts
    sed -i '2s/.*/::1         localhost/' /etc/hosts
}

get_info() {  
  clear
  GREEN='\033[0;32m'
  NC='\033[0m'
  echo -e "${GREEN}请输入节点备注名称（别名） (默认: vps):${NC}"
  read isp
  isp=${isp:-vps}
  
  if [ -f "${work_dir}/argo.log" ]; then
      for i in {1..5}; do
          purple "第 $i 次尝试获取ArgoDoamin中..."
          argodomain=$(sed -n 's|.*https://\([^/]*trycloudflare\.com\).*|\1|p' "${work_dir}/argo.log")
          [ -n "$argodomain" ] && break
          sleep 2
      done
  else
      restart_argo
      sleep 6
      argodomain=$(sed -n 's|.*https://\([^/]*trycloudflare\.com\).*|\1|p' "${work_dir}/argo.log")
  fi

  green "\nArgoDomain：${purple}$argodomain${re}\n"

  # 分别提取 VLESS 和 Hysteria2 的凭据
  VLESS_UUID=$(jq -r '.inbounds[] | select(.tag=="vless-ws") | .users[0].uuid' "$config_dir")
  HY2_UUID=$(jq -r '.inbounds[] | select(.type=="hysteria2") | .users[0].password' "$config_dir")
  WS_PATH=$(jq -r '.inbounds[] | select(.tag=="vless-ws") | .transport.path' "$config_dir")
  ENCODED_PATH=$(printf '%s' "$WS_PATH" | sed 's#/#%2F#g')

  VLESS="vless://$VLESS_UUID@$CFIP:$CFPORT?encryption=none&security=tls&sni=$argodomain&fp=chrome&type=ws&host=$argodomain&path=${ENCODED_PATH}#优质-$isp"

  cat > ${work_dir}/url.txt <<EOF
$VLESS
EOF

  yellow "\n==========================================================================================\n"
  green "$VLESS"
  yellow "\n==========================================================================================\n"

  if [[ "$CERT_CRT" == *"/selfsigned/"* ]]; then
      domain="www.bing.com"
      insecure="true"
  else
      domain="$(basename "$(dirname "$CERT_CRT")")"
      insecure="false"
  fi
  
  # 使用独立的 Hysteria2 密码 (UUID) 生成链接
  green "hysteria2://$HY2_UUID@$domain:$hy2_port?security=tls&alpn=h3&insecure=$insecure&sni=$domain#Hy2-$isp"
  yellow "\n==========================================================================================\n"
}

manage_service() {
    local service_name="$1"
    local action="$2"

    if [ -z "$service_name" ] || [ -z "$action" ]; then
        red "缺少服务名或操作参数\n"
        return 1
    fi
    
    local status=$(check_service "$service_name" 2>/dev/null)

    case "$action" in
        "start")
            if [ "$status" == "running" ]; then 
                yellow "${service_name} 正在运行\n"
                return 0
            elif [ "$status" == "not installed" ]; then 
                yellow "${service_name} 尚未安装!\n"
                return 1
            else 
                yellow "正在启动 ${service_name} 服务\n"
                if command_exists rc-service; then
                    rc-service "$service_name" start
                elif command_exists systemctl; then
                    systemctl daemon-reload
                    systemctl start "$service_name"
                fi
                
                if [ $? -eq 0 ]; then
                    green "${service_name} 服务已成功启动\n"
                    return 0
                else
                    red "${service_name} 服务启动失败\n"
                    return 1
                fi
            fi
            ;;
            
        "stop")
            if [ "$status" == "not installed" ]; then 
                yellow "${service_name} 尚未安装！\n"
                return 2
            elif [ "$status" == "not running" ]; then
                yellow "${service_name} 未运行\n"
                return 1
            else
                yellow "正在停止 ${service_name} 服务\n"
                if command_exists rc-service; then
                    rc-service "$service_name" stop
                elif command_exists systemctl; then
                    systemctl stop "$service_name"
                fi
                
                if [ $? -eq 0 ]; then
                    green "${service_name} 服务已成功停止\n"
                    return 0
                else
                    red "${service_name} 服务停止失败\n"
                    return 1
                fi
            fi
            ;;
            
        "restart")
            if [ "$status" == "not installed" ]; then
                yellow "${service_name} 尚未安装！\n"
                return 1
            else
                yellow "正在重启 ${service_name} 服务\n"
                if command_exists rc-service; then
                    rc-service "$service_name" restart
                elif command_exists systemctl; then
                    systemctl daemon-reload
                    systemctl restart "$service_name"
                fi
                
                if [ $? -eq 0 ]; then
                    green "${service_name} 服务已成功重启\n"
                    return 0
                else
                    red "${service_name} 服务重启失败\n"
                    return 1
                fi
            fi
            ;;
            
        *)
            red "无效的操作: $action\n"
            red "可用操作: start, stop, restart\n"
            return 1
            ;;
    esac
}

start_singbox() { manage_service "sing-box" "start"; }
stop_singbox() { manage_service "sing-box" "stop"; }
restart_singbox() { manage_service "sing-box" "restart"; }
start_argo() { manage_service "argo" "start"; }
stop_argo() { manage_service "argo" "stop"; }
restart_argo() { manage_service "argo" "restart"; }

uninstall_singbox() {
   reading "确定要彻底卸载 sing-box 及相关组件吗? (y/n): " choice
   case "${choice}" in
       y|Y)
           yellow "正在清理进程与系统服务..."
           if command_exists rc-service; then
                rc-service sing-box stop >/dev/null 2>&1 || true
                rc-service argo stop >/dev/null 2>&1 || true
                rc-update del sing-box default >/dev/null 2>&1 || true
                rc-update del argo default >/dev/null 2>&1 || true
                rm -f /etc/init.d/sing-box /etc/init.d/argo
           else
                systemctl stop "${server_name}" argo >/dev/null 2>&1 || true
                systemctl disable "${server_name}" argo >/dev/null 2>&1 || true
                rm -f /etc/systemd/system/sing-box.service /etc/systemd/system/argo.service
                systemctl daemon-reload || true
            fi

           yellow "正在清理核心二进制文件与配置..."
           if [ -d "${work_dir}" ]; then
               rm -rf "${work_dir}"
           fi
           
           if [ -d /root/cert ]; then
                reading "是否删除证书目录 /root/cert ? (y/n): " delcert
                case "$delcert" in
                    y|Y) rm -rf /root/cert ;;
                    *) yellow "已保留证书目录" ;;
                esac
            fi
            
            reading "是否同时卸载 acme.sh 及自动续期任务？(y/n): " delacme
            case "$delacme" in
             y|Y)
                 if [ -f /root/.acme.sh/acme.sh ]; then
                      /root/.acme.sh/acme.sh --uninstall >/dev/null 2>&1
                 fi
                 rm -rf /root/.acme.sh
                 green "acme.sh 环境已清理"
                 ;;
                *) yellow "已保留 acme.sh 及自动续期配置" ;;
            esac
            
           green "\n✅ sing-box 及所有关联组件已彻底卸载完毕，当前环境已纯净。\n\n" && return
           ;;
       *)
           purple "已取消卸载操作\n\n"
           return
           ;;
   esac
}

change_config() {
    local singbox_status=$(check_singbox 2>/dev/null)
    local singbox_installed=$?
    
    if [ $singbox_installed -eq 2 ]; then
        yellow "sing-box 尚未安装！"
        sleep 1
        menu
        return
    fi
    
    clear
    echo ""
    green  "sing-box当前状态: $singbox_status\n"
    skyblue "------以下是一些常用的优选域名------"
    green " 1. cf.090227.xyz" 
    green " 2: cf.877774.xyz"
    green " 3: cf.877771.xyz"
    green " 4: cdns.doon.eu.org"  
    green " 5: cf.zhetengsha.eu.org" 
    green " 6: time.is"
    skyblue "------------"
    purple "0. 返回主菜单"
    skyblue "------------"
    reading "请输入选择: " choice
    case "${choice}" in
        0)  menu ;;
        *)  red "无效的选项！" ;; 
    esac
}

manage_singbox() {
    local singbox_status=$(check_singbox 2>/dev/null)
    
    clear
    echo ""
    green "=== sing-box 管理 ===\n"
    green "sing-box当前状态: $singbox_status\n"
    green "1. 启动sing-box服务"
    skyblue "-------------------"
    green "2. 停止sing-box服务"
    skyblue "-------------------"
    green "3. 重启sing-box服务"
    skyblue "-------------------"
    purple "0. 返回主菜单"
    skyblue "------------"
    reading "\n请输入选择: " choice
    case "${choice}" in
        1) start_singbox ;;  
        2) stop_singbox ;;
        3) restart_singbox ;;
        0) menu ;;
        *) red "无效的选项！" && sleep 1 && manage_singbox;;
    esac
}

manage_argo() {
    local argo_status=$(check_argo 2>/dev/null)

    clear
    echo ""
    green "=== Argo 隧道管理 ===\n"
    green "Argo当前状态: $argo_status\n"
    green "1. 启动Argo服务"
    skyblue "------------"
    green "2. 停止Argo服务"
    skyblue "------------"
    green "3. 重启Argo服务"
    skyblue "------------"
    green "4. 添加Argo固定隧道"
    skyblue "----------------"
    purple "0. 返回主菜单"
    skyblue "-----------"
    reading "\n请输入选择: " choice
    case "${choice}" in
        1)  start_argo ;;
        2)  stop_argo ;; 
        3)  clear
            if command_exists rc-service 2>/dev/null; then
                grep -Fq -- '--url http://localhost' /etc/init.d/argo && get_info || { green "\n当前使用固定隧道,无需获取临时域名"; sleep 2; menu; }
            else
                grep -q 'ExecStart=.*--url http://localhost' /etc/systemd/system/argo.service && get_info || { green "\n当前使用固定隧道,无需获取临时域名"; sleep 2; menu; }
            fi
         ;; 
        4)
            clear
            yellow "\n固定隧道可为json或token，固定隧道端口为8001，自行在cf后台设置\n"
            reading "\n请输入你的argo域名: " argo_domain
            ArgoDomain=$argo_domain
            reading "\n请输入你的argo密钥(token或json): " argo_auth
            if [[ $argo_auth =~ TunnelSecret ]]; then
                echo $argo_auth > ${work_dir}/tunnel.json
                cat > ${work_dir}/tunnel.yml << EOF
tunnel: $(cut -d\" -f12 <<< "$argo_auth")
credentials-file: ${work_dir}/tunnel.json
protocol: http2
                                           
ingress:
  - hostname: $ArgoDomain
    service: http://localhost:8001
    originRequest:
      noTLSVerify: true
  - service: http_status:404
EOF
                if command_exists rc-service 2>/dev/null; then
                    sed -i '/^command_args=/c\command_args="-c '\''/etc/sing-box/argo tunnel --edge-ip-version auto --config /etc/sing-box/tunnel.yml run 2>&1'\''"' /etc/init.d/argo
                else
                    sed -i '/^ExecStart=/c ExecStart=/bin/sh -c "/etc/sing-box/argo tunnel --edge-ip-version auto --config /etc/sing-box/tunnel.yml run 2>&1"' /etc/systemd/system/argo.service
                fi
                restart_argo
                sleep 1 
                change_argo_domain
            elif [[ $argo_auth =~ ^[A-Z0-9a-z=]{120,250}$ ]]; then
                if command_exists rc-service 2>/dev/null; then
                    sed -i "/^command_args=/c\command_args=\"-c '/etc/sing-box/argo tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token $argo_auth 2>&1'\"" /etc/init.d/argo
                else
                    sed -i '/^ExecStart=/c ExecStart=/bin/sh -c "/etc/sing-box/argo tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token '$argo_auth' 2>&1"' /etc/systemd/system/argo.service
                fi
                restart_argo
                sleep 1 
                change_argo_domain
            else
                yellow "你输入的argo域名或token不匹配，请重新输入"
                manage_argo            
            fi
            ;; 
        0)  menu ;; 
        *)  red "无效的选项！" ;;
    esac
}

change_argo_domain() {
    content=$(cat "$client_dir")
    vless_url=$(grep -Eo 'vless://[^ ]+' "$client_dir" | head -n 1)

    if [ -z "$vless_url" ]; then
        echo "❌ 未找到 VLESS 节点链接，请确认文件格式正确。"
        return
    fi

    new_vless_url=$(echo "$vless_url" \
    | sed -E "s/(sni=)[^&]+/\1${ArgoDomain}/g" \
    | sed -E "s/(host=)[^&]+/\1${ArgoDomain}/g")

    new_content=$(echo "$content" | sed "s|$vless_url|$new_vless_url|g")
    echo "$new_content" > "$client_dir"

    echo "$new_vless_url" > ${work_dir}/url.txt
    base64 -w0 ${work_dir}/url.txt > ${work_dir}/sub.txt

    green "\n✅ VLESS 节点已更新 Argo 域名，更新订阅或手动复制以下节点：\n "
    purple "$new_vless_url\n"
}

show_status(){
  local lines=()
  lines+=("$(yellow "Argo 状态: $argo_status") ｜ $(yellow "singbox 状态: $singbox_status")")
  
  if [[ -s "$config_dir" ]] && command -v jq >/dev/null 2>&1; then
    local cert_path
    cert_path="$(jq -r '.inbounds[]? | select(.type=="hysteria2") | .tls.certificate_path' "$config_dir" 2>/dev/null | head -n1 || true)"
    if [[ -n "$cert_path" && "$cert_path" != "null" ]]; then
      cert_dir="$(dirname "$cert_path")"
      lines+=("$(green "当前使用的证书：$cert_dir")")
    else
      lines+=("$(red "未检测到证书路径")")
    fi
  fi

  if [[ -s "$config_dir" ]] && command -v jq >/dev/null 2>&1; then
    local cpath enddate end_ts now_ts days enddate_cn
    cpath="$(jq -r '.inbounds[]? | select(.type=="hysteria2") | .tls.certificate_path' "$config_dir" 2>/dev/null | head -n1 || true)"
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
            lines+=("$(yellow "证书有效期至 $enddate_cn，剩余 $days 天")")
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

  lines+=("$(green "节点配置文件目录：$config_dir")")

  if [[ -x "$work_dir/sing-box" ]]; then
    local local_ver="$($work_dir/sing-box version 2>/dev/null | awk '/version/{print $NF}')"
  else
    local_ver="未安装"
  fi

  local latest_ver="$(curl -fsSL https://data.jsdelivr.com/v1/package/gh/SagerNet/sing-box | grep -Eo '\"[0-9]+\.[0-9]+\.[0-9]+\"' | tr -d '\"' | head -n1 || echo "未知")"
  lines+=("$(green "当前 Sing-box 版本：$local_ver") ｜ $(yellow "最新版本：$latest_ver")")

  if [[ -x "$work_dir/argo" ]]; then
    local argo_local_ver="$($work_dir/argo --version 2>/dev/null | awk '{print $3}')"
  else
    argo_local_ver="未安装"
  fi
  local argo_latest_ver="$(curl -fsSL "https://api.github.com/repos/cloudflare/cloudflared/releases/latest" 2>/dev/null | jq -r '.tag_name // empty' | tr -d 'v')"
  if [[ -z "$argo_latest_ver" ]]; then
      argo_latest_ver="$(curl -fsSL https://data.jsdelivr.com/v1/package/gh/cloudflare/cloudflared 2>/dev/null | jq -r '.versions[0] // empty' || echo "未知")"
  fi
  lines+=("$(green "当前 Argo 隧道版本：$argo_local_ver") ｜ $(yellow "最新版本：$argo_latest_ver")")

  bbr=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
  ipv4=$(curl -s4m5 icanhazip.com || echo "无IPv4")
  ipv6=$(curl -s6m5 icanhazip.com || echo "无IPv6")
  lines+=("本地IPV4地址：$ipv4   本地IPV6地址：$ipv6")
  local local_time cn_time
  local_time="$(date '+%Y-%m-%d %H:%M:%S %Z(%z)')"
  cn_time="$(TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M:%S %Z(+08:00)')"
  lines+=("$(yellow "状态刷新时间：$cn_time")")
  lines+=("$(yellow "BBR算法:$bbr")   $(yellow 脚本版本：Ver_2026.6.11)" ) 
  local W=72
  local purple=" \033[35m"; local reset=" \033[0m"
  local line; line=$(printf "%*s" "$W" "" | tr " " "-")

  printf "%b%s%b\n" "$purple" "$line" "$reset"
  for ln in "${lines[@]}"; do
    echo -e " $ln"
  done
  printf "%b%s%b\n\n" "$purple" "$line" "$reset"
}

update_components() {
    clear
    green "=== 更新核心组件 ==="
    yellow "1. 更新 sing-box 核心"
    yellow "2. 更新 Argo (Cloudflared) 隧道"
    purple "0. 返回主菜单"
    reading "请选择要更新的组件 [0-2]: " comp_choice

    case "${comp_choice}" in
        1) target_comp="sing-box" ;;
        2) target_comp="argo" ;;
        0) return ;;
        *) red "无效选择！"; sleep 1; update_components; return ;;
    esac

    echo ""
    yellow "1. 个人维护版本 (JaWaoo/singboxm 优化版)"
    if [ "$target_comp" == "sing-box" ]; then
        yellow "2. 官方最新版本 (SagerNet/sing-box 原版)"
    else
        yellow "2. 官方最新版本 (cloudflare/cloudflared 原版)"
    fi
    purple "0. 取消更新并返回"
    reading "请选择版本来源 [0-2]: " source_choice

    case "${source_choice}" in
        1) update_source="personal" ;;
        2) update_source="official" ;;
        0) return ;;
        *) red "无效选择！"; sleep 1; update_components; return ;;
    esac

    yellow "正在准备更新环境..."

    ARCH_RAW=$(uname -m)
    case "${ARCH_RAW}" in
        'x86_64') ARCH='amd64'; CF_ARCH='amd64' ;;
        'x86' | 'i686' | 'i386') ARCH='386'; CF_ARCH='386' ;;
        'aarch64' | 'arm64') ARCH='arm64'; CF_ARCH='arm64' ;;
        'armv7l') ARCH='armv7'; CF_ARCH='arm' ;;  
        's390x') ARCH='s390x'; CF_ARCH='amd64' ;; 
        *) red "不支持的架构: ${ARCH_RAW}"; return 1 ;;
    esac

    download_success=false

    if [ "$target_comp" == "sing-box" ]; then
        stop_singbox
        [ -f "${work_dir}/sing-box" ] && cp -f "${work_dir}/sing-box" "${work_dir}/sing-box.bak"

        if [ "$update_source" == "personal" ]; then
            yellow "正在拉取 sing-box 个人维护版本 (sb${ARCH})..."
            if curl -fsSL -o "${work_dir}/sing-box.new" "https://github.com/JaWaoo/singboxm/releases/latest/download/sb${ARCH}"; then
                download_success=true
            fi
        elif [ "$update_source" == "official" ]; then
            yellow "正在查询 API 获取 sing-box 官方最新版本..."
            LATEST_TAG=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | jq -r '.tag_name // empty')
            if [ -z "$LATEST_TAG" ]; then
                LATEST_TAG=$(curl -fsSL https://data.jsdelivr.com/v1/package/gh/SagerNet/sing-box | jq -r '.versions[0] // empty')
                [[ -n "$LATEST_TAG" ]] && LATEST_TAG="v${LATEST_TAG}"
            fi
            
            if [ -n "$LATEST_TAG" ]; then
                VERSION=${LATEST_TAG#v}
                TAR_NAME="sing-box-${VERSION}-linux-${ARCH}"
                DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/${LATEST_TAG}/${TAR_NAME}.tar.gz"
                
                green "锁定最新官方版本: ${LATEST_TAG}"
                yellow "开始下载并解包官方预编译环境..."
                
                if curl -fsSL -o "/tmp/${TAR_NAME}.tar.gz" "${DOWNLOAD_URL}"; then
                    tar -xzf "/tmp/${TAR_NAME}.tar.gz" -C /tmp/
                    if [ -f "/tmp/${TAR_NAME}/sing-box" ]; then
                        cp -f "/tmp/${TAR_NAME}/sing-box" "${work_dir}/sing-box.new"
                        rm -rf "/tmp/${TAR_NAME}" "/tmp/${TAR_NAME}.tar.gz"
                        download_success=true
                    fi
                fi
            fi
        fi

        if [ "$download_success" = true ]; then
            chmod +x "${work_dir}/sing-box.new"
            mv "${work_dir}/sing-box.new" "${work_dir}/sing-box"

            yellow "执行本地配置文件合法性校验..."
            if ${work_dir}/sing-box check -c ${config_dir}; then
                start_singbox
                new_ver=$(${work_dir}/sing-box version 2>/dev/null | awk '/version/{print $NF}')
                green "\n✅ sing-box 更新完毕！当前运行版本：${new_ver}"
                rm -f "${work_dir}/sing-box.bak"
            else
                red "❌ 新版本配置文件校验不通过，正在触发自动回滚机制..."
                mv -f "${work_dir}/sing-box.bak" "${work_dir}/sing-box" 2>/dev/null
                start_singbox
                return 1
            fi
        else
            red "❌ sing-box 下载或解包失败，正在恢复原始版本状态..."
            mv -f "${work_dir}/sing-box.bak" "${work_dir}/sing-box" 2>/dev/null
            start_singbox
            return 1
        fi

    elif [ "$target_comp" == "argo" ]; then
        stop_argo
        [ -f "${work_dir}/argo" ] && cp -f "${work_dir}/argo" "${work_dir}/argo.bak"

        if [ "$update_source" == "personal" ]; then
            yellow "正在拉取 Argo 个人维护版本 (cf${ARCH})..."
            if curl -fsSL -o "${work_dir}/argo.new" "https://github.com/JaWaoo/singboxm/releases/latest/download/cf${ARCH}"; then
                download_success=true
            fi
        elif [ "$update_source" == "official" ]; then
            yellow "正在拉取 Argo 官方最新二进制文件..."
            DOWNLOAD_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}"
            if curl -fsSL -o "${work_dir}/argo.new" "${DOWNLOAD_URL}"; then
                download_success=true
            fi
        fi

        if [ "$download_success" = true ]; then
            chmod +x "${work_dir}/argo.new"
            mv "${work_dir}/argo.new" "${work_dir}/argo"

            yellow "验证 Argo 二进制文件可用性..."
            if ${work_dir}/argo --version >/dev/null 2>&1; then
                start_argo
                new_ver=$(${work_dir}/argo --version 2>/dev/null | awk '{print $3}')
                green "\n✅ Argo 隧道 更新完毕！当前运行版本：${new_ver}"
                rm -f "${work_dir}/argo.bak"
            else
                red "❌ Argo 新版本文件校验失败 (可能由于架构不匹配)，正在回滚..."
                mv -f "${work_dir}/argo.bak" "${work_dir}/argo" 2>/dev/null
                start_argo
                return 1
            fi
        else
            red "❌ Argo 下载失败，正在恢复原始版本状态..."
            mv -f "${work_dir}/argo.bak" "${work_dir}/argo" 2>/dev/null
            start_argo
            return 1
        fi
    fi
    
    sleep 2
}

menu() {
   clear
   while true; do
   singbox_status=$(check_singbox 2>/dev/null)
   argo_status=$(check_argo 2>/dev/null)
   show_status
   
   green "1. 安装sing-box"
   red "2. 卸载sing-box"
   echo "==============="
   green "3. sing-box管理"
   green "4. Argo隧道管理"
   echo  "==============="
   green  "5. 常用优选域名查看"
   echo  "==============="
   green "6. Hy2证书相关"
   echo  "==============="
   green  "7. 更新singbox / cloudflare"
   echo  "==============="   
   purple "8. ssh综合工具箱"
   echo  "==============="
   red "0. 退出脚本"
   echo "==========="
   reading "请输入选择(0-8): " choice

   trap 'red "已取消操作"; exit' INT

   case "${choice}" in
        1)  
            check_singbox &>/dev/null; check_singbox=$?
            if [ ${check_singbox} -eq 0 ]; then
                yellow "sing-box 已经安装！\n"
            else
                install_singbox
                if command_exists systemctl; then
                    main_systemd_services
                elif command_exists rc-update; then
                    alpine_openrc_services
                    change_hosts
                    rc-service sing-box restart
                    rc-service argo restart
                else
                    echo "Unsupported init system"
                    exit 1 
                fi
                sleep 5
                get_info
            fi
           ;;
        2) uninstall_singbox ;;
        3) manage_singbox ;;
        4) manage_argo ;;
        5) change_config ;;
        6) apply_certificate_menu ;;
        7) update_components ;;
        8) 
           clear
           bash <(curl -Ls https://raw.githubusercontent.com/JaWaoo/singboxm/refs/heads/main/ssh_tools)
           ;;           
        0) exit 0 ;;
        *) red "无效的选项，请输入 0 到 8" ;;
   esac
   read -n 1 -s -r -p $'\033[1;91m按任意键返回...\033[0m'
done
}

menu