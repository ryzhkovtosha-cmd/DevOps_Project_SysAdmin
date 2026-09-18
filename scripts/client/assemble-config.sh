#!/usr/bin/env bash
# Запускается СОТРУДНИКОМ на своём компьютере после получения архива
# от администратора.
#
# Использование:
#   ./assemble-config.sh <имя>-bundle.tar.gz
#
# Собирает единый файл .ovpn: берёт присланные сертификаты и добавляет к ним
# ваш приватный ключ, который всё это время лежал только на вашей машине.
# Именно поэтому сборка происходит здесь, а не на сервере — ключ не должен
# оказаться в архиве, который путешествует по почте или мессенджеру.

set -euo pipefail

readonly WORK_DIR="${HOME}/.infra-vpn"

die() { printf 'Ошибка: %s\n' "$*" >&2; exit 1; }

if [[ $# -lt 1 ]]; then
    printf 'Использование: %s <имя>-bundle.tar.gz\n' "$0" >&2
    exit 64
fi

BUNDLE="$1"
[[ -f "${BUNDLE}" ]] || die "Архив не найден: ${BUNDLE}"

command -v openssl >/dev/null 2>&1 || die "Не найден openssl."
command -v tar >/dev/null 2>&1     || die "Не найден tar."

# Временный каталог удаляется в любом случае, даже при ошибке или Ctrl+C:
# в нём лежат сертификаты, оставлять их в /tmp незачем.
TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "${TMP_DIR}"; }
trap cleanup EXIT INT TERM

tar -xzf "${BUNDLE}" -C "${TMP_DIR}" || die "Не удалось распаковать ${BUNDLE}"

# Имя клиента определяем по единственному файлу .crt, который не ca.crt.
CLIENT_CRT="$(find "${TMP_DIR}" -name '*.crt' ! -name 'ca.crt' | head -1)"
[[ -n "${CLIENT_CRT}" ]] || die "В архиве нет клиентского сертификата"

CLIENT_NAME="$(basename "${CLIENT_CRT}" .crt)"
BUNDLE_DIR="$(dirname "${CLIENT_CRT}")"

CA_CRT="${BUNDLE_DIR}/ca.crt"
TA_KEY="${BUNDLE_DIR}/ta.key"
BASE_CONF="${BUNDLE_DIR}/base.conf"
CLIENT_KEY="${WORK_DIR}/${CLIENT_NAME}.key"

for f in "${CA_CRT}" "${TA_KEY}" "${BASE_CONF}"; do
    [[ -f "${f}" ]] || die "В архиве не хватает файла: $(basename "${f}")"
done

[[ -f "${CLIENT_KEY}" ]] || die \
    "Не найден ваш приватный ключ ${CLIENT_KEY}. Он создаётся скриптом gen-client-request.sh."

# Сертификат должен подходить к ключу. Если администратор по ошибке прислал
# чужой сертификат, лучше узнать об этом сейчас, а не при подключении.
CRT_PUB="$(openssl x509 -in "${CLIENT_CRT}" -noout -pubkey | openssl sha256)"
KEY_PUB="$(openssl pkey -in "${CLIENT_KEY}" -pubout 2>/dev/null | openssl sha256)"
[[ "${CRT_PUB}" == "${KEY_PUB}" ]] || die \
    "Присланный сертификат не соответствует вашему ключу. Сообщите администратору."

OUTPUT="${WORK_DIR}/${CLIENT_NAME}.ovpn"

{
    cat "${BASE_CONF}"
    printf '\n<ca>\n';        cat "${CA_CRT}";     printf '</ca>\n'
    printf '\n<cert>\n';      cat "${CLIENT_CRT}"; printf '</cert>\n'
    printf '\n<key>\n';       cat "${CLIENT_KEY}"; printf '</key>\n'
    printf '\n<tls-crypt>\n'; cat "${TA_KEY}";     printf '</tls-crypt>\n'
} > "${OUTPUT}"

# Внутри файла лежит приватный ключ, поэтому права строго 600.
chmod 600 "${OUTPUT}"

printf '\nГотово: %s\n\n' "${OUTPUT}"
printf 'Этот файл содержит ваш приватный ключ — он равнозначен паролю.\n'
printf 'Не пересылайте его и не выкладывайте в общие папки.\n\n'
printf 'Подключение:\n'
printf '  Linux:   sudo openvpn --config %s\n' "${OUTPUT}"
printf '  macOS:   откройте файл двойным щелчком (Tunnelblick)\n'
printf '  Windows: поместите в C:\\Program Files\\OpenVPN\\config\\\n\n'
