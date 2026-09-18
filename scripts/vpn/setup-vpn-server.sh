#!/usr/bin/env bash
# Шаг 2 из 2 настройки VPN-сервера: раскладывает подписанные сертификаты,
# включает маршрутизацию, настраивает фаервол и запускает OpenVPN.
#
# Использование:
#   sudo ./setup-vpn-server.sh <server.crt> <ca.crt> <crl.pem> [имя]
#
# Пример:
#   sudo ./setup-vpn-server.sh /tmp/vpn-server.crt /tmp/ca.crt /tmp/crl.pem
#
# Список отзыва обязателен: конфигурация содержит crl-verify, и без файла
# служба не запустится. Забирается с машины удостоверяющего центра вместе
# с сертификатом.
#
# Предполагается, что конфигурация OpenVPN уже принесена deb-пакетом
# infra-vpn-config. Если пакета нет, скрипт об этом скажет.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../project.env
source "${SCRIPT_DIR}/../project.env"

readonly VPN_HOME="/var/lib/infra-vpn"
readonly VPN_PKI="${VPN_HOME}/pki"
readonly OVPN_DIR="/etc/openvpn/server"
readonly USAGE="$0 <server.crt> <ca.crt> <crl.pem> [имя-сервера]"

require_root
require_args "$#" 3 "${USAGE}"

SERVER_CRT="$1"
CA_CRT="$2"
CRL_FILE="$3"
SERVER_CN="${4:-vpn-server}"
validate_name "${SERVER_CN}"

# --- Проверки ---------------------------------------------------------------

[[ -f "${SERVER_CRT}" ]] || die "${EX_DATAERR}" "Не найден сертификат сервера: ${SERVER_CRT}"
[[ -f "${CA_CRT}" ]]     || die "${EX_DATAERR}" "Не найден сертификат CA: ${CA_CRT}"
[[ -f "${CRL_FILE}" ]]   || die "${EX_DATAERR}" "Не найден список отзыва: ${CRL_FILE}"

# Просроченный список отзыва заставляет OpenVPN отвергать ВСЕХ клиентов.
# Проверяем сразу, а не после первого неудачного подключения.
CRL_NEXT="$(openssl crl -in "${CRL_FILE}" -noout -nextupdate 2>/dev/null | cut -d= -f2)"
[[ -n "${CRL_NEXT}" ]] || die "${EX_DATAERR}" "Файл ${CRL_FILE} не является списком отзыва"
if [[ "$(date -d "${CRL_NEXT}" +%s)" -le "$(date +%s)" ]]; then
    die "${EX_DATAERR}" "Список отзыва просрочен (до ${CRL_NEXT}). Обновите его на центре: easyrsa gen-crl"
fi
log_info "Список отзыва действителен до ${CRL_NEXT}"

SERVER_KEY="${VPN_PKI}/private/${SERVER_CN}.key"
[[ -f "${SERVER_KEY}" ]] || die "${EX_UNAVAILABLE}" \
    "Нет приватного ключа ${SERVER_KEY}. Сначала выполните request-server-cert.sh"

# Ключ и сертификат должны быть парой. Если перепутали файлы, OpenVPN
# упадёт при старте с невнятной ошибкой — лучше поймать здесь.
log_info "Проверяю соответствие ключа и сертификата"
CRT_PUB="$(openssl x509 -in "${SERVER_CRT}" -noout -pubkey | openssl sha256)"
KEY_PUB="$(openssl pkey -in "${SERVER_KEY}" -pubout | openssl sha256)"
[[ "${CRT_PUB}" == "${KEY_PUB}" ]] || die "${EX_DATAERR}" \
    "Сертификат не соответствует приватному ключу этого сервера"

# Сертификат должен быть подписан именно нашим CA.
log_info "Проверяю цепочку доверия"
openssl verify -CAfile "${CA_CRT}" "${SERVER_CRT}" >/dev/null 2>&1 || die "${EX_DATAERR}" \
    "Сертификат не проходит проверку по ${CA_CRT}"
log_ok "Сертификат корректен"

# --- Установка --------------------------------------------------------------

apt_install openvpn firewalld

install_certificates() {
    ensure_dir "${OVPN_DIR}" 0700 "root:root"
    install -m 0644 -o root -g root "${CA_CRT}"     "${OVPN_DIR}/ca.crt"
    install -m 0644 -o root -g root "${SERVER_CRT}" "${OVPN_DIR}/server.crt"
    install -m 0600 -o root -g root "${SERVER_KEY}" "${OVPN_DIR}/server.key"

    # CRL кладём ВНЕ закрытого каталога: OpenVPN перечитывает его при каждом
    # подключении клиента, уже от имени nobody, а в ${OVPN_DIR} с правами 0700
    # тот войти не сможет. Подробности — в комментарии к server.conf.
    install -m 0644 -o root -g root "${CRL_FILE}" "/etc/openvpn/crl.pem"

    log_ok "Сертификаты установлены в ${OVPN_DIR}, список отзыва — в /etc/openvpn/crl.pem"
}

# tls-crypt: общий симметричный ключ, которым шифруется само TLS-рукопожатие.
# Пакет без правильного ключа сервер отбрасывает молча, не отвечая ничего.
# Сканер портов не видит, что на 1194/udp вообще что-то слушает, а перебор
# и DoS по TLS становятся неосуществимыми.
generate_tls_crypt_key() {
    local ta="${OVPN_DIR}/ta.key"
    if [[ -f "${ta}" ]]; then
        log_info "Ключ tls-crypt уже существует, новый не создаю"
        return 0
    fi
    log_info "Генерирую ключ tls-crypt"
    # Синтаксис менялся между версиями OpenVPN: 2.4 требует --genkey --secret,
    # 2.5+ ожидает --genkey secret. Пробуем новый, откатываемся на старый.
    if ! openvpn --genkey secret "${ta}" >/dev/null 2>&1; then
        openvpn --genkey --secret "${ta}" >/dev/null 2>&1
    fi
    chmod 600 "${ta}"
    log_ok "Ключ tls-crypt создан"
}

