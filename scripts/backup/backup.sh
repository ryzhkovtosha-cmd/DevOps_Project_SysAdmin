#!/usr/bin/env bash
# Создаёт зашифрованную резервную копию и отправляет её в два независимых
# места. Запускается по таймеру systemd раз в сутки.
#
# Использование:
#   sudo ./backup.sh <ca|vpn|artifacts>
#
# Что копируется:
#   ca         — инфраструктура открытых ключей удостоверяющего центра
#   vpn        — сертификаты и конфигурация VPN-сервера
#   artifacts  — скрипты и deb-пакеты инфраструктуры
#
# Копия шифруется ДО отправки: она содержит приватный ключ удостоверяющего
# центра. Незашифрованная копия на чужом диске равносильна компрометации
# всей системы доверия — злоумышленник сможет выпустить себе любой
# сертификат, и отличить его от легитимного будет невозможно.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

# project.env здесь НЕ подключается намеренно: скрипту он не нужен, все
# его параметры приходят из /etc/infra-backup/backup.conf. Лишний source —
# лишняя точка отказа ДО установки ловушки, которая пишет метрики. Именно
# так и случилось: чтение project.env падало на неустановленной HOME, и
# сбой не оставлял в мониторинге никаких следов.

readonly BACKUP_CONF="/etc/infra-backup/backup.conf"
readonly PASSPHRASE_FILE="/etc/infra-backup/passphrase"
readonly STAGING="/var/lib/infra-backup/staging"
readonly METRICS_DIR="/var/lib/node_exporter/textfile_collector"
readonly USAGE="$0 <ca|vpn|artifacts>"

# Сколько копий держать. Суточные за две недели покрывают типичный срок,
# за который замечают порчу данных; недельные за два месяца — на случай,
# когда проблему обнаружили поздно.
readonly KEEP_DAILY=14
readonly KEEP_WEEKLY=8

require_root
require_args "$#" 1 "${USAGE}"
require_cmd tar gpg sha256sum

JOB="$1"
START_TS="$(date +%s)"
EXIT_CODE=0

# Метрики пишем в любом случае — и при успехе, и при провале. Иначе
# сломавшаяся задача просто перестанет обновлять метку времени, и алерт
# BackupTooOld сработает лишь через сутки. Явный код ошибки даёт сигнал
# в течение десяти минут.
write_metrics() {
    local code="$1" size="${2:-0}"
    [[ -d "${METRICS_DIR}" ]] || return 0
    local out="${METRICS_DIR}/infra_backup.prom"
    local tmp
    tmp="$(mktemp "${out}.XXXXXX")"

    # Сохраняем строки по другим задачам: файл общий для ca, vpn и artifacts.
    if [[ -f "${out}" ]]; then
        grep -v "backup_job=\"${JOB}\"" "${out}" 2>/dev/null \
            | grep -v '^#' > "${tmp}" || true
    fi

    {
        printf '# HELP infra_backup_last_success_timestamp_seconds Время последнего успешного копирования\n'
        printf '# TYPE infra_backup_last_success_timestamp_seconds gauge\n'
        printf '# HELP infra_backup_last_exit_code Код возврата последнего запуска\n'
        printf '# TYPE infra_backup_last_exit_code gauge\n'
        printf '# HELP infra_backup_size_bytes Размер последней копии\n'
        printf '# TYPE infra_backup_size_bytes gauge\n'
        printf '# HELP infra_backup_duration_seconds Длительность последнего запуска\n'
        printf '# TYPE infra_backup_duration_seconds gauge\n'
    } >> "${tmp}"

    printf 'infra_backup_last_exit_code{backup_job="%s"} %s\n' "${JOB}" "${code}" >> "${tmp}"
    printf 'infra_backup_duration_seconds{backup_job="%s"} %s\n' \
        "${JOB}" "$(( $(date +%s) - START_TS ))" >> "${tmp}"
    if [[ "${code}" -eq 0 ]]; then
        printf 'infra_backup_last_success_timestamp_seconds{backup_job="%s"} %s\n' \
            "${JOB}" "$(date +%s)" >> "${tmp}"
        printf 'infra_backup_size_bytes{backup_job="%s"} %s\n' "${JOB}" "${size}" >> "${tmp}"
    elif [[ -f "${out}" ]]; then
        # При ошибке сохраняем прежнюю метку успеха — по ней видно,
        # насколько устарела последняя годная копия.
        grep "infra_backup_last_success_timestamp_seconds{backup_job=\"${JOB}\"}" "${out}" >> "${tmp}" 2>/dev/null || true
        grep "infra_backup_size_bytes{backup_job=\"${JOB}\"}" "${out}" >> "${tmp}" 2>/dev/null || true
    fi

    chmod 644 "${tmp}"
    mv "${tmp}" "${out}"
}

