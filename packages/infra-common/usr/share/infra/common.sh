# shellcheck shell=bash
# shellcheck disable=SC2034  # константы и функции библиотеки используются
#                            # вызывающими скриптами, а не ею самой
# Это БИБЛИОТЕКА, а не исполняемый скрипт: она подключается через source.
# Shebang намеренно отсутствует — файл не предназначен для прямого запуска,
# и Debian Policy требует, чтобы неисполняемые файлы его не имели.
# Общая библиотека для всех скриптов проекта.
# Подключается так:  source "$(dirname "$0")/../lib/common.sh"
#
# Даёт: единообразное логирование, аварийный выход с осмысленным кодом,
# проверки окружения и идемпотентные помощники для правки файлов.

# Строгий режим. Вынесен сюда, чтобы не дублировать в каждом скрипте:
#   -e            прервать выполнение на первой неуспешной команде
#   -u            обращение к необъявленной переменной — ошибка
#   -o pipefail   код возврата конвейера = код упавшей команды,
#                 иначе `ложная_команда | true` считалось бы успехом
set -euo pipefail
# IFS НАМЕРЕННО не переопределяется.
#
# Распространённый приём «строгого режима» — выставить IFS=$'\n\t', чтобы
# имена файлов с пробелами не разваливались на части. Но он же ломает
# обычное разделение слов там, где оно нужно: подстановка вроде
# `yc ${kind} get`, где kind="vpc network", уедет в команду ОДНИМ
# аргументом "vpc network", и вызов молча провалится.
#
# Защита от пробелов достигается кавычками вокруг каждой подстановки —
# это проверяется shellcheck и работает без побочных эффектов.
# Второй неочевидный эффект переопределения: "${массив[*]}" склеивается
# первым символом IFS, то есть переводом строки вместо пробела, и все
# сообщения со списками расползаются по строкам.

# Коды выхода по соглашению sysexits.h — так вызывающая сторона (cron,
# CI, другой скрипт) может отличить «неверные аргументы» от «нет прав».
readonly EX_USAGE=64        # неверные аргументы
readonly EX_DATAERR=65      # некорректные входные данные
readonly EX_UNAVAILABLE=69  # отсутствует внешняя зависимость
readonly EX_SOFTWARE=70     # внутренняя ошибка логики
readonly EX_NOPERM=77       # недостаточно прав

_log() {
    local level="$1"; shift
    printf '%s [%-5s] %s\n' "$(date +'%Y-%m-%dT%H:%M:%S%z')" "${level}" "$*" >&2
}

log_info()  { _log INFO  "$@"; }
log_warn()  { _log WARN  "$@"; }
log_error() { _log ERROR "$@"; }
log_ok()    { _log OK    "$@"; }

# die <код> <сообщение...> — печатает ошибку и завершает скрипт этим кодом.
die() {
    local code="$1"; shift
    log_error "$@"
    exit "${code}"
}

# require_root — часть действий меняет системные файлы. Без root они
# провалятся на середине, оставив систему в половинчатом состоянии.
# Дешевле упасть сразу с понятным текстом.
require_root() {
    [[ "${EUID}" -eq 0 ]] || die "${EX_NOPERM}" "Требуются права root. Запустите через sudo."
}

# require_cmd <команда...> — проверяет наличие всех утилит в PATH.
require_cmd() {
    local missing=()
    local cmd
    for cmd in "$@"; do
        command -v "${cmd}" >/dev/null 2>&1 || missing+=("${cmd}")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        die "${EX_UNAVAILABLE}" "Не найдены обязательные утилиты: ${missing[*]}"
    fi
}

# require_args <получено> <нужно> <текст-подсказки>
require_args() {
    local got="$1" need="$2" usage="$3"
    if [[ "${got}" -lt "${need}" ]]; then
        printf 'Использование: %s\n' "${usage}" >&2
        exit "${EX_USAGE}"
    fi
}

