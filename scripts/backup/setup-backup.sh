#!/usr/bin/env bash
# Настраивает систему резервного копирования на защищаемой машине:
# ключ шифрования, доступ к серверу хранения, расписание.
#
# Использование:
#   sudo ./setup-backup.sh <ca|vpn|artifacts>
#
# Запускается один раз на каждой машине, данные которой нужно копировать.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../project.env
source "${SCRIPT_DIR}/../project.env"

readonly CONF_DIR="/etc/infra-backup"
readonly BACKUP_CONF="${CONF_DIR}/backup.conf"
readonly PASSPHRASE_FILE="${CONF_DIR}/passphrase"
readonly BACKUP_BIN="/usr/local/sbin/infra-backup"
readonly USAGE="$0 <ca|vpn|artifacts>"

require_root
require_args "$#" 1 "${USAGE}"

JOB="$1"
case "${JOB}" in
    ca|vpn|artifacts) ;;
    *) die "${EX_USAGE}" "Задача должна быть ca, vpn или artifacts" ;;
esac

apt_install gnupg openssh-client rsync

ensure_dir "${CONF_DIR}" 0700 "root:root"
ensure_dir /var/lib/infra-backup/staging 0700 "root:root"

# --- Парольная фраза --------------------------------------------------------

# Одна и та же фраза на всех машинах: иначе при восстановлении придётся
# помнить, какая копия каким ключом закрыта. Хранится ВНЕ инфраструктуры —
# в менеджере паролей команды. Копия, зашифрованная фразой, которая лежит
# на той же машине, защищена ровно никак.
if [[ -s "${PASSPHRASE_FILE}" ]]; then
    log_info "Парольная фраза уже задана"
