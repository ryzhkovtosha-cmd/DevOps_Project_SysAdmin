#!/usr/bin/env bash
# Выпускает сертификат для VPN-сервера. Запускается НА МАШИНЕ АДМИНИСТРАТОРА,
# не на серверах: только у неё есть доступ по SSH и к центру, и к VPN.
#
# Использование:
#   ./issue-server-cert.sh [имя-сервера]        (по умолчанию vpn-server)
#
# Переменные окружения для переопределения адресов:
#   CA_HOST=1.2.3.4 VPN_HOST=5.6.7.8 ./issue-server-cert.sh
#
# Что делает по шагам:
#   1. на VPN-сервере создаёт ключ и запрос на сертификат;
#   2. забирает ТОЛЬКО запрос — приватный ключ остаётся на сервере;
#   3. показывает отпечаток запроса для сверки;
#   4. отправляет запрос на удостоверяющий центр и подписывает его;
#   5. забирает сертификат, сертификат центра и список отзыва;
#   6. раскладывает их на VPN-сервере и запускает службу.
#
# Шаг 4 интерактивен: центр запросит парольную фразу приватного ключа.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../project.env
source "${SCRIPT_DIR}/../project.env"

require_cmd ssh scp openssl

SERVER_CN="${1:-vpn-server}"
validate_name "${SERVER_CN}"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT INT TERM

# Публичный адрес машины. Внутренние адреса из project.env отсюда
# недостижимы: администратор находится вне облачной сети.
resolve_host() {
    local vm_name="$1"
    require_cmd yc
    yc compute instance get --name "${vm_name}" --format json 2>/dev/null \
        | grep -oP '"address":\s*"\K[0-9.]+' | tail -1
}

CA_HOST="${CA_HOST:-$(resolve_host "${CA_VM}")}"
VPN_HOST="${VPN_HOST:-$(resolve_host "${VPN_VM}")}"

[[ -n "${CA_HOST}" ]]  || die "${EX_UNAVAILABLE}" \
    "Не удалось определить адрес ${CA_VM}. Задайте вручную: CA_HOST=1.2.3.4 $0"
[[ -n "${VPN_HOST}" ]] || die "${EX_UNAVAILABLE}" \
    "Не удалось определить адрес ${VPN_VM}. Задайте вручную: VPN_HOST=1.2.3.4 $0"

log_info "Удостоверяющий центр: ${CA_HOST}"
log_info "VPN-сервер:           ${VPN_HOST}"

ca()  { ssh -o BatchMode=yes -o ConnectTimeout=15 "${SSH_USER}@${CA_HOST}" "$@"; }
vpn() { ssh -o BatchMode=yes -o ConnectTimeout=15 "${SSH_USER}@${VPN_HOST}" "$@"; }

# --- Шаг 0. Доступность обеих машин --------------------------------------
log_info "Проверяю доступность машин"
ca  'true' || die "${EX_UNAVAILABLE}" "Нет доступа по SSH к ${CA_HOST}"
vpn 'true' || die "${EX_UNAVAILABLE}" "Нет доступа по SSH к ${VPN_HOST}"
# sudo обязателен: /var/lib/infra-ca имеет права 0700 root:root, и обычный
# пользователь не может даже войти в каталог, чтобы проверить содержимое.
ca  'sudo test -d /var/lib/infra-ca/pki' \
    || die "${EX_UNAVAILABLE}" "На ${CA_HOST} не развёрнут центр. Выполните там: sudo infra-ca-init"
log_ok "Обе машины доступны"

# --- Шаг 1. Ключ и запрос на VPN-сервере ---------------------------------
if vpn "sudo test -f /var/lib/infra-vpn/pki/private/${SERVER_CN}.key" 2>/dev/null; then
    log_info "Ключ сервера уже создан, использую существующий запрос"
else
    log_info "Создаю ключ и запрос на ${VPN_HOST}"
    vpn "test -x ~/scripts/vpn/request-server-cert.sh" \
        || die "${EX_UNAVAILABLE}" \
           "На VPN-сервере нет ~/scripts/vpn/request-server-cert.sh. Скопируйте каталог scripts."
    vpn "sudo ~/scripts/vpn/request-server-cert.sh ${SERVER_CN}" \
        || die "${EX_SOFTWARE}" "Создание запроса не удалось"
fi

# --- Шаг 2. Забираем ТОЛЬКО запрос ----------------------------------------
log_info "Забираю запрос на сертификат"
scp -q "${SSH_USER}@${VPN_HOST}:/tmp/${SERVER_CN}.req" "${WORK}/" \
    || die "${EX_UNAVAILABLE}" "Не удалось забрать запрос"

