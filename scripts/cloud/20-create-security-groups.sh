#!/usr/bin/env bash
# Создаёт группы безопасности — это фаервол на уровне облака, первый рубеж
# обороны до того, как пакет вообще доберётся до операционной системы.
#
# Принцип: по умолчанию запрещено всё, открывается только то, без чего
# сервис не работает. Второй рубеж (firewalld внутри ОС) настраивается
# отдельно скриптами и deb-пакетами — так одна ошибка в конфигурации не
# раскрывает сервер целиком.
#
# Разделение по ролям:
#   sg-ca      доступ только по SSH с адреса администратора. Больше ничего:
#              удостоверяющий центр не обслуживает сетевые запросы.
#   sg-vpn     SSH + 1194/udp всему интернету (иначе сотрудники не подключатся)
#   sg-mon     SSH + веб-интерфейсы Prometheus и Alertmanager
#   sg-backup  SSH + приём файлов из внутренней сети

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../project.env
source "${SCRIPT_DIR}/../project.env"

require_cmd yc

INTERNAL_CIDRS="${SUBNET_A_RANGE},${SUBNET_B_RANGE}"

if [[ "${ADMIN_CIDR}" == "0.0.0.0/0" ]]; then
    log_warn "ADMIN_CIDR = 0.0.0.0/0 — SSH будет открыт всему интернету."
    log_warn "Укажите свой адрес в project.env: curl -s ifconfig.me"
fi

sg_exists() { yc vpc security-group get --name "$1" >/dev/null 2>&1; }

# create_sg <имя> <описание> <правило...>
create_sg() {
    local name="$1" desc="$2"; shift 2
    if sg_exists "${name}"; then
        log_info "Группа ${name} уже существует, пропускаю"
        return 0
    fi
    local args=()
    local rule
    for rule in "$@"; do
        args+=(--rule "${rule}")
    done
    log_info "Создаю группу безопасности ${name}"
    yc vpc security-group create \
        --name "${name}" \
        --network-name "${NET_NAME}" \
        --description "${desc}" \
        "${args[@]}" >/dev/null
    log_ok "Группа ${name} создана"
}

main() {
    # ВНИМАНИЕ: требования yc к портам различаются по протоколам, и ошибки
    # при их нарушении противоположны по смыслу:
    #   protocol=any  — порты ОБЯЗАТЕЛЬНЫ, иначе
    #                   "port or [from/to]-port fields is required";
    #   protocol=icmp — порты ЗАПРЕЩЕНЫ, иначе
    #                   "cannot set port with ICMP protocol";
    #   protocol=tcp/udp — порт указывается обычным образом.
    # У ICMP портов нет в принципе, поэтому запрет логичен; протокол any
    # охватывает в том числе tcp и udp, отсюда обязательный диапазон.
    local any_ports="from-port=0,to-port=65535"

    # Исходящий трафик нужен всем: обновления пакетов, DNS, отправка писем.
    local egress_all="direction=egress,${any_ports},protocol=any,v4-cidrs=[0.0.0.0/0]"
    local ssh_admin="direction=ingress,port=22,protocol=tcp,v4-cidrs=[${ADMIN_CIDR}]"
    # Пинги внутри сети — минимальная диагностика связности между серверами.
    local icmp_internal="direction=ingress,protocol=icmp,v4-cidrs=[${INTERNAL_CIDRS}]"
    # Метрики отдаём только серверу мониторинга, /32 — ровно один адрес.
    local scrape_node="direction=ingress,port=${PORT_NODE_EXPORTER},protocol=tcp,v4-cidrs=[${MON_IP}/32]"
    local scrape_vpn="direction=ingress,port=${PORT_OPENVPN_EXPORTER},protocol=tcp,v4-cidrs=[${MON_IP}/32]"

    create_sg "sg-ca" "Удостоверяющий центр: только SSH администратора" \
        "${egress_all}" "${ssh_admin}" "${icmp_internal}" "${scrape_node}"

    create_sg "sg-vpn" "VPN-сервер: SSH и OpenVPN" \
        "${egress_all}" "${ssh_admin}" "${icmp_internal}" \
        "${scrape_node}" "${scrape_vpn}" \
        "direction=ingress,port=${VPN_PORT},protocol=${VPN_PROTO},v4-cidrs=[0.0.0.0/0]"

    # Веб-интерфейс мониторинга доступен администратору и из туннеля VPN:
    # сотрудник, подключённый к VPN, получает адрес из 10.8.0.0/24.
    create_sg "sg-mon" "Сервер мониторинга: SSH и веб-интерфейсы" \
        "${egress_all}" "${ssh_admin}" "${icmp_internal}" "${scrape_node}" \
        "direction=ingress,port=${PORT_PROMETHEUS},protocol=tcp,v4-cidrs=[${ADMIN_CIDR},${VPN_SUBNET}]" \
        "direction=ingress,port=${PORT_ALERTMANAGER},protocol=tcp,v4-cidrs=[${ADMIN_CIDR},${VPN_SUBNET}]"

    create_sg "sg-backup" "Сервер бэкапов: приём файлов из внутренней сети" \
        "${egress_all}" "${ssh_admin}" "${icmp_internal}" "${scrape_node}" \
        "direction=ingress,port=22,protocol=tcp,v4-cidrs=[${INTERNAL_CIDRS}]"

    log_ok "Группы безопасности готовы"
    yc vpc security-group list
}

main "$@"
