#!/bin/bash

C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_BLUE='\033[0;34m'
C_RESET='\033[0m'

REG_DOMAIN="^[a-zA-Z0-9][a-zA-Z0-9-]{1,61}[a-zA-Z0-9]\.[a-zA-Z]{2,}$"
REG_EMAIL="^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$"

DOMAIN=${cert_domain:-}
EMAIL=${cert_email:-}
BIND_IP=0.0.0.0

USER=${user:-}
PASS=${pass:-}

ENCRYPT_TYPE=${encrypt_type:-}

PORT_SHADOWSOCKS=${port_shadowsocks:-}
PORT_HTTP2=${port_http2:-}
PORT_WSS=${port_wss:-}

CERT_DIR=/etc/letsencrypt

# fetch current ip
get_current_ip() {
    if command -v curl > /dev/null 2>&1; then
        curl -s https://ipinfo.io/ip
    elif command -v wget > /dev/null 2>&1; then
        wget -qO- https://ipinfo.io/ip
    fi
}

# fetch current domain
get_domain_ip() {
    local domain="$1"

    if command -v dig > /dev/null 2>&1; then
        dig +short "$domain" @8.8.8.8 | head -n 1
    elif command -v nslookup > /dev/null 2>&1; then
        nslookup "$domain" | awk '/^Address: / { print $2 }' | head -n 1
    fi
}

# Determine if the current domain is bound to the current IP address.
check_domain_ip() {
    local domain="$1"
    local current_ip
    local domain_ip

    current_ip=$(get_current_ip)
    domain_ip=$(get_domain_ip "$domain")

    if [ "$current_ip" != "$domain_ip" ]; then
        echo -e "${C_RED}域名 $domain（绑定在 $domain_ip）未绑定到当前机器 IP：$current_ip${C_RESET}"
        echo -e "${C_RED}请先完成域名的绑定后（$domain: $current_ip）重新执行本脚本${C_RESET}"
        return 1
    else 
        echo -e "${C_YELLOW}检测到域名 $domain 已经绑定到当前机器 IP $current_ip${C_RESET}"
    fi
}

# Test if the port is accessible from the outside."
test_port() {
    local host="$1"
    local port="$2"

    echo -e "${C_YELLOW}正在检测代理程序是否正常启动${C_RESET}"
    # Check after 5 seconds to avoid network anomalies during initial connection establishment.
    sleep 5s

    if echo "quit" | telnet -E "$host" "$port" 2>/dev/null | grep -q Connected; then
        echo "端口 $host:$port 能够被正常访问"
        return 0
    else
        echo -e "${C_RED}端口测试：$host:$port，不可访问，请确保防火墙已经开启了端口的访问${C_RESET}"
        echo ""
        return 1
    fi
}

# Ensure the correct DOMAIN is set.
ensure_domain() {
    if [ -z "$DOMAIN" ]; then
        read -p "域名（domain）的值，请输入：" DOMAIN
    fi
}

# Ensure the correct EMAIL is set.
ensure_email() {
    if [ -z "$EMAIL" ]; then
        read -p "邮箱（email）的值，请输入：" EMAIL
    fi
}

# Ensure the correct USER is set.
ensure_user() {
    if [ -z "$USER" ]; then
        read -p "账户名（user）的值，请输入：" USER
    fi
}

# Ensure the correct PASS is set.
ensure_pass() {
    if [ -z "$PASS" ]; then
        read -sp "密码（pass）的值，请输入：" PASS
        echo ""
    fi
}

# Ensure the correct ENCRYPT_TYPE is set.
ensure_encrypt_type() {
    if [ -z "$ENCRYPT_TYPE" ]; then
        read -p "加密方式（encrypt_type）的值，请输入（如 aes-256-cfb）：" ENCRYPT_TYPE
    fi

    local valid_types=("aes-256-cfb" "other-valid-type")
    for valid_type in "${valid_types[@]}"; do
        if [ "$ENCRYPT_TYPE" == "$valid_type" ]; then
            echo "当前加密方式是：$ENCRYPT_TYPE"
            return 0
        fi
    done
    unset ENCRYPT_TYPE
    ensure_encrypt_type
}