# Метрики пишутся при любом выходе, включая аварийный.
on_exit() {
    local code=$?
    [[ "${EXIT_CODE}" -ne 0 ]] && code="${EXIT_CODE}"
    if [[ "${code}" -ne 0 ]]; then
        log_error "Копирование ${JOB} завершилось с кодом ${code}"
        write_metrics "${code}" 0
    fi
    rm -rf "${STAGING:?}/${JOB}" 2>/dev/null || true
}
trap on_exit EXIT

# --- Настройки --------------------------------------------------------------

[[ -f "${BACKUP_CONF}" ]] || die "${EX_UNAVAILABLE}" \
    "Нет ${BACKUP_CONF}. Создайте его по образцу в docs/02-backup-policy.md"
# shellcheck source=/dev/null
source "${BACKUP_CONF}"

: "${BACKUP_HOST:?Не задан BACKUP_HOST в ${BACKUP_CONF}}"
: "${BACKUP_USER:?Не задан BACKUP_USER в ${BACKUP_CONF}}"
: "${BACKUP_REMOTE_DIR:?Не задан BACKUP_REMOTE_DIR в ${BACKUP_CONF}}"

[[ -f "${PASSPHRASE_FILE}" ]] || die "${EX_UNAVAILABLE}" \
    "Нет файла с парольной фразой ${PASSPHRASE_FILE}"
# Права проверяем явно: файл с ключом шифрования всех копий не должен быть
# доступен на чтение никому, кроме root.
PERMS="$(stat -c '%a' "${PASSPHRASE_FILE}")"
[[ "${PERMS}" == "600" || "${PERMS}" == "400" ]] || die "${EX_NOPERM}" \
    "Права на ${PASSPHRASE_FILE} должны быть 600, сейчас ${PERMS}"

# --- Что копировать в зависимости от задачи --------------------------------

case "${JOB}" in
    ca)
        SOURCES=("/var/lib/infra-ca/pki" "/var/lib/infra-ca/vars")
        MIN_SIZE=4096
        ;;
    vpn)
        SOURCES=("/etc/openvpn/server" "/etc/infra-vpn" "/var/lib/infra-vpn/pki")
        MIN_SIZE=4096
        ;;
    artifacts)
        SOURCES=("/srv/infra-artifacts")
        MIN_SIZE=1024
        ;;
    *)
        printf 'Использование: %s\n' "${USAGE}" >&2
        exit "${EX_USAGE}"
        ;;
esac

# Проверяем, что источники существуют. Молчаливое копирование пустоты —
# худший вид отказа: задача успешна, а копии нет.
EXISTING=()
for src in "${SOURCES[@]}"; do
    if [[ -e "${src}" ]]; then
        EXISTING+=("${src}")
    else
        log_warn "Источник не существует, пропускаю: ${src}"
    fi
