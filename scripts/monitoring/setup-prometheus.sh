#!/usr/bin/env bash
# Разворачивает сервер мониторинга: Prometheus, Alertmanager и защищённый
# паролем доступ к их веб-интерфейсам.
#
# Использование:
#   sudo ./setup-prometheus.sh
#
# Конфигурации и правила алертов приходят пакетом infra-monitoring-config.
# Этот скрипт ставит недостающий софт, закрывает веб-интерфейсы паролем,
# подставляет пароль SMTP и настраивает фаервол.
#
# Запускается интерактивно: пароли не должны попадать ни в текст скрипта,
# ни в историю команд.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../project.env
source "${SCRIPT_DIR}/../project.env"

readonly ALERTMANAGER_CONF="/etc/prometheus/infra-alertmanager.yml"
readonly PROMETHEUS_CONF="/etc/prometheus/infra-prometheus.yml"
readonly NGINX_TEMPLATE="/usr/share/infra-monitoring/nginx-site.template"
readonly NGINX_SITE="/etc/nginx/sites-available/infra-monitoring"
readonly HTPASSWD="/etc/nginx/infra-monitoring.htpasswd"

require_root

check_config_package() {
    [[ -f "${PROMETHEUS_CONF}" ]] || die "${EX_UNAVAILABLE}" \
        "Нет ${PROMETHEUS_CONF}. Установите: sudo apt install ./infra-monitoring-config_*.deb"
    [[ -f "${NGINX_TEMPLATE}" ]] || die "${EX_UNAVAILABLE}" \
        "Нет ${NGINX_TEMPLATE}. Нужен пакет infra-monitoring-config версии 1.0.2 или новее."
    [[ -f /etc/prometheus/rules/node.rules.yml ]] || die "${EX_UNAVAILABLE}" \
        "Нет правил алертов. Установите пакет infra-monitoring-config."
    log_info "Конфигурация мониторинга на месте (принесена deb-пакетом)"
}

install_software() {
    apt_install prometheus prometheus-alertmanager prometheus-node-exporter \
                nginx-light apache2-utils firewalld openssl
    log_info "Prometheus $(dpkg-query -W -f='${Version}' prometheus 2>/dev/null)"
    log_info "Alertmanager $(dpkg-query -W -f='${Version}' prometheus-alertmanager 2>/dev/null)"
}

