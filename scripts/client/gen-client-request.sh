#!/usr/bin/env bash
# Запускается СОТРУДНИКОМ на своём компьютере (Linux или macOS).
# Создаёт приватный ключ и запрос на сертификат.
#
# Использование:
#   ./gen-client-request.sh <ваше-имя>
#
# Пример:
#   ./gen-client-request.sh ivanov
#
# Приватный ключ остаётся у вас и никому не передаётся — ни администратору,
# ни удостоверяющему центру. Администратору отправляется только файл .req:
# из него ключ восстановить невозможно.
#
# Зависимости: только openssl, который уже есть в macOS и любом Linux.
# Устанавливать easy-rsa или OpenVPN для этого шага не нужно.

set -euo pipefail

readonly WORK_DIR="${HOME}/.infra-vpn"
readonly USAGE="$0 <ваше-имя-латиницей>"

die() { printf 'Ошибка: %s\n' "$*" >&2; exit 1; }

if [[ $# -lt 1 ]]; then
    printf 'Использование: %s\n' "${USAGE}" >&2
    exit 64
fi

CLIENT_NAME="$1"

# Имя попадёт в Common Name сертификата и в имена файлов.
if [[ ! "${CLIENT_NAME}" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$ ]]; then
    die "Имя '${CLIENT_NAME}' недопустимо. Используйте латиницу, цифры, дефис и подчёркивание."
fi

command -v openssl >/dev/null 2>&1 || die "Не найден openssl. Установите пакет openssl."

mkdir -p "${WORK_DIR}"
chmod 700 "${WORK_DIR}"

KEY="${WORK_DIR}/${CLIENT_NAME}.key"
REQ="${WORK_DIR}/${CLIENT_NAME}.req"

if [[ -f "${KEY}" ]]; then
    printf 'Ключ %s уже существует.\n' "${KEY}"
    printf 'Если создать новый, прежний сертификат станет бесполезен.\n'
    read -r -p 'Пересоздать ключ? [y/N] ' answer
    [[ "${answer}" =~ ^[Yy]$ ]] || { printf 'Оставляю прежний ключ.\n'; exit 0; }
fi

printf 'Создаю приватный ключ на эллиптических кривых...\n'
# secp384r1 — та же кривая, что настроена в удостоверяющем центре.
openssl ecparam -genkey -name secp384r1 -out "${KEY}" 2>/dev/null
chmod 600 "${KEY}"

printf 'Создаю запрос на сертификат...\n'
openssl req -new -key "${KEY}" -out "${REQ}" -sha512 \
    -subj "/CN=${CLIENT_NAME}" 2>/dev/null

chmod 644 "${REQ}"

cat <<INFO

Готово.

  Приватный ключ (НИКОМУ НЕ ОТПРАВЛЯТЬ):
      ${KEY}

  Запрос на сертификат (отправьте администратору):
      ${REQ}

Отпечаток запроса — продиктуйте его администратору голосом или в мессенджере,
чтобы он убедился, что получил именно ваш файл, а не подменённый:

INFO

openssl req -in "${REQ}" -noout -pubkey | openssl sha256

cat <<INFO

Дальше:
  1. Отправьте файл ${CLIENT_NAME}.req администратору любым удобным способом.
  2. В ответ получите архив ${CLIENT_NAME}-bundle.tar.gz
  3. Соберите итоговую конфигурацию:  ./assemble-config.sh ${CLIENT_NAME}-bundle.tar.gz

INFO
