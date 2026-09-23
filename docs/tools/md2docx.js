// Конвертер подмножества markdown в .docx: заголовки, абзацы, списки, таблицы,
// блоки кода, изображения. Таблицы — с шириной в DXA, иначе ломаются в Google Docs.
//
// Использование:
//   node docs/tools/md2docx.js docs/<документ>.md docs/<документ>.docx "<колонтитул>"
// Зависимость: npm install docx
const fs = require('fs');
const path = require('path');
const {
  Document, Packer, Paragraph, TextRun, ExternalHyperlink, Table, TableRow, TableCell,
  ImageRun, Header, Footer, AlignmentType, HeadingLevel, LevelFormat, WidthType,
  BorderStyle, ShadingType, PageNumber,
} = require('docx');

const [, , IN, OUT, RUNNING_TITLE] = process.argv;
const SRC_DIR = path.dirname(IN);
// Склеиваем строки, разорванные жёстким переносом: в markdown это один абзац
// или один пункт списка. Иначе каждая строка стала бы отдельным абзацем.
function normalize(src) {
  const out = [];
  let fence = false;
  const startsBlock = l => /^(#{1,6} |\||```|!\[|---\s*$|\s*- |\d+\. )/.test(l);
  const closed = l => /^(#{1,6} |\||!\[|---\s*$|```)/.test(l);
  for (const l of src) {
    if (l.startsWith('```')) { fence = !fence; out.push(l); continue; }
    if (fence) { out.push(l); continue; }
    const prev = out.length ? out[out.length - 1] : '';
    if (l.trim() && prev.trim() && !closed(prev) && !startsBlock(l)) {
      out[out.length - 1] = prev.replace(/\s+$/, '') + ' ' + l.trim();
    } else out.push(l);
  }
  return out;
}
const lines = normalize(fs.readFileSync(IN, 'utf8').split('\n'));

const FONT = 'Arial';
const MONO = 'Courier New';
const CONTENT_W = 9638;             // A4 минус поля по 2 см, в DXA
const COLORS = { ink: '1F2328', muted: '5B6470', rule: 'C9CED6', head: 'EAF0F6', code: 'F3F4F6', link: '1F5FAE' };

// ---------- строчная разметка: **жирный**, `код`, [текст](ссылка) ----------
function inline(text, base = {}) {
  const out = [];
  const re = /(\*\*[^*]+\*\*|`[^`]+`|\[[^\]]+\]\([^)]+\))/g;
  let last = 0, m;
  while ((m = re.exec(text)) !== null) {
    if (m.index > last) out.push(new TextRun({ text: text.slice(last, m.index), ...base }));
    const tok = m[0];
    if (tok.startsWith('**')) {
      out.push(...inline(tok.slice(2, -2), { ...base, bold: true }));
    } else if (tok.startsWith('`')) {
      out.push(new TextRun({ text: tok.slice(1, -1), font: MONO, size: 19, ...base }));
    } else {
      const lm = tok.match(/^\[([^\]]+)\]\(([^)]+)\)$/);
      out.push(new ExternalHyperlink({ link: lm[2],
        children: [new TextRun({ text: lm[1], style: 'Hyperlink', ...base })] }));
    }
    last = m.index + tok.length;
  }
  if (last < text.length) out.push(new TextRun({ text: text.slice(last), ...base }));
  return out;
}

