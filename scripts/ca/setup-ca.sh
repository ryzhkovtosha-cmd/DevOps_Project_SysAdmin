#!/usr/bin/env bash
# Разворачивает удостоверяющий центр на выделенной машине.
#
# Запускается ОДИН РАЗ на ca-server, интерактивно: при создании корневого
# сертификата Easy-RSA спросит парольную фразу для приватного ключа CA.
# Эта фраза намеренно не хранится в скрипте — иначе защита ключа теряет
# смысл: кто прочитал скрипт, тот получил и ключ.
#
# Использование:
#   sudo ./setup-ca.sh
#
# Идемпотентность: если корневой сертификат уже выпущен, скрипт сообщает
# об этом и выходит успешно, ничего не перезаписывая. Перевыпуск корневого
# сертификата обесценил бы все ранее выданные — такое делается только
# осознанно и вручную.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../project.env
source "${SCRIPT_DIR}/../project.env"

readonly CA_HOME="/var/lib/infra-ca"
readonly CA_PKI="${CA_HOME}/pki"
readonly CA_CONF_DIR="/etc/infra-ca"

require_root

install_packages() {
    apt_install easy-rsa openssl firewalld
}

prepare_layout() {
    # 0700 на каталоге с PKI: внутри лежит приватный ключ CA. Даже при
    # ошибке в правах на отдельный файл каталог остаётся закрытым.
    ensure_dir "${CA_HOME}" 0700 "root:root"
    ensure_dir "${CA_HOME}/incoming" 0700 "root:root"   # присланные CSR
    ensure_dir "${CA_HOME}/outgoing" 0755 "root:root"   # выданные сертификаты
    ensure_dir "${CA_CONF_DIR}" 0755 "root:root"

    # Symlink на ВСЕ файлы easy-rsa, а не только на исполняемый.
    #
    # easyrsa ищет рядом с собой шаблон openssl-easyrsa.cnf и каталог
    # x509-types с описаниями типов сертификатов. Если слинковать только
    # сам скрипт, init-pki отработает, а build-ca упадёт с невнятным
    # "Failed to update .../safessl-easyrsa.cnf": шаблон не из чего копировать.
    #
    # Ссылки, а не копии: при обновлении пакета easy-rsa получаем свежие
    # файлы без ручного вмешательства.
    local easyrsa_share="/usr/share/easy-rsa"
    [[ -x "${easyrsa_share}/easyrsa" ]] || die "${EX_UNAVAILABLE}" \
        "Не найден ${easyrsa_share}/easyrsa. Проверьте, что пакет easy-rsa установлен."
    [[ -f "${easyrsa_share}/openssl-easyrsa.cnf" ]] || die "${EX_UNAVAILABLE}" \
        "Не найден ${easyrsa_share}/openssl-easyrsa.cnf. Пакет easy-rsa установлен неполно."
    ln -sf "${easyrsa_share}"/* "${CA_HOME}/"
}

# Файл vars задаёт реквизиты и криптографию будущих сертификатов.
# Генерируется из project.env, чтобы параметры компании жили в одном месте.
write_vars() {
    local vars="${CA_HOME}/vars"
    if [[ -f "${vars}" ]]; then
        log_info "Файл vars уже существует, пропускаю"
        return 0
    fi
    cat > "${vars}" <<VARS
# Сгенерировано setup-ca.sh — правьте project.env, а не этот файл.
set_var EASYRSA_REQ_COUNTRY   "${CA_COUNTRY}"
set_var EASYRSA_REQ_PROVINCE  "${CA_PROVINCE}"
set_var EASYRSA_REQ_CITY      "${CA_CITY}"
set_var EASYRSA_REQ_ORG       "${CA_ORG}"
set_var EASYRSA_REQ_EMAIL     "${CA_EMAIL}"
set_var EASYRSA_REQ_OU        "${CA_OU}"

# Эллиптические кривые вместо RSA: ключи короче, подпись быстрее,
# стойкость сопоставима с RSA-3072. Побочный эффект — не нужны
# параметры Диффи-Хеллмана, поэтому в конфиге OpenVPN будет dh none.
set_var EASYRSA_ALGO          "ec"
set_var EASYRSA_CURVE         "secp384r1"
set_var EASYRSA_DIGEST        "sha512"

# Срок жизни: корневой — 10 лет, выданные — 1 год.
# Короткий срок клиентских сертификатов ограничивает окно, в котором
# полезен украденный ключ, и заставляет регулярно проверять список
# действующих сотрудников.
set_var EASYRSA_CA_EXPIRE     3650
set_var EASYRSA_CERT_EXPIRE   365
set_var EASYRSA_CRL_DAYS      180
VARS
    chmod 600 "${vars}"
    log_ok "Создан ${vars}"
}

init_pki() {
    if [[ -f "${CA_PKI}/ca.crt" ]]; then
        log_info "PKI уже содержит корневой сертификат, не трогаю"
        return 0
    fi

    # Половинчатое состояние: каталог есть, а шаблона конфигурации в нём нет.
    # Так выглядит PKI, созданная до того, как были слинкованы все файлы
    # easy-rsa. Корневого сертификата ещё нет, поэтому пересоздать безопасно.
    if [[ -d "${CA_PKI}" && ! -f "${CA_PKI}/openssl-easyrsa.cnf" ]]; then
        log_warn "PKI создана не полностью (нет openssl-easyrsa.cnf), пересоздаю"
        rm -rf "${CA_PKI}"
    fi

    if [[ -d "${CA_PKI}" ]]; then
        log_info "Каталог PKI уже существует, пропускаю инициализацию"
        return 0
    fi

    log_info "Инициализирую инфраструктуру открытых ключей"
    ( cd "${CA_HOME}" && EASYRSA="${CA_HOME}" EASYRSA_PKI="${CA_PKI}" \
        ./easyrsa --batch init-pki >/dev/null )
    [[ -f "${CA_PKI}/openssl-easyrsa.cnf" ]] || die "${EX_SOFTWARE}" \
        "init-pki не создала openssl-easyrsa.cnf — проверьте целостность пакета easy-rsa"
    log_ok "PKI создана: ${CA_PKI}"
}

build_ca() {
    if [[ -f "${CA_PKI}/ca.crt" ]]; then
        log_info "Корневой сертификат уже выпущен, пропускаю"
        return 0
    fi
    log_info "Создаю корневой сертификат."
    log_warn "Сейчас будет запрошена парольная фраза для приватного ключа CA."
    log_warn "Запомните её: она нужна при каждой подписи сертификата."
    ( cd "${CA_HOME}" \
      && EASYRSA="${CA_HOME}" EASYRSA_PKI="${CA_PKI}" EASYRSA_REQ_CN="${CA_ORG} Root CA" \
         ./easyrsa build-ca )
    chmod 600 "${CA_PKI}/private/ca.key"
    # Открытый сертификат раздаётся всем участникам, его прятать не нужно.
    cp "${CA_PKI}/ca.crt" "${CA_HOME}/outgoing/ca.crt"
    chmod 644 "${CA_HOME}/outgoing/ca.crt"
    log_ok "Корневой сертификат выпущен"
}

build_crl() {
    # Список отзыва нужен, чтобы сертификат уволившегося сотрудника
    # перестал работать до истечения срока. Создаём сразу, пустым.
    if [[ -f "${CA_PKI}/crl.pem" ]]; then
        log_info "Список отзыва уже существует, пропускаю"
        return 0
    fi
    log_info "Создаю список отзыва сертификатов (CRL)"
    ( cd "${CA_HOME}" && EASYRSA="${CA_HOME}" EASYRSA_PKI="${CA_PKI}" ./easyrsa gen-crl )
    cp "${CA_PKI}/crl.pem" "${CA_HOME}/outgoing/crl.pem"
    chmod 644 "${CA_HOME}/outgoing/crl.pem"
    log_ok "CRL создан"
}

configure_firewall() {
    service_enable_now firewalld
    # На машине CA не работает ни одного сетевого сервиса, кроме SSH.
    # Всё остальное закрыто, включая ICMP извне.
    if firewall-cmd --permanent --query-service=ssh >/dev/null 2>&1; then
        log_info "SSH уже разрешён в firewalld"
    else
        firewall-cmd --permanent --add-service=ssh >/dev/null
        log_ok "SSH разрешён в firewalld"
    fi
    firewalld_allow_from "${MON_IP}/32" "${PORT_NODE_EXPORTER}/tcp"
    firewall-cmd --reload >/dev/null
    log_ok "Фаервол настроен"
}

show_summary() {
    log_ok "Удостоверяющий центр развёрнут."
    printf '\n'
    printf 'Корневой сертификат:\n'
    openssl x509 -in "${CA_PKI}/ca.crt" -noout -subject -issuer -dates
    printf '\nОтпечаток SHA-256 (сверяйте при передаче сертификата):\n'
    openssl x509 -in "${CA_PKI}/ca.crt" -noout -fingerprint -sha256
    printf '\nДальше: принимайте запросы командой  sudo infra-ca-sign <тип> <имя> <файл.req>\n'
}

main() {
    install_packages
    prepare_layout
    write_vars
    init_pki
    build_ca
    build_crl
    configure_firewall
    show_summary
}

main "$@"
