#!/usr/bin/env bash
# Проверяет состояние компонента инфраструктуры и печатает отчёт.
#
# Использование:
#   sudo ./verify.sh <ca|vpn|mon|backup|all>
#
# Каждая проверка независима: скрипт не останавливается на первой ошибке,
# а проходит весь список и выводит итог. Так за один запуск видно все
# проблемы сразу, а не по одной за проход.
#
# Код возврата 0 — всё в порядке, 1 — есть провалившиеся проверки.
# Это позволяет вызывать скрипт из другого скрипта или из CI.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../project.env
source "${SCRIPT_DIR}/../project.env"

# Строгий режим мешает собирать результаты проверок: провалившаяся
# команда прервала бы скрипт. Внутри проверок отключаем -e намеренно.
set +e

readonly USAGE="$0 <ca|vpn|mon|backup|all>"
require_args "$#" 1 "${USAGE}"

PASSED=0
FAILED=0
WARNED=0

ok()   { printf '  \033[32m[ OK ]\033[0m %s\n' "$*"; PASSED=$((PASSED + 1)); }
fail() { printf '  \033[31m[FAIL]\033[0m %s\n' "$*"; FAILED=$((FAILED + 1)); }
warn() { printf '  \033[33m[WARN]\033[0m %s\n' "$*"; WARNED=$((WARNED + 1)); }
head2(){ printf '\n\033[1m%s\033[0m\n' "$*"; }

# check <описание> <команда...> — выполняет и записывает результат.
check() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then ok "${desc}"; else fail "${desc}"; fi
}

# --- Общие проверки любой машины -------------------------------------------

verify_common() {
    head2 "Базовое состояние машины"
    check "Служба SSH работает" systemctl is-active --quiet ssh
    check "firewalld работает"  systemctl is-active --quiet firewalld

    if sshd -t 2>/dev/null; then ok "Конфигурация SSH корректна"
    else fail "Конфигурация SSH содержит ошибки (sshd -t)"; fi

    if sshd -T 2>/dev/null | grep -qi '^passwordauthentication no'; then
        ok "Вход по паролю отключён"
    else
        warn "Вход по паролю разрешён — проверьте пакет infra-hardening"
    fi

    if sshd -T 2>/dev/null | grep -qi '^permitrootlogin no'; then
        ok "Вход под root запрещён"
    else
        warn "Разрешён вход под root"
    fi

    local free_pct
    free_pct="$(df --output=pcent / | tail -1 | tr -dc '0-9')"
    if [[ "${free_pct}" -lt 85 ]]; then ok "Место на диске: занято ${free_pct}%"
    else warn "Диск заполнен на ${free_pct}%"; fi

    check "Экспортёр метрик работает" systemctl is-active --quiet prometheus-node-exporter
}

# --- Удостоверяющий центр ---------------------------------------------------

verify_ca() {
    head2 "Удостоверяющий центр"
    local pki="/var/lib/infra-ca/pki"

    if [[ -d "${pki}" ]]; then ok "PKI развёрнута"; else fail "Нет каталога ${pki}"; return; fi

    local perms
    perms="$(stat -c '%a' /var/lib/infra-ca)"
    if [[ "${perms}" == "700" ]]; then ok "Права на каталог центра: 700"
    else fail "Права на /var/lib/infra-ca = ${perms}, должно быть 700"; fi

    if [[ -f "${pki}/private/ca.key" ]]; then
        perms="$(stat -c '%a' "${pki}/private/ca.key")"
        if [[ "${perms}" == "600" || "${perms}" == "400" ]]; then
            ok "Права на приватный ключ центра: ${perms}"
        else
            fail "Права на ca.key = ${perms} — ключ доступен посторонним"
        fi
    else
        fail "Отсутствует приватный ключ центра"
    fi

    if [[ -f "${pki}/ca.crt" ]]; then
        if openssl x509 -in "${pki}/ca.crt" -noout -checkend 0 >/dev/null 2>&1; then
            local days
            days="$(( ( $(date -d "$(openssl x509 -in "${pki}/ca.crt" -noout -enddate | cut -d= -f2)" +%s) - $(date +%s) ) / 86400 ))"
            ok "Корневой сертификат действителен ещё ${days} дней"
        else
            fail "Корневой сертификат ИСТЁК"
        fi
    else
        fail "Отсутствует корневой сертификат"
    fi

    if [[ -f "${pki}/crl.pem" ]]; then
        if openssl crl -in "${pki}/crl.pem" -noout -nextupdate >/dev/null 2>&1; then
            local crl_end
            crl_end="$(openssl crl -in "${pki}/crl.pem" -noout -nextupdate | cut -d= -f2)"
            if [[ "$(date -d "${crl_end}" +%s)" -gt "$(date +%s)" ]]; then
                ok "Список отзыва действителен до ${crl_end}"
            else
                fail "Список отзыва ПРОСРОЧЕН — сервер отвергнет всех клиентов"
            fi
        fi
    else
        warn "Список отзыва не создан"
    fi

    local issued
    issued="$(find "${pki}/issued" -name '*.crt' 2>/dev/null | wc -l)"
    ok "Выпущено сертификатов: ${issued}"

    # На машине центра не должно быть открытых сетевых служб, кроме SSH.
    local listening
    listening="$(ss -lntH 2>/dev/null | awk '{print $4}' | grep -vE '127\.0\.0\.1|\[::1\]' | grep -oE ':[0-9]+$' | tr -d ':' | grep -v '^22$' | sort -u | tr '\n' ' ')"
    if [[ -z "${listening}" ]]; then
        ok "Посторонних сетевых служб нет"
    else
        warn "Открыты порты помимо SSH: ${listening}"
    fi
}

