#!/usr/bin/env bash
# Проверяет deb-пакеты на ОТДЕЛЬНОЙ, только что созданной виртуальной машине.
# Выполняет требование ТЗ: «протестируйте работу артефактов на отдельной
# виртуальной машине, созданной недавно».
#
# Использование:
#   ./test-on-fresh-vm.sh <каталог-с-deb> [имя-временной-ВМ]
#
# Пример:
#   ./test-on-fresh-vm.sh ../../dist
#
# Что проверяется:
#   1. пакеты устанавливаются на чистую систему без ручного вмешательства;
#   2. зависимости разрешаются из репозиториев;
#   3. установленные команды отвечают и возвращают осмысленные коды;
#   4. повторная установка поверх себя не ломается (идемпотентность);
#   5. purge возвращает систему к исходному состоянию без остатков.
#
# Временная ВМ удаляется в конце — в том числе при ошибке или Ctrl+C.
# Проверять пакеты на рабочем сервере бессмысленно: там уже разрешены
# зависимости и созданы каталоги, и половина проблем не проявится.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../project.env
source "${SCRIPT_DIR}/../project.env"

readonly USAGE="$0 <каталог-с-deb> [имя-временной-ВМ]"
require_args "$#" 1 "${USAGE}"
require_cmd yc ssh scp

DEB_DIR="$(cd "$1" && pwd)"
TEST_VM="${2:-pkg-test-$(date +%s)}"

