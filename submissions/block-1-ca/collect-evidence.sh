#!/usr/bin/env bash
# Собирает текстовый отчёт о состоянии удостоверяющего центра.
#
# Запускать НА МАШИНЕ ca-server:
#   sudo ./collect-evidence.sh
#
# Результат — файл ca-report.txt в текущем каталоге. Его можно приложить к
# материалам блока: он содержит то же, что и скриншоты, но в виде текста,
# который куратор сможет прочитать и скопировать.
#
# Секретов в отчёт не попадает: приватные ключи, парольные фразы и содержимое
# ключа tls-crypt не выводятся ни в каком виде.

set -euo pipefail

OUT="${1:-ca-report.txt}"

if [[ "${EUID}" -ne 0 ]]; then
    printf 'Требуются права root: sudo %s\n' "$0" >&2
    exit 77
fi

section() { printf '\n========== %s ==========\n\n' "$1"; }

{
    printf 'Отчёт по блоку 1: удостоверяющий центр\n'
    printf 'Машина: %s\n' "$(hostname)"
    printf 'Собран: %s\n' "$(date -Is)"
    printf 'ОС: %s\n' "$(lsb_release -ds 2>/dev/null || cat /etc/os-release | head -1)"

    section 'КОРНЕВОЙ СЕРТИФИКАТ'
    if [[ -f /var/lib/infra-ca/pki/ca.crt ]]; then
        openssl x509 -in /var/lib/infra-ca/pki/ca.crt -noout -subject -issuer -dates
        printf '\nОтпечаток SHA-256:\n'
        openssl x509 -in /var/lib/infra-ca/pki/ca.crt -noout -fingerprint -sha256
        printf '\nАлгоритм ключа:\n'
        openssl x509 -in /var/lib/infra-ca/pki/ca.crt -noout -text \
            | grep -A1 'Public Key Algorithm' | sed 's/^ */  /'
        printf '\nАлгоритм подписи:\n'
        openssl x509 -in /var/lib/infra-ca/pki/ca.crt -noout -text \
            | grep -m1 'Signature Algorithm' | sed 's/^ */  /'
    else
        printf 'Корневой сертификат не найден\n'
    fi

    section 'СПИСОК ОТЗЫВА'
    if [[ -f /var/lib/infra-ca/pki/crl.pem ]]; then
        openssl crl -in /var/lib/infra-ca/pki/crl.pem -noout -lastupdate -nextupdate
    else
        printf 'CRL не создан\n'
    fi

    section 'ПРАВА НА ЧУВСТВИТЕЛЬНЫЕ ОБЪЕКТЫ'
    # Только режимы доступа и владельцы, никакого содержимого.
    stat -c '%A %U:%G  %n' /var/lib/infra-ca 2>/dev/null || true
    stat -c '%A %U:%G  %n' /var/lib/infra-ca/pki 2>/dev/null || true
    stat -c '%A %U:%G  %n' /var/lib/infra-ca/pki/private 2>/dev/null || true
    stat -c '%A %U:%G  %n' /var/lib/infra-ca/pki/private/ca.key 2>/dev/null || true

    section 'ВЫПУЩЕННЫЕ СЕРТИФИКАТЫ'
    if [[ -d /var/lib/infra-ca/pki/issued ]]; then
        printf 'Всего: %s\n\n' "$(find /var/lib/infra-ca/pki/issued -name '*.crt' | wc -l)"
        for crt in /var/lib/infra-ca/pki/issued/*.crt; do
            [[ -f "${crt}" ]] || continue
            printf '%s\n' "$(basename "${crt}")"
            openssl x509 -in "${crt}" -noout -subject -dates | sed 's/^/    /'
        done
    else
        printf 'Пока ни одного\n'
    fi

    section 'УСТАНОВЛЕННЫЕ ПАКЕТЫ ИНФРАСТРУКТУРЫ'
    dpkg-query -W -f='${Package} ${Version} ${Status}\n' 'infra-*' 2>/dev/null || true

    section 'ЗАВИСИМОСТЬ ОТ EASY-RSA'
    dpkg-query -W -f='${Package}: ${Depends}\n' infra-ca-config 2>/dev/null || true
    printf '\nУстановленная версия easy-rsa: '
    dpkg-query -W -f='${Version}\n' easy-rsa 2>/dev/null || printf 'не установлен\n'

    section 'ФАЕРВОЛ'
    firewall-cmd --list-all 2>/dev/null || printf 'firewalld недоступен\n'

    section 'НАСТРОЙКИ SSH (действующие)'
    sshd -T 2>/dev/null | grep -E '^(permitrootlogin|passwordauthentication|maxauthtries|permitemptypasswords|x11forwarding)' \
        || printf 'не удалось получить\n'

    section 'СЕТЕВЫЕ СЛУЖБЫ'
    printf 'Машина центра не должна слушать ничего, кроме SSH:\n\n'
    ss -lntuH 2>/dev/null | awk '{printf "  %-6s %s\n", $1, $5}' | sort -u || true

    section 'ПАРАМЕТРЫ ЯДРА ИЗ ПАКЕТА infra-hardening'
    for k in net.ipv4.conf.all.rp_filter net.ipv4.tcp_syncookies \
             net.ipv4.conf.all.accept_redirects net.ipv4.icmp_echo_ignore_broadcasts; do
        printf '  %s\n' "$(sysctl -n "${k}" 2>/dev/null | xargs -I{} echo "${k} = {}")"
    done

    section 'ТАЙМЕР СБОРА МЕТРИК О СЕРТИФИКАТАХ'
    systemctl list-timers infra-cert-metrics.timer --no-pager 2>/dev/null || true
    printf '\nСобранные метрики:\n'
    grep -v '^#' /var/lib/node_exporter/textfile_collector/infra_certs.prom 2>/dev/null \
        | sed 's/^/  /' || printf '  файл пока пуст\n'

    section 'ИТОГОВАЯ ПРОВЕРКА'
    printf 'Вывод verify.sh ca приведён ниже.\n'
} > "${OUT}" 2>&1

# verify.sh раскрашивает вывод — убираем управляющие последовательности,
# иначе в текстовом файле будет мусор вида ESC[32m.
if [[ -x ./verify.sh ]]; then
    ./verify.sh ca 2>&1 | sed 's/\x1b\[[0-9;]*m//g' >> "${OUT}" || true
elif [[ -x ../../scripts/test/verify.sh ]]; then
    ../../scripts/test/verify.sh ca 2>&1 | sed 's/\x1b\[[0-9;]*m//g' >> "${OUT}" || true
else
    printf 'verify.sh не найден рядом — запустите вручную\n' >> "${OUT}"
fi

chmod 644 "${OUT}"
printf 'Отчёт готов: %s (%s строк)\n' "${OUT}" "$(wc -l < "${OUT}")"
printf 'Проверьте его глазами перед публикацией, затем заберите к себе:\n'
printf '  scp %s@<ca-ip>:~/%s ./\n' "${SUDO_USER:-yc-user}" "${OUT}"
