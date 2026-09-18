#!/usr/bin/env bash
# Выпускает доступ сотруднику. Запускается НА МАШИНЕ АДМИНИСТРАТОРА.
#
# Использование:
#   ./issue-client-cert.sh <имя> <путь-к-присланному.req>
#
# Пример:
#   ./issue-client-cert.sh ivanov ~/Downloads/ivanov.req
#
# Что делает:
#   1. проверяет, что присланный файл действительно является запросом;
#   2. показывает его отпечаток для сверки с сотрудником;
#   3. подписывает запрос на удостоверяющем центре;
#   4. собирает на VPN-сервере комплект файлов;
#   5. забирает комплект, готовый к отправке сотруднику.
#
# Приватный ключ сотрудника в этой цепочке не участвует: он остаётся на его
# машине с момента создания запроса. Поэтому итоговый архив можно переслать
# обычной почтой — без ключа получателя он бесполезен.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../project.env
source "${SCRIPT_DIR}/../project.env"

readonly USAGE="$0 <имя> <путь-к-запросу.req>"
require_args "$#" 2 "${USAGE}"
require_cmd ssh scp openssl

CLIENT_NAME="$1"
REQ_FILE="$2"
validate_name "${CLIENT_NAME}"
[[ -f "${REQ_FILE}" ]] || die "${EX_DATAERR}" "Файл запроса не найден: ${REQ_FILE}"

OUT_DIR="${OUT_DIR:-$PWD}"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT INT TERM

resolve_host() {
    local vm_name="$1"
    require_cmd yc
    yc compute instance get --name "${vm_name}" --format json 2>/dev/null \
        | grep -oP '"address":\s*"\K[0-9.]+' | tail -1
}

CA_HOST="${CA_HOST:-$(resolve_host "${CA_VM}")}"
VPN_HOST="${VPN_HOST:-$(resolve_host "${VPN_VM}")}"
[[ -n "${CA_HOST}" ]]  || die "${EX_UNAVAILABLE}" "Задайте адрес центра: CA_HOST=1.2.3.4 $0 ..."
[[ -n "${VPN_HOST}" ]] || die "${EX_UNAVAILABLE}" "Задайте адрес VPN: VPN_HOST=1.2.3.4 $0 ..."

# --- Шаг 1. Проверка присланного запроса ----------------------------------

openssl req -in "${REQ_FILE}" -noout -verify >/dev/null 2>&1 \
    || die "${EX_DATAERR}" "Файл ${REQ_FILE} не является корректным запросом на сертификат"

REQ_CN="$(openssl req -in "${REQ_FILE}" -noout -subject 2>/dev/null \
          | sed -n 's/.*CN\s*=\s*\([^,/]*\).*/\1/p' | xargs)"
log_info "Common Name в запросе: ${REQ_CN}"
if [[ "${REQ_CN}" != "${CLIENT_NAME}" ]]; then
    log_warn "CN в запросе (${REQ_CN}) не совпадает с указанным именем (${CLIENT_NAME})"
    confirm "Продолжить?" || die "${EX_DATAERR}" "Отменено"
fi

printf '\n'
log_warn "СВЕРЬТЕ ОТПЕЧАТОК с сотрудником по независимому каналу."
log_warn "Это единственная защита от подмены запроса по дороге."
openssl req -in "${REQ_FILE}" -noout -pubkey | openssl sha256 | sed 's/^/    /'
printf '\n'
confirm "Отпечаток совпал, подписывать?" || die "${EX_DATAERR}" "Отменено оператором"

# --- Шаг 2. Подпись на удостоверяющем центре ------------------------------

log_info "Передаю запрос на центр ${CA_HOST}"
scp -q "${REQ_FILE}" "${SSH_USER}@${CA_HOST}:/tmp/${CLIENT_NAME}.req" \
    || die "${EX_UNAVAILABLE}" "Передача не удалась"

log_warn "Центр запросит парольную фразу приватного ключа."
ssh -t "${SSH_USER}@${CA_HOST}" \
    "sudo infra-ca-sign client ${CLIENT_NAME} /tmp/${CLIENT_NAME}.req" \
    || die "${EX_SOFTWARE}" "Подписание не удалось"

log_info "Забираю выпущенный сертификат"
# Через sudo cat: каталог центра закрыт правами 0700 root:root,
# и scp от имени обычного пользователя в него не войдёт.
ssh -o BatchMode=yes "${SSH_USER}@${CA_HOST}" \
    "sudo cat '/var/lib/infra-ca/outgoing/${CLIENT_NAME}/${CLIENT_NAME}.crt'" \
    > "${WORK}/${CLIENT_NAME}.crt" 2>/dev/null
[[ -s "${WORK}/${CLIENT_NAME}.crt" ]] \
    || die "${EX_UNAVAILABLE}" "Не удалось забрать сертификат"

# --- Шаг 3. Сборка комплекта на VPN-сервере -------------------------------

log_info "Собираю комплект на VPN-сервере"
scp -q "${WORK}/${CLIENT_NAME}.crt" "${SSH_USER}@${VPN_HOST}:/tmp/" \
    || die "${EX_UNAVAILABLE}" "Передача на VPN-сервер не удалась"

ssh -t "${SSH_USER}@${VPN_HOST}" \
    "sudo infra-vpn-make-client ${CLIENT_NAME} /tmp/${CLIENT_NAME}.crt" \
    || die "${EX_SOFTWARE}" "Сборка комплекта не удалась"

log_info "Забираю комплект"
ssh "${SSH_USER}@${VPN_HOST}" \
    "sudo cp /var/lib/infra-vpn/clients/${CLIENT_NAME}-bundle.tar.gz /tmp/ && sudo chown ${SSH_USER}: /tmp/${CLIENT_NAME}-bundle.tar.gz" \
    || die "${EX_SOFTWARE}" "Не удалось подготовить комплект к передаче"
scp -q "${SSH_USER}@${VPN_HOST}:/tmp/${CLIENT_NAME}-bundle.tar.gz" "${OUT_DIR}/" \
    || die "${EX_UNAVAILABLE}" "Не удалось забрать комплект"

# Временную копию на сервере убираем: в архиве общий ключ tls-crypt.
ssh "${SSH_USER}@${VPN_HOST}" "rm -f /tmp/${CLIENT_NAME}-bundle.tar.gz /tmp/${CLIENT_NAME}.crt" || true

chmod 600 "${OUT_DIR}/${CLIENT_NAME}-bundle.tar.gz"

cat <<SUMMARY

Комплект готов: ${OUT_DIR}/${CLIENT_NAME}-bundle.tar.gz

Отправьте его сотруднику. Он выполнит у себя:
  ./assemble-config.sh ${CLIENT_NAME}-bundle.tar.gz

и получит файл ~/.infra-vpn/${CLIENT_NAME}.ovpn для подключения.

Внутри архива общий ключ tls-crypt — не выкладывайте его в публичный доступ,
хотя без приватного ключа получателя подключиться по нему нельзя.

SUMMARY
