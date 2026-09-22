# Генератор схем инфраструктуры и потоков данных: SVG + PNG.
#
# Использование:  python3 docs/tools/diagrams.py
# Результат:      docs/diagrams/{infrastructure,dataflow}.{svg,png}
# Зависимость:    pip install cairosvg
#
# Схемы описаны кодом, а не нарисованы вручную: при смене адреса или
# порта правится одна строка, и обе картинки пересобираются одинаково.
import os
import cairosvg

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'diagrams')

FONT = "DejaVu Sans, Arial, sans-serif"
C = {  # палитра
    'ink': '#1f2328', 'muted': '#5b6470', 'faint': '#8a8f98', 'line': '#c9ced6',
    'green': '#3f8f5f', 'green_bg': '#eef7f1', 'red': '#c0504d', 'red_bg': '#fdf1f1',
    'violet': '#7a62bd', 'violet_bg': '#f4f0fb', 'gold': '#b8901c', 'gold_bg': '#fdf9ec',
    'blue': '#4f86c6', 'blue_bg': '#eef4fb', 'orange': '#c7703f', 'orange_bg': '#fdf2ec',
    'grey_bg': '#f6f7f8',
}

class SVG:
    def __init__(self, w, h):
        self.w, self.h, self.parts = w, h, []
    def add(self, s): self.parts.append(s)
    def rect(self, x, y, w, h, fill='#fff', stroke=None, dash=False, rx=10, sw=1.5):
        st = f' stroke="{stroke}" stroke-width="{sw}"' if stroke else ''
        da = ' stroke-dasharray="6 4"' if dash else ''
        self.add(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{rx}" fill="{fill}"{st}{da}/>')
    def text(self, x, y, s, size=12.5, weight='normal', fill=None, anchor='start'):
        s = s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')
        self.add(f'<text x="{x}" y="{y}" font-family="{FONT}" font-size="{size}" '
                 f'font-weight="{weight}" fill="{fill or C["ink"]}" text-anchor="{anchor}">{s}</text>')
    def lines(self, x, y, items, step=19):
        for i, it in enumerate(items):
            if isinstance(it, tuple): self.text(x, y + i * step, it[0], **it[1])
            else: self.text(x, y + i * step, it, fill=C['muted'])
    def arrow(self, pts, color, dash=False, sw=2, both=False):
        d = 'M ' + ' L '.join(f'{x} {y}' for x, y in pts)
        mid = color.strip('#')
        da = ' stroke-dasharray="6 4"' if dash else ''
        ms = f' marker-start="url(#a{mid})"' if both else ''
        self.add(f'<path d="{d}" fill="none" stroke="{color}" stroke-width="{sw}"{da}{ms} marker-end="url(#a{mid})"/>')
    def render(self, path_svg, path_png):
        colors = {v for k, v in C.items() if not k.endswith('_bg')}
        markers = ''.join(
            f'<marker id="a{c.strip("#")}" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" '
            f'markerHeight="7" orient="auto-start-reverse"><path d="M0 0 L10 5 L0 10 z" fill="{c}"/></marker>'
            for c in colors)
        svg = (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {self.w} {self.h}" '
               f'width="{self.w}" height="{self.h}"><defs>{markers}</defs>'
               f'<rect width="{self.w}" height="{self.h}" fill="#ffffff"/>' + ''.join(self.parts) + '</svg>')
        open(path_svg, 'w', encoding='utf-8').write(svg)
        cairosvg.svg2png(bytestring=svg.encode(), write_to=path_png, output_width=self.w * 2)

def bold(s, size=14.5): return (s, dict(size=size, weight='bold'))
def tag(s, color):      return (s, dict(size=11.5, fill=color))

# ======================================================================
# 1. СХЕМА ИНФРАСТРУКТУРЫ
# ======================================================================
d = SVG(1200, 830)
d.text(30, 42, 'Схема инфраструктуры VPN-сервиса', size=22, weight='bold')
d.text(30, 66, 'Yandex Cloud · VPC infra-net · две геозоны · все адреса по состоянию на момент сдачи', fill=C['muted'])

# Внешний мир
d.rect(30, 90, 250, 510, fill='#fbfbfc', stroke=C['line'])
d.text(46, 114, 'ВНЕШНИЙ МИР', size=11.5, weight='bold', fill=C['faint'])
d.rect(46, 130, 218, 76, fill=C['blue_bg'], stroke=C['blue'])
d.lines(60, 154, [bold('Сотрудники', 14), 'OpenVPN-клиент', 'Linux · macOS · Windows'], 18)
d.rect(46, 232, 218, 76, fill=C['orange_bg'], stroke=C['orange'])
d.lines(60, 256, [bold('Администратор', 14), 'SSH только с ADMIN_CIDR', 'yc CLI · скрипты · пакеты'], 18)
d.rect(46, 510, 218, 64, fill=C['grey_bg'], stroke=C['line'])
d.lines(60, 534, [bold('Почтовый сервер', 13.5), 'smtp.yandex.ru:587, TLS'], 18)

# VPC и подсети
d.rect(300, 90, 870, 510, fill='#ffffff', stroke='#9aa5b1', dash=True)
d.text(316, 114, 'VPC infra-net', size=12, weight='bold', fill=C['faint'])
d.rect(316, 124, 574, 462, fill='#ffffff', stroke=C['line'], dash=True)
d.text(332, 146, 'infra-subnet-a · ru-central1-a · 10.128.0.0/24', size=11.5, weight='bold', fill=C['faint'])

d.rect(332, 158, 530, 122, fill=C['green_bg'], stroke=C['green'])
d.lines(348, 182, [bold('vpn-server'),
                   '10.128.0.11 · публичный 111.88.249.0 (статический)',
                   'OpenVPN 1194/udp · туннель 10.8.0.0/24 · NAT',
                   'tls-crypt · AES-256-GCM · проверка списка отзыва',
                   tag('node-exporter :9100 + метрики OpenVPN', C['green'])])
d.rect(332, 292, 530, 122, fill=C['red_bg'], stroke=C['red'])
d.lines(348, 316, [bold('ca-server'),
                   '10.128.0.10 · публичный 46.21.247.189 (статический)',
                   'Easy-RSA · PKI в /var/lib/infra-ca, права 0700',
                   'сетевых служб нет, кроме SSH',
                   tag('node-exporter :9100 + сроки сертификатов', C['red'])])
d.rect(332, 426, 530, 146, fill=C['violet_bg'], stroke=C['violet'])
d.lines(348, 450, [bold('mon-server'),
                   '10.128.0.12 · публичный 46.21.244.236 (эфемерный)',
                   'nginx 10.128.0.12:9090 и :9093 — вход по паролю',
                   'Prometheus 127.0.0.1:9090 · Alertmanager 127.0.0.1:9093',
                   '22 правила алертов · оповещения на почту',
                   tag('node-exporter :9100', C['violet'])])

d.rect(904, 124, 250, 300, fill='#ffffff', stroke=C['line'], dash=True)
d.text(920, 146, 'infra-subnet-b', size=11.5, weight='bold', fill=C['faint'])
d.text(920, 163, 'ru-central1-b · 10.129.0.0/24', size=11.5, weight='bold', fill=C['faint'])
d.rect(920, 178, 218, 160, fill=C['gold_bg'], stroke=C['gold'])
d.lines(934, 202, [bold('backup-server'), '10.129.0.10',
                   'публичного адреса нет', 'копии в /srv/backups',
                   'пользователь infra-backup', tag('node-exporter :9100', C['gold'])])

d.rect(904, 440, 250, 146, fill=C['grey_bg'], stroke='#9aa5b1', dash=True)
d.text(920, 462, 'СЕРВИСЫ ОБЛАКА, ВНЕ VPC', size=11, weight='bold', fill=C['faint'])
d.lines(920, 488, [bold('Снимки дисков', 13.5), 'расписание infra-daily',
                   'диски ca-server и vpn-server'], 18)
d.lines(920, 552, [('Object Storage', dict(size=13, weight='bold', fill=C['faint'])),
                   ('подготовлено, не включено', dict(size=11.5, fill=C['faint']))], 18)

# Связи
d.arrow([(264, 168), (330, 200)], C['green'], sw=2.6)
d.text(270, 166, '1194/udp', size=11.5, weight='bold', fill=C['green'])
d.arrow([(264, 272), (298, 272), (298, 350), (330, 350)], C['orange'], dash=True)
d.text(250, 330, 'SSH 22', size=11.5, weight='bold', fill=C['orange'], anchor='end')
d.arrow([(332, 548), (266, 548)], C['violet'])
d.text(299, 540, '587', size=11.5, weight='bold', fill=C['violet'], anchor='middle')
# шина опроса метрик
d.add(f'<path d="M 876 500 L 876 212" fill="none" stroke="{C["violet"]}" stroke-width="2" stroke-dasharray="3 3"/>')
d.arrow([(876, 500), (864, 500)], C['violet'], sw=2)
d.arrow([(876, 219), (864, 219)], C['violet'], sw=2)
d.arrow([(876, 352), (864, 352)], C['violet'], sw=2)
d.arrow([(876, 316), (918, 316)], C['violet'], sw=2)
# копии
d.arrow([(862, 250), (918, 250)], C['gold'], sw=2.4)
d.arrow([(862, 400), (890, 400), (890, 284), (918, 284)], C['gold'], sw=2.4)

# Легенда
d.rect(30, 620, 1140, 190, fill='#fbfbfc', stroke=C['line'])
d.text(46, 646, 'Принципы разграничения доступа', size=14, weight='bold')
leg = [
    (C['green'],  '1194/udp — единственный порт, открытый всему интернету. Пакет без общего ключа tls-crypt отбрасывается до начала переговоров.'),
    (C['orange'], 'SSH 22 — только с адреса администратора. backup-server публичного адреса не имеет и доступен только изнутри сети, через VPN.'),
    (C['violet'], 'Метрики: порт 9100 открыт только для 10.128.0.12. Метрики OpenVPN, сертификатов и бэкапов идут через тот же порт.'),
    (C['gold'],   'Копии шифруются GPG AES-256 до отправки, целостность сверяется SHA-256 на приёмной стороне. Копии — в другой геозоне.'),
    (C['red'],    'Удостоверяющий центр не обслуживает сетевых запросов. Приватные ключи сотрудников на него не попадают — подписывается только CSR.'),
]
for i, (col, txt) in enumerate(leg):
    y = 674 + i * 24
    d.add(f'<circle cx="54" cy="{y - 4}" r="5" fill="{col}"/>')
    d.text(68, y, txt, size=12)
d.text(68, 798, 'Два рубежа обороны заданы независимо: группы безопасности облака и firewalld в каждой ОС.',
       size=11.5, fill=C['faint'])
d.render(os.path.join(OUT, 'infrastructure.svg'), os.path.join(OUT, 'infrastructure.png'))

# ======================================================================
# 2. СХЕМА ПОТОКОВ ДАННЫХ
# ======================================================================
f = SVG(1200, 1010)
f.text(30, 42, 'Схема потоков данных', size=22, weight='bold')
f.text(30, 66, 'Кто с кем общается, по каким портам и что передаётся', fill=C['muted'])

def panel(x, y, w, h, title):
    f.rect(x, y, w, h, fill='#fbfbfc', stroke=C['line'])
    f.text(x + 16, y + 26, title, size=14.5, weight='bold')

# Поток 1
panel(30, 86, 1140, 230, 'Поток 1. Выдача доступа сотруднику')
boxes = [(50, 'Сотрудник', 'gen-client-request.sh', 'создаёт ключ и CSR', C['blue'], C['blue_bg']),
         (330, 'Администратор', 'issue-client-cert.sh', 'сверяет отпечаток', C['orange'], C['orange_bg']),
         (610, 'ca-server', 'infra-ca-sign client', 'подписывает CSR', C['red'], C['red_bg']),
         (890, 'vpn-server', 'infra-vpn-make-client', 'собирает комплект', C['green'], C['green_bg'])]
for x, t, a, b, s, bg in boxes:
    f.rect(x, 128, 240, 78, fill=bg, stroke=s)
    f.lines(x + 14, 152, [bold(t, 13.5), a, b], 19)
for x1, lab in [(290, '.req'), (570, 'scp 22'), (850, '.crt')]:
    f.arrow([(x1, 167), (x1 + 38, 167)], C['muted'])
    f.text(x1 + 19, 158, lab, size=11, fill=C['muted'], anchor='middle')
f.arrow([(1010, 206), (1010, 234), (170, 234), (170, 210)], C['muted'], dash=True)
f.text(590, 252, 'комплект .tar.gz: ca.crt + сертификат + ta.key + шаблон; assemble-config.sh собирает .ovpn у сотрудника',
       size=11.5, fill=C['muted'], anchor='middle')
f.rect(50, 266, 1100, 36, fill=C['gold_bg'], stroke=C['gold'], rx=6)
f.text(66, 289, 'Приватный ключ сотрудника не пересекает ни одну стрелку: он создаётся на его машине и остаётся там.', size=12.5)

# Поток 2
panel(30, 330, 1140, 170, 'Поток 2. Рабочий трафик сотрудника')
for x, t, a, s, bg in [(50, 'Ноутбук', 'tun0 · 10.8.0.x', C['blue'], C['blue_bg']),
                       (430, 'vpn-server', '10.8.0.1 → NAT → 111.88.249.0', C['green'], C['green_bg']),
                       (870, 'Интернет', 'видит адрес 111.88.249.0', '#9aa5b1', C['grey_bg'])]:
    f.rect(x, 372, 280 if x == 430 else 250, 60, fill=bg, stroke=s)
    f.lines(x + 14, 396, [bold(t, 13.5), a], 20)
f.arrow([(300, 402), (428, 402)], C['green'], sw=2.6)
f.text(364, 394, '1194/udp', size=11, weight='bold', fill=C['green'], anchor='middle')
f.arrow([(710, 402), (868, 402)], C['muted'])
f.text(789, 394, 'открытый трафик', size=11, fill=C['muted'], anchor='middle')
f.text(50, 456, 'push redirect-gateway заворачивает в туннель весь трафик; push dhcp-option DNS переводит разрешение имён внутрь туннеля.', size=12)
f.text(50, 478, 'Провайдер сотрудника видит только шифрованный поток к одному адресу — ни содержимого, ни имён сайтов.', size=12, fill=C['muted'])

# Поток 3
panel(30, 514, 560, 230, 'Поток 3. Сбор метрик')
f.rect(50, 556, 190, 58, fill=C['violet_bg'], stroke=C['violet'])
f.lines(64, 580, [bold('Prometheus', 13.5), '127.0.0.1:9090'], 20)
f.rect(330, 552, 240, 66, fill='#ffffff', stroke=C['line'])
f.lines(344, 574, ['ca, vpn, mon, backup', ('node-exporter :9100', dict(size=12.5, weight='bold'))], 22)
f.arrow([(240, 585), (328, 585)], C['violet'])
f.text(284, 577, 'раз в 15 с', size=11, fill=C['violet'], anchor='middle')
f.lines(50, 646, [('Свои метрики — через textfile-коллектор, без лишних портов:', dict(size=12)),
                  'сроки сертификатов и CRL — раз в час',
                  'состояние OpenVPN — раз в 30 секунд',
                  'результат копирования — при каждом запуске'], 21)

# Поток 4
panel(610, 514, 560, 230, 'Поток 4. Оповещения')
f.rect(630, 556, 150, 58, fill=C['violet_bg'], stroke=C['violet'])
f.lines(644, 580, [bold('Prometheus', 13.5), '22 правила'], 20)
f.rect(810, 556, 160, 58, fill=C['violet_bg'], stroke=C['violet'])
f.lines(824, 580, [bold('Alertmanager', 13.5), '127.0.0.1:9093'], 20)
f.rect(1000, 556, 150, 58, fill=C['orange_bg'], stroke=C['orange'])
f.lines(1014, 580, [bold('Почта', 13.5), 'SMTP 587, TLS'], 20)
f.arrow([(780, 585), (808, 585)], C['violet'])
f.arrow([(970, 585), (998, 585)], C['orange'])
f.lines(630, 646, [('Группировка по алерту и машине: падение четырёх', dict(size=12)),
                   'серверов даёт одно письмо, а не четыре.',
                   ('Подавление: при InstanceDown гасятся вторичные', dict(size=12)),
                   'алерты той же машины.'], 21)

# Поток 5
panel(30, 758, 560, 170, 'Поток 5. Веб-доступ к мониторингу')
f.rect(50, 800, 200, 60, fill=C['orange_bg'], stroke=C['orange'])
f.lines(64, 824, [bold('Администратор', 13), 'или клиент VPN'], 20)
f.rect(330, 800, 240, 60, fill=C['violet_bg'], stroke=C['violet'])
f.lines(344, 824, [bold('nginx 10.128.0.12', 13), ':9090 · :9093 · пароль'], 20)
f.arrow([(250, 830), (328, 830)], C['orange'])
f.text(50, 890, 'Пускает только с ADMIN_CIDR и из 10.8.0.0/24.', size=12)
f.text(50, 912, 'Prometheus и Alertmanager слушают лишь 127.0.0.1.', size=12, fill=C['muted'])

# Поток 6
panel(610, 758, 560, 170, 'Поток 6. Резервное копирование')
f.rect(630, 800, 180, 60, fill=C['red_bg'], stroke=C['red'])
f.lines(644, 824, [bold('ca, vpn', 13), 'ежесуточно 03:20'], 20)
f.rect(930, 800, 220, 60, fill=C['gold_bg'], stroke=C['gold'])
f.lines(944, 824, [bold('backup-server', 13), '10.129.0.10 · infra-backup'], 20)
f.arrow([(810, 830), (928, 830)], C['gold'], sw=2.4)
f.text(869, 822, 'SSH 22', size=11, weight='bold', fill=C['gold'], anchor='middle')
f.text(630, 890, 'GPG AES-256 до отправки, сверка SHA-256 после.', size=12)
f.text(630, 912, 'Ключ доступа выделенный; вписывается вручную.', size=12, fill=C['muted'])

# Сводка портов
f.rect(30, 942, 1140, 58, fill=C['grey_bg'], stroke=C['line'])
f.text(46, 964, 'Сводка портов', size=13, weight='bold')
f.text(46, 987, '1194/udp — всем · 22/tcp — ADMIN_CIDR · 9100 — только 10.128.0.12 · 9090, 9093 — ADMIN_CIDR и 10.8.0.0/24 через nginx · 587 — исходящий SMTP',
       size=11.5)
f.render(os.path.join(OUT, 'dataflow.svg'), os.path.join(OUT, 'dataflow.png'))
print('схемы готовы')
