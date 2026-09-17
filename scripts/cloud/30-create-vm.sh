#!/usr/bin/env bash
# Создаёт одну виртуальную машину с заданной ролью.
#
# Использование:
#   ./30-create-vm.sh <роль>
# где роль — одна из: ca, vpn, mon, backup
#
# Роль определяет зону, подсеть, внутренний адрес, группу безопасности
# и нужен ли машине публичный адрес.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../project.env
source "${SCRIPT_DIR}/../project.env"

readonly USAGE="$0 <ca|vpn|mon|backup>"
require_args "$#" 1 "${USAGE}"
require_cmd yc

ROLE="$1"

# Публичный ключ кладём в ВМ при создании — пароль для входа не заводится
# вообще, что снимает целый класс атак на подбор.
[[ -f "${SSH_KEY}" ]] || die "${EX_UNAVAILABLE}" \
    "Нет публичного SSH-ключа ${SSH_KEY}. Создайте: ssh-keygen -t ed25519"

# Разбор роли в конкретные параметры.
case "${ROLE}" in
    ca)
        VM_NAME="${CA_VM}";     ZONE="${CLOUD_ZONE_A}"; SUBNET="${SUBNET_A_NAME}"
        INTERNAL_IP="${CA_IP}"; SG="sg-ca";   PUBLIC_IP_MODE="static"
        ;;
    vpn)
        VM_NAME="${VPN_VM}";    ZONE="${CLOUD_ZONE_A}"; SUBNET="${SUBNET_A_NAME}"
        INTERNAL_IP="${VPN_IP}"; SG="sg-vpn"; PUBLIC_IP_MODE="static"
        ;;
    mon)
        VM_NAME="${MON_VM}";    ZONE="${CLOUD_ZONE_A}"; SUBNET="${SUBNET_A_NAME}"
        INTERNAL_IP="${MON_IP}"; SG="sg-mon"; PUBLIC_IP_MODE="ephemeral"
        ;;
    backup)
        # Публичного адреса нет принципиально: сервер бэкапов достижим только
        # изнутри инфраструктуры. Меньше поверхность атаки на хранилище копий.
        VM_NAME="${BACKUP_VM}"; ZONE="${CLOUD_ZONE_B}"; SUBNET="${SUBNET_B_NAME}"
        INTERNAL_IP="${BACKUP_IP}"; SG="sg-backup"; PUBLIC_IP_MODE="none"
        ;;
    *)
        printf 'Неизвестная роль: %s\n' "${ROLE}" >&2
        printf 'Использование: %s\n' "${USAGE}" >&2
        exit "${EX_USAGE}"
        ;;
esac

if yc compute instance get --name "${VM_NAME}" >/dev/null 2>&1; then
    log_info "ВМ ${VM_NAME} уже существует, пропускаю создание"
    yc compute instance get --name "${VM_NAME}"
    exit 0
fi

# Идентификатор группы безопасности нужен в виде UUID.
SG_ID="$(yc vpc security-group get --name "${SG}" --format json | grep -oP '"id":\s*"\K[^"]+' | head -1)"
[[ -n "${SG_ID}" ]] || die "${EX_UNAVAILABLE}" \
    "Группа безопасности ${SG} не найдена. Сначала запустите 20-create-security-groups.sh"

# Собираем описание сетевого интерфейса.
NIC="subnet-name=${SUBNET},ipv4-address=${INTERNAL_IP},security-group-ids=${SG_ID}"
case "${PUBLIC_IP_MODE}" in
    static)
        # Адрес зарезервирован заранее и переживает остановку машины.
        PUBLIC_IP="$(yc vpc address get --name "${VM_NAME}-ip" --format json \
            | grep -oP '"address":\s*"\K[^"]+' | head -1)"
        [[ -n "${PUBLIC_IP}" ]] || die "${EX_UNAVAILABLE}" \
            "Статический адрес ${VM_NAME}-ip не найден. Запустите 10-create-network.sh"
        NIC="${NIC},nat-address=${PUBLIC_IP}"
        log_info "Машине будет назначен статический адрес ${PUBLIC_IP}"
        ;;
    ephemeral)
        # Адрес выдаётся облаком и меняется при остановке ВМ. Квоту на
        # статические адреса не расходует.
        NIC="${NIC},nat-ip-version=ipv4"
        log_info "Машине будет назначен эфемерный публичный адрес"
        ;;
    none)
        log_info "Публичного адреса не будет: машина доступна только изнутри сети"
        ;;
    *)
        die "${EX_SOFTWARE}" "Неизвестный режим публичного адреса: ${PUBLIC_IP_MODE}"
        ;;
esac

log_info "Создаю ВМ ${VM_NAME} (роль ${ROLE}, зона ${ZONE})"
yc compute instance create \
    --name "${VM_NAME}" \
    --hostname "${VM_NAME}" \
    --zone "${ZONE}" \
    --cores "${VM_CORES}" \
    --core-fraction "${VM_CORE_FRACTION}" \
    --memory "${VM_MEMORY}" \
    --network-interface "${NIC}" \
    --create-boot-disk "image-folder-id=standard-images,image-family=${VM_IMAGE_FAMILY},size=${VM_DISK_SIZE},type=network-ssd" \
    --ssh-key "${SSH_KEY}" \
    --labels "role=${ROLE},project=vpn-infra" \
    >/dev/null

log_ok "ВМ ${VM_NAME} создана"
yc compute instance get --name "${VM_NAME}"
