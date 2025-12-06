#!/bin/bash

# ============================================================================
# Hysteria v2 Server Installer and Management Script
# ============================================================================
# Этот скрипт автоматизирует установку, настройку и управление сервером 
# Hysteria v2 на VPS Linux. Структура и логика аналогичны популярному 
# скрипту установки 3x-ui для Xray, но адаптированы для Hysteria v2.
#
# Hysteria - это мощный набор инструментов для обхода цензуры, 
# использующий собственный протокол на основе QUIC.
#
# Использование:
#   ./hysteria_installer.sh install   - Установить и настроить Hysteria
#   ./hysteria_installer.sh start     - Запустить сервис
#   ./hysteria_installer.sh stop      - Остановить сервис
#   ./hysteria_installer.sh restart   - Перезапустить сервис
#   ./hysteria_installer.sh status    - Показать статус сервиса
#   ./hysteria_installer.sh log       - Показать логи
#   ./hysteria_installer.sh update    - Обновить Hysteria
#   ./hysteria_installer.sh uninstall - Удалить Hysteria
#   ./hysteria_installer.sh           - Показать меню
# ============================================================================

# Цветовые переменные для стилизации вывода (аналогично 3x-ui)
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
blue='\033[0;36m'
plain='\033[0m'

# Глобальные переменные
HYSTERIA_BIN="/usr/local/bin/hysteria"
HYSTERIA_CONFIG_DIR="/etc/hysteria"
HYSTERIA_CONFIG_FILE="${HYSTERIA_CONFIG_DIR}/config.yaml"
HYSTERIA_SERVICE="/etc/systemd/system/hysteria.service"
HYSTERIA_LOG="/var/log/hysteria.log"
HYSTERIA_UI_DIR="/opt/hysteria-ui"
HYSTERIA_UI_SERVICE="/etc/systemd/system/hysteria-ui.service"

# ============================================================================
# Проверка прав root (аналогично 3x-ui)
# ============================================================================
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${red}Ошибка: Этот скрипт должен быть запущен с правами root!${plain}"
        echo -e "${yellow}Используйте: sudo $0${plain}"
        exit 1
    fi
}

# ============================================================================
# Определение архитектуры CPU (аналогично 3x-ui)
# ============================================================================
arch() {
    case "$(uname -m)" in
        x86_64 | x64 | amd64)
            echo "amd64"
            ;;
        i*86 | x86)
            echo "386"
            ;;
        aarch64 | arm64)
            echo "arm64"
            ;;
        armv7* | armv6* | arm)
            echo "arm"
            ;;
        s390x)
            echo "s390x"
            ;;
        *)
            echo -e "${red}Неподдерживаемая архитектура: $(uname -m)${plain}"
            exit 1
            ;;
    esac
}

# ============================================================================
# Проверка версии GLIBC (требуется >= 2.27 для Hysteria v2)
# Аналогично проверке в 3x-ui, но с изменённой требуемой версией
# ============================================================================
check_glibc_version() {
    echo -e "${blue}Проверка версии GLIBC...${plain}"
    
    if ! command -v ldd &> /dev/null; then
        echo -e "${yellow}Внимание: ldd не найден, пропускаем проверку GLIBC${plain}"
        return 0
    fi
    
    local glibc_version=$(ldd --version | head -n1 | grep -oP '\d+\.\d+' | head -n1)
    
    if [[ -z "$glibc_version" ]]; then
        echo -e "${yellow}Внимание: Не удалось определить версию GLIBC${plain}"
        return 0
    fi
    
    local required_version="2.27"
    
    if awk "BEGIN {exit !($glibc_version >= $required_version)}"; then
        echo -e "${green}GLIBC версия $glibc_version >= $required_version - OK${plain}"
        return 0
    else
        echo -e "${red}Ошибка: GLIBC версия $glibc_version < $required_version${plain}"
        echo -e "${red}Hysteria v2 требует GLIBC >= $required_version${plain}"
        echo -e "${yellow}Обновите вашу систему или используйте более новый дистрибутив${plain}"
        exit 1
    fi
}

# ============================================================================
# Установка базовых зависимостей (аналогично 3x-ui)
# ============================================================================
install_base() {
    echo -e "${blue}Установка базовых зависимостей...${plain}"
    
    # Определение типа пакетного менеджера
    if command -v apt-get &>/dev/null; then
        # Debian/Ubuntu
        echo -e "${green}Обнаружен APT (Debian/Ubuntu)${plain}"
        apt-get update
        apt-get install -y wget curl tar tzdata qrencode ca-certificates python3 python3-pip python3-venv openssl
        
    elif command -v yum &>/dev/null; then
        # CentOS/RHEL
        echo -e "${green}Обнаружен YUM (CentOS/RHEL)${plain}"
        yum update -y
        yum install -y wget curl tar tzdata qrencode ca-certificates python3 python3-pip openssl
        
    elif command -v dnf &>/dev/null; then
        # Fedora
        echo -e "${green}Обнаружен DNF (Fedora)${plain}"
        dnf update -y
        dnf install -y wget curl tar tzdata qrencode ca-certificates python3 python3-pip openssl
        
    elif command -v zypper &>/dev/null; then
        # OpenSUSE
        echo -e "${green}Обнаружен Zypper (OpenSUSE)${plain}"
        zypper refresh
        zypper install -y wget curl tar timezone qrencode ca-certificates python3 python3-pip openssl
        
    elif command -v pacman &>/dev/null; then
        # Arch Linux
        echo -e "${green}Обнаружен Pacman (Arch Linux)${plain}"
        pacman -Sy --noconfirm wget curl tar tzdata qrencode ca-certificates python python-pip openssl
        
    else
        echo -e "${red}Ошибка: Неподдерживаемый пакетный менеджер${plain}"
        exit 1
    fi
    
    echo -e "${green}Базовые зависимости установлены${plain}"
}

# ============================================================================
# Генерация случайной строки (аналогично gen_random_string из 3x-ui)
# ============================================================================
gen_random_string() {
    local length=${1:-32}
    tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$length"
}