openssl req -in "${WORK}/${SERVER_CN}.req" -noout -verify >/dev/null 2>&1 \
    || die "${EX_DATAERR}" "Полученный файл не является запросом на сертификат"

printf '\n'
log_info "Отпечаток запроса — сверьте его при необходимости:"
openssl req -in "${WORK}/${SERVER_CN}.req" -noout -pubkey | openssl sha256 | sed 's/^/    /'
printf '\n'

# --- Шаг 3. Подпись на центре ---------------------------------------------
log_info "Отправляю запрос на удостоверяющий центр"
scp -q "${WORK}/${SERVER_CN}.req" "${SSH_USER}@${CA_HOST}:/tmp/" \
    || die "${EX_UNAVAILABLE}" "Не удалось передать запрос на центр"

log_warn "Сейчас центр запросит парольную фразу приватного ключа."
# -t выделяет терминал: без него ввод парольной фразы невозможен.
ssh -t "${SSH_USER}@${CA_HOST}" \
    "sudo infra-ca-sign server ${SERVER_CN} /tmp/${SERVER_CN}.req" \
    || die "${EX_SOFTWARE}" "Подписание не удалось"

# --- Шаг 4. Забираем сертификат, корневой сертификат и список отзыва ------
log_info "Забираю выпущенные файлы"

# Читаем через sudo cat, а не через scp. Файлы лежат внутри
# /var/lib/infra-ca с правами 0700 root:root: scp работает от имени
# обычного пользователя и не сможет войти в каталог. Ослаблять права на
# каталог с приватным ключом центра ради удобства копирования не стоит.
fetch_from_ca() {
    local remote="$1" local_path="$2"
    ca "sudo cat '${remote}'" > "${local_path}" 2>/dev/null \
        && [[ -s "${local_path}" ]]
}

fetch_from_ca "/var/lib/infra-ca/outgoing/${SERVER_CN}/${SERVER_CN}.crt" \
              "${WORK}/${SERVER_CN}.crt" \
    || die "${EX_UNAVAILABLE}" "Не удалось забрать сертификат"
fetch_from_ca "/var/lib/infra-ca/outgoing/${SERVER_CN}/ca.crt" "${WORK}/ca.crt" \
    || die "${EX_UNAVAILABLE}" "Не удалось забрать сертификат центра"

# Список отзыва обязателен: без него служба не запустится.
# Обновляем его перед выдачей, чтобы на сервер уехал свежий.
log_info "Обновляю список отзыва на центре"
ssh -t "${SSH_USER}@${CA_HOST}" \
    'sudo sh -c "cd /var/lib/infra-ca && EASYRSA=/var/lib/infra-ca EASYRSA_PKI=/var/lib/infra-ca/pki ./easyrsa gen-crl && cp pki/crl.pem outgoing/crl.pem && chmod 644 outgoing/crl.pem"' \
    || log_warn "Не удалось обновить список отзыва, беру имеющийся"
fetch_from_ca "/var/lib/infra-ca/outgoing/crl.pem" "${WORK}/crl.pem" \
    || die "${EX_UNAVAILABLE}" "Не удалось забрать список отзыва"

log_info "Проверяю цепочку доверия локально"
openssl verify -CAfile "${WORK}/ca.crt" "${WORK}/${SERVER_CN}.crt" >/dev/null 2>&1 \
    || die "${EX_DATAERR}" "Сертификат не проходит проверку по ca.crt"
log_ok "Сертификат корректен"

# --- Шаг 5. Раскладываем на VPN-сервере и запускаем -----------------------
log_info "Передаю файлы на VPN-сервер"
scp -q "${WORK}/${SERVER_CN}.crt" "${WORK}/ca.crt" "${WORK}/crl.pem" \
    "${SSH_USER}@${VPN_HOST}:/tmp/" \
    || die "${EX_UNAVAILABLE}" "Передача на VPN-сервер не удалась"

log_info "Запускаю настройку VPN-сервера"
ssh -t "${SSH_USER}@${VPN_HOST}" \
    "sudo ~/scripts/vpn/setup-vpn-server.sh /tmp/${SERVER_CN}.crt /tmp/ca.crt /tmp/crl.pem ${SERVER_CN}" \
    || die "${EX_SOFTWARE}" "Настройка VPN-сервера не удалась"

cat <<SUMMARY

Сертификат выпущен, VPN-сервер настроен и запущен.

  Публичный адрес: ${VPN_HOST}
  Порт:            ${VPN_PORT}/${VPN_PROTO}

Проверка:
  ssh ${SSH_USER}@${VPN_HOST} 'sudo ~/scripts/test/verify.sh vpn'

Выдать доступ сотруднику:
  ./issue-client-cert.sh <имя> <путь-к-присланному.req>

SUMMARY
