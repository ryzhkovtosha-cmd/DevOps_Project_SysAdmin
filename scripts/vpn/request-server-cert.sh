#!/usr/bin/env bash
# Шаг 1 из 2 настройки VPN-сервера: создаёт приватный ключ сервера и запрос
# на подпись сертификата.
#
# Использование:
#   sudo ./request-server-cert.sh [имя]        (по умолчанию vpn-server)
#
# Приватный ключ остаётся на этой машине и никуда не передаётся. Наружу
# уходит только .req — запрос, из которого ключ невосстановим.
#
# После выполнения:
#   1. Скопируйте .req на машину CA
#   2. Там: sudo infra-ca-sign server vpn-server /tmp/vpn-server.req
#   3. Заберите обратно .crt и ca.crt
#   4. Запустите setup-vpn-server.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../project.env
source "${SCRIPT_DIR}/../project.env"

readonly VPN_HOME="/var/lib/infra-vpn"
readonly VPN_PKI="${VPN_HOME}/pki"

require_root

SERVER_CN="${1:-vpn-server}"
validate_name "${SERVER_CN}"

apt_install easy-rsa openssl

ensure_dir "${VPN_HOME}" 0700 "root:root"
# Линкуем ВСЕ файлы easy-rsa: помимо самого скрипта нужны шаблон
# openssl-easyrsa.cnf и каталог x509-types, иначе gen-req не отработает.
ln -sf /usr/share/easy-rsa/* "${VPN_HOME}/"

# Локальный vars — только алгоритм. Реквизиты организации подставит CA
# при подписи, дублировать их здесь незачем.
if [[ ! -f "${VPN_HOME}/vars" ]]; then
    cat > "${VPN_HOME}/vars" <<'VARS'
set_var EASYRSA_ALGO   "ec"
set_var EASYRSA_CURVE  "secp384r1"
set_var EASYRSA_DIGEST "sha512"
VARS
    chmod 600 "${VPN_HOME}/vars"
fi

if [[ ! -d "${VPN_PKI}" ]]; then
    log_info "Инициализирую локальную PKI VPN-сервера"
    ( cd "${VPN_HOME}" && EASYRSA="${VPN_HOME}" EASYRSA_PKI="${VPN_PKI}" ./easyrsa --batch init-pki >/dev/null )
fi

if [[ -f "${VPN_PKI}/private/${SERVER_CN}.key" ]]; then
    log_info "Ключ сервера уже существует, новый не создаю"
else
    log_info "Генерирую ключ и запрос на сертификат для CN=${SERVER_CN}"
    # nopass обязателен: служба стартует без участия человека и не сможет
    # ввести парольную фразу. Ключ защищён правами доступа файловой системы.
    # EASYRSA_REQ_CN обязателен. Имя в команде gen-req задаёт только имя
    # ФАЙЛОВ, а Common Name внутри запроса берётся из этой переменной.
    # В режиме --batch easyrsa не спрашивает его у оператора и молча
    # подставляет своё значение по умолчанию — ChangeMe.
    ( cd "${VPN_HOME}" && EASYRSA="${VPN_HOME}" EASYRSA_PKI="${VPN_PKI}" \
        EASYRSA_REQ_CN="${SERVER_CN}" \
        ./easyrsa --batch gen-req "${SERVER_CN}" nopass >/dev/null )

    # Проверяем результат: молчаливая подстановка чужого CN — ровно тот
    # случай, который обнаруживается сильно позже и не в том месте.
    actual_cn=""
    actual_cn="$(openssl req -in "${VPN_PKI}/reqs/${SERVER_CN}.req" -noout -subject 2>/dev/null \
                 | sed -n 's/.*CN\s*=\s*\([^,/]*\).*/\1/p' | xargs)"
    [[ "${actual_cn}" == "${SERVER_CN}" ]] || die "${EX_SOFTWARE}" \
        "В запросе оказался CN='${actual_cn}' вместо '${SERVER_CN}'"
    log_ok "Common Name в запросе: ${actual_cn}"
    chmod 600 "${VPN_PKI}/private/${SERVER_CN}.key"
fi

REQ="${VPN_PKI}/reqs/${SERVER_CN}.req"
[[ -f "${REQ}" ]] || die "${EX_SOFTWARE}" "Запрос не создан: ${REQ}"

# Копия запроса в /tmp с открытыми правами — чтобы обычный пользователь
# мог забрать её по scp, не подключаясь root'ом.
cp "${REQ}" "/tmp/${SERVER_CN}.req"
chmod 644 "/tmp/${SERVER_CN}.req"

log_ok "Запрос готов: /tmp/${SERVER_CN}.req"
printf '\nОтпечаток запроса (продиктуйте оператору CA для сверки):\n'
openssl req -in "${REQ}" -noout -pubkey | openssl sha256

cat <<NEXT

Дальнейшие шаги:
  1. На своей машине:   scp ${SSH_USER}@<vpn-ip>:/tmp/${SERVER_CN}.req ./
  2. Загрузите на CA:   scp ${SERVER_CN}.req ${SSH_USER}@<ca-ip>:/tmp/
  3. На CA:             sudo infra-ca-sign server ${SERVER_CN} /tmp/${SERVER_CN}.req
  4. Заберите:          scp -r ${SSH_USER}@<ca-ip>:/var/lib/infra-ca/outgoing/${SERVER_CN} ./
  5. Загрузите на VPN:  scp ${SERVER_CN}/*.crt ${SSH_USER}@<vpn-ip>:/tmp/
  6. На VPN:            sudo ./setup-vpn-server.sh /tmp/${SERVER_CN}.crt /tmp/ca.crt
NEXT