# ============================================================================
# Установка Hysteria v2
# ============================================================================
install_hysteria() {
    echo -e "${blue}Начало установки Hysteria v2...${plain}"
    
    # Проверка GLIBC
    check_glibc_version
    
    # Определение архитектуры
    local cpu_arch=$(arch)
    echo -e "${green}Архитектура: $cpu_arch${plain}"
    
    # Получение последней версии с GitHub API
    echo -e "${blue}Получение информации о последней версии...${plain}"
    local latest_version=$(curl -s https://api.github.com/repos/apernet/hysteria/releases/latest | grep -Po '"tag_name": "\K.*?(?=")')
    
    if [[ -z "$latest_version" ]]; then
        echo -e "${red}Ошибка: Не удалось получить информацию о последней версии${plain}"
        exit 1
    fi
    
    # Сохраняем версию с префиксом 'v' для тега
    echo -e "${green}Последняя версия: $latest_version${plain}"
    
    # Формирование имени файла
    local download_file="hysteria-linux-${cpu_arch}"
    local download_url="https://github.com/apernet/hysteria/releases/download/${latest_version}/${download_file}"
    
    echo -e "${blue}Скачивание Hysteria v2...${plain}"
    echo -e "${yellow}URL: $download_url${plain}"
    
    # Скачивание бинарного файла
    if ! wget -O /tmp/hysteria "$download_url"; then
        echo -e "${red}Ошибка: Не удалось скачать Hysteria${plain}"
        exit 1
    fi
    
    # Установка бинарного файла
    echo -e "${blue}Установка бинарного файла...${plain}"
    chmod +x /tmp/hysteria
    mv /tmp/hysteria "$HYSTERIA_BIN"
    
    # Проверка установки
    if "$HYSTERIA_BIN" version &>/dev/null; then
        echo -e "${green}Hysteria v2 успешно установлен: $("$HYSTERIA_BIN" version)${plain}"
    else
        echo -e "${yellow}Внимание: Не удалось проверить версию Hysteria${plain}"
    fi
}

# ============================================================================
# Установка acme.sh для получения TLS сертификатов
# ============================================================================
install_acme() {
    if [[ -f ~/.acme.sh/acme.sh ]]; then
        echo -e "${green}acme.sh уже установлен${plain}"
        return 0
    fi
    
    echo -e "${blue}Установка acme.sh...${plain}"
    curl https://get.acme.sh | sh
    
    if [[ -f ~/.acme.sh/acme.sh ]]; then
        echo -e "${green}acme.sh успешно установлен${plain}"
        # Включение автоматического обновления
        ~/.acme.sh/acme.sh --upgrade --auto-upgrade
        return 0
    else
        echo -e "${red}Ошибка: Не удалось установить acme.sh${plain}"
        return 1
    fi
}

# ============================================================================
# Получение TLS сертификата с помощью acme.sh
# ============================================================================
obtain_certificate() {
    local domain=$1
    
    echo -e "${blue}Получение TLS сертификата для домена: $domain${plain}"
    
    # Остановка Hysteria если запущен (для освобождения порта 80)
    if systemctl is-active --quiet hysteria; then
        echo -e "${yellow}Остановка Hysteria для получения сертификата...${plain}"
        systemctl stop hysteria
    fi
    
    # Получение сертификата через standalone режим
    ~/.acme.sh/acme.sh --issue -d "$domain" --standalone --keylength ec-256
    
    if [[ $? -ne 0 ]]; then
        echo -e "${red}Ошибка: Не удалось получить сертификат${plain}"
        echo -e "${yellow}Убедитесь, что:${plain}"
        echo -e "${yellow}1. Домен $domain указывает на IP этого сервера${plain}"
        echo -e "${yellow}2. Порты 80 и 443 открыты в файрволе${plain}"
        echo -e "${yellow}3. На сервере не запущены другие веб-серверы на порту 80${plain}"
        return 1
    fi
    
    # Создание директории для сертификатов
    mkdir -p "$HYSTERIA_CONFIG_DIR"
    
    # Установка сертификатов в директорию Hysteria
    ~/.acme.sh/acme.sh --install-cert -d "$domain" --ecc \
        --key-file "${HYSTERIA_CONFIG_DIR}/private.key" \
        --fullchain-file "${HYSTERIA_CONFIG_DIR}/cert.crt"
    
    if [[ $? -eq 0 ]]; then
        echo -e "${green}Сертификат успешно установлен${plain}"
        chmod 644 "${HYSTERIA_CONFIG_DIR}/cert.crt"
        chmod 600 "${HYSTERIA_CONFIG_DIR}/private.key"
        return 0
    else
        echo -e "${red}Ошибка: Не удалось установить сертификат${plain}"
        return 1
    fi
}

# ============================================================================
# Установка веб-панели Hysteria UI
# ============================================================================
install_web_panel() {
    echo -e "${blue}Установка веб-панели Hysteria UI...${plain}"
    
    # Создание директории
    mkdir -p "$HYSTERIA_UI_DIR"
    
    # Определение текущей директории скрипта
    SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
    
    # Копирование файлов веб-панели
    if [[ -d "${SCRIPT_DIR}/web" ]]; then
        echo -e "${blue}Копирование файлов веб-панели...${plain}"
        cp -r "${SCRIPT_DIR}/web/"* "$HYSTERIA_UI_DIR/"
    else
        echo -e "${yellow}Директория web/ не найдена, скачиваем с GitHub...${plain}"
        
        # Скачивание файлов с GitHub (если репозиторий существует)
        cd "$HYSTERIA_UI_DIR"
        
        # Создание основных файлов если их нет
        mkdir -p templates static
        
        echo -e "${red}Файлы веб-панели не найдены. Разместите директорию 'web/' рядом со скриптом${plain}"
        return 1
    fi
    
    # Установка Python зависимостей
    echo -e "${blue}Установка Python зависимостей...${plain}"
    cd "$HYSTERIA_UI_DIR"
    
    # Создание виртуального окружения
    echo -e "${blue}Создание виртуального окружения Python...${plain}"
    python3 -m venv venv
    
    # Активация виртуального окружения и установка зависимостей
    source venv/bin/activate
    
    if [[ -f "requirements.txt" ]]; then
        pip install --upgrade pip
        pip install -r requirements.txt
    else
        pip install Flask Werkzeug qrcode Pillow PyYAML
    fi
    
    deactivate
    
    # Определение адреса сервера из конфига Hysteria
    echo -e "${blue}Определение адреса сервера...${plain}"
    local server_address=""
    local insecure_flag="1"
    
    if [[ -f "${HYSTERIA_CONFIG_DIR}/server_address.txt" ]]; then
        server_address=$(cat "${HYSTERIA_CONFIG_DIR}/server_address.txt")
        echo -e "${green}Адрес из конфига: $server_address${plain}"
    else
        server_address=$(curl -s4 ifconfig.me || curl -s4 icanhazip.com || echo "")
        echo -e "${green}Обнаружен IP: $server_address${plain}"
    fi
    
    if [[ -f "${HYSTERIA_CONFIG_DIR}/insecure_flag.txt" ]]; then
        insecure_flag=$(cat "${HYSTERIA_CONFIG_DIR}/insecure_flag.txt")
    fi
    
    # Обновление server_ip в базе данных после её инициализации
    if [[ -n "$server_address" ]]; then
        # Запустим Python скрипт для обновления настроек в БД
        cat > "${HYSTERIA_UI_DIR}/update_settings.py" <<PYEOF
import sqlite3
import sys

db_path = '/opt/hysteria-ui/hysteria.db'
server_address = sys.argv[1] if len(sys.argv) > 1 else ''
insecure_flag = sys.argv[2] if len(sys.argv) > 2 else '1'

if server_address:
    conn = sqlite3.connect(db_path)
    c = conn.cursor()
    c.execute("UPDATE settings SET value=? WHERE key='server_ip'", (server_address,))
    c.execute("INSERT OR REPLACE INTO settings (key, value) VALUES ('insecure_flag', ?)", (insecure_flag,))
    conn.commit()
    conn.close()
    print(f"Адрес обновлён в базе данных: {server_address}")
    print(f"Флаг insecure: {insecure_flag}")
else:
    print("Адрес не указан")
PYEOF
        
        # Запускаем Python скрипт для обновления настроек
        ${HYSTERIA_UI_DIR}/venv/bin/python3 "${HYSTERIA_UI_DIR}/update_settings.py" "$server_address" "$insecure_flag"
    else
        echo -e "${yellow}Не удалось определить адрес автоматически${plain}"
    fi
    
    # Создание systemd сервиса для веб-панели
    echo -e "${blue}Создание systemd сервиса для веб-панели...${plain}"
    
    cat > "$HYSTERIA_UI_SERVICE" <<EOF
[Unit]
Description=Hysteria UI Web Panel
After=network.target hysteria.service

[Service]
Type=simple
User=root
WorkingDirectory=${HYSTERIA_UI_DIR}
ExecStart=${HYSTERIA_UI_DIR}/venv/bin/python3 ${HYSTERIA_UI_DIR}/app.py
Restart=on-failure
RestartSec=10s

[Install]
WantedBy=multi-user.target
EOF

    # Перезагрузка systemd и запуск сервиса
    systemctl daemon-reload
    systemctl enable hysteria-ui
    systemctl start hysteria-ui
    
    sleep 3
    if systemctl is-active --quiet hysteria-ui; then
        echo -e "${green}✓ Веб-панель Hysteria UI успешно запущена!${plain}"
        
        # Ждем инициализации БД и обновляем настройки
        sleep 2
        if [[ -f "${HYSTERIA_UI_DIR}/update_settings.py" ]] && [[ -n "$server_address" ]]; then
            echo -e "${blue}Обновление настроек в базе данных...${plain}"
            ${HYSTERIA_UI_DIR}/venv/bin/python3 "${HYSTERIA_UI_DIR}/update_settings.py" "$server_address" "$insecure_flag"
        fi
        
        return 0
    else
        echo -e "${red}✗ Ошибка запуска веб-панели${plain}"
        echo -e "${yellow}Проверьте логи: journalctl -u hysteria-ui -n 50${plain}"
        return 1
    fi
}

# ============================================================================
# Генерация самоподписанного сертификата
# ============================================================================
generate_self_signed_cert() {
    local domain="$1"
    [[ -z "$domain" ]] && domain="hysteria.local"
    
    echo -e "${blue}Генерация самоподписанного сертификата для ${domain}...${plain}"
    
    mkdir -p "$HYSTERIA_CONFIG_DIR"
    
    # Генерация приватного ключа и сертификата
    openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
        -keyout "${HYSTERIA_CONFIG_DIR}/private.key" \
        -out "${HYSTERIA_CONFIG_DIR}/cert.crt" \
        -subj "/CN=${domain}" \
        -days 36500 2>/dev/null
    
    if [[ $? -eq 0 ]]; then
        chmod 644 "${HYSTERIA_CONFIG_DIR}/cert.crt"
        chmod 600 "${HYSTERIA_CONFIG_DIR}/private.key"
        echo -e "${green}✓ Самоподписанный сертификат создан для ${domain}${plain}"
        return 0
    else
        echo -e "${red}✗ Ошибка: Не удалось создать сертификат${plain}"
        return 1
    fi
}

# ============================================================================
# Настройка собственного SSL сертификата
# ============================================================================
setup_custom_cert() {
    echo -e "${blue}═══════════════ Настройка собственного SSL сертификата ═══════════════${plain}"
    
    read -p "Введите путь к файлу сертификата (.crt/.pem): " cert_file
    read -p "Введите путь к приватному ключу (.key): " key_file
    
    # Проверка существования файлов
    if [[ ! -f "$cert_file" ]]; then
        echo -e "${red}✗ Файл сертификата не найден: $cert_file${plain}"
        return 1
    fi
    
    if [[ ! -f "$key_file" ]]; then
        echo -e "${red}✗ Файл ключа не найден: $key_file${plain}"
        return 1
    fi
    
    # Копирование сертификатов
    mkdir -p "$HYSTERIA_CONFIG_DIR"
    cp "$cert_file" "${HYSTERIA_CONFIG_DIR}/cert.crt"
    cp "$key_file" "${HYSTERIA_CONFIG_DIR}/private.key"
    
    chmod 644 "${HYSTERIA_CONFIG_DIR}/cert.crt"
    chmod 600 "${HYSTERIA_CONFIG_DIR}/private.key"
    
    echo -e "${green}✓ SSL сертификат успешно настроен${plain}"
    return 0
}

# ============================================================================
# Настройка Hysteria v2
# ============================================================================
config_hysteria() {
    echo -e "${blue}╔═══════════════════════════════════════════════════════════════╗${plain}"
    echo -e "${blue}║              Настройка Hysteria v2 сервера                    ║${plain}"
    echo -e "${blue}╚═══════════════════════════════════════════════════════════════╝${plain}\n"
    
    # Выбор типа адреса (IP или домен)
    local server_address
    local use_domain=false
    local insecure_flag="1"
    
    echo -e "${yellow}Выберите тип адреса сервера:${plain}"
    echo -e "  ${green}1)${plain} IP адрес"
    echo -e "  ${green}2)${plain} Доменное имя"
    read -p "Ваш выбор [1-2]: " address_choice
    
    case "$address_choice" in
        2)
            use_domain=true
            read -p "Введите доменное имя (например, vpn.example.com): " server_address
            
            # Проверка корректности домена
            if [[ ! "$server_address" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,61}[a-zA-Z0-9]?(\.[a-zA-Z0-9][a-zA-Z0-9-]{0,61}[a-zA-Z0-9]?)*$ ]]; then
                echo -e "${red}✗ Некорректное доменное имя${plain}"
                return 1
            fi
            
            echo -e "${green}✓ Использование домена: $server_address${plain}"
            ;;
        *)
            use_domain=false
            server_address=$(curl -s4 ifconfig.me || curl -s4 icanhazip.com)
            if [[ -z "$server_address" ]]; then
                read -p "Не удалось определить IP автоматически. Введите IP вручную: " server_address
            fi
            echo -e "${green}✓ Использование IP: $server_address${plain}"
            ;;
    esac
    
    # Выбор типа SSL сертификата
    echo -e "\n${yellow}Выберите тип SSL сертификата:${plain}"
    echo -e "  ${green}1)${plain} Самоподписанный сертификат (быстро, для тестирования)"
    echo -e "  ${green}2)${plain} Собственный SSL сертификат (рекомендуется для продакшена)"
    read -p "Ваш выбор [1-2]: " cert_choice
    
    case "$cert_choice" in
        2)
            if ! setup_custom_cert; then
                echo -e "${yellow}Ошибка настройки сертификата. Используется самоподписанный.${plain}"
                generate_self_signed_cert "$server_address"
                insecure_flag="1"
            else
                insecure_flag="0"
                echo -e "${green}✓ Будет использован ваш SSL сертификат${plain}"
            fi
            ;;
        *)
            generate_self_signed_cert "$server_address"
            insecure_flag="1"
            ;;
    esac
    
    # Ввод логина и пароля пользователя
    echo -e "\n${blue}═══════════════ Создание пользователя Hysteria ═══════════════${plain}"
    local username
    local password
    local password_confirm
    
    read -p "Введите имя пользователя: " username
    
    # Проверка имени пользователя
    if [[ -z "$username" ]] || [[ ! "$username" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        echo -e "${red}✗ Некорректное имя пользователя (используйте только буквы, цифры, _ и -)${plain}"
        return 1
    fi
    
    while true; do
        read -sp "Введите пароль (минимум 8 символов): " password
        echo
        
        if [[ ${#password} -lt 8 ]]; then
            echo -e "${red}✗ Пароль слишком короткий (минимум 8 символов)${plain}"
            continue
        fi
        
        read -sp "Подтвердите пароль: " password_confirm
        echo
        
        if [[ "$password" != "$password_confirm" ]]; then
            echo -e "${red}✗ Пароли не совпадают${plain}"
            continue
        fi
        
        break
    done
    
    echo -e "${green}✓ Пользователь создан: $username${plain}"
    
    # Создание конфигурационного файла
    echo -e "${blue}Создание конфигурационного файла...${plain}"
    mkdir -p "$HYSTERIA_CONFIG_DIR"
    
    cat > "$HYSTERIA_CONFIG_FILE" <<EOF
listen: :443

tls:
  cert: ${HYSTERIA_CONFIG_DIR}/cert.crt
  key: ${HYSTERIA_CONFIG_DIR}/private.key

auth:
  type: password
  password: ${password}

masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com
    rewriteHost: true

quic:
  initStreamReceiveWindow: 16777216
  maxStreamReceiveWindow: 16777216
  initConnReceiveWindow: 33554432
  maxConnReceiveWindow: 33554432
  maxIdleTimeout: 30s
  maxIncomingStreams: 1024
  disablePathMTUDiscovery: false

bandwidth:
  up: 1 gbps
  down: 1 gbps

ignoreClientBandwidth: false

speedTest: false

disableUDP: false

udpIdleTimeout: 60s
EOF
    
    # Сохранение типа адреса и insecure флага для веб-панели
    echo "$server_address" > "${HYSTERIA_CONFIG_DIR}/server_address.txt"
    echo "$insecure_flag" > "${HYSTERIA_CONFIG_DIR}/insecure_flag.txt"

    echo -e "${green}Конфигурационный файл создан: $HYSTERIA_CONFIG_FILE${plain}"
    
    # Создание systemd сервиса
    echo -e "${blue}Создание systemd сервиса...${plain}"
    
    cat > "$HYSTERIA_SERVICE" <<EOF
[Unit]
Description=Hysteria v2 Server
After=network.target nss-lookup.target
Wants=network.target

[Service]
Type=simple
User=root
ExecStart=${HYSTERIA_BIN} server -c ${HYSTERIA_CONFIG_FILE}
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

    echo -e "${green}Systemd сервис создан: $HYSTERIA_SERVICE${plain}"
    
    # Перезагрузка systemd
    systemctl daemon-reload
    
    # Включение и запуск сервиса
    echo -e "${blue}Включение и запуск Hysteria...${plain}"
    systemctl enable hysteria
    systemctl start hysteria
    
    # Проверка статуса
    sleep 2
    if systemctl is-active --quiet hysteria; then
        echo -e "${green}✓ Hysteria успешно запущен!${plain}"
    else
        echo -e "${red}✗ Ошибка запуска Hysteria${plain}"
        echo -e "${yellow}Проверьте логи: journalctl -u hysteria -n 50${plain}"
        exit 1
    fi
    
    # Формирование Hysteria2 URL
    local hysteria_url="hysteria2://${password}@${server_address}:443/?insecure=${insecure_flag}#${username}"
    
    # Вывод информации для подключения
    echo -e "\n${green}╔═══════════════════════════════════════════════════════════════╗${plain}"
    echo -e "${green}║        Hysteria v2 успешно установлен и настроен!            ║${plain}"
    echo -e "${green}╚═══════════════════════════════════════════════════════════════╝${plain}\n"
    
    echo -e "${blue}═══════════════ Информация для подключения ═══════════════${plain}"
    echo -e "${yellow}Адрес:${plain}       $server_address"
    echo -e "${yellow}Порт:${plain}        443"
    echo -e "${yellow}Протокол:${plain}    Hysteria2"
    echo -e "${yellow}Пользователь:${plain} $username"
    echo -e "${yellow}Пароль:${plain}      $password"
    if [[ "$insecure_flag" == "1" ]]; then
        echo -e "${yellow}TLS:${plain}         Самоподписанный сертификат (insecure=1)"
    else
        echo -e "${yellow}TLS:${plain}         Собственный SSL сертификат"
    fi
    echo -e "${blue}═══════════════════════════════════════════════════════════${plain}\n"
    
    echo -e "${green}Hysteria2 URL:${plain}"
    echo -e "${yellow}$hysteria_url${plain}\n"
    
    # Генерация QR-кода если доступен qrencode
    if command -v qrencode &>/dev/null; then
        echo -e "${green}QR-код для подключения:${plain}"
        qrencode -t ANSIUTF8 "$hysteria_url"
        echo ""
    fi
    
    echo -e "${blue}═══════════════════════════════════════════════════════════${plain}"
    echo -e "${yellow}Сохраните эту информацию в безопасном месте!${plain}"
    echo -e "${yellow}Настройте клиент Hysteria v2 используя данные выше${plain}"
    echo -e "${blue}═══════════════════════════════════════════════════════════${plain}\n"
    
    # Сохранение информации в файл
    local info_file="${HYSTERIA_CONFIG_DIR}/connection_info.txt"
    cat > "$info_file" <<EOF
Hysteria v2 Connection Information
===================================
Address: $server_address
Port: 443
Protocol: Hysteria2
Username: $username
Password: $password
TLS: $([ "$insecure_flag" == "1" ] && echo "Self-signed certificate (insecure=1)" || echo "Custom SSL certificate")

Hysteria2 URL:
$hysteria_url

Generated: $(date)
EOF
    
    echo -e "${green}Информация сохранена в: $info_file${plain}"
    
    # Установка веб-панели
    echo -e "\n${blue}═══════════════════════════════════════════════════════════${plain}"
    echo -e "${yellow}Устанавливаем веб-панель управления...${plain}"
    echo -e "${blue}═══════════════════════════════════════════════════════════${plain}\n"
    
    install_web_panel
    
    if [[ $? -eq 0 ]]; then
        local panel_port="54321"
        
        echo -e "\n${green}╔═══════════════════════════════════════════════════════════════╗${plain}"
        echo -e "${green}║           Веб-панель Hysteria UI установлена!                ║${plain}"
        echo -e "${green}╚═══════════════════════════════════════════════════════════════╝${plain}\n"
        
        echo -e "${blue}═══════════════ Настройка администратора веб-панели ═══════════════${plain}"
        
        local admin_username
        local admin_password
        local admin_password_confirm
        
        echo -e "${yellow}Создайте учетную запись администратора:${plain}"
        read -p "Введите логин администратора: " admin_username
        
        if [[ -z "$admin_username" ]] || [[ ! "$admin_username" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            echo -e "${red}✗ Некорректный логин (используйте только буквы, цифры, _ и -)${plain}"
            admin_username="admin"
            admin_password="admin"
            echo -e "${yellow}Используются учетные данные по умолчанию: admin/admin${plain}"
        else
            while true; do
                read -sp "Введите пароль (минимум 8 символов): " admin_password
                echo
                
                if [[ ${#admin_password} -lt 8 ]]; then
                    echo -e "${red}✗ Пароль слишком короткий (минимум 8 символов)${plain}"
                    continue
                fi
                
                read -sp "Подтвердите пароль: " admin_password_confirm
                echo
                
                if [[ "$admin_password" != "$admin_password_confirm" ]]; then
                    echo -e "${red}✗ Пароли не совпадают${plain}"
                    continue
                fi
                
                break
            done
        fi
        
        # Создание администратора в БД
        ${HYSTERIA_UI_DIR}/venv/bin/python3 -c "
import sqlite3
from werkzeug.security import generate_password_hash

conn = sqlite3.connect('/opt/hysteria-ui/hysteria.db')
c = conn.cursor()
c.execute('DELETE FROM admins')
c.execute('INSERT INTO admins (username, password) VALUES (?, ?)', 
          ('$admin_username', generate_password_hash('$admin_password')))
conn.commit()
conn.close()
print('Администратор создан')
" 2>/dev/null
        
        echo -e "\n${blue}═══════════════ Доступ к веб-панели ═══════════════${plain}"
        echo -e "${yellow}URL:${plain}         http://${server_address}:${panel_port}"
        echo -e "${yellow}Логин:${plain}       $admin_username"
        echo -e "${yellow}Пароль:${plain}      [установлен вами]"
        echo -e "${blue}═══════════════════════════════════════════════════${plain}\n"
    fi
    
    # Настройка firewall
    configure_firewall
}

# ============================================================================
# Запуск Hysteria
# ============================================================================
start_hysteria() {
    if systemctl is-active --quiet hysteria; then
        echo -e "${yellow}Hysteria уже запущен${plain}"
        return 0
    fi
    
    echo -e "${blue}Запуск Hysteria...${plain}"
    systemctl start hysteria
    
    sleep 2
    if systemctl is-active --quiet hysteria; then
        echo -e "${green}✓ Hysteria успешно запущен${plain}"
    else
        echo -e "${red}✗ Ошибка запуска Hysteria${plain}"
        echo -e "${yellow}Проверьте логи: journalctl -u hysteria -n 50${plain}"
    fi
}

# ============================================================================
# Остановка Hysteria
# ============================================================================
stop_hysteria() {
    if ! systemctl is-active --quiet hysteria; then
        echo -e "${yellow}Hysteria уже остановлен${plain}"
        return 0
    fi
    
    echo -e "${blue}Остановка Hysteria...${plain}"
    systemctl stop hysteria
    
    sleep 2
    if ! systemctl is-active --quiet hysteria; then
        echo -e "${green}✓ Hysteria успешно остановлен${plain}"
    else
        echo -e "${red}✗ Ошибка остановки Hysteria${plain}"
    fi
}

# ============================================================================
# Перезапуск Hysteria
# ============================================================================
restart_hysteria() {
    echo -e "${blue}Перезапуск Hysteria...${plain}"
    systemctl restart hysteria
    
    sleep 2
    if systemctl is-active --quiet hysteria; then
        echo -e "${green}✓ Hysteria успешно перезапущен${plain}"
    else
        echo -e "${red}✗ Ошибка перезапуска Hysteria${plain}"
        echo -e "${yellow}Проверьте логи: journalctl -u hysteria -n 50${plain}"
    fi
}

# ============================================================================
# Статус Hysteria
# ============================================================================
status_hysteria() {
    echo -e "${blue}═══════════════ Статус Hysteria ═══════════════${plain}"
    systemctl status hysteria --no-pager
    echo -e "${blue}═══════════════════════════════════════════════${plain}"
}

# ============================================================================
# Логи Hysteria
# ============================================================================
log_hysteria() {
    echo -e "${blue}═══════════════ Логи Hysteria (последние 50 строк) ═══════════════${plain}"
    journalctl -u hysteria -n 50 --no-pager
    echo -e "${blue}═══════════════════════════════════════════════════════════════════${plain}"
    echo -e "${yellow}Для просмотра логов в реальном времени: journalctl -u hysteria -f${plain}"
}

# ============================================================================
# Обновление Hysteria
# ============================================================================
update_hysteria() {
    echo -e "${blue}═══════════════ Обновление Hysteria ═══════════════${plain}"
    
    # Проверка текущей версии
    if [[ -f "$HYSTERIA_BIN" ]]; then
        local current_version=$("$HYSTERIA_BIN" version 2>/dev/null | head -n1)
        echo -e "${yellow}Текущая версия: $current_version${plain}"
    fi
    
    # Остановка сервиса
    echo -e "${blue}Остановка Hysteria...${plain}"
    systemctl stop hysteria
    
    # Резервное копирование старого бинарника
    if [[ -f "$HYSTERIA_BIN" ]]; then
        cp "$HYSTERIA_BIN" "${HYSTERIA_BIN}.backup"
        echo -e "${green}Создана резервная копия: ${HYSTERIA_BIN}.backup${plain}"
    fi
    
    # Установка новой версии
    install_hysteria
    
    # Запуск сервиса
    echo -e "${blue}Запуск Hysteria...${plain}"
    systemctl start hysteria
    
    sleep 2
    if systemctl is-active --quiet hysteria; then
        local new_version=$("$HYSTERIA_BIN" version 2>/dev/null | head -n1)
        echo -e "${green}✓ Hysteria успешно обновлён: $new_version${plain}"
        
        # Удаление резервной копии
        rm -f "${HYSTERIA_BIN}.backup"
    else
        echo -e "${red}✗ Ошибка при обновлении Hysteria${plain}"
        echo -e "${yellow}Восстановление из резервной копии...${plain}"
        
        if [[ -f "${HYSTERIA_BIN}.backup" ]]; then
            mv "${HYSTERIA_BIN}.backup" "$HYSTERIA_BIN"
            systemctl start hysteria
            echo -e "${green}Восстановлена предыдущая версия${plain}"
        fi
    fi
}

# ============================================================================
# Настройка Firewall
# ============================================================================
configure_firewall() {
    echo -e "\n${blue}═══════════════ Настройка Firewall ═══════════════${plain}"
    
    # Проверка наличия firewall
    if command -v ufw &>/dev/null; then
        echo -e "${green}Обнаружен UFW${plain}"
        
        # Проверка активности UFW
        if ufw status | grep -q "Status: active"; then
            echo -e "${blue}Открытие портов в UFW...${plain}"
            
            # Hysteria порт (UDP обязательно!)
            ufw allow 443/udp comment 'Hysteria Server'
            ufw allow 443/tcp comment 'Hysteria Server (TCP)'
            
            # Веб-панель
            echo -e "${yellow}Открыть порт 54321 для веб-панели?${plain}"
            echo -e "${yellow}1) Да, открыть для всех${plain}"
            echo -e "${yellow}2) Да, но только для моего IP${plain}"
            echo -e "${yellow}3) Нет, использую SSH туннель${plain}"
            read -p "Выбор [1-3]: " fw_choice
            
            case "$fw_choice" in
                1)
                    ufw allow 54321/tcp comment 'Hysteria UI Panel'
                    echo -e "${green}✓ Порт 54321 открыт для всех${plain}"
                    ;;
                2)
                    echo -e "${yellow}Определяю ваш IP...${plain}"
                    local my_ip=$(curl -s4 ifconfig.me)
                    if [[ -n "$my_ip" ]]; then
                        ufw allow from "$my_ip" to any port 54321 comment 'Hysteria UI Panel'
                        echo -e "${green}✓ Порт 54321 открыт только для $my_ip${plain}"
                    else
                        echo -e "${red}Не удалось определить IP${plain}"
                    fi
                    ;;
                3)
                    echo -e "${blue}Порт 54321 не открыт. Используйте SSH туннель:${plain}"
                    echo -e "${yellow}ssh -L 54321:localhost:54321 root@${server_ip:-SERVER_IP}${plain}"
                    ;;
            esac
            
            ufw reload
            echo -e "${green}✓ Firewall настроен${plain}"
        else
            echo -e "${yellow}UFW не активен. Активировать? (y/n)${plain}"
            read -p "Ответ: " activate_ufw
            if [[ "$activate_ufw" == "y" || "$activate_ufw" == "Y" ]]; then
                ufw --force enable
                configure_firewall
            fi
        fi
        
    elif command -v firewall-cmd &>/dev/null; then
        echo -e "${green}Обнаружен FirewallD${plain}"
        
        if systemctl is-active --quiet firewalld; then
            echo -e "${blue}Открытие портов в FirewallD...${plain}"
            
            firewall-cmd --add-port=443/udp --permanent
            firewall-cmd --add-port=443/tcp --permanent
            firewall-cmd --add-port=54321/tcp --permanent
            firewall-cmd --reload
            
            echo -e "${green}✓ Firewall настроен${plain}"
        else
            echo -e "${yellow}FirewallD не запущен${plain}"
        fi
        
    elif command -v iptables &>/dev/null; then
        echo -e "${green}Обнаружен iptables${plain}"
        echo -e "${blue}Открытие портов в iptables...${plain}"
        
        iptables -A INPUT -p udp --dport 443 -j ACCEPT
        iptables -A INPUT -p tcp --dport 443 -j ACCEPT
        iptables -A INPUT -p tcp --dport 54321 -j ACCEPT
        
        # Сохранение правил
        if command -v netfilter-persistent &>/dev/null; then
            netfilter-persistent save
        elif command -v iptables-save &>/dev/null; then
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || iptables-save > /etc/sysconfig/iptables 2>/dev/null
        fi
        
        echo -e "${green}✓ Firewall настроен${plain}"
    else
        echo -e "${yellow}Firewall не обнаружен${plain}"
        echo -e "${yellow}Убедитесь, что порты 443 (UDP) и 54321 (TCP) открыты вручную${plain}"
    fi
    
    echo -e "\n${blue}═══════════════════════════════════════════════════${plain}"
    echo -e "${green}Открытые порты:${plain}"
    echo -e "${yellow}  443/UDP  - Hysteria Server (ОБЯЗАТЕЛЬНО)${plain}"
    echo -e "${yellow}  443/TCP  - Hysteria Server (маскировка)${plain}"
    echo -e "${yellow}  54321/TCP - Веб-панель управления${plain}"
    echo -e "${blue}═══════════════════════════════════════════════════${plain}\n"
}

# ============================================================================
# Управление веб-панелью
# ============================================================================
start_panel() {
    if systemctl is-active --quiet hysteria-ui; then
        echo -e "${yellow}Веб-панель уже запущена${plain}"
        return 0
    fi
    
    echo -e "${blue}Запуск веб-панели...${plain}"
    systemctl start hysteria-ui
    
    sleep 2
    if systemctl is-active --quiet hysteria-ui; then
        echo -e "${green}✓ Веб-панель успешно запущена${plain}"
        echo -e "${yellow}URL: http://$(curl -s4 ifconfig.me):54321${plain}"
    else
        echo -e "${red}✗ Ошибка запуска веб-панели${plain}"
        echo -e "${yellow}Проверьте логи: journalctl -u hysteria-ui -n 50${plain}"
    fi
}

stop_panel() {
    if ! systemctl is-active --quiet hysteria-ui; then
        echo -e "${yellow}Веб-панель уже остановлена${plain}"
        return 0
    fi
    
    echo -e "${blue}Остановка веб-панели...${plain}"
    systemctl stop hysteria-ui
    
    sleep 2
    if ! systemctl is-active --quiet hysteria-ui; then
        echo -e "${green}✓ Веб-панель успешно остановлена${plain}"
    else
        echo -e "${red}✗ Ошибка остановки веб-панели${plain}"
    fi
}

restart_panel() {
    echo -e "${blue}Перезапуск веб-панели...${plain}"
    systemctl restart hysteria-ui
    
    sleep 2
    if systemctl is-active --quiet hysteria-ui; then
        echo -e "${green}✓ Веб-панель успешно перезапущена${plain}"
        echo -e "${yellow}URL: http://$(curl -s4 ifconfig.me):54321${plain}"
    else
        echo -e "${red}✗ Ошибка перезапуска веб-панели${plain}"
        echo -e "${yellow}Проверьте логи: journalctl -u hysteria-ui -n 50${plain}"
    fi
}

status_panel() {
    echo -e "${blue}═══════════════ Статус веб-панели ═══════════════${plain}"
    systemctl status hysteria-ui --no-pager
    echo -e "${blue}═════════════════════════════════════════════════${plain}"
    
    if systemctl is-active --quiet hysteria-ui; then
        echo -e "\n${green}Веб-панель запущена${plain}"
        echo -e "${yellow}URL: http://$(curl -s4 ifconfig.me):54321${plain}"
        echo -e "${yellow}Логин: admin / Пароль: admin${plain}"
    fi
}

# ============================================================================
# Удаление Hysteria
# ============================================================================
uninstall_hysteria() {
    echo -e "${red}═══════════════ Удаление Hysteria ═══════════════${plain}"
    echo -e "${yellow}Это действие удалит Hysteria, веб-панель и все конфигурации${plain}"
    read -p "Вы уверены? (y/n): " confirm
    
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo -e "${blue}Удаление отменено${plain}"
        return 0
    fi
    
    # Остановка и отключение сервиса Hysteria
    if systemctl is-active --quiet hysteria; then
        echo -e "${blue}Остановка Hysteria...${plain}"
        systemctl stop hysteria
    fi
    
    if systemctl is-enabled --quiet hysteria 2>/dev/null; then
        echo -e "${blue}Отключение автозапуска Hysteria...${plain}"
        systemctl disable hysteria
    fi
    
    # Остановка и отключение веб-панели
    if systemctl is-active --quiet hysteria-ui; then
        echo -e "${blue}Остановка веб-панели...${plain}"
        systemctl stop hysteria-ui
    fi
    
    if systemctl is-enabled --quiet hysteria-ui 2>/dev/null; then
        echo -e "${blue}Отключение автозапуска веб-панели...${plain}"
        systemctl disable hysteria-ui
    fi
    
    # Удаление systemd сервисов
    if [[ -f "$HYSTERIA_SERVICE" ]]; then
        echo -e "${blue}Удаление systemd сервиса Hysteria...${plain}"
        rm -f "$HYSTERIA_SERVICE"
    fi
    
    if [[ -f "$HYSTERIA_UI_SERVICE" ]]; then
        echo -e "${blue}Удаление systemd сервиса веб-панели...${plain}"
        rm -f "$HYSTERIA_UI_SERVICE"
    fi
    
    systemctl daemon-reload
    
    # Удаление бинарного файла
    if [[ -f "$HYSTERIA_BIN" ]]; then
        echo -e "${blue}Удаление бинарного файла Hysteria...${plain}"
        rm -f "$HYSTERIA_BIN"
    fi
    
    # Удаление веб-панели
    if [[ -d "$HYSTERIA_UI_DIR" ]]; then
        echo -e "${blue}Удаление веб-панели...${plain}"
        read -p "Удалить веб-панель и базу данных? (y/n): " confirm_panel
        
        if [[ "$confirm_panel" == "y" || "$confirm_panel" == "Y" ]]; then
            rm -rf "$HYSTERIA_UI_DIR"
            echo -e "${green}Веб-панель удалена${plain}"
        else
            echo -e "${yellow}Веб-панель сохранена в: $HYSTERIA_UI_DIR${plain}"
        fi
    fi
    
    # Удаление конфигурации
    if [[ -d "$HYSTERIA_CONFIG_DIR" ]]; then
        echo -e "${blue}Удаление конфигурации...${plain}"
        read -p "Удалить конфигурационные файлы и сертификаты? (y/n): " confirm_config
        
        if [[ "$confirm_config" == "y" || "$confirm_config" == "Y" ]]; then
            rm -rf "$HYSTERIA_CONFIG_DIR"
            echo -e "${green}Конфигурация удалена${plain}"
        else
            echo -e "${yellow}Конфигурация сохранена в: $HYSTERIA_CONFIG_DIR${plain}"
        fi
    fi
    
    echo -e "${green}✓ Hysteria и веб-панель успешно удалены${plain}"
}

# ============================================================================
# Отображение меню управления (аналогично 3x-ui)
# ============================================================================
show_menu() {
    echo -e "
${green}╔═══════════════════════════════════════════════════════════════╗
║                                                               ║
║         ${blue}Hysteria v2 Server Management Script${green}                 ║
║                                                               ║
╚═══════════════════════════════════════════════════════════════╝${plain}

${blue}═══════════════════════════════════════════════════════════════${plain}
${yellow}  Установка и управление${plain}
${blue}═══════════════════════════════════════════════════════════════${plain}
  ${green}1.${plain} Установить и настроить Hysteria v2 + Веб-панель
  ${green}2.${plain} Запустить Hysteria
  ${green}3.${plain} Остановить Hysteria
  ${green}4.${plain} Перезапустить Hysteria
  ${green}5.${plain} Показать статус Hysteria
  ${green}6.${plain} Показать логи Hysteria
${blue}═══════════════════════════════════════════════════════════════${plain}
${yellow}  Веб-панель${plain}
${blue}═══════════════════════════════════════════════════════════════${plain}
  ${green}7.${plain} Запустить веб-панель
  ${green}8.${plain} Остановить веб-панель
  ${green}9.${plain} Перезапустить веб-панель
  ${green}10.${plain} Статус веб-панели
${blue}═══════════════════════════════════════════════════════════════${plain}
${yellow}  Обслуживание${plain}
${blue}═══════════════════════════════════════════════════════════════${plain}
  ${green}11.${plain} Настроить Firewall
  ${green}12.${plain} Обновить Hysteria
  ${green}13.${plain} Удалить Hysteria и веб-панель
${blue}═══════════════════════════════════════════════════════════════${plain}
  ${green}0.${plain} Выход
${blue}═══════════════════════════════════════════════════════════════${plain}
"
    
    read -p "Выберите действие [0-13]: " choice
    
    case "$choice" in
        1)
            install_base
            install_hysteria
            config_hysteria
            ;;
        2)
            start_hysteria
            ;;
        3)
            stop_hysteria
            ;;
        4)
            restart_hysteria
            ;;
        5)
            status_hysteria
            ;;
        6)
            log_hysteria
            ;;
        7)
            start_panel
            ;;
        8)
            stop_panel
            ;;
        9)
            restart_panel
            ;;
        10)
            status_panel
            ;;
        11)
            configure_firewall
            ;;
        12)
            update_hysteria
            ;;
        13)
            uninstall_hysteria
            ;;
        0)
            echo -e "${green}До свидания!${plain}"
            exit 0
            ;;
        *)
            echo -e "${red}Неверный выбор. Пожалуйста, выберите 0-13${plain}"
            ;;
    esac
}