// ---------- таблица ----------
function table(rows) {
  const PIPE = '\u0000';
  const cells = rows.map(r => r.replace(/\\\|/g, PIPE).trim().replace(/^\||\|$/g, '')
    .split('|').map(c => c.trim().split(PIPE).join('|')));
  const header = cells[0];
  const body = cells.slice(2);                     // вторая строка — разделитель
  const n = header.length;
  // Ширина колонки: не меньше самого длинного неразрывного слова (иначе
  // имена алертов рвутся посередине), остаток — пропорционально объёму текста.
  const rowsForWidth = cells.filter((_, k) => k !== 1);
  const tokenW = t => t.startsWith('`') ? (t.length - 2) * 118 : t.replace(/\*/g, '').length * 100;
  const minW = Array.from({ length: n }, (_, i) => Math.min(4200, 260 + Math.max(...rowsForWidth.map(r =>
    Math.max(0, ...((r[i] || '').match(/`[^`]+`|\S+/g) || ['']).map(tokenW))))));
  const vol = Array.from({ length: n }, (_, i) =>
    Math.max(8, ...rowsForWidth.map(r => (r[i] || '').replace(/[*`]/g, '').length)));
  let widths;
  const spare = CONTENT_W - minW.reduce((a, b) => a + b, 0);
  if (spare >= 0) {
    const tv = vol.reduce((a, b) => a + b, 0);
    widths = minW.map((m, i) => m + Math.floor(spare * vol[i] / tv));
  } else {
    const tm = minW.reduce((a, b) => a + b, 0);
    widths = minW.map(m => Math.floor(m * CONTENT_W / tm));
  }
  widths[widths.indexOf(Math.max(...widths))] += CONTENT_W - widths.reduce((a, b) => a + b, 0);

  const border = { style: BorderStyle.SINGLE, size: 4, color: COLORS.rule };
  const borders = { top: border, bottom: border, left: border, right: border };
  const mkRow = (r, isHead) => new TableRow({
    tableHeader: isHead,
    children: r.map((c, i) => new TableCell({
      width: { size: widths[i], type: WidthType.DXA },
      borders,
      shading: isHead ? { type: ShadingType.CLEAR, fill: COLORS.head, color: 'auto' } : undefined,
      margins: { top: 60, bottom: 60, left: 100, right: 100 },
      children: [new Paragraph({ spacing: { after: 0 },
        children: inline(c, { size: 19, bold: isHead ? true : undefined }) })],
    })),
  });
  return new Table({
    width: { size: CONTENT_W, type: WidthType.DXA },
    columnWidths: widths,
    rows: [mkRow(header, true), ...body.map(r => mkRow(r, false))],
  });
}

// ---------- изображение ----------
function image(file, alt) {
  const buf = fs.readFileSync(path.join(SRC_DIR, file));
  const w = buf.readUInt32BE(16), h = buf.readUInt32BE(20);   // заголовок IHDR в PNG
  const targetW = 640;
  return [
    new Paragraph({ alignment: AlignmentType.CENTER, spacing: { before: 120, after: 60 },
      children: [new ImageRun({ type: 'png', data: buf,
        transformation: { width: targetW, height: Math.round(h * targetW / w) },
        altText: { title: alt, description: alt, name: alt } })] }),
    new Paragraph({ alignment: AlignmentType.CENTER, spacing: { after: 200 },
      children: [new TextRun({ text: alt, italics: true, size: 18, color: COLORS.muted })] }),
  ];
}

// ---------- разбор документа ----------
const children = [];
let title = '';
let listInstance = 0;
let inNumbered = false;

for (let i = 0; i < lines.length; i++) {
  const line = lines[i];

  if (line.startsWith('```')) {                         // блок кода
    const code = [];
    for (i++; i < lines.length && !lines[i].startsWith('```'); i++) code.push(lines[i]);
    code.forEach((c, k) => children.push(new Paragraph({
      shading: { type: ShadingType.CLEAR, fill: COLORS.code, color: 'auto' },
      indent: { left: 200, right: 200 },
      spacing: { before: k === 0 ? 80 : 0, after: k === code.length - 1 ? 160 : 0, line: 260 },
      children: [new TextRun({ text: c.length ? c : ' ', font: MONO, size: 17, color: COLORS.ink })],
    })));
    inNumbered = false;
    continue;
  }
  if (line.startsWith('|')) {                           // таблица
    const rows = [];
    for (; i < lines.length && lines[i].startsWith('|'); i++) rows.push(lines[i]);
    i--;
    children.push(table(rows));
    children.push(new Paragraph({ spacing: { after: 120 }, children: [] }));
    inNumbered = false;
    continue;
  }
  const img = line.match(/^!\[([^\]]*)\]\(([^)]+)\)$/);
  if (img) { children.push(...image(img[2], img[1])); continue; }

  if (line.startsWith('# ')) {
    title = line.slice(2).trim();
    children.push(new Paragraph({ heading: HeadingLevel.TITLE, children: [new TextRun(title)] }));
    continue;
  }
  if (line.startsWith('## ')) {
    children.push(new Paragraph({ heading: HeadingLevel.HEADING_1, children: inline(line.slice(3)) }));
    inNumbered = false; continue;
  }
  if (line.startsWith('### ')) {
    children.push(new Paragraph({ heading: HeadingLevel.HEADING_2, children: inline(line.slice(4)) }));
    inNumbered = false; continue;
  }
  if (line.trim() === '---') {
    children.push(new Paragraph({ spacing: { before: 60, after: 160 },
      border: { bottom: { style: BorderStyle.SINGLE, size: 6, color: COLORS.rule, space: 1 } }, children: [] }));
    continue;
  }
  const sub = line.match(/^\s{2,}- (.*)$/);
  if (sub) {
    children.push(new Paragraph({ numbering: { reference: 'bullets', level: 1 },
      spacing: { after: 60 }, children: inline(sub[1]) }));
    continue;
  }
  if (line.startsWith('- ')) {
    children.push(new Paragraph({ numbering: { reference: 'bullets', level: 0 },
      spacing: { after: 80 }, children: inline(line.slice(2)) }));
    inNumbered = false; continue;
  }
  const num = line.match(/^(\d+)\. (.*)$/);
  if (num) {
    if (num[1] === '1') listInstance++;   // промежуточный код или текст список не рвут
    children.push(new Paragraph({ numbering: { reference: 'numbers', level: 0, instance: listInstance },
      spacing: { after: 80 }, children: inline(num[2]) }));
    continue;
  }
  if (line.trim() === '') {
    // пустая строка внутри нумерованного списка не прерывает его, если дальше пункт
    if (inNumbered && !(lines[i + 1] || '').match(/^\d+\. |^\s{2,}- /)) inNumbered = false;
    continue;
  }
  children.push(new Paragraph({ spacing: { after: 140, line: 300 }, children: inline(line.trim()) }));
  inNumbered = false;
}