# --- VPN-сервер -------------------------------------------------------------

verify_vpn() {
    head2 "VPN-сервер"
    check "Служба OpenVPN работает" systemctl is-active --quiet openvpn-server@server

    if ip link show tun0 >/dev/null 2>&1; then ok "Интерфейс tun0 поднят"
    else fail "Интерфейс tun0 отсутствует"; fi

    if ss -lunH 2>/dev/null | grep -q ":${VPN_PORT}"; then
        ok "Порт ${VPN_PORT}/${VPN_PROTO} прослушивается"
    else
        fail "Порт ${VPN_PORT}/${VPN_PROTO} не прослушивается"
    fi

    if [[ "$(sysctl -n net.ipv4.ip_forward)" == "1" ]]; then
        ok "Маршрутизация пакетов включена"
    else
        fail "ip_forward выключен — клиенты не выйдут в интернет"
    fi

    if firewall-cmd --query-masquerade >/dev/null 2>&1; then
        ok "NAT (маскарадинг) включён"
    else
        fail "NAT выключен — туннель поднимется, но интернета не будет"
    fi

    if firewall-cmd --query-port="${VPN_PORT}/${VPN_PROTO}" >/dev/null 2>&1; then
        ok "Порт открыт в firewalld"
    else
        fail "Порт ${VPN_PORT}/${VPN_PROTO} закрыт в firewalld"
    fi

    # Директива, без которой задача теряет смысл: трафик пойдёт мимо туннеля.
    if grep -qE '^\s*push\s+"redirect-gateway' /etc/openvpn/server/server.conf 2>/dev/null; then
        ok "Весь трафик клиента заворачивается в туннель"
    else
        fail "Нет push redirect-gateway — внешний адрес клиента не изменится"
    fi

    if grep -qE '^\s*tls-crypt\s' /etc/openvpn/server/server.conf 2>/dev/null; then
        ok "Рукопожатие защищено tls-crypt"
    else
        warn "tls-crypt не настроен"
    fi

    local f
    for f in ca.crt server.crt server.key ta.key crl.pem; do
        if [[ -f "/etc/openvpn/server/${f}" ]]; then ok "Файл ${f} на месте"
        else fail "Отсутствует /etc/openvpn/server/${f}"; fi
    done

    if [[ -f /etc/openvpn/server/server.crt ]]; then
        if openssl verify -CAfile /etc/openvpn/server/ca.crt \
             /etc/openvpn/server/server.crt >/dev/null 2>&1; then
            ok "Сертификат сервера подписан нашим центром"
        else
            fail "Сертификат сервера не проходит проверку по ca.crt"
        fi
    fi

    local clients
    clients="$(grep -c '^10\.8\.0\.' /var/log/openvpn/openvpn-status.log 2>/dev/null || echo 0)"
    ok "Подключённых клиентов сейчас: ${clients}"
}

# --- Сервер мониторинга -----------------------------------------------------