# ============================================================================
# Справка
# ============================================================================
show_help() {
    echo -e "${blue}═══════════════════════════════════════════════════════════════${plain}"
    echo -e "${green}Hysteria v2 Server Installer and Management Script${plain}"
    echo -e "${blue}═══════════════════════════════════════════════════════════════${plain}"
    echo -e ""
    echo -e "${yellow}Использование:${plain}"
    echo -e "  $0 [команда]"
    echo -e ""
    echo -e "${yellow}Команды:${plain}"
    echo -e "  ${green}install${plain}     - Установить и настроить Hysteria v2 + Веб-панель"
    echo -e "  ${green}start${plain}       - Запустить сервис Hysteria"
    echo -e "  ${green}stop${plain}        - Остановить сервис Hysteria"
    echo -e "  ${green}restart${plain}     - Перезапустить сервис Hysteria"
    echo -e "  ${green}status${plain}      - Показать статус сервиса"
    echo -e "  ${green}log${plain}         - Показать логи сервиса"
    echo -e "  ${green}firewall${plain}    - Настроить firewall (открыть порты)"
    echo -e "  ${green}update${plain}      - Обновить Hysteria до последней версии"
    echo -e "  ${green}uninstall${plain}   - Удалить Hysteria и веб-панель"
    echo -e "  ${green}help${plain}        - Показать эту справку"
    echo -e ""
    echo -e "${yellow}Без аргументов скрипт отображает интерактивное меню${plain}"
    echo -e ""
    echo -e "${yellow}Веб-панель доступна по адресу: http://YOUR_SERVER_IP:54321${plain}"
    echo -e "${yellow}Логин: admin | Пароль: admin (измените после первого входа!)${plain}"
    echo -e "${blue}═══════════════════════════════════════════════════════════════${plain}"
    echo -e ""
    echo -e "${yellow}О скрипте:${plain}"
    echo -e "Этот скрипт автоматизирует установку и управление сервером"
    echo -e "Hysteria v2 - мощного инструмента для обхода цензуры."
    echo -e ""
    echo -e "Структура и логика скрипта аналогичны популярному скрипту"
    echo -e "установки 3x-ui для Xray, но адаптированы для Hysteria v2."
    echo -e ""
    echo -e "${yellow}Основные возможности:${plain}"
    echo -e "- Автоматическое определение архитектуры системы"
    echo -e "- Проверка версии GLIBC (требуется >= 2.27)"
    echo -e "- Установка зависимостей для различных дистрибутивов"
    echo -e "- Автоматическая генерация самоподписанного TLS сертификата"
    echo -e "- Генерация безопасных паролей"
    echo -e "- Настройка systemd сервиса"
    echo -e "- Веб-панель управления (аналог 3x-ui)"
    echo -e "- Управление пользователями через веб-интерфейс"
    echo -e "- QR-коды для быстрого подключения"
    echo -e "- Статистика и мониторинг"
    echo -e "- Полное управление жизненным циклом сервиса"
    echo -e "${blue}═══════════════════════════════════════════════════════════════${plain}"
}