// ---------- документ ----------
const doc = new Document({
  creator: 'Infra Team',
  title,
  styles: {
    default: { document: { run: { font: FONT, size: 21, color: COLORS.ink } } },
    paragraphStyles: [
      { id: 'Title', name: 'Title', basedOn: 'Normal', next: 'Normal',
        run: { font: FONT, size: 40, bold: true, color: COLORS.ink },
        paragraph: { spacing: { after: 200 } } },
      { id: 'Heading1', name: 'Heading 1', basedOn: 'Normal', next: 'Normal', quickFormat: true,
        run: { font: FONT, size: 30, bold: true, color: COLORS.ink },
        paragraph: { spacing: { before: 360, after: 160 }, outlineLevel: 0, keepNext: true } },
      { id: 'Heading2', name: 'Heading 2', basedOn: 'Normal', next: 'Normal', quickFormat: true,
        run: { font: FONT, size: 24, bold: true, color: COLORS.ink },
        paragraph: { spacing: { before: 240, after: 120 }, outlineLevel: 1, keepNext: true } },
    ],
    characterStyles: [
      { id: 'Hyperlink', name: 'Hyperlink', run: { color: COLORS.link, underline: {} } },
    ],
  },
  numbering: {
    config: [
      { reference: 'bullets', levels: [
        { level: 0, format: LevelFormat.BULLET, text: '•', alignment: AlignmentType.LEFT,
          style: { paragraph: { indent: { left: 540, hanging: 280 } } } },
        { level: 1, format: LevelFormat.BULLET, text: '–', alignment: AlignmentType.LEFT,
          style: { paragraph: { indent: { left: 1000, hanging: 280 } } } } ] },
      { reference: 'numbers', levels: [
        { level: 0, format: LevelFormat.DECIMAL, text: '%1.', alignment: AlignmentType.LEFT,
          style: { paragraph: { indent: { left: 540, hanging: 320 } } } } ] },
    ],
  },
  sections: [{
    properties: { page: { size: { width: 11906, height: 16838 },
      margin: { top: 1134, bottom: 1134, left: 1134, right: 1134 } } },
    headers: { default: new Header({ children: [new Paragraph({ alignment: AlignmentType.RIGHT,
      children: [new TextRun({ text: RUNNING_TITLE || title, size: 16, color: COLORS.muted })] })] }) },
    footers: { default: new Footer({ children: [new Paragraph({ alignment: AlignmentType.CENTER,
      children: [new TextRun({ children: ['стр. ', PageNumber.CURRENT, ' из ', PageNumber.TOTAL_PAGES],
        size: 16, color: COLORS.muted })] })] }) },
    children,
  }],
});

Packer.toBuffer(doc).then(b => { fs.writeFileSync(OUT, b); console.log('готово:', OUT); });
