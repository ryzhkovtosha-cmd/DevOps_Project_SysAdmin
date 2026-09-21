#!/usr/bin/env bash
# Собирает текстовый отчёт о состоянии мониторинга.
# Запускать НА МАШИНЕ mon-server:  sudo ./collect-evidence.sh
# Секретов в отчёт не попадает: пароли и хеши не выводятся.

set -euo pipefail
OUT="${1:-monitoring-report.txt}"
[[ "${EUID}" -eq 0 ]] || { printf 'Требуются права root: sudo %s\n' "$0" >&2; exit 77; }
section() { printf '\n========== %s ==========\n\n' "$1"; }
API="http://127.0.0.1:9090/api/v1"

{
    printf 'Отчёт по блоку 3: мониторинг\n'
    printf 'Машина: %s\nСобран: %s\n' "$(hostname)" "$(date -Is)"
    printf 'Prometheus: %s\n'   "$(dpkg-query -W -f='${Version}' prometheus 2>/dev/null)"
    printf 'Alertmanager: %s\n' "$(dpkg-query -W -f='${Version}' prometheus-alertmanager 2>/dev/null)"

    section 'СЛУЖБЫ'
    for u in prometheus prometheus-alertmanager nginx prometheus-node-exporter; do
        printf '  %-32s %s\n' "$u" "$(systemctl is-active "$u" 2>/dev/null)"
    done

    section 'ПАРАМЕТРЫ ЗАПУСКА (через drop-in)'
    cat /etc/prometheus/infra-prometheus.env
    cat /etc/prometheus/infra-alertmanager.env

    section 'ПРОСЛУШИВАЕМЫЕ ПОРТЫ'
    printf 'Службы обязаны слушать только loopback, снаружи их закрывает прокси:\n\n'
    ss -lntH 2>/dev/null | awk '{printf "  %-24s\n", $4}' | sort -u

    section 'ЗАЩИТА ВЕБ-ИНТЕРФЕЙСА'
    printf 'Файл паролей: %s\n' "$(stat -c '%A %U:%G' /etc/nginx/infra-monitoring.htpasswd 2>/dev/null || echo отсутствует)"
    printf 'Пользователи: %s\n' "$(cut -d: -f1 /etc/nginx/infra-monitoring.htpasswd 2>/dev/null | tr '\n' ' ')"
    printf 'Ответ на внешний запрос без пароля: HTTP %s (ожидается 401)\n' \
        "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://$(hostname -I | awk '{print $1}'):9090/" 2>/dev/null)"

    section 'ЦЕЛИ ОПРОСА'
    curl -s "${API}/targets" 2>/dev/null | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)['data']['activeTargets']
except Exception:
    print('  не удалось опросить API'); sys.exit()
for t in d:
    print('  %-28s %-10s %s' % (t['labels'].get('instance','?'), t['health'], t['labels'].get('job','')))
" 2>/dev/null || printf '  не удалось получить список целей\n'

    section 'ЗАГРУЖЕННЫЕ ПРАВИЛА'
    curl -s "${API}/rules" 2>/dev/null | python3 -c "
import json,sys
try:
    g=json.load(sys.stdin)['data']['groups']
except Exception:
    print('  не удалось опросить API'); sys.exit()
print('  групп: %d, правил: %d\n' % (len(g), sum(len(x['rules']) for x in g)))
for grp in g:
    print('  [%s]' % grp['name'])
    for r in grp['rules']:
        print('    %-32s severity=%-9s %s' % (r.get('name','?'),
              r.get('labels',{}).get('severity','-'), r.get('state','')))
" 2>/dev/null || printf '  не удалось получить правила\n'

    section 'АКТИВНЫЕ АЛЕРТЫ'
    curl -s "${API}/alerts" 2>/dev/null | python3 -c "
import json,sys
try:
    a=json.load(sys.stdin)['data']['alerts']
except Exception:
    print('  не удалось опросить API'); sys.exit()
print('  активных: %d' % len(a))
for x in a:
    print('    %-28s %-9s %s' % (x['labels'].get('alertname','?'),
          x.get('state','?'), x['labels'].get('instance_name','')))
" 2>/dev/null || printf '  нет данных\n'

    section 'ГЛУБИНА ИСТОРИИ МЕТРИК'
    curl -s "${API}/query?query=(time()-min(node_boot_time_seconds))/86400" 2>/dev/null \
      | grep -oE '"[0-9.]+"' | tail -1 | xargs -I{} printf '  машины работают суток: %s\n' {}
    printf '  занято хранилищем: %s\n' "$(du -sh /var/lib/prometheus 2>/dev/null | cut -f1)"

    section 'ПРОВЕРКА КОНФИГУРАЦИИ'
    promtool check config /etc/prometheus/infra-prometheus.yml 2>&1
    for r in /etc/prometheus/rules/*.yml; do
        printf '%s: ' "$(basename "$r")"
        promtool check rules "$r" 2>&1 | grep -oE '[0-9]+ rules found|FAILED' | head -1
    done

    section 'ПРАВА НА ФАЙЛ С ПАРОЛЕМ SMTP'
    stat -c '  %A %U:%G  %n' /etc/prometheus/infra-alertmanager.yml 2>/dev/null
    if grep -q '@@SMTP_PASSWORD@@' /etc/prometheus/infra-alertmanager.yml 2>/dev/null; then
        printf '  пароль SMTP НЕ подставлен\n'
    else
        printf '  пароль SMTP подставлен (значение не выводится)\n'
    fi

    section 'ФАЕРВОЛ'
    firewall-cmd --list-all 2>/dev/null
} > "${OUT}" 2>&1

if [[ -x ~/scripts/test/verify.sh ]]; then
    printf '\n========== ИТОГОВАЯ ПРОВЕРКА ==========\n\n' >> "${OUT}"
    ~/scripts/test/verify.sh mon 2>&1 | sed 's/\x1b\[[0-9;]*m//g' >> "${OUT}" || true
fi

chmod 644 "${OUT}"
printf 'Отчёт готов: %s (%s строк)\n' "${OUT}" "$(wc -l < "${OUT}")"