# Веб-интерфейс Prometheus по умолчанию открыт любому, кто дотянулся до
# порта, а показывает он схему сети, имена машин и состояние сервисов —
# готовую карту для разведки. Собственной аутентификации у версии 2.15 из
# Ubuntu 20.04 нет: флаг --web.config.file появился только в 2.24. Поэтому
# доступ закрывается обратным прокси, который работает с любой версией и
# заодно даёт готовую точку для подключения HTTPS.
setup_web_auth() {
    if [[ -f "${HTPASSWD}" ]]; then
        log_info "Пароль веб-доступа уже задан, пропускаю"
    else
        local password password2
        if [[ -t 0 ]]; then
            read -r -s -p "Придумайте пароль для веб-интерфейсов (пользователь admin): " password
            printf '\n'
            read -r -s -p "Повторите: " password2
            printf '\n'
            [[ "${password}" == "${password2}" ]] || die "${EX_DATAERR}" "Пароли не совпадают"
            [[ ${#password} -ge 8 ]] || die "${EX_DATAERR}" "Слишком короткий пароль, минимум 8 символов"
        else
            password="$(openssl rand -base64 18)"
            log_warn "Сгенерирован пароль: ${password}"
            log_warn "Запишите его сейчас — второй раз показан не будет."
        fi

        # -B bcrypt, -C 12 — стоимость вычисления хеша. Пароль в открытом
        # виде никуда не сохраняется, в файл идёт только хеш.
        htpasswd -cbB -C 12 "${HTPASSWD}" admin "${password}" >/dev/null 2>&1 \
            || die "${EX_SOFTWARE}" "Не удалось создать файл паролей"
        chmod 640 "${HTPASSWD}"
        chown root:www-data "${HTPASSWD}" 2>/dev/null || true
        log_ok "Пароль веб-доступа задан (пользователь admin)"
    fi

    # Адрес подставляем из project.env: в пакете его держать нельзя,
    # у каждой установки он свой.
    sed "s|@@LISTEN_ADDR@@|${MON_IP}|g" "${NGINX_TEMPLATE}" > "${NGINX_SITE}"
    ln -sf "${NGINX_SITE}" /etc/nginx/sites-enabled/infra-monitoring

    # Сайт по умолчанию занимает порт 80 и нам не нужен.
    rm -f /etc/nginx/sites-enabled/default

    nginx -t >/dev/null 2>&1 || { nginx -t; die "${EX_SOFTWARE}" "Конфигурация nginx содержит ошибки"; }
    log_ok "Прокси настроен на ${MON_IP}:${PORT_PROMETHEUS} и ${MON_IP}:${PORT_ALERTMANAGER}"
}

# Alertmanager 0.15 не умеет читать пароль SMTP из отдельного файла:
# smtp_auth_password_file появился только в 0.25. Приходится подставлять
# его прямо в конфигурацию, поэтому права на неё ограничиваются.
setup_smtp_password() {
    if ! grep -q '@@SMTP_PASSWORD@@' "${ALERTMANAGER_CONF}"; then
        log_info "Пароль SMTP уже подставлен, пропускаю"
        return 0
    fi
    if [[ ! -t 0 ]]; then
        log_warn "Неинтерактивный запуск: пароль SMTP не задан, письма отправляться не будут."
        log_warn "Подставьте его позже вместо @@SMTP_PASSWORD@@ в ${ALERTMANAGER_CONF}"
        return 0
    fi

    local smtp_pass
    read -r -s -p "Пароль ящика ${SMTP_FROM} (Enter — пропустить): " smtp_pass
    printf '\n'
    if [[ -z "${smtp_pass}" ]]; then
        log_warn "Пароль SMTP не задан — письма отправляться не будут."
        return 0
    fi

    # Экранируем символы, значимые для sed: в пароле может быть что угодно.
    local escaped
    escaped="$(printf '%s' "${smtp_pass}" | sed -e 's/[&|\\]/\\&/g')"
    sed -i "s|@@SMTP_PASSWORD@@|${escaped}|" "${ALERTMANAGER_CONF}"
    chmod 640 "${ALERTMANAGER_CONF}"
    chown root:prometheus "${ALERTMANAGER_CONF}" 2>/dev/null || true
    log_ok "Пароль SMTP подставлен, права на файл ограничены"
}

validate_config() {
    require_cmd promtool
    log_info "Проверяю конфигурацию Prometheus"
    promtool check config "${PROMETHEUS_CONF}" \
        || die "${EX_DATAERR}" "Конфигурация Prometheus содержит ошибки"

    log_info "Проверяю правила алертов"
    local rules_ok=0 f
    for f in /etc/prometheus/rules/*.yml; do
        promtool check rules "${f}" || rules_ok=1
    done
    [[ "${rules_ok}" -eq 0 ]] || die "${EX_DATAERR}" "Правила алертов содержат ошибки"

    if command -v amtool >/dev/null 2>&1; then
        amtool check-config "${ALERTMANAGER_CONF}" >/dev/null 2>&1 \
            && log_ok "Конфигурация Alertmanager принята" \
            || log_warn "amtool не принял конфигурацию Alertmanager — проверьте вручную"
    fi
    log_ok "Конфигурация и правила корректны"
}

configure_firewall() {
    service_enable_now firewalld
    firewall-cmd --permanent --add-service=ssh >/dev/null 2>&1 || true

    # Веб-интерфейсы доступны администратору и из туннеля VPN.
    # Открывать их всему интернету незачем даже под паролем.
    firewalld_allow_from "${ADMIN_CIDR}"  "${PORT_PROMETHEUS}/tcp"
    firewalld_allow_from "${ADMIN_CIDR}"  "${PORT_ALERTMANAGER}/tcp"
    firewalld_allow_from "${VPN_SUBNET}"  "${PORT_PROMETHEUS}/tcp"
    firewalld_allow_from "${VPN_SUBNET}"  "${PORT_ALERTMANAGER}/tcp"
    firewalld_allow_from "${MON_IP}/32"   "${PORT_NODE_EXPORTER}/tcp"

    firewall-cmd --reload >/dev/null
    log_ok "Фаервол настроен"
}

start_services() {
    systemctl daemon-reload
    service_enable_now prometheus
    service_enable_now prometheus-alertmanager
    service_enable_now prometheus-node-exporter
    systemctl restart prometheus prometheus-alertmanager
    service_enable_now nginx
    systemctl reload nginx 2>/dev/null || systemctl restart nginx
    sleep 3

    local unit
    for unit in prometheus prometheus-alertmanager nginx; do
        if ! systemctl is-active --quiet "${unit}"; then
            journalctl -u "${unit}" -n 20 --no-pager >&2
            die "${EX_SOFTWARE}" "Служба ${unit} не запустилась"
        fi
    done
    log_ok "Prometheus, Alertmanager и nginx запущены"
}

verify() {
    log_info "Проверяю результат"

    # Службы обязаны слушать ТОЛЬКО loopback: снаружи их закрывает прокси.
    if ss -lntH 2>/dev/null | grep -q "127.0.0.1:${PORT_PROMETHEUS}"; then
        log_ok "Prometheus слушает только loopback"
    else
        log_warn "Prometheus слушает не на loopback — проверьте drop-in из пакета"
    fi

    log_info "Жду первого цикла опроса"
    sleep 12
    local up_total up_ok
    up_total="$(curl -s --max-time 5 "http://127.0.0.1:${PORT_PROMETHEUS}/api/v1/query?query=count(up)" \
        | grep -oE '"[0-9]+"' | tail -1 | tr -d '"' || true)"
    up_ok="$(curl -s --max-time 5 "http://127.0.0.1:${PORT_PROMETHEUS}/api/v1/query?query=sum(up)" \
        | grep -oE '"[0-9]+"' | tail -1 | tr -d '"' || true)"
    log_info "Целей опроса отвечает: ${up_ok:-0} из ${up_total:-0}"
    if [[ "${up_ok:-0}" != "${up_total:-0}" ]]; then
        log_warn "Отвечают не все цели. Установите infra-node-metrics на остальные машины."
    fi

    # Доступ снаружи должен требовать пароль.
    local code
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
        "http://${MON_IP}:${PORT_PROMETHEUS}/" || true)"
    if [[ "${code}" == "401" ]]; then
        log_ok "Внешний доступ требует пароль (HTTP 401)"
    else
        log_warn "Внешний доступ вернул код ${code}, ожидался 401"
    fi
}

main() {
    check_config_package
    install_software
    setup_web_auth
    setup_smtp_password
    validate_config
    configure_firewall
    start_services
    verify

    cat <<SUMMARY

Сервер мониторинга готов.
  Prometheus:    http://${MON_IP}:${PORT_PROMETHEUS}   пользователь admin
  Alertmanager:  http://${MON_IP}:${PORT_ALERTMANAGER}   пользователь admin

Из интернета порты закрыты: доступ с ${ADMIN_CIDR} и из туннеля ${VPN_SUBNET}.

Дальше на КАЖДОЙ машине инфраструктуры:
  sudo apt install ./infra-common_*.deb ./infra-node-metrics_*.deb

На VPN-сервере дополнительно:
  sudo ./setup-openvpn-exporter.sh
SUMMARY
}

main "$@"
