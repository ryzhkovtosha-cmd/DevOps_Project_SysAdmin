#!/usr/bin/env bash
# Создаёт собственную VPC-сеть и две подсети в разных геозонах.
#
# Почему не сеть default: в ней оказывается любая ВМ, созданная в этом
# облаке, включая чужие эксперименты. Своя сеть даёт изолированный периметр
# и фиксированную адресацию, на которую можно опереться в правилах фаервола
# и в конфигурации Prometheus.
#
# Скрипт идемпотентен: повторный запуск ничего не пересоздаёт.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../project.env
source "${SCRIPT_DIR}/../project.env"

require_cmd yc

# yc_exists <слово...> <имя> — возвращает 0, если ресурс уже существует.
# Вызывается так:  yc_exists vpc network "${NET_NAME}"
#
# Подкоманда передаётся ОТДЕЛЬНЫМИ аргументами, а не одной строкой с
# расчётом на разделение слов. Расчёт на разделение хрупок: он зависит от
# текущего значения IFS, и при малейшем его изменении подкоманда уезжает
# в yc одним аргументом. Проверка тогда всегда отвечает «не существует»,
# и скрипт перестаёт быть идемпотентным: пытается создать уже созданное
# и упирается в квоту.
yc_exists() {
    local name="${!#}"                # последний аргумент — имя ресурса
    local subcommand=("${@:1:$#-1}")  # всё до него — подкоманда yc
    yc "${subcommand[@]}" get --name "${name}" >/dev/null 2>&1
}

create_network() {
    if yc_exists vpc network "${NET_NAME}"; then
        log_info "Сеть ${NET_NAME} уже существует, пропускаю"
        return 0
    fi
    log_info "Создаю сеть ${NET_NAME}"
    yc vpc network create \
        --name "${NET_NAME}" \
        --description "Инфраструктура VPN-сервиса: CA, VPN, мониторинг, бэкапы" \
        >/dev/null
    log_ok "Сеть ${NET_NAME} создана"
}

create_subnet() {
    local name="$1" zone="$2" range="$3"
    if yc_exists vpc subnet "${name}"; then
        log_info "Подсеть ${name} уже существует, пропускаю"
        return 0
    fi
    log_info "Создаю подсеть ${name} (${zone}, ${range})"
    yc vpc subnet create \
        --name "${name}" \
        --network-name "${NET_NAME}" \
        --zone "${zone}" \
        --range "${range}" \
        >/dev/null
    log_ok "Подсеть ${name} создана"
}

# Резервируем статические публичные адреса. Эфемерный адрес освобождается
# при остановке ВМ, и после запуска машина получает новый — тогда пришлось бы
# править remote во всех клиентских конфигурациях. Пункт 2a ТЗ.
reserve_address() {
    local name="$1" zone="$2"
    if yc_exists vpc address "${name}"; then
        log_info "Адрес ${name} уже зарезервирован, пропускаю"
        return 0
    fi
    log_info "Резервирую статический адрес ${name}"
    yc vpc address create \
        --name "${name}" \
        --external-ipv4 "zone=${zone}" \
        >/dev/null
    log_ok "Адрес ${name} зарезервирован"
}

main() {
    create_network
    create_subnet "${SUBNET_A_NAME}" "${CLOUD_ZONE_A}" "${SUBNET_A_RANGE}"
    create_subnet "${SUBNET_B_NAME}" "${CLOUD_ZONE_B}" "${SUBNET_B_RANGE}"

    # Статические адреса резервируем ТОЛЬКО там, где они действительно нужны.
    # Квота на статические внешние адреса по умолчанию невелика, и тратить
    # её на машины, которым хватает эфемерного адреса, незачем.
    #
    #   vpn-server — обязательно: адрес прописан в директиве remote у каждого
    #                сотрудника, его смена означает перевыпуск конфигураций всем;
    #   ca-server  — обязательно по пункту 2a ТЗ, плюс удобно для SSH;
    #   mon-server — достаточно эфемерного: веб-интерфейс открывается через VPN,
    #                а при смене адреса ничего перенастраивать не нужно.
    reserve_address "${CA_VM}-ip"  "${CLOUD_ZONE_A}"
    reserve_address "${VPN_VM}-ip" "${CLOUD_ZONE_A}"

    log_ok "Сетевой слой готов. Зарезервированные адреса:"
    yc vpc address list
}

main "$@"
