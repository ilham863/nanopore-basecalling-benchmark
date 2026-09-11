"""Konverter Markdown -> HTML untuk dokumen formal (A4, siap cetak PDF).

Sengaja dibuat minimal dan tanpa dependensi: hanya menangani subset Markdown
yang dipakai dokumen ini — heading, tabel, daftar, blockquote, code fence,
penekanan inline, dan garis horizontal.
"""
import html
import re
import sys

CSS = """
@page { size: A4; margin: 20mm 18mm 18mm 18mm; }
* { box-sizing: border-box; }
body { font-family: "Segoe UI", Arial, sans-serif; font-size: 10.5pt; line-height: 1.6;
       color: #16202b; margin: 0; }
h1 { font-size: 20pt; margin: 0 0 4mm; color: #0b3d62; line-height: 1.25;
     border-bottom: 2.5pt solid #0b3d62; padding-bottom: 3mm; }
h2 { font-size: 14pt; margin: 10mm 0 3mm; color: #0b3d62;
     border-bottom: 1pt solid #b9c8d4; padding-bottom: 2mm; break-after: avoid; }
h3 { font-size: 11.5pt; margin: 6mm 0 2mm; color: #1b4f72; break-after: avoid; }
h4 { font-size: 10.5pt; margin: 4mm 0 2mm; color: #1b4f72; }
p { margin: 0 0 3mm; text-align: justify; }
strong { color: #0b2030; }
table { width: 100%; border-collapse: collapse; margin: 3mm 0 5mm; font-size: 9.5pt;
        break-inside: avoid; }
th { background: #0b3d62; color: #fff; text-align: left; padding: 2mm 2.5mm; font-weight: 600; }
td { border-bottom: 0.5pt solid #ccd6e0; padding: 2mm 2.5mm; vertical-align: top; }
tr:nth-child(even) td { background: #f4f8fb; }
blockquote { border-left: 3pt solid #b8791a; background: #fdf7ec; margin: 4mm 0;
             padding: 3mm 4mm; break-inside: avoid; }
blockquote p { margin: 0 0 2mm; }
blockquote p:last-child { margin: 0; }
ul, ol { margin: 0 0 3mm; padding-left: 6mm; }
li { margin-bottom: 1.5mm; }
code { font-family: Consolas, monospace; font-size: 9pt; background: #eef2f6;
       padding: 0.4mm 1mm; border-radius: 2px; }
pre { font-family: Consolas, monospace; font-size: 9.5pt; background: #f4f8fb;
      border-left: 3pt solid #0b3d62; padding: 3mm 4mm; margin: 3mm 0 4mm;
      white-space: pre-wrap; break-inside: avoid; }
pre code { background: none; padding: 0; }
hr { border: none; border-top: 0.5pt solid #ccd6e0; margin: 7mm 0; }
"""


def inline(text):
    """Penekanan inline. Escape dulu, baru tanam markup — urutan ini mencegah
    isi dokumen menyuntikkan HTML."""
    out = html.escape(text)
    out = re.sub(r'`([^`]+)`', r'<code>\1</code>', out)
    out = re.sub(r'\*\*([^*]+)\*\*', r'<strong>\1</strong>', out)
    out = re.sub(r'(?<![*\w])\*([^*]+)\*(?![*\w])', r'<em>\1</em>', out)
    return out


def convert(md):
    lines = md.split('\n')
    out = []
    i = 0
    n = len(lines)

    while i < n:
        line = lines[i]
        stripped = line.strip()

        # --- code fence ---
        if stripped.startswith('```'):
            i += 1
            buf = []
            while i < n and not lines[i].strip().startswith('```'):
                buf.append(html.escape(lines[i]))
                i += 1
            i += 1
            out.append('<pre><code>' + '\n'.join(buf) + '</code></pre>')
            continue

        # --- kosong ---
        if not stripped:
            i += 1
            continue

        # --- garis horizontal ---
        if re.fullmatch(r'-{3,}', stripped):
            out.append('<hr>')
            i += 1
            continue

        # --- heading ---
        m = re.match(r'^(#{1,4})\s+(.*)$', stripped)
        if m:
            lvl = len(m.group(1))
            out.append('<h%d>%s</h%d>' % (lvl, inline(m.group(2)), lvl))
            i += 1
            continue

        # --- tabel: baris header diikuti baris pemisah ---
        if stripped.startswith('|') and i + 1 < n and re.match(r'^\s*\|[\s:|-]+\|\s*$', lines[i + 1]):
            def cells(row):
                return [c.strip() for c in row.strip().strip('|').split('|')]

            head = cells(lines[i])
            i += 2
            rows = []
            while i < n and lines[i].strip().startswith('|'):
                rows.append(cells(lines[i]))
                i += 1
            t = ['<table>', '<tr>']
            for c in head:
                t.append('<th>%s</th>' % inline(c))
            t.append('</tr>')
            for r in rows:
                t.append('<tr>')
                for c in r:
                    t.append('<td>%s</td>' % inline(c))
                t.append('</tr>')
            t.append('</table>')
            out.append('\n'.join(t))
            continue

        # --- blockquote ---
        if stripped.startswith('>'):
            buf = []
            while i < n and lines[i].strip().startswith('>'):
                buf.append(lines[i].strip().lstrip('>').strip())
                i += 1
            # baris kosong di dalam kutipan memisahkan paragraf
            paras = '\n'.join(buf).split('\n\n')
            body = ''.join('<p>%s</p>' % inline(' '.join(p.split('\n'))) for p in paras if p.strip())
            out.append('<blockquote>%s</blockquote>' % body)
            continue

        # --- daftar berbutir / bernomor ---
        bullet = re.match(r'^[-*]\s+(.*)$', stripped)
        number = re.match(r'^\d+\.\s+(.*)$', stripped)
        if bullet or number:
            tag = 'ul' if bullet else 'ol'
            pat = r'^[-*]\s+(.*)$' if bullet else r'^\d+\.\s+(.*)$'
            items = []
            while i < n:
                s = lines[i].strip()
                m2 = re.match(pat, s)
                if m2:
                    items.append(m2.group(1))
                    i += 1
                elif s and not re.match(r'^([-*]|\d+\.)\s', s) and lines[i].startswith('  ') and items:
                    items[-1] += ' ' + s          # lanjutan butir yang dilipat
                    i += 1
                else:
                    break
            out.append('<%s>%s</%s>' % (tag, ''.join('<li>%s</li>' % inline(x) for x in items), tag))
            continue

        # --- paragraf ---
        buf = []
        while i < n and lines[i].strip() and not re.match(
                r'^\s*(#{1,4}\s|[-*]\s|\d+\.\s|>|\||```|-{3,}\s*$)', lines[i]):
            buf.append(lines[i].strip())
            i += 1
        if buf:
            out.append('<p>%s</p>' % inline(' '.join(buf)))
        else:
            i += 1

    return '\n'.join(out)


if __name__ == '__main__':
    src, dst = sys.argv[1], sys.argv[2]
    md = io_read = open(src, encoding='utf-8').read()
    title = 'Dokumen'
    m = re.search(r'^#\s+(.*)$', md, re.M)
    if m:
        title = m.group(1)
    body = convert(md)
    page = ('<!doctype html><html lang="id"><head><meta charset="utf-8">'
            '<title>' + html.escape(title) + '</title><style>' + CSS + '</style></head>'
            '<body>' + body + '</body></html>')
    open(dst, 'w', encoding='utf-8').write(page)
    print('OK ->', dst, len(page), 'bytes')
