#!/usr/bin/env bash
# Восстанавливает данные из резервной копии.
#
# Использование:
#   sudo ./restore.sh <ca|vpn|artifacts> [имя-файла-копии]
#   sudo ./restore.sh --list <ca|vpn|artifacts>
#   sudo ./restore.sh --verify <ca|vpn|artifacts>
#
# Без указания файла берётся самая свежая копия.
#
# Восстановление идёт НЕ поверх рабочих данных, а в отдельный каталог.
# Оператор сам решает, что и куда переносить. Автоматическая перезапись
# рабочей PKI из старой копии уничтожила бы все сертификаты, выпущенные
# после её создания, — и восстановить их было бы уже неоткуда.
#
# Режим --verify предназначен для регулярной проверки: копия, которую
# ни разу не пробовали развернуть, не является резервной копией.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

readonly BACKUP_CONF="/etc/infra-backup/backup.conf"
readonly PASSPHRASE_FILE="/etc/infra-backup/passphrase"
readonly RESTORE_DIR="/var/lib/infra-backup/restore"
readonly USAGE="$0 [--list|--verify] <ca|vpn|artifacts> [файл.gpg]"

require_root
require_args "$#" 1 "${USAGE}"
require_cmd gpg tar sha256sum ssh scp

MODE="restore"
case "$1" in
    --list)   MODE="list";   shift ;;
    --verify) MODE="verify"; shift ;;
    --*)      die "${EX_USAGE}" "Неизвестный режим: $1" ;;
esac

require_args "$#" 1 "${USAGE}"
JOB="$1"
WANTED="${2:-}"

case "${JOB}" in
    ca|vpn|artifacts) ;;
    *) die "${EX_USAGE}" "Задача должна быть ca, vpn или artifacts" ;;
esac

[[ -f "${BACKUP_CONF}" ]] || die "${EX_UNAVAILABLE}" "Нет ${BACKUP_CONF}"
# shellcheck source=/dev/null
source "${BACKUP_CONF}"
: "${BACKUP_HOST:?}" "${BACKUP_USER:?}" "${BACKUP_REMOTE_DIR:?}"

REMOTE_PATH="${BACKUP_REMOTE_DIR}/${JOB}"

list_backups() {
    ssh -o BatchMode=yes -o ConnectTimeout=15 "${BACKUP_USER}@${BACKUP_HOST}" \
        "ls -1t ${REMOTE_PATH}/*.gpg 2>/dev/null | xargs -r -n1 basename" \
        || die "${EX_UNAVAILABLE}" "Сервер бэкапов недоступен"
}

if [[ "${MODE}" == "list" ]]; then
    log_info "Доступные копии задачи ${JOB}:"
    list_backups | nl -w3 -s'. ' | sed 's/^/  /'
    exit 0
fi

# --- Выбор копии ------------------------------------------------------------

if [[ -z "${WANTED}" ]]; then
    WANTED="$(list_backups | head -1)"
    [[ -n "${WANTED}" ]] || die "${EX_DATAERR}" "Копий задачи ${JOB} не найдено"
    log_info "Беру самую свежую копию: ${WANTED}"
fi

ensure_dir "${RESTORE_DIR}" 0700 "root:root"
WORK="${RESTORE_DIR}/${JOB}-$(date +%Y%m%d-%H%M%S)"
ensure_dir "${WORK}" 0700 "root:root"

log_info "Скачиваю ${WANTED}"
scp -q -o BatchMode=yes "${BACKUP_USER}@${BACKUP_HOST}:${REMOTE_PATH}/${WANTED}" "${WORK}/" \
    || die "${EX_UNAVAILABLE}" "Не удалось скачать копию"
scp -q -o BatchMode=yes "${BACKUP_USER}@${BACKUP_HOST}:${REMOTE_PATH}/${WANTED}.sha256" "${WORK}/" \
    2>/dev/null || log_warn "Файл контрольной суммы отсутствует, проверка целостности пропущена"

# --- Проверка целостности ---------------------------------------------------

if [[ -f "${WORK}/${WANTED}.sha256" ]]; then
    log_info "Сверяю контрольную сумму"
    EXPECTED="$(cat "${WORK}/${WANTED}.sha256")"
    ACTUAL="$(sha256sum "${WORK}/${WANTED}" | awk '{print $1}')"
    [[ "${EXPECTED}" == "${ACTUAL}" ]] || die "${EX_DATAERR}" \
        "Контрольная сумма не совпала — файл повреждён. Возьмите более раннюю копию."
    log_ok "Целостность подтверждена"
fi

# --- Расшифровка ------------------------------------------------------------

[[ -f "${PASSPHRASE_FILE}" ]] || die "${EX_UNAVAILABLE}" \
    "Нет ${PASSPHRASE_FILE}. Без парольной фразы копия бесполезна."