# ============================================================================
# ОСНОВНАЯ ЛОГИКА СКРИПТА
# ============================================================================

# Проверка прав root
check_root

# Обработка аргументов командной строки
if [[ $# -eq 0 ]]; then
    # Если аргументов нет - показать меню
    while true; do
        show_menu
    done
else
    # Если есть аргументы - обработать команду
    case "$1" in
        install)
            install_base
            install_hysteria
            config_hysteria
            ;;
        start)
            start_hysteria
            ;;
        stop)
            stop_hysteria
            ;;
        restart)
            restart_hysteria
            ;;
        status)
            status_hysteria
            ;;
        log)
            log_hysteria
            ;;
        firewall)
            configure_firewall
            ;;
        update)
            update_hysteria
            ;;
        uninstall)
            uninstall_hysteria
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            echo -e "${red}Неизвестная команда: $1${plain}"
            echo -e "${yellow}Используйте '$0 help' для справки${plain}"
            exit 1
            ;;
    esac
fi

# ============================================================================
# КОНЕЦ СКРИПТА
# ============================================================================
# 
# Структура скрипта и аналогия с 3x-ui:
# 
# 1. Цветовые переменные (red, green, yellow, blue, plain) - как в 3x-ui
# 2. Проверка root прав - check_root() - аналогично 3x-ui
# 3. Определение архитектуры - arch() - использует case, как в 3x-ui
# 4. Проверка GLIBC - check_glibc_version() - адаптирована из 3x-ui
# 5. Установка зависимостей - install_base() - поддерживает те же дистрибутивы
# 6. Генерация случайных строк - gen_random_string() - как в 3x-ui
# 7. Установка основного ПО - install_hysteria() - вместо install_x-ui()
# 8. Настройка - config_hysteria() - создает config.yaml вместо db и config.json
# 9. Управление сервисом - start/stop/restart/status/log - аналогично 3x-ui
# 10. Обновление - update_hysteria() - с резервным копированием
# 11. Удаление - uninstall_hysteria() - с подтверждением
# 12. Меню - show_menu() - ASCII графика и цветное оформление как в 3x-ui
# 13. Обработка аргументов - основная логика - поддержка subcommands
# 
# Ключевые отличия от 3x-ui:
# - Hysteria использует config.yaml вместо базы данных
# - Hysteria не имеет веб-интерфейса (только CLI)
# - Hysteria требует обязательный TLS (используется acme.sh)
# - Hysteria использует протокол QUIC (не TCP/WebSocket как Xray)
# - Вывод connection string в формате hysteria2://
# ============================================================================