mapfile -t ALL_DEBS < <(find "${DEB_DIR}" -maxdepth 1 -name '*.deb' | sort)
[[ ${#ALL_DEBS[@]} -gt 0 ]] || die "${EX_DATAERR}" "В ${DEB_DIR} нет ни одного .deb"

# Если в каталоге лежат две версии одного пакета, apt возьмёт новую и
# установка пройдёт, а dpkg -i на шаге идемпотентности попытается
# поставить обе и откажется откатываться на старую. Отказ выглядит как
# дефект пакета, хотя это просто забытый файл. Оставляем свежую версию.
declare -A NEWEST=()
for deb in "${ALL_DEBS[@]}"; do
    name="$(dpkg-deb -f "${deb}" Package 2>/dev/null)" || continue
    ver="$(dpkg-deb -f "${deb}" Version 2>/dev/null)" || continue
    if [[ -n "${NEWEST[${name}]:-}" ]]; then
        prev_ver="$(dpkg-deb -f "${NEWEST[${name}]}" Version)"
        if dpkg --compare-versions "${ver}" gt "${prev_ver}"; then
            log_warn "Пропускаю устаревший $(basename "${NEWEST[${name}]}") — есть версия ${ver}"
            NEWEST[${name}]="${deb}"
        else
            log_warn "Пропускаю устаревший $(basename "${deb}") — есть версия ${prev_ver}"
        fi
    else
        NEWEST[${name}]="${deb}"
    fi
done

DEBS=()
for name in "${!NEWEST[@]}"; do
    DEBS+=("${NEWEST[${name}]}")
done
log_info "Пакетов к проверке: ${#DEBS[@]}"

CLEANED=0
cleanup() {
    [[ "${CLEANED}" -eq 1 ]] && return 0
    CLEANED=1
    printf '\n'
    log_info "Удаляю временную ВМ ${TEST_VM}"
    yc compute instance delete --name "${TEST_VM}" >/dev/null 2>&1 \
        && log_ok "Временная ВМ удалена" \
        || log_warn "Не удалось удалить ${TEST_VM} — проверьте вручную: yc compute instance list"
}
trap cleanup EXIT INT TERM

# --- Создание чистой машины ------------------------------------------------

log_info "Создаю временную ВМ ${TEST_VM} (эфемерный адрес, без статики)"
yc compute instance create \
    --name "${TEST_VM}" \
    --zone "${CLOUD_ZONE_A}" \
    --cores 2 --core-fraction 20 --memory 2G \
    --network-interface "subnet-name=${SUBNET_A_NAME},nat-ip-version=ipv4" \
    --create-boot-disk "image-folder-id=standard-images,image-family=${VM_IMAGE_FAMILY},size=15" \
    --ssh-key "${SSH_KEY}" \
    --labels "role=pkg-test,project=vpn-infra" \
    >/dev/null || die "${EX_UNAVAILABLE}" "Не удалось создать ВМ"

TEST_IP="$(yc compute instance get --name "${TEST_VM}" --format json \
    | grep -oP '"address":\s*"\K[0-9.]+' | tail -1)"
[[ -n "${TEST_IP}" ]] || die "${EX_UNAVAILABLE}" "Не удалось определить адрес ВМ"
log_ok "ВМ создана: ${TEST_IP}"

# Машина отвечает на SSH не сразу после создания.
log_info "Жду готовности SSH"
for _ in $(seq 1 30); do
    if ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
           -o ConnectTimeout=5 "${SSH_USER}@${TEST_IP}" true 2>/dev/null; then
        log_ok "SSH доступен"
        break
    fi
    sleep 5
done
ssh -o BatchMode=yes -o ConnectTimeout=5 "${SSH_USER}@${TEST_IP}" true 2>/dev/null \
    || die "${EX_UNAVAILABLE}" "ВМ не отвечает по SSH"

# LogLevel=ERROR глушит предупреждения SSH: в отчёте о проверке пакетов
# они занимают больше места, чем сам результат.
rvm() {
    ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR \
        "${SSH_USER}@${TEST_IP}" "$@"
}

# --- Проверки ---------------------------------------------------------------

PASSED=0; FAILED=0
ok()   { printf '  \033[32m[ OK ]\033[0m %s\n' "$*"; PASSED=$((PASSED + 1)); }
bad()  { printf '  \033[31m[FAIL]\033[0m %s\n' "$*"; FAILED=$((FAILED + 1)); }

printf '\n\033[1mСнимок системы до установки\033[0m\n'
rvm 'dpkg-query -W -f="\${Package}\n" | sort' > /tmp/pkgs-before.txt
rvm 'find /etc/infra /etc/infra-ca /etc/infra-vpn /usr/share/infra /var/lib/infra-* /usr/sbin/infra-* 2>/dev/null | sort || true' \
    > /tmp/files-before.txt || true
ok "Зафиксировано пакетов: $(wc -l < /tmp/pkgs-before.txt)"

log_info "Копирую пакеты на машину"
scp -q "${DEBS[@]}" "${SSH_USER}@${TEST_IP}:~/" || die "${EX_UNAVAILABLE}" "Копирование не удалось"

printf '\n\033[1m1. Установка на чистую систему\033[0m\n'
if rvm 'sudo apt-get update -qq && sudo apt-get install -y -qq ./*.deb' >/tmp/install.log 2>&1; then
    ok "Все пакеты установились, зависимости разрешены"
else
    bad "Установка не удалась"
    # Конфликт файлов — самая частая причина, показываем её отдельно:
    # в общем потоке вывода dpkg эта строка теряется среди сотен других.
    if grep -q 'trying to overwrite' /tmp/install.log; then
        printf '\n      \033[1mКонфликт файлов с другим пакетом:\033[0m\n'
        grep 'trying to overwrite' /tmp/install.log | sed 's/^/      /'
    fi
    printf '\n      Последние строки журнала установки:\n'
    grep -E '^(E:|dpkg: error)' /tmp/install.log | tail -10 | sed 's/^/      /'
    printf '\n\033[1mДальнейшие проверки пропущены: система в неконсистентном состоянии.\033[0m\n'
    printf 'Их результаты были бы недостоверны.\n'
    printf '\nИтог: успешно %s, провалено %s\n' "${PASSED}" "${FAILED}"
    exit 1
fi

printf '\n\033[1m2. Состояние пакетов\033[0m\n'
# Подстановка процесса, а не конвейер: тело while в конвейере выполняется
# в подоболочке, и увеличенные там счётчики PASSED и FAILED пропадают.
while read -r line; do
    [[ -n "${line}" ]] || continue
    case "${line}" in
        *"install ok installed"*) ok "${line}" ;;
        *) bad "${line}" ;;
    esac
done < <(rvm "dpkg-query -W -f='\${Package} \${Version} \${Status}\\n' 'infra-*' 2>/dev/null" || true)
rvm "dpkg-query -W -f='\${Status}\\n' 'infra-*' 2>/dev/null | grep -qv 'install ok installed'" \
    && bad "Не все пакеты настроены" || ok "Все пакеты в состоянии installed"

printf '\n\033[1m3. Установленные команды отвечают\033[0m\n'
# Команды, принимающие обязательные аргументы: запускаем без них и ждём
# код 64 (EX_USAGE). Это безопасно — они завершаются, ничего не сделав.
for cmd in infra-ca-sign infra-vpn-make-client; do
    if rvm "command -v ${cmd} >/dev/null 2>&1"; then
        code="$(rvm "sudo ${cmd} >/dev/null 2>&1; echo \$?")"
        [[ "${code}" == "64" ]] \
            && ok "${cmd} без аргументов возвращает 64 (EX_USAGE)" \
            || bad "${cmd} вернул код ${code}, ожидался 64"
    else
        bad "${cmd} не установлена"
    fi
done

# Команды без обязательных аргументов запускать НЕЛЬЗЯ: infra-ca-init
# развернул бы на тестовой машине настоящий удостоверяющий центр, а
# infra-cert-metrics писал бы метрики. Проверяем иначе: команда на месте,
# исполняема и синтаксически корректна.
for cmd in infra-ca-init infra-cert-metrics; do
    if rvm "command -v ${cmd} >/dev/null 2>&1 && sudo bash -n \$(command -v ${cmd})"; then
        ok "${cmd} установлена и синтаксически корректна"
    else
        bad "${cmd} отсутствует или содержит синтаксическую ошибку"
    fi
done

printf '\n\033[1m4. Man-страницы\033[0m\n'
for m in infra-ca-init infra-ca-sign infra-vpn-make-client infra-cert-metrics; do
    rvm "man -w ${m} >/dev/null 2>&1" && ok "man ${m}" || log_info "  man ${m} — нет (пакет не установлен)"
done

printf '\n\033[1m5. Права на чувствительные каталоги\033[0m\n'
for d in /var/lib/infra-ca /var/lib/infra-vpn; do
    perms="$(rvm "stat -c '%a' ${d} 2>/dev/null" || true)"
    [[ -z "${perms}" ]] && continue
    [[ "${perms}" == "700" ]] && ok "${d} имеет права 700" || bad "${d} имеет права ${perms}"
done

printf '\n\033[1m6. Повторная установка (идемпотентность)\033[0m\n'
# dpkg -i, а не apt --reinstall: apt на локальных файлах отвечает
# "Internal Error, No file name", а нам важно повторно выполнить
# установочные сценарии и убедиться, что они идемпотентны.
if rvm 'sudo dpkg -i ./*.deb' >/tmp/reinstall.log 2>&1; then
    ok "Повторная установка поверх себя прошла без ошибок"
else
    bad "Повторная установка сломалась"
    tail -15 /tmp/reinstall.log | sed 's/^/      /'
fi

printf '\n\033[1m7. Полная очистка (purge)\033[0m\n'
if rvm 'sudo apt-get purge -y -qq "infra-*"' >/tmp/purge.log 2>&1; then
    ok "Пакеты удалены"
else
    bad "Удаление завершилось с ошибкой"
    tail -15 /tmp/purge.log | sed 's/^/      /'
fi

rvm 'find /etc/infra /etc/infra-ca /etc/infra-vpn /usr/share/infra /var/lib/infra-* /usr/sbin/infra-* 2>/dev/null | sort || true' \
    > /tmp/files-after.txt || true
if diff -q /tmp/files-before.txt /tmp/files-after.txt >/dev/null; then
    ok "Система вернулась к исходному состоянию, следов не осталось"
else
    # PKI и ключи мы удалять отказываемся намеренно — это не дефект.
    leftovers="$(diff /tmp/files-before.txt /tmp/files-after.txt | grep '^>' | sed 's/^> //')"
    if printf '%s' "${leftovers}" | grep -qvE 'pki|\.key$'; then
        bad "Остались посторонние файлы:"
        printf '%s\n' "${leftovers}" | sed 's/^/      /'
    else
        ok "Остались только ключи и PKI — так и задумано, их purge не трогает"
    fi
fi

printf '\n\033[1mИтог: успешно %s, провалено %s\033[0m\n' "${PASSED}" "${FAILED}"
printf 'Проверка выполнена на отдельной ВМ %s (%s), созданной для этого теста.\n' \
    "${TEST_VM}" "${TEST_IP}"

[[ "${FAILED}" -eq 0 ]] || exit 1