else
    if [[ -t 0 ]]; then
        local_pass=""
        read -r -s -p "Парольная фраза для шифрования копий: " local_pass; printf '\n'
        read -r -s -p "Повторите: " local_pass2; printf '\n'
        [[ "${local_pass}" == "${local_pass2}" ]] || die "${EX_DATAERR}" "Фразы не совпадают"
        [[ ${#local_pass} -ge 16 ]] || die "${EX_DATAERR}" \
            "Слишком короткая фраза. Минимум 16 символов: этой фразой закрыт приватный ключ центра."
        printf '%s' "${local_pass}" > "${PASSPHRASE_FILE}"
    else
        die "${EX_USAGE}" "Запустите интерактивно: нужна парольная фраза"
    fi
    chmod 600 "${PASSPHRASE_FILE}"
    log_ok "Парольная фраза сохранена (${PASSPHRASE_FILE}, права 600)"
    log_warn "ЗАПИШИТЕ её в менеджер паролей команды. Потеря фразы = потеря всех копий."
fi

# --- Ключ доступа к серверу хранения ---------------------------------------

SSH_KEY_FILE="/root/.ssh/id_ed25519_backup"
if [[ ! -f "${SSH_KEY_FILE}" ]]; then
    ensure_dir /root/.ssh 0700 "root:root"
    # Отдельный ключ только для бэкапов, без парольной фразы: задача идёт
    # по расписанию, ввести пароль некому. Ограничение компенсируется на
    # стороне сервера хранения — там ключ привязан к единственной команде.
    ssh-keygen -t ed25519 -N "" -f "${SSH_KEY_FILE}" -C "infra-backup-${JOB}" >/dev/null
    log_ok "Создан ключ доступа к серверу хранения"
fi

ensure_line /root/.ssh/config "Host ${BACKUP_IP}"
ensure_line /root/.ssh/config "    IdentityFile ${SSH_KEY_FILE}"
ensure_line /root/.ssh/config "    StrictHostKeyChecking accept-new"
chmod 600 /root/.ssh/config

# --- Файл настроек ----------------------------------------------------------

if [[ ! -f "${BACKUP_CONF}" ]]; then
    cat > "${BACKUP_CONF}" <<CONF
# Настройки резервного копирования. Создано setup-backup.sh.

# Основное место хранения — отдельная ВМ в другой геозоне.
BACKUP_HOST="${BACKUP_IP}"
BACKUP_USER="infra-backup"
BACKUP_REMOTE_DIR="/srv/backups"

# Второе независимое место — объектное хранилище. Раскомментируйте
# после создания бакета и настройки ключей доступа:
#   yc storage bucket create --name company-infra-backups
#   aws configure --profile default
# Смысл второго места: сервер в единственном экземпляре не является
# надёжным хранилищем. Пожар в дата-центре уносит и данные, и копии.
#S3_BUCKET="company-infra-backups"
#S3_ENDPOINT="https://storage.yandexcloud.net"
CONF
    chmod 600 "${BACKUP_CONF}"
    log_ok "Создан ${BACKUP_CONF}"
fi

# --- Установка команды и расписания ----------------------------------------

install -m 0700 -o root -g root "${SCRIPT_DIR}/backup.sh" "${BACKUP_BIN}"
install -m 0700 -o root -g root "${SCRIPT_DIR}/restore.sh" /usr/local/sbin/infra-restore

# Библиотека нужна установленным копиям скриптов.
if [[ ! -f /usr/share/infra/common.sh ]]; then
    ensure_dir /usr/share/infra 0755 "root:root"
    install -m 0644 "${SCRIPT_DIR}/../lib/common.sh" /usr/share/infra/common.sh
fi
sed -i -e 's|^SCRIPT_DIR=.*$|# Библиотека приходит из пакета infra-common|' \
       -e 's|^source "\${SCRIPT_DIR}/../lib/common.sh"$|source /usr/share/infra/common.sh|' \
       -e 's|^source "\${SCRIPT_DIR}/../project.env"$|source /etc/infra/project.env|' \
       "${BACKUP_BIN}" /usr/local/sbin/infra-restore

cat > /etc/systemd/system/infra-backup.service <<UNIT
[Unit]
Description=Резервное копирование (задача ${JOB})
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
# У служб systemd переменная HOME не задана. Без неё ssh не находит
# ~/.ssh/config и ключ доступа к серверу хранения.
Environment=HOME=/root
ExecStart=${BACKUP_BIN} ${JOB}
# Задача не должна висеть бесконечно, занимая место промежуточным архивом.
TimeoutStartSec=30min
Nice=10
IOSchedulingClass=idle
UNIT

cat > /etc/systemd/system/infra-backup.timer <<'UNIT'
[Unit]
Description=Ежесуточное резервное копирование

[Timer]
# 03:20 — время низкой нагрузки. Разброс в 20 минут, чтобы три машины
# не начали копирование одновременно и не забили канал.
OnCalendar=*-*-* 03:20:00
RandomizedDelaySec=20min
# Persistent=true запускает пропущенную задачу после включения машины:
# если сервер был выключен ночью, копия сделается при старте, а не
# пропустится до следующих суток.
Persistent=true

[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable --quiet infra-backup.timer
systemctl start infra-backup.timer
log_ok "Расписание включено"

cat <<SUMMARY

Резервное копирование настроено для задачи «${JOB}».

Остался один ручной шаг — разрешить этой машине писать на сервер хранения.
Выполните на ${BACKUP_IP} от имени root:

  # Имя НЕ backup: в Debian и Ubuntu такой системный пользователь уже есть
  # (домашний каталог /var/backups, оболочка nologin), и ключи, положенные
  # в /srv/backups, sshd просто не увидит.
  getent passwd infra-backup >/dev/null || useradd -m -d /srv/backups -s /bin/bash infra-backup
  mkdir -p /srv/backups/.ssh && chmod 700 /srv/backups/.ssh
  cat >> /srv/backups/.ssh/authorized_keys <<'KEY'
$(cat "${SSH_KEY_FILE}.pub")
KEY
  sort -u -o /srv/backups/.ssh/authorized_keys /srv/backups/.ssh/authorized_keys
  chown -R infra-backup:infra-backup /srv/backups
  chmod 600 /srv/backups/.ssh/authorized_keys

Проверка:
  sudo systemctl start infra-backup.service
  sudo journalctl -u infra-backup -n 30 --no-pager
  sudo infra-restore --list ${JOB}
  sudo infra-restore --verify ${JOB}

Следующий запуск по расписанию:
  systemctl list-timers infra-backup.timer

SUMMARY