done
[[ ${#EXISTING[@]} -gt 0 ]] || { EXIT_CODE="${EX_DATAERR}"; die "${EX_DATAERR}" \
    "Ни один источник для задачи ${JOB} не найден. Копировать нечего."; }

# --- Создание копии ---------------------------------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
ensure_dir "${STAGING}/${JOB}" 0700 "root:root"
ARCHIVE="${STAGING}/${JOB}/${JOB}-${STAMP}.tar.gz"
ENCRYPTED="${ARCHIVE}.gpg"

log_info "Создаю архив задачи ${JOB}"
tar -czf "${ARCHIVE}" --absolute-names "${EXISTING[@]}" 2>/dev/null \
    || { EXIT_CODE="${EX_SOFTWARE}"; die "${EX_SOFTWARE}" "Не удалось создать архив"; }

RAW_SIZE="$(stat -c '%s' "${ARCHIVE}")"
log_info "Размер архива: ${RAW_SIZE} байт"

# Порог правдоподобия. Архив меньше минимального означает, что в него
# попала пустая точка монтирования или каталог без данных.
if [[ "${RAW_SIZE}" -lt "${MIN_SIZE}" ]]; then
    EXIT_CODE="${EX_DATAERR}"
    die "${EX_DATAERR}" "Архив подозрительно мал (${RAW_SIZE} < ${MIN_SIZE} байт). Проверьте источники."
fi

log_info "Шифрую копию"
gpg --batch --yes --quiet \
    --symmetric --cipher-algo AES256 --digest-algo SHA512 \
    --passphrase-file "${PASSPHRASE_FILE}" \
    --output "${ENCRYPTED}" "${ARCHIVE}" \
    || { EXIT_CODE="${EX_SOFTWARE}"; die "${EX_SOFTWARE}" "Шифрование не удалось"; }

# Незашифрованный архив стираем немедленно.
shred -u "${ARCHIVE}" 2>/dev/null || rm -f "${ARCHIVE}"

# Контрольная сумма — чтобы при восстановлении отличить повреждённый файл
# от неверной парольной фразы.
sha256sum "${ENCRYPTED}" | awk '{print $1}' > "${ENCRYPTED}.sha256"
ENC_SIZE="$(stat -c '%s' "${ENCRYPTED}")"

# --- Отправка в место хранения ---------------------------------------------

REMOTE_PATH_FOR_JOB="${BACKUP_REMOTE_DIR}/${JOB}"

log_info "Отправляю на ${BACKUP_HOST}"
# Разбираем причину отказа: «сервер не отвечает» и «сервер не принял ключ»
# лечатся по-разному, а общее «недоступен» отправляет искать не туда.
SSH_ERR="$(ssh -o BatchMode=yes -o ConnectTimeout=15 "${BACKUP_USER}@${BACKUP_HOST}" \
    "mkdir -p ${BACKUP_REMOTE_DIR}/${JOB} && chmod 700 ${BACKUP_REMOTE_DIR}/${JOB}" 2>&1)" || {
    if printf '%s' "${SSH_ERR}" | grep -q 'Permission denied'; then
        EXIT_CODE="${EX_NOPERM}"
        die "${EX_NOPERM}" "Сервер хранения не принял ключ пользователя ${BACKUP_USER}. \
Проверьте, что публичный ключ этой машины есть в authorized_keys и что домашний \
каталог пользователя — ${BACKUP_REMOTE_DIR}: getent passwd ${BACKUP_USER}"
    elif printf '%s' "${SSH_ERR}" | grep -q 'not available'; then
        EXIT_CODE="${EX_NOPERM}"
        die "${EX_NOPERM}" "У пользователя ${BACKUP_USER} на сервере хранения нет оболочки (nologin)"
    else
        EXIT_CODE="${EX_UNAVAILABLE}"
        die "${EX_UNAVAILABLE}" "Сервер хранения ${BACKUP_HOST} не отвечает: ${SSH_ERR}"
    fi
}

scp -q -o BatchMode=yes -o ConnectTimeout=15 \
    "${ENCRYPTED}" "${ENCRYPTED}.sha256" \
    "${BACKUP_USER}@${BACKUP_HOST}:${BACKUP_REMOTE_DIR}/${JOB}/" \
    || { EXIT_CODE="${EX_UNAVAILABLE}"; die "${EX_UNAVAILABLE}" "Передача не удалась"; }

# Проверяем, что на той стороне файл целый. Без этого мы знаем лишь, что
# scp не вернул ошибку, а не что данные доехали неповреждёнными.
LOCAL_SUM="$(cat "${ENCRYPTED}.sha256")"
REMOTE_SUM="$(ssh -o BatchMode=yes "${BACKUP_USER}@${BACKUP_HOST}" \
    "sha256sum ${BACKUP_REMOTE_DIR}/${JOB}/$(basename "${ENCRYPTED}") | awk '{print \$1}'" 2>/dev/null || true)"
if [[ "${LOCAL_SUM}" != "${REMOTE_SUM}" ]]; then
    EXIT_CODE="${EX_DATAERR}"
    die "${EX_DATAERR}" "Контрольные суммы не совпали: копия доехала повреждённой"
fi
log_ok "Копия доставлена и проверена по контрольной сумме"

# --- Второе независимое место (объектное хранилище) ------------------------

if [[ -n "${S3_BUCKET:-}" ]] && command -v aws >/dev/null 2>&1; then
    log_info "Дублирую в объектное хранилище ${S3_BUCKET}"
    if aws --endpoint-url="${S3_ENDPOINT:-https://storage.yandexcloud.net}" \
        s3 cp "${ENCRYPTED}" "s3://${S3_BUCKET}/${JOB}/" --only-show-errors; then
        log_ok "Копия в объектном хранилище размещена"
    else
        # Отказ второго места — не повод считать задачу проваленной:
        # первая копия уже доставлена и проверена.
        log_warn "Не удалось отправить в объектное хранилище, основная копия сохранена"
    fi
else
    log_info "Объектное хранилище не настроено, пропускаю"
fi

# --- Ротация ----------------------------------------------------------------

log_info "Убираю устаревшие копии"
# Здесь-документ в кавычках: подстановка переменных происходит НА СЕРВЕРЕ
# хранения, а не здесь. Параметры передаются позиционными аргументами —
# иначе локальные значения подставились бы в текст скрипта, и любой символ
# вроде кавычки в пути сломал бы удалённый разбор.
ssh -o BatchMode=yes "${BACKUP_USER}@${BACKUP_HOST}" \
    "bash -s -- '${REMOTE_PATH_FOR_JOB}' '${KEEP_DAILY}' '${KEEP_WEEKLY}'" <<'ROTATE' \
    || log_warn "Ротация не выполнена, старые копии остались"
set -euo pipefail
dir="$1"; keep_daily="$2"; keep_weekly="$3"
cd "$dir" 2>/dev/null || exit 0

# Политика хранения:
#   1) последние N копий держим всегда — это суточная глубина;
#   2) из более старых оставляем только воскресные, не более M штук;
#   3) всё остальное удаляем.
# Смысл двух уровней: суточные покрывают срок, за который обычно замечают
# порчу данных; недельные нужны, когда проблему обнаружили поздно.

mapfile -t all < <(ls -1t ./*.gpg 2>/dev/null || true)
[ "${#all[@]}" -gt 0 ] || exit 0

weekly_kept=0
index=0
for file in "${all[@]}"; do
    index=$((index + 1))
    # Свежие копии не трогаем.
    if [ "$index" -le "$keep_daily" ]; then
        continue
    fi
    # Дату берём из имени файла вида <задача>-ГГГГММДД-ЧЧММСС.tar.gz.gpg
    stamp="$(printf '%s' "$file" | grep -oE '[0-9]{8}' | head -1)"
    weekday=""
    if [ -n "$stamp" ]; then
        weekday="$(date -d "$stamp" +%u 2>/dev/null || true)"
    fi
    if [ "$weekday" = "7" ] && [ "$weekly_kept" -lt "$keep_weekly" ]; then
        weekly_kept=$((weekly_kept + 1))
        continue
    fi
    rm -f -- "$file" "$file.sha256"
    printf 'удалена устаревшая копия: %s\n' "$file"
done
ROTATE

write_metrics 0 "${ENC_SIZE}"
log_ok "Копирование задачи ${JOB} завершено успешно (${ENC_SIZE} байт)"