check_config_present() {
    if [[ ! -f "${OVPN_DIR}/server.conf" ]]; then
        die "${EX_UNAVAILABLE}" \
            "Нет ${OVPN_DIR}/server.conf. Установите пакет: sudo apt install ./infra-vpn-config_*.deb"
    fi
    log_info "Конфигурация сервера на месте (принесена deb-пакетом)"
}

# Без ip_forward ядро не пересылает пакеты между интерфейсами: трафик,
# пришедший в туннель, просто не попадёт на внешний интерфейс.
enable_forwarding() {
    local conf="/etc/sysctl.d/61-infra-vpn-forward.conf"
    if [[ ! -f "${conf}" ]]; then
        printf 'net.ipv4.ip_forward = 1\n' > "${conf}"
    fi
    sysctl --quiet --system
    local current
    current="$(sysctl -n net.ipv4.ip_forward)"
    [[ "${current}" == "1" ]] || die "${EX_SOFTWARE}" "Не удалось включить ip_forward"
    log_ok "Маршрутизация пакетов включена"
}

# NAT подменяет внутренний адрес 10.8.0.x на публичный адрес сервера.
# Без него запросы уходят в интернет, но ответы возвращаться некуда.
configure_firewall() {
    service_enable_now firewalld

    local zone="public"
    if firewall-cmd --permanent --zone="${zone}" --query-service=ssh >/dev/null 2>&1; then
        log_info "SSH уже разрешён"
    else
        firewall-cmd --permanent --zone="${zone}" --add-service=ssh >/dev/null
    fi

    if firewall-cmd --permanent --zone="${zone}" --query-port="${VPN_PORT}/${VPN_PROTO}" >/dev/null 2>&1; then
        log_info "Порт ${VPN_PORT}/${VPN_PROTO} уже открыт"
    else
        firewall-cmd --permanent --zone="${zone}" --add-port="${VPN_PORT}/${VPN_PROTO}" >/dev/null
        log_ok "Открыт порт ${VPN_PORT}/${VPN_PROTO}"
    fi

    if firewall-cmd --permanent --zone="${zone}" --query-masquerade >/dev/null 2>&1; then
        log_info "Маскарадинг уже включён"
    else
        firewall-cmd --permanent --zone="${zone}" --add-masquerade >/dev/null
        log_ok "Маскарадинг (NAT) включён"
    fi

    # Трафик из туннеля должен свободно ходить внутри доверенной зоны.
    if ! firewall-cmd --permanent --zone=trusted --query-interface=tun0 >/dev/null 2>&1; then
        firewall-cmd --permanent --zone=trusted --add-interface=tun0 >/dev/null
    fi

    # Метрики отдаём только серверу мониторинга.
    firewalld_allow_from "${MON_IP}/32" "${PORT_NODE_EXPORTER}/tcp"
    firewalld_allow_from "${MON_IP}/32" "${PORT_OPENVPN_EXPORTER}/tcp"

    firewall-cmd --reload >/dev/null
    log_ok "Фаервол настроен"
}

start_service() {
    ensure_dir /var/log/openvpn 0755 "root:root"
    ensure_dir /var/lib/infra-vpn/clients 0700 "root:root"
    # Имя после @ — это имя конфигурационного файла: systemd подставит его
    # в шаблон и запустит /etc/openvpn/server/server.conf
    systemctl enable --quiet openvpn-server@server.service
    systemctl restart openvpn-server@server.service
    sleep 2
    if systemctl is-active --quiet openvpn-server@server.service; then
        log_ok "Служба OpenVPN запущена"
    else
        log_error "Служба не запустилась. Последние строки журнала:"
        journalctl -u openvpn-server@server -n 30 --no-pager >&2
        die "${EX_SOFTWARE}" "Запуск OpenVPN не удался"
    fi
}

verify() {
    log_info "Проверяю результат"
    ip -brief address show tun0 || die "${EX_SOFTWARE}" "Интерфейс tun0 не поднялся"
    ss -lunp | grep -q ":${VPN_PORT}" || die "${EX_SOFTWARE}" "Порт ${VPN_PORT} не прослушивается"
    log_ok "tun0 поднят, порт ${VPN_PORT}/${VPN_PROTO} прослушивается"
}

main() {
    check_config_present
    install_certificates
    generate_tls_crypt_key
    enable_forwarding
    configure_firewall
    start_service
    verify

    local public_ip
    public_ip="$(curl -s --max-time 5 ifconfig.me || echo '<не определён>')"
    cat <<SUMMARY

VPN-сервер готов.
  Публичный адрес:  ${public_ip}
  Порт:             ${VPN_PORT}/${VPN_PROTO}
  Подсеть клиентов: ${VPN_SUBNET}

Выдать доступ сотруднику:
  1. Сотрудник у себя: ./gen-client-request.sh <имя>
  2. Присылает вам <имя>.req
  3. Вы на CA:         sudo infra-ca-sign client <имя> /tmp/<имя>.req
  4. Вы на VPN:        sudo infra-vpn-make-client <имя> /tmp/<имя>.crt
  5. Отдаёте сотруднику <имя>-bundle.tar.gz
SUMMARY
}

main "$@"