log_info "Расшифровываю"
gpg --batch --yes --quiet --decrypt \
    --passphrase-file "${PASSPHRASE_FILE}" \
    --output "${WORK}/archive.tar.gz" "${WORK}/${WANTED}" \
    || die "${EX_DATAERR}" "Расшифровка не удалась: неверная парольная фраза или файл повреждён"

log_info "Распаковываю"
ensure_dir "${WORK}/data" 0700 "root:root"
tar -xzf "${WORK}/archive.tar.gz" -C "${WORK}/data" \
    || die "${EX_DATAERR}" "Архив не распаковывается"

rm -f "${WORK}/archive.tar.gz" "${WORK}/${WANTED}"

# --- Проверка содержимого ---------------------------------------------------

log_info "Проверяю содержимое копии"
case "${JOB}" in
    ca)
        CA_CRT="$(find "${WORK}/data" -name 'ca.crt' | head -1)"
        CA_KEY="$(find "${WORK}/data" -path '*private/ca.key' | head -1)"
        [[ -n "${CA_CRT}" ]] || die "${EX_DATAERR}" "В копии нет корневого сертификата"
        [[ -n "${CA_KEY}" ]] || die "${EX_DATAERR}" "В копии нет приватного ключа центра"

        # Ключ и сертификат обязаны быть парой: иначе копия негодна,
        # и узнать об этом лучше сейчас, а не в момент настоящей аварии.
        CRT_PUB="$(openssl x509 -in "${CA_CRT}" -noout -pubkey | openssl sha256)"
        KEY_PUB="$(openssl pkey -in "${CA_KEY}" -pubout 2>/dev/null | openssl sha256)"
        [[ "${CRT_PUB}" == "${KEY_PUB}" ]] || die "${EX_DATAERR}" \
            "Ключ и сертификат в копии не соответствуют друг другу"

        ISSUED_COUNT="$(find "${WORK}/data" -path '*issued/*.crt' | wc -l)"
        log_ok "Копия корректна: корневой сертификат + ключ, выпущено сертификатов: ${ISSUED_COUNT}"
        openssl x509 -in "${CA_CRT}" -noout -subject -dates | sed 's/^/    /'
        ;;
    vpn)
        SRV_CRT="$(find "${WORK}/data" -name 'server.crt' | head -1)"
        [[ -n "${SRV_CRT}" ]] || die "${EX_DATAERR}" "В копии нет сертификата сервера"
        [[ -n "$(find "${WORK}/data" -name 'ta.key' | head -1)" ]] \
            || log_warn "В копии нет ta.key — клиентам понадобится новый ключ tls-crypt"
        log_ok "Копия корректна"
        openssl x509 -in "${SRV_CRT}" -noout -subject -dates | sed 's/^/    /'
        ;;
    artifacts)
        DEB_COUNT="$(find "${WORK}/data" -name '*.deb' | wc -l)"
        SH_COUNT="$(find "${WORK}/data" -name '*.sh' | wc -l)"
        [[ "${DEB_COUNT}" -gt 0 || "${SH_COUNT}" -gt 0 ]] \
            || die "${EX_DATAERR}" "В копии нет ни пакетов, ни скриптов"
        log_ok "Копия корректна: пакетов ${DEB_COUNT}, скриптов ${SH_COUNT}"
        ;;
esac

# --- Итог -------------------------------------------------------------------

if [[ "${MODE}" == "verify" ]]; then
    # Проверочный режим: убедились, что копия разворачивается, и убрали
    # за собой. Расшифрованные ключи не должны оставаться на диске.
    log_ok "Копия ${WANTED} проверена: расшифровывается, распаковывается, содержимое на месте"
    rm -rf "${WORK}"
    log_info "Временные данные удалены"
    exit 0
fi

cat <<SUMMARY

Копия развёрнута в: ${WORK}/data

ВНИМАНИЕ. Рабочие данные НЕ перезаписаны намеренно. Сравните содержимое
и переносите осознанно — копия может быть старше текущего состояния,
и слепая перезапись уничтожит сертификаты, выпущенные после её создания.

Для удостоверяющего центра:
  diff -rq ${WORK}/data/var/lib/infra-ca/pki /var/lib/infra-ca/pki
  # убедились, что копия новее или рабочие данные утрачены:
  rsync -a ${WORK}/data/var/lib/infra-ca/ /var/lib/infra-ca/
  chmod 700 /var/lib/infra-ca
  chmod 600 /var/lib/infra-ca/pki/private/ca.key

После переноса УДАЛИТЕ временный каталог — в нём лежат приватные ключи:
  shred -u ${WORK}/data/var/lib/infra-ca/pki/private/* 2>/dev/null
  rm -rf ${WORK}

SUMMARY
