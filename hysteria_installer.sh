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
        apt-get install -y wget curl tar tzdata qrencode ca-certificates
        
    elif command -v yum &>/dev/null; then
        # CentOS/RHEL
        echo -e "${green}Обнаружен YUM (CentOS/RHEL)${plain}"
        yum update -y
        yum install -y wget curl tar tzdata qrencode ca-certificates
        
    elif command -v dnf &>/dev/null; then
        # Fedora
        echo -e "${green}Обнаружен DNF (Fedora)${plain}"
        dnf update -y
        dnf install -y wget curl tar tzdata qrencode ca-certificates
        
    elif command -v zypper &>/dev/null; then
        # OpenSUSE
        echo -e "${green}Обнаружен Zypper (OpenSUSE)${plain}"
        zypper refresh
        zypper install -y wget curl tar timezone qrencode ca-certificates
        
    elif command -v pacman &>/dev/null; then
        # Arch Linux
        echo -e "${green}Обнаружен Pacman (Arch Linux)${plain}"
        pacman -Sy --noconfirm wget curl tar tzdata qrencode ca-certificates
        
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
    
    # Удаление префикса 'v' если есть
    latest_version=${latest_version#v}
    echo -e "${green}Последняя версия: $latest_version${plain}"
    
    # Формирование имени файла
    local download_file="hysteria-linux-${cpu_arch}"
    local download_url="https://github.com/apernet/hysteria/releases/download/app/v${latest_version}/${download_file}"
    
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
# Настройка Hysteria v2
# ============================================================================
config_hysteria() {
    echo -e "${blue}=== Настройка Hysteria v2 ===${plain}"
    
    # Запрос доменного имени
    echo -e "${yellow}Введите доменное имя, которое указывает на IP этого сервера:${plain}"
    read -p "Домен: " domain
    
    if [[ -z "$domain" ]]; then
        echo -e "${red}Ошибка: Домен не может быть пустым${plain}"
        exit 1
    fi
    
    # Проверка корректности домена
    if [[ ! "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        echo -e "${red}Ошибка: Некорректный формат домена${plain}"
        exit 1
    fi
    
    # Установка acme.sh
    install_acme
    if [[ $? -ne 0 ]]; then
        exit 1
    fi
    
    # Получение сертификата
    obtain_certificate "$domain"
    if [[ $? -ne 0 ]]; then
        exit 1
    fi
    
    # Генерация пароля
    echo -e "${blue}Генерация пароля...${plain}"
    local password=$(gen_random_string 32)
    
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
    
    # Получение IP сервера
    local server_ip=$(curl -s4 ifconfig.me)
    if [[ -z "$server_ip" ]]; then
        server_ip=$(hostname -I | awk '{print $1}')
    fi
    
    # Формирование Hysteria2 URL
    local hysteria_url="hysteria2://${password}@${domain}:443/?insecure=0&sni=${domain}"
    
    # Вывод информации для подключения
    echo -e "\n${green}╔═══════════════════════════════════════════════════════════════╗${plain}"
    echo -e "${green}║        Hysteria v2 успешно установлен и настроен!            ║${plain}"
    echo -e "${green}╚═══════════════════════════════════════════════════════════════╝${plain}\n"
    
    echo -e "${blue}═══════════════ Информация для подключения ═══════════════${plain}"
    echo -e "${yellow}Сервер:${plain}      $domain"
    echo -e "${yellow}IP:${plain}          $server_ip"
    echo -e "${yellow}Порт:${plain}        443"
    echo -e "${yellow}Протокол:${plain}    Hysteria2"
    echo -e "${yellow}Пароль:${plain}      $password"
    echo -e "${yellow}TLS:${plain}         Включён"
    echo -e "${yellow}SNI:${plain}         $domain"
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
Server: $domain
IP: $server_ip
Port: 443
Protocol: Hysteria2
Password: $password
TLS: Enabled
SNI: $domain

Hysteria2 URL:
$hysteria_url

Generated: $(date)
EOF
    
    echo -e "${green}Информация сохранена в: $info_file${plain}"
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
# Удаление Hysteria
# ============================================================================
uninstall_hysteria() {
    echo -e "${red}═══════════════ Удаление Hysteria ═══════════════${plain}"
    echo -e "${yellow}Это действие удалит Hysteria и все его конфигурации${plain}"
    read -p "Вы уверены? (y/n): " confirm
    
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo -e "${blue}Удаление отменено${plain}"
        return 0
    fi
    
    # Остановка и отключение сервиса
    if systemctl is-active --quiet hysteria; then
        echo -e "${blue}Остановка Hysteria...${plain}"
        systemctl stop hysteria
    fi
    
    if systemctl is-enabled --quiet hysteria 2>/dev/null; then
        echo -e "${blue}Отключение автозапуска...${plain}"
        systemctl disable hysteria
    fi
    
    # Удаление systemd сервиса
    if [[ -f "$HYSTERIA_SERVICE" ]]; then
        echo -e "${blue}Удаление systemd сервиса...${plain}"
        rm -f "$HYSTERIA_SERVICE"
        systemctl daemon-reload
    fi
    
    # Удаление бинарного файла
    if [[ -f "$HYSTERIA_BIN" ]]; then
        echo -e "${blue}Удаление бинарного файла...${plain}"
        rm -f "$HYSTERIA_BIN"
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
    
    echo -e "${green}✓ Hysteria успешно удалён${plain}"
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
  ${green}1.${plain} Установить и настроить Hysteria v2
  ${green}2.${plain} Запустить Hysteria
  ${green}3.${plain} Остановить Hysteria
  ${green}4.${plain} Перезапустить Hysteria
  ${green}5.${plain} Показать статус Hysteria
  ${green}6.${plain} Показать логи Hysteria
${blue}═══════════════════════════════════════════════════════════════${plain}
${yellow}  Обслуживание${plain}
${blue}═══════════════════════════════════════════════════════════════${plain}
  ${green}7.${plain} Обновить Hysteria
  ${green}8.${plain} Удалить Hysteria
${blue}═══════════════════════════════════════════════════════════════${plain}
  ${green}0.${plain} Выход
${blue}═══════════════════════════════════════════════════════════════${plain}
"
    
    read -p "Выберите действие [0-8]: " choice
    
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
            update_hysteria
            ;;
        8)
            uninstall_hysteria
            ;;
        0)
            echo -e "${green}До свидания!${plain}"
            exit 0
            ;;
        *)
            echo -e "${red}Неверный выбор. Пожалуйста, выберите 0-8${plain}"
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
    echo -e "  ${green}install${plain}     - Установить и настроить Hysteria v2"
    echo -e "  ${green}start${plain}       - Запустить сервис Hysteria"
    echo -e "  ${green}stop${plain}        - Остановить сервис Hysteria"
    echo -e "  ${green}restart${plain}     - Перезапустить сервис Hysteria"
    echo -e "  ${green}status${plain}      - Показать статус сервиса"
    echo -e "  ${green}log${plain}         - Показать логи сервиса"
    echo -e "  ${green}update${plain}      - Обновить Hysteria до последней версии"
    echo -e "  ${green}uninstall${plain}   - Удалить Hysteria"
    echo -e "  ${green}help${plain}        - Показать эту справку"
    echo -e ""
    echo -e "${yellow}Без аргументов скрипт отображает интерактивное меню${plain}"
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
    echo -e "- Автоматическое получение TLS сертификатов (Let's Encrypt)"
    echo -e "- Генерация безопасных паролей"
    echo -e "- Настройка systemd сервиса"
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