verify_mon() {
    head2 "Сервер мониторинга"
    check "Prometheus работает"   systemctl is-active --quiet prometheus
    check "Alertmanager работает" systemctl is-active --quiet prometheus-alertmanager

    if command -v promtool >/dev/null 2>&1; then
        check "Конфигурация Prometheus корректна" promtool check config /etc/prometheus/prometheus.yml
        local rules_bad=0 f
        for f in /etc/prometheus/rules/*.yml; do
            promtool check rules "${f}" >/dev/null 2>&1 || rules_bad=1
        done
        if [[ "${rules_bad}" -eq 0 ]]; then ok "Правила алертов корректны"
        else fail "Есть ошибки в правилах алертов"; fi
    fi

    if [[ -f /etc/prometheus/web.yml ]]; then ok "Веб-интерфейс закрыт паролем"
    else warn "Веб-интерфейс Prometheus открыт без аутентификации"; fi

    # Сколько целей реально отвечает. Именно это отличает «мониторинг
    # настроен» от «мониторинг работает».
    local targets_up targets_total
    targets_up="$(curl -s --max-time 5 "http://localhost:${PORT_PROMETHEUS}/api/v1/query?query=sum(up)" 2>/dev/null \
        | grep -oE '"[0-9]+"' | tail -1 | tr -d '"')"
    targets_total="$(curl -s --max-time 5 "http://localhost:${PORT_PROMETHEUS}/api/v1/query?query=count(up)" 2>/dev/null \
        | grep -oE '"[0-9]+"' | tail -1 | tr -d '"')"
    if [[ -n "${targets_up}" && -n "${targets_total}" ]]; then
        if [[ "${targets_up}" == "${targets_total}" ]]; then
            ok "Отвечают все цели опроса: ${targets_up}/${targets_total}"
        else
            fail "Отвечают не все цели: ${targets_up}/${targets_total}"
        fi
    else
        warn "Не удалось опросить API Prometheus (возможно, включена аутентификация)"
    fi

    local rules_loaded
    rules_loaded="$(curl -s --max-time 5 "http://localhost:${PORT_PROMETHEUS}/api/v1/rules" 2>/dev/null \
        | grep -o '"name"' | wc -l)"
    if [[ "${rules_loaded}" -gt 0 ]]; then ok "Загружено правил: ${rules_loaded}"
    else warn "Правила не загружены или API недоступно"; fi

    if [[ -s /etc/prometheus/smtp-password ]]; then ok "Пароль SMTP задан"
    else warn "Пароль SMTP не задан — письма отправляться не будут"; fi
}

# --- Резервное копирование --------------------------------------------------

verify_backup() {
    head2 "Резервное копирование"

    if [[ -f /etc/infra-backup/backup.conf ]]; then ok "Настройки копирования на месте"
    else fail "Нет /etc/infra-backup/backup.conf"; return; fi

    local perms
    perms="$(stat -c '%a' /etc/infra-backup/passphrase 2>/dev/null || echo "нет")"
    if [[ "${perms}" == "600" || "${perms}" == "400" ]]; then
        ok "Права на парольную фразу: ${perms}"
    else
        fail "Права на файл парольной фразы: ${perms}"
    fi

    check "Таймер копирования включён" systemctl is-enabled --quiet infra-backup.timer

    local next
    next="$(systemctl show infra-backup.timer -p NextElapseUSecRealtime --value 2>/dev/null)"
    [[ -n "${next}" ]] && ok "Следующий запуск: ${next}"

    # Возраст последней копии — главный показатель. Всё остальное может
    # быть настроено идеально, но если копии месячной давности, это не
    # резервное копирование.
    local metrics="/var/lib/node_exporter/textfile_collector/infra_backup.prom"
    if [[ -f "${metrics}" ]]; then
        local last_ts age_h code
        last_ts="$(grep -oE 'infra_backup_last_success_timestamp_seconds\{[^}]*\} [0-9]+' "${metrics}" \
                   | awk '{print $2}' | sort -n | tail -1)"
        code="$(grep -oE 'infra_backup_last_exit_code\{[^}]*\} [0-9]+' "${metrics}" \
                | awk '{print $2}' | sort -rn | head -1)"
        if [[ -n "${last_ts}" ]]; then
            age_h="$(( ( $(date +%s) - last_ts ) / 3600 ))"
            if [[ "${age_h}" -lt 26 ]]; then ok "Последняя копия создана ${age_h} ч назад"
            else fail "Последней копии ${age_h} ч — копирование не работает"; fi
        else
            fail "Ни одной успешной копии ещё не создано"
        fi
        if [[ "${code:-0}" -eq 0 ]]; then ok "Последний запуск завершился успешно"
        else fail "Последний запуск завершился с кодом ${code}"; fi
    else
        warn "Метрики копирования отсутствуют — задача ещё не запускалась"
    fi
}

# --- Запуск -----------------------------------------------------------------

case "$1" in
    ca)     verify_common; verify_ca ;;
    vpn)    verify_common; verify_vpn ;;
    mon)    verify_common; verify_mon ;;
    backup) verify_common; verify_backup ;;
    all)    verify_common; verify_ca; verify_vpn; verify_mon; verify_backup ;;
    *)      printf 'Использование: %s\n' "${USAGE}" >&2; exit "${EX_USAGE}" ;;
esac

printf '\n\033[1mИтог:\033[0m успешно %s, предупреждений %s, провалено %s\n' \
    "${PASSED}" "${WARNED}" "${FAILED}"

[[ "${FAILED}" -eq 0 ]] || exit 1
exit 0