# Ensure the correct PORT_ is set.
ensure_valid_port() {
  local port_variable_name="$1"
  local port_value
  while true; do
    port_value=${!port_variable_name}

    if [ -z "$port_value" ]; then
      local pval=$(echo $port_variable_name | tr '[:upper:]' '[:lower:]')
      read -p "端口（$pval），请输入：" port_value
    fi

    if validate_port "$port_value"; then
      eval "$port_variable_name=$port_value"
      break
    else
      echo "无效的端口，请重新输入"
    fi

    if netstat -tuln | grep -wq "$1"; then
        echo "端口 $port_value 被占用，请重新输入"
    fi
  done

  # open iptables
  iptables -A INPUT -p tcp --dport $port_value -j ACCEPT
  iptables -I OUTPUT -p tcp --sport $port_value -j ACCEPT
}

# Ensure an unoccupied port is set
validate_port() {
    local port="$1"
    if [ -z "$port" ]; then
        echo -e "${C_RED}端口不能为空。${C_RESET}"
        return 1
    elif [[ ! $port =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        echo -e "${C_RED}端口必须是 1 到 65535 之间的整数。${C_RESET}"
        return 1
    elif (sudo ss -tuln | grep -q ":$port "); then
        echo -e "${C_RED}端口已被占用，请选择其他端口。${C_RESET}"
        return 1
    fi
    return 0
}

# Detect if the user is root.
is_sudo_user() {
    if [ "$EUID" -eq 0 ]; then
        return 0
    else
        echo -e "${C_RED}此程序未使用 sudo（或以非 root 用户身份）执行${C_RESET}"
        return 1
    fi
}

# Detect if the system is Debian.
is_debian() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [[ "$ID" == "debian" ]]; then
            return 0
        else
            echo -e "${C_RED}这不是一个 Debian 系统${C_RESET}"
            return 1
        fi
    else
        echo -e "${C_RED}无法确定您的系统类型${C_RESET}"
        return 1
    fi
}

# Determine if the Docker process has started.
is_docker_container_running() {
  container_name="$1"
  if [ "$(docker ps -q -f name="$container_name")" ]; then
    return 0
  else
    return 1
  fi
}

# install dependencies, like curl/wget/dig/nslookup
install_dependencies() {
    echo -e "${C_BLUE}正在更新 source 源${C_RESET}"
    sudo apt-get update > /dev/null
    sudo apt-get -y install curl wget net-tools dnsutils > /dev/null
}

# install docker
install_docker() {
    if ! command -v docker > /dev/null 2>&1; then
        echo -e "${C_YELLOW}检测到未安装 Docker，正在安装${C_RESET}"
        sudo apt-get -y install ca-certificates curl gnupg > /dev/null 2>&1
        sudo mkdir -m 0755 -p /etc/apt/keyrings > /dev/null 2>&1
        curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg > /dev/null 2>&1
        echo \
        "deb [arch="$(dpkg --print-architecture)" signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
        "$(. /etc/os-release && echo "$VERSION_CODENAME")" stable" | \
        sudo tee /etc/apt/sources.list.d/docker.list > /dev/null 2>&1
        sudo apt-get update > /dev/null 2>&1
        sudo apt-get -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin > /dev/null 2>&1
        sudo apt autoremove -y > /dev/null 2>&1
    fi
}

# install certificates
install_cert() {
    ensure_domain

    CERT_FILE="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
    if [ -f "$CERT_FILE" ]; then
        echo -e "${C_GREEN}域名 $DOMAIN 的证书已经存在，省略证书安装步骤${C_RESET}"
        return 0
    fi

    # Check if the domain has been correctly A-recorded to the current machine's IP.
    if ! check_domain_ip "$DOMAIN"; then
        exit 1
    fi

    ensure_email

    echo -e "${C_YELLOW}检测到 $DOMAIN 没有安装证书，正在使用 docker+certbot 安装证书${C_RESET}"
    sudo docker pull certbot/certbot > /dev/null
    sudo docker container prune -f > /dev/null
    sudo docker run -it --rm --name certbot \
        -v "/etc/letsencrypt:/etc/letsencrypt" \
        -v "/var/lib/letsencrypt:/var/lib/letsencrypt" \
        --net=host certbot/certbot certonly -d $DOMAIN --standalone --email $EMAIL --agree-tos --no-eff-email > /tmp/install-proxy.log 2>&1

    # Check if the certificate file exists before the program execution ends.
    max_attempts=60

    for ((attempt=1; attempt<=max_attempts; attempt++)); do
    if [ -f "$CERT_FILE" ]; then
        echo "生成 $DOMAIN 的证书成功"
        break
    else
        sleep 1s
    fi
    done

    if [ $attempt -gt $max_attempts ]; then
        echo "轮训证书超时，请求稍后人工确认 $CERT_FILE 证书是否生成成功，再重新执行改脚本"
        echo "如需查看详细日志，请执行 cat /tmp/install-proxy.log"
        exit 1
    fi

    # auto update certificates
    (crontab -l 2>/dev/null; echo "0 0 1 * * /usr/bin/certbot renew --force-renewal") | crontab -

}

# setup shadowsocks proxy
setup_shadowsocks() {
    local docker_name=gost-ss
    echo -e "${C_BLUE}> 正在进行 Shadowsocks 代理设置，需要配置有效端口/加密方式${C_RESET}"

    install_docker
    if is_docker_container_running "$docker_name"; then
        echo -e "${C_GREEN}$docker_name 代理已经成功启动，使用 docker logs $docker_name 查看日志${C_RESET}"
        echo ""
        return
    fi

    ensure_valid_port PORT_SHADOWSOCKS
    ensure_encrypt_type
    ensure_pass

    echo -e "${C_YELLOW}正在使用 docker+gost 启动 Shadowsocks 代理${C_RESET}"
    sudo docker pull ginuerzh/gost > /dev/null
    sudo docker container prune -f > /dev/null
    sudo docker run -d --name $docker_name \
        --net=host ginuerzh/gost \
        -L "ss://${ENCRYPT_TYPE}:${PASS}@0.0.0.0:${PORT_SHADOWSOCKS}" > /tmp/install-proxy.log 2>&1

    if ! is_docker_container_running "$container_name"; then
        echo "$docker_name 启动失败，使用 docker logs $docker_name 查看错误日志"
        return
    fi

    local domain=${DOMAIN:-"127.0.0.1"}
    if test_port $domain $PORT_SHADOWSOCKS; then
        echo -e "${C_BLUE}已经成功启动了 $docker_name 代理程序${C_RESET}"
        echo "对应配置：ss://${ENCRYPT_TYPE}:${PASS}@${domain}:${PORT_SHADOWSOCKS}"
        echo ""
    fi
}

# setup websockets proxy
setup_websockets() {
    local docker_name=gost-ws
    echo -e "${C_BLUE}> 正在进行 Websockets 代理设置，需要配置账户名/密码/端口/域名/邮箱，邮箱和域名用于证书配置${C_RESET}"

    install_docker
    if is_docker_container_running "$docker_name"; then
        echo -e "${C_GREEN}$docker_name 代理已经成功启动，使用 docker logs $docker_name 查看日志${C_RESET}"
        echo ""
        return
    fi
    
    ensure_valid_port PORT_WSS
    ensure_user
    ensure_pass

    install_cert

    echo -e "${C_YELLOW}正在使用 docker+gost 启动 Websockets 代理${C_RESET}"
    CERT=${CERT_DIR}/live/${DOMAIN}/fullchain.pem
    KEY=${CERT_DIR}/live/${DOMAIN}/privkey.pem
    sudo docker pull ginuerzh/gost > /dev/null
    sudo docker container prune -f > /dev/null
    sudo docker run -d --name $docker_name \
        -v ${CERT_DIR}:${CERT_DIR}:ro \
        --net=host ginuerzh/gost \
        -L "mwss://${USER}:${PASS}@${BIND_IP}:${PORT_WSS}?cert=${CERT}&key=${KEY}" > /tmp/install-proxy.log 2>&1

    if ! is_docker_container_running "$container_name"; then
        echo "$docker_name 启动失败，使用 docker logs $docker_name 查看错误日志"
        return
    fi

    if test_port $DOMAIN $PORT_WSS; then
        echo -e "${C_BLUE}已经成功启动了 $docker_name 代理程序${C_RESET}"
        echo "对应配置：wss://${USER}:${PASS}@${DOMAIN}:${PORT_WSS}"
        echo ""
    fi
}

# setup http2 proxy
setup_http2() {
    local docker_name=gost-http2
    echo -e "${C_BLUE}> 正在进行 HTTP/2 代理设置，需要配置账户名/密码/端口/域名/邮箱，邮箱和域名用于证书配置${C_RESET}"

    install_docker
    if is_docker_container_running "$docker_name"; then
        echo -e "${C_GREEN}$docker_name 代理已经成功启动，使用 docker logs $docker_name 查看日志${C_RESET}"
        echo ""
        return
    fi

    ensure_valid_port PORT_HTTP2
    ensure_user
    ensure_pass

    install_cert

    echo -e "${C_YELLOW}正在使用 docker+gost 启动 http2 代理${C_RESET}"
    CERT=${CERT_DIR}/live/${DOMAIN}/fullchain.pem
    KEY=${CERT_DIR}/live/${DOMAIN}/privkey.pem
    sudo docker pull ginuerzh/gost > /dev/null
    sudo docker container prune -f > /dev/null
    sudo docker run -d --name $docker_name \
        -v ${CERT_DIR}:${CERT_DIR}:ro \
        --net=host ginuerzh/gost \
        -L "http2://${USER}:${PASS}@${BIND_IP}:${PORT_HTTP2}?cert=${CERT}&key=${KEY}" > /tmp/install-proxy.log 2>&1

    if ! is_docker_container_running "$container_name"; then
        echo "$docker_name 启动失败，使用 docker logs $docker_name 查看错误日志"
        return
    fi

    if test_port $DOMAIN $PORT_HTTP2; then
        echo -e "${C_BLUE}已经成功启动了 $docker_name 代理程序${C_RESET}"
        echo "测试方法：curl -IL https://www.google.com --proxy https://${USER}:${PASS}@${DOMAIN}:${PORT_HTTP2}"
        echo ""
    fi
}

# choose proxy types
select_proxy() {
    echo "===================================================="
    echo "请选择要实现的代理类型（输入多个序号，以空格分隔）："
    echo "1. Shadowsocks"
    echo "2. Websockets"
    echo "3. HTTP/2"
    echo "===================================================="

    local choices
    read -rp "输入序号：" -a choices

    for choice in "${choices[@]}"; do
        case $choice in
            1)
                setup_shadowsocks
                ;;
            2)
                setup_websockets
                ;;
            3)
                setup_http2
                ;;
            *)
                echo "无效的选择：$choice"
                ;;
        esac
    done
}

print_banner() {
    echo "===================================================="
    echo "Proxyer - v1.0.0"
    echo "https://github.com/barretlee/proxyer"
    echo ""
    echo "使用方法："
    echo "  chmod +x install.sh && ./install.sh"
    echo ""
    echo "使用建议："
    echo "  - 将域名的解析放到 Cloudflare 上"
    echo "===================================================="
}

# entry point
main() {

    print_banner

    if ! is_sudo_user; then
        return 1
    fi
    if ! is_debian; then
        return 2
    fi

    set -e
    sudo dmesg -n 4

    install_dependencies
    select_proxy
}

main