# validate_name <строка> — проверяет, что имя годится для Common Name и
# имени файла. Без этой проверки аргумент вида "../../etc/passwd" уехал бы
# в пути к файлам.
validate_name() {
    local name="$1"
    if [[ ! "${name}" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$ ]]; then
        die "${EX_DATAERR}" "Недопустимое имя '${name}'. Разрешены латиница, цифры, дефис и подчёркивание (до 64 символов)."
    fi
}

# confirm <вопрос> — интерактивное подтверждение. В неинтерактивном режиме
# (cron, CI) автоматически отвечает «нет», чтобы скрипт не завис навсегда.
confirm() {
    local prompt="$1"
    if [[ ! -t 0 ]]; then
        log_warn "Неинтерактивный запуск, отказ от действия: ${prompt}"
        return 1
    fi
    local answer
    read -r -p "${prompt} [y/N] " answer
    [[ "${answer}" =~ ^[Yy]$ ]]
}

# ---------------------------------------------------------------------------
# Идемпотентные помощники.
# Идемпотентность = повторный запуск даёт тот же результат, что и первый,
# и не ломает уже настроенную систему. Прямое требование ТЗ.
# ---------------------------------------------------------------------------

# ensure_line <файл> <строка> — добавляет строку, только если её ещё нет.
ensure_line() {
    local file="$1" line="$2"
    touch "${file}"
    if grep -qxF -- "${line}" "${file}"; then
        log_info "Уже присутствует в ${file}: ${line}"
    else
        printf '%s\n' "${line}" >> "${file}"
        log_ok "Добавлено в ${file}: ${line}"
    fi
}

# ensure_dir <путь> <права> [владелец] — создаёт каталог и выставляет режим.
ensure_dir() {
    local path="$1" mode="$2" owner="${3:-}"
    mkdir -p "${path}"
    chmod "${mode}" "${path}"
    if [[ -n "${owner}" ]]; then
        chown "${owner}" "${path}"
    fi
    log_info "Каталог готов: ${path} (${mode})"
}

# backup_file <файл> — сохраняет копию перед правкой.
backup_file() {
    local file="$1"
    [[ -f "${file}" ]] || return 0
    local stamp
    stamp="$(date +%Y%m%d-%H%M%S)"
    cp -a "${file}" "${file}.bak-${stamp}"
    log_info "Резервная копия: ${file}.bak-${stamp}"
}

# apt_install <пакет...> — ставит только недостающие пакеты.
apt_install() {
    local to_install=()
    local pkg
    for pkg in "$@"; do
        if dpkg-query -W -f='${Status}' "${pkg}" 2>/dev/null | grep -q "ok installed"; then
            log_info "Пакет уже установлен: ${pkg}"
        else
            to_install+=("${pkg}")
        fi
    done
    if [[ ${#to_install[@]} -gt 0 ]]; then
        log_info "Установка пакетов: ${to_install[*]}"
        DEBIAN_FRONTEND=noninteractive apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${to_install[@]}"
        log_ok "Установлено: ${to_install[*]}"
    fi
}

# service_enable_now <юнит> — включает автозапуск и стартует, если не запущен.
service_enable_now() {
    local unit="$1"
    systemctl enable --quiet "${unit}" 2>/dev/null || true
    if systemctl is-active --quiet "${unit}"; then
        log_info "Служба уже работает: ${unit}"
    else
        systemctl start "${unit}"
        log_ok "Служба запущена: ${unit}"
    fi
}

# firewalld_allow_from <источник-CIDR> <порт/протокол> — rich rule, пускающая
# конкретный адрес на конкретный порт. Используется, чтобы экспортёры
# метрик отвечали только серверу мониторинга (пункт 9 блока 3 ТЗ).
firewalld_allow_from() {
    local source="$1" port="$2"
    local proto="${port##*/}" num="${port%%/*}"
    local rule="rule family=ipv4 source address=${source} port port=${num} protocol=${proto} accept"
    if firewall-cmd --permanent --query-rich-rule="${rule}" >/dev/null 2>&1; then
        log_info "Правило уже есть: ${source} -> ${port}"
    else
        firewall-cmd --permanent --add-rich-rule="${rule}" >/dev/null
        log_ok "Разрешено: ${source} -> ${port}"
    fi
}
