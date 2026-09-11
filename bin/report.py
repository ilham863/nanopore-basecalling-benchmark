#!/usr/bin/env python3
"""Generator laporan kelayakan basecalling — lintas platform (Windows & Linux).

Membaca marathon_summary.csv (+ machine_spec.json bila ada) lalu menghasilkan:
  - vonis kelayakan ke konsol
  - report.html            (indeks: vonis + spesifikasi + tabel per hari)
  - report_<tanggal>.html  (satu per hari)
  - report_final.html      (salinan beku, bila dijalankan dengan --final)

Ambang yang dipakai identik dengan Basecall.ps1 supaya hasil dari mesin Windows
dan Linux dapat disandingkan secara sah.

Pemakaian:
    python3 report.py <folder-hasil> [--final] [--model NAMA] [--device DEV]
"""
import csv
import datetime as dt
import html
import json
import os
import statistics
import sys

# Ambang laju tiap tingkat, dalam GB POD5-setara per jam.
# Diturunkan dari POD5 target dibagi durasi run standar 72 jam.
TIERS = [
    ('T4', 57, 'P2 Solo, 2 flow cell, keluaran maksimum (TMO)'),
    ('T3', 37, 'P2 Solo, 2 flow cell, keluaran nominal'),
    ('T2', 19, 'P2 Solo, 1 flow cell'),
    ('T1', 3,  'MinION Mk1B, 1 flow cell'),
]

AMBANG_RETENSI = 0.90
AMBANG_AVAIL = 0.99
AMBANG_OOM = 1
AMBANG_SUHU_NAIK = 3
AMBANG_DAYA_PCT = 70
AMBANG_CLOCK_PCT = 90
AMBANG_SEBARAN_PCT = 5

BULAN = ['Januari', 'Februari', 'Maret', 'April', 'Mei', 'Juni',
         'Juli', 'Agustus', 'September', 'Oktober', 'November', 'Desember']


# ---------------------------------------------------------------- util

def angka(v):
    """Ambil nilai numerik, atau None kalau selnya kosong/bukan angka."""
    try:
        s = str(v).strip()
        if not s:
            return None
        return float(s)
    except (TypeError, ValueError):
        return None


def waktu(v):
    try:
        return dt.datetime.strptime(str(v).strip(), '%Y-%m-%d %H:%M:%S')
    except (TypeError, ValueError):
        return None


def laju(row):
    """Laju POD5-setara per jam untuk satu baris ringkasan."""
    secs = angka(row.get('seconds'))
    equiv = angka(row.get('pod5_equiv_gb'))
    if not secs or secs <= 0 or equiv is None:
        return None
    return equiv / (secs / 3600.0)


def tingkat(rate):
    for nama, ambang, _ in TIERS:
        if rate >= ambang:
            return nama
    return '-'


def desc_tier(nama):
    for n, _, d in TIERS:
        if n == nama:
            return d
    return ''


def median(vals):
    vals = [v for v in vals if v is not None]
    return statistics.median(vals) if vals else None


def tgl_indo(key):
    d = dt.datetime.strptime(key, '%Y%m%d')
    return '%d %s %d' % (d.day, BULAN[d.month - 1], d.year)


# ---------------------------------------------------------------- statistik

def stats(rows):
    rows = list(rows)
    ok = [r for r in rows if r.get('status') == 'OK']
    rates = [laju(r) for r in ok]
    rates = [r for r in rates if r is not None]

    def kolom(nama):
        return [v for v in (angka(r.get(nama)) for r in ok) if v is not None]

    equiv = kolom('pod5_equiv_gb')
    temps = kolom('gpu_max_temp_c')
    pows = kolom('gpu_avg_power_w')
    clks = kolom('gpu_avg_clock_mhz')

    med = median(rates)
    return {
        'total': len(rows),
        'ok': len(ok),
        'fail': len([r for r in rows if r.get('status') == 'FAIL']),
        'oom': len([r for r in rows if r.get('status') == 'OOM']),
        'med': round(med, 1) if med else 0.0,
        'min': round(min(rates), 1) if rates else 0.0,
        'max': round(max(rates), 1) if rates else 0.0,
        'equiv': round(sum(equiv), 1) if equiv else 0.0,
        'suhu': int(max(temps)) if temps else None,
        'daya': round(sum(pows) / len(pows)) if pows else None,
        'clock': round(sum(clks) / len(clks)) if clks else None,
    }


def vonis(rows, harian):
    """Vonis kelayakan: tingkat kemampuan + lolos/tidaknya kriteria ketahanan."""
    rows = list(rows)
    ok = [r for r in rows if r.get('status') == 'OK']
    bench = ok[1:]                       # loop pertama selalu dibuang
    rates = [r for r in (laju(x) for x in bench) if r is not None]
    med = median(rates)
    med = round(med, 1) if med else 0.0

    catatan = []
    dur_ok = True

    # Hari parsial di ujung hanya berisi beberapa loop dan angkanya tidak stabil,
    # jadi dibuang dari pembandingan retensi.
    hari = [h for h in harian if h['stat']['ok'] >= 3] or list(harian)
    ret = None
    if len(hari) >= 2 and hari[0]['stat']['med'] > 0:
        ret = round(hari[-1]['stat']['med'] / hari[0]['stat']['med'], 3)
        if ret < AMBANG_RETENSI:
            dur_ok = False
            catatan.append('Retensi laju %s, di bawah syarat %.2f - laju hari terakhir '
                           'tinggal %d%% dari hari pertama.'
                           % (ret, AMBANG_RETENSI, round(ret * 100)))

    avail = round(len(ok) / len(rows), 3) if rows else 0.0
    if avail < AMBANG_AVAIL:
        dur_ok = False
        catatan.append('Ketersediaan %s, di bawah syarat %.2f.' % (avail, AMBANG_AVAIL))

    gagal = len([r for r in rows if r.get('status') == 'FAIL'])
    if gagal:
        dur_ok = False
        catatan.append('%d loop gagal tanpa pemulihan.' % gagal)

    oom = len([r for r in rows if r.get('status') == 'OOM'])
    if oom > AMBANG_OOM:
        dur_ok = False
        catatan.append('%d kali kehabisan VRAM, syarat maksimal %d kali.' % (oom, AMBANG_OOM))

    return {'med': med, 'tier': tingkat(med), 'dur_ok': dur_ok,
            'catatan': catatan, 'ret': ret, 'avail': avail, 'fail': gagal, 'oom': oom}


# ---------------------------------------------------------------- konsol

def cetak_konsol(rows, harian, spec):
    v = vonis(rows, harian)
    ok = [r for r in rows if r.get('status') == 'OK']
    bench = ok[1:]
    rates = [r for r in (laju(x) for x in bench) if r is not None]

    sebaran = 0.0
    if len(rates) > 1 and v['med'] > 0:
        sebaran = round(((max(rates) - min(rates)) / v['med']) * 100, 1)

    t0, t1 = waktu(rows[0].get('start')), waktu(rows[-1].get('end'))
    jam = round((t1 - t0).total_seconds() / 3600, 1) if t0 and t1 else 0

    print()
    print('  LAPORAN KELAYAKAN BASECALLING')
    print()
    print('  CAKUPAN')
    print('    %-22s%s' % ('Total loop', len(rows)))
    print('    %-22s%s' % ('Loop sukses', len(ok)))
    print('    %-22s%s jam' % ('Durasi', jam))
    print('    %-22s%s TB POD5-setara' % ('Data diproses', rows[-1].get('cum_tb', '-')))
    print()
    print('  UJI A - KEMAMPUAN')
    print('    %-22s%s GB POD5/jam  (median %d loop, loop pertama dibuang)'
          % ('Laju terukur', v['med'], len(bench)))
    print('    %-22s%s%%' % ('Sebaran antar-loop', sebaran))
    print()
    for nama, ambang, desc in TIERS:
        tanda = '[LULUS]' if v['med'] >= ambang else '[  -  ]'
        print('    %s %-4s%5d GB/jam   %s' % (tanda, nama, ambang, desc))
    print()

    # ---- keabsahan ----
    print('  KEABSAHAN PENGUKURAN')
    masalah = []
    daya = [x for x in (angka(r.get('gpu_avg_power_w')) for r in bench) if x is not None]
    clk = [x for x in (angka(r.get('gpu_avg_clock_mhz')) for r in bench) if x is not None]
    lim_daya = lim_clk = None
    if spec:
        gpus = spec.get('GPU') or []
        if gpus:
            lim_daya = angka(str(gpus[0].get('TDP', '')).replace('W', ''))
            lim_clk = angka(str(gpus[0].get('Clock', '')).replace('MHz', ''))

    if daya and lim_daya:
        pct = round(sum(daya) / len(daya) / lim_daya * 100)
        baik = pct >= AMBANG_DAYA_PCT
        if not baik:
            masalah.append('daya hanya %d%% TDP - GPU kemungkinan menunggu data' % pct)
        print('    %s %-20s%d W dari %d W (%d%% TDP, syarat >= %d%%)'
              % ('[OK]' if baik else '[!!]', 'Daya rata-rata',
                 round(sum(daya) / len(daya)), lim_daya, pct, AMBANG_DAYA_PCT))
    elif daya:
        print('    [??] %-20s%d W (TDP tidak terbaca)'
              % ('Daya rata-rata', round(sum(daya) / len(daya))))
    else:
        print('    [??] %-20stidak terekam' % 'Daya rata-rata')

    if clk and lim_clk:
        pct = round(sum(clk) / len(clk) / lim_clk * 100)
        baik = pct >= AMBANG_CLOCK_PCT
        if not baik:
            masalah.append('clock SM hanya %d%% dari maksimum' % pct)
        print('    %s %-20s%d MHz dari %d MHz (%d%%, syarat >= %d%%)'
              % ('[OK]' if baik else '[!!]', 'Clock SM rata-rata',
                 round(sum(clk) / len(clk)), lim_clk, pct, AMBANG_CLOCK_PCT))

    baik = sebaran < AMBANG_SEBARAN_PCT
    if not baik:
        masalah.append('sebaran antar-loop %s%% melebihi %d%%' % (sebaran, AMBANG_SEBARAN_PCT))
    print('    %s %-20s%s%% (syarat < %d%%)'
          % ('[OK]' if baik else '[!!]', 'Sebaran laju', sebaran, AMBANG_SEBARAN_PCT))
    print()

    # ---- ketahanan ----
    print('  UJI B - KETAHANAN')
    if v['ret'] is not None:
        baik = v['ret'] >= AMBANG_RETENSI
        print('    %s %-22s%s  (syarat >= %.2f)'
              % ('[OK]' if baik else '[!!]', 'Retensi laju', v['ret'], AMBANG_RETENSI))
    else:
        print('    [??] %-22sdata belum cukup' % 'Retensi laju')

    print('    %s %-22s%s  (%d OK dari %d loop, syarat >= %.2f)'
          % ('[OK]' if v['avail'] >= AMBANG_AVAIL else '[!!]', 'Ketersediaan',
             v['avail'], len(ok), len(rows), AMBANG_AVAIL))
    print('    %s %-22s%d  (syarat 0)'
          % ('[OK]' if v['fail'] == 0 else '[!!]', 'Gagal tak pulih', v['fail']))
    print('    %s %-22s%d  (syarat <= %d)'
          % ('[OK]' if v['oom'] <= AMBANG_OOM else '[!!]', 'Kehabisan VRAM', v['oom'], AMBANG_OOM))

    if len(harian) >= 2:
        s0, s1 = harian[0]['stat']['suhu'], harian[-1]['stat']['suhu']
        if s0 is not None and s1 is not None:
            naik = s1 - s0
            print('    %s %-22s%+d C  (syarat <= +%d C)'
                  % ('[OK]' if naik <= AMBANG_SUHU_NAIK else '[!!]',
                     'Kenaikan suhu', naik, AMBANG_SUHU_NAIK))
    print()

    # ---- vonis ----
    print('  VONIS')
    if v['tier'] == '-':
        print('    Laju %s GB/jam di bawah T1 - tidak memadai untuk basecalling real-time.' % v['med'])
        print('    Masih layak dipakai untuk basecalling offline setelah run selesai.')
    else:
        print('    Tingkat tercapai : %s - %s' % (v['tier'], desc_tier(v['tier'])))
        if v['dur_ok']:
            print('    Ketahanan        : LULUS - sanggup dipakai berkelanjutan pada tingkat %s.' % v['tier'])
        else:
            print('    Ketahanan        : TIDAK LULUS - hanya layak untuk basecalling offline.')
            for c in v['catatan']:
                print('                       - %s' % c)
    if masalah:
        print()
        print('    Peringatan keabsahan - angka di atas belum tentu menggambarkan GPU:')
        for m in masalah:
            print('      - %s' % m)
    print()
    return v


# ---------------------------------------------------------------- HTML

CSS = """<style>
body{font-family:"Segoe UI",Arial,sans-serif;font-size:14px;line-height:1.5;color:#16202b;
     background:#f7f9fb;margin:0;padding:24px}
.wrap{max-width:1100px;margin:0 auto}
h1{font-size:22px;margin:0 0 4px;color:#0b3d62}
h2{font-size:16px;margin:28px 0 10px;color:#0b3d62;border-bottom:2px solid #0b3d62;padding-bottom:5px}
.sub{color:#5a6a78;font-size:13px;margin-bottom:20px}
.cards{display:flex;flex-wrap:wrap;gap:12px;margin-bottom:8px}
.card{background:#fff;border:1px solid #dbe3ea;border-radius:6px;padding:12px 16px;min-width:150px;flex:1}
.card .k{font-size:11px;color:#5a6a78;text-transform:uppercase;letter-spacing:.4px}
.card .v{font-size:20px;font-weight:600;color:#0b3d62;margin-top:2px}
.card .n{font-size:11px;color:#7a8894;margin-top:2px}
table{width:100%;border-collapse:collapse;background:#fff;border:1px solid #dbe3ea;
      border-radius:6px;overflow:hidden;font-size:13px}
th{background:#0b3d62;color:#fff;text-align:left;padding:8px 10px;font-weight:600;white-space:nowrap}
td{border-bottom:1px solid #e6ecf1;padding:7px 10px;white-space:nowrap}
tr:last-child td{border-bottom:none}
tr:nth-child(even) td{background:#f7fafc}
td.n,th.n{text-align:right}
.ok{color:#1e7a46;font-weight:600}
.fail{color:#b02a37;font-weight:600}
.oom{color:#b8791a;font-weight:600}
.note{background:#fff;border-left:4px solid #0b3d62;padding:10px 14px;margin:14px 0;border-radius:0 6px 6px 0}
.warn{border-left-color:#b8791a;background:#fdf9f2}
.bad{border-left-color:#b02a37;background:#fdf4f5}
.good{border-left-color:#1e7a46;background:#f2faf5}
a{color:#0b3d62}
.foot{margin-top:28px;padding-top:12px;border-top:1px solid #dbe3ea;font-size:12px;color:#5a6a78}
@media(max-width:700px){td,th{white-space:normal}}
</style>"""


def e(v):
    return html.escape('' if v is None else str(v))


def kartu(k, v, n=''):
    return ('<div class="card"><div class="k">%s</div><div class="v">%s</div>'
            '<div class="n">%s</div></div>' % (e(k), e(v), n))


def spec_html(spec):
    if not spec:
        return ''
    out = ['<h2>Spesifikasi mesin uji</h2><table>',
           '<tr><th style="width:170px">Komponen</th><th>Keterangan</th></tr>']
    baris = [('Host', spec.get('Host')), ('Mesin', spec.get('Mesin')),
             ('Platform', spec.get('Platform')), ('Sistem operasi', spec.get('OS')),
             ('CPU', '%s · %s' % (spec.get('CPU', ''), spec.get('CpuCore', ''))),
             ('RAM', spec.get('RAM'))]
    for k, v in baris:
        if v and str(v).strip() not in ('', '·'):
            out.append('<tr><td><b>%s</b></td><td>%s</td></tr>' % (e(k), e(v)))
    out.append('</table>')

    gpus = spec.get('GPU') or []
    if gpus:
        out.append('<h2>GPU</h2><table><tr><th>Kartu</th><th class="n">VRAM</th>'
                   '<th class="n">TDP</th><th class="n">Clock maks</th><th>Driver</th></tr>')
        for g in gpus:
            out.append('<tr><td>%s</td><td class="n">%s</td><td class="n">%s</td>'
                       '<td class="n">%s</td><td>%s</td></tr>'
                       % (e(g.get('Nama')), e(g.get('VRAM')), e(g.get('TDP')),
                          e(g.get('Clock')), e(g.get('Driver'))))
        out.append('</table>')

    disks = spec.get('Disk') or []
    if disks:
        out.append('<h2>Penyimpanan</h2><table><tr><th>Drive</th><th>Label</th><th>FS</th>'
                   '<th class="n">Kapasitas</th><th class="n">Bebas</th>'
                   '<th class="n">Terpakai</th><th>Peran</th></tr>')
        for d in disks:
            hl = ' style="background:#eef6fb"' if d.get('Peran') else ''
            out.append('<tr%s><td><b>%s</b></td><td>%s</td><td>%s</td><td class="n">%s</td>'
                       '<td class="n">%s</td><td class="n">%s</td><td>%s</td></tr>'
                       % (hl, e(d.get('Drive')), e(d.get('Label')), e(d.get('FS')),
                          e(d.get('Total')), e(d.get('Bebas')), e(d.get('Pakai')),
                          e(d.get('Peran'))))
        out.append('</table>')

    out.append('<h2>Konfigurasi basecalling</h2><table>'
               '<tr><th style="width:170px">Item</th><th>Nilai</th></tr>')
    cfg = [('Model', spec.get('Model')), ('Dorado', spec.get('Dorado')),
           ('Versi dorado', spec.get('DoradoVer')), ('Cache model', spec.get('ModelCache')),
           ('Device', spec.get('Device')), ('Folder POD5', spec.get('Pod5Dir')),
           ('Dataset', '%s berkas · %s' % (spec.get('Pod5Berkas', '?'), spec.get('Pod5Ukuran', '?'))
            if spec.get('Pod5Berkas') else None),
           ('Direkam', spec.get('Waktu'))]
    for k, v in cfg:
        if v and str(v).strip():
            out.append('<tr><td><b>%s</b></td><td>%s</td></tr>' % (e(k), e(v)))
    out.append('</table>')
    return '\n'.join(out)


def tulis_harian(outdir, harian, meta, gen):
    for idx, h in enumerate(harian):
        st = h['stat']
        p = ['<!doctype html><html lang="id"><head><meta charset="utf-8">',
             '<title>Laporan Harian %s</title>' % e(h['tgl']),
             '<meta name="viewport" content="width=device-width,initial-scale=1">',
             CSS, '</head><body><div class="wrap">',
             '<h1>Laporan Marathon Basecalling &mdash; Hari ke-%d</h1>' % (idx + 1),
             '<div class="sub">%s &middot; %s</div>' % (e(h['tgl']), meta),
             '<div class="cards">',
             kartu('Laju median', st['med'], 'GB POD5/jam'),
             kartu('Tingkat', tingkat(st['med']), 'berdasar laju hari ini'),
             kartu('Data diproses', st['equiv'], 'GB POD5-setara'),
             kartu('Loop', '%d/%d' % (st['ok'], st['total']), 'sukses / total')]
        if h['ret'] is not None:
            p.append(kartu('Retensi', h['ret'], 'vs hari pertama'))
        if st['suhu'] is not None:
            p.append(kartu('Suhu maks', st['suhu'], '&deg;C'))
        p.append('</div>')

        if h['ret'] is not None and h['ret'] < AMBANG_RETENSI:
            p.append('<div class="note bad"><b>Retensi di bawah ambang.</b> Laju hari ini '
                     'tinggal %d%% dari hari pertama, sedangkan syarat ketahanan minimal 90%%.'
                     '</div>' % round(h['ret'] * 100))
        if st['fail']:
            p.append('<div class="note bad"><b>%d loop gagal tanpa pemulihan.</b> Periksa '
                     'berkas log dorado pada hari ini.</div>' % st['fail'])
        if st['oom']:
            p.append('<div class="note warn"><b>%d kali kehabisan VRAM.</b> Batch diturunkan '
                     'otomatis; nilai efektifnya pada kolom Batch.</div>' % st['oom'])

        p.append('<h2>Rincian per loop</h2><table><tr><th>Loop</th><th>Mulai</th>'
                 '<th class="n">Durasi</th><th class="n">Batch</th><th class="n">POD5-setara</th>'
                 '<th class="n">Laju</th><th class="n">Suhu</th><th class="n">Daya</th>'
                 '<th class="n">Clock SM</th><th>Status</th></tr>')
        for r in h['rows']:
            rt = laju(r)
            secs = angka(r.get('seconds'))
            w = waktu(r.get('start'))
            cls = {'OK': 'ok', 'OOM': 'oom'}.get(r.get('status'), 'fail')
            p.append('<tr><td>%s</td><td>%s</td><td class="n">%s mnt</td><td class="n">%s</td>'
                     '<td class="n">%s GB</td><td class="n">%s</td><td class="n">%s</td>'
                     '<td class="n">%s</td><td class="n">%s</td><td class="%s">%s</td></tr>'
                     % (e(r.get('loop')), w.strftime('%H:%M:%S') if w else '',
                        round(secs / 60) if secs else '', e(r.get('batchsize')),
                        e(r.get('pod5_equiv_gb')), round(rt, 1) if rt else '',
                        e(r.get('gpu_max_temp_c')), e(r.get('gpu_avg_power_w')),
                        e(r.get('gpu_avg_clock_mhz')), cls, e(r.get('status'))))
        p.append('</table>')
        p.append('<div class="foot">Dibuat %s dari marathon_summary.csv &middot; '
                 '<a href="report.html">Kembali ke indeks</a></div></div></body></html>' % e(gen))

        with open(os.path.join(outdir, 'report_%s.html' % h['key']), 'w', encoding='utf-8') as f:
            f.write('\n'.join(p))


def tulis_indeks(outdir, rows, harian, spec, meta, gen, final):
    v = vonis(rows, harian)
    st = stats(rows)
    p = ['<!doctype html><html lang="id"><head><meta charset="utf-8">',
         '<title>Marathon Basecalling - Ringkasan</title>',
         '<meta name="viewport" content="width=device-width,initial-scale=1">',
         CSS, '</head><body><div class="wrap">',
         '<h1>Marathon Basecalling &mdash; Ringkasan</h1>',
         '<div class="sub">%s &middot; %d hari pengujian</div>' % (meta, len(harian)),
         '<div class="cards">',
         kartu('Laju median', st['med'], 'GB POD5/jam'),
         kartu('Tingkat', tingkat(st['med']), 'keseluruhan'),
         kartu('Total data', round(st['equiv'] / 1024, 2), 'TB POD5-setara'),
         kartu('Loop', '%d/%d' % (st['ok'], st['total']), 'sukses / total'),
         '</div>']

    p.append('<h2>%s</h2>' % ('Vonis akhir' if final else 'Vonis sementara'))
    if v['tier'] == '-':
        p.append('<div class="note bad"><b>Tidak mencapai T1.</b> Laju %s GB POD5/jam berada '
                 'di bawah ambang 3 GB/jam, sehingga mesin ini tidak memadai untuk basecalling '
                 'real-time. Masih layak untuk basecalling offline.</div>' % v['med'])
    else:
        p.append('<div class="note"><b>Tingkat tercapai: %s</b> &mdash; %s.<br>Laju median %s '
                 'GB POD5/jam, dihitung dari loop sukses di luar loop pertama.</div>'
                 % (v['tier'], e(desc_tier(v['tier'])), v['med']))
        if v['dur_ok']:
            p.append('<div class="note good"><b>Ketahanan: LULUS.</b> Seluruh kriteria '
                     'terpenuhi, sehingga mesin ini sanggup dipakai berkelanjutan pada '
                     'tingkat %s.</div>' % v['tier'])
        else:
            li = ''.join('<li>%s</li>' % e(c) for c in v['catatan'])
            p.append('<div class="note bad"><b>Ketahanan: TIDAK LULUS.</b> Mesin mencapai %s '
                     'pada kondisi terbaiknya, namun tidak mempertahankannya. Hanya layak '
                     'untuk basecalling offline.<ul>%s</ul></div>' % (v['tier'], li))
    if not final:
        p.append('<div class="note warn">Marathon masih berjalan. Vonis di atas dihitung dari '
                 'data yang terkumpul sejauh ini dan diperbarui setiap loop selesai.</div>')

    p.append(spec_html(spec))

    p.append('<h2>Per hari</h2><table><tr><th>Hari</th><th>Tanggal</th><th class="n">Loop</th>'
             '<th class="n">Laju median</th><th class="n">Tingkat</th><th class="n">Retensi</th>'
             '<th class="n">Suhu maks</th><th class="n">Data</th><th>Laporan</th></tr>')
    for idx, h in enumerate(harian):
        s = h['stat']
        cls = ' class="fail"' if h['ret'] is not None and h['ret'] < AMBANG_RETENSI else ''
        p.append('<tr><td>%d</td><td>%s</td><td class="n">%d/%d</td><td class="n">%s</td>'
                 '<td class="n">%s</td><td class="n"%s>%s</td><td class="n">%s</td>'
                 '<td class="n">%s GB</td><td><a href="report_%s.html">buka</a></td></tr>'
                 % (idx + 1, e(h['tgl']), s['ok'], s['total'], s['med'], tingkat(s['med']),
                    cls, h['ret'] if h['ret'] is not None else '-',
                    s['suhu'] if s['suhu'] is not None else '-', s['equiv'], h['key']))
    p.append('</table>')
    p.append('<div class="note">Retensi adalah laju median hari tersebut dibagi laju median '
             'hari pertama. Syarat kelulusan ketahanan minimal 0,90 pada hari terakhir.</div>')
    p.append('<div class="foot">Dibuat %s dari marathon_summary.csv</div></div></body></html>' % e(gen))

    isi = '\n'.join(p)
    with open(os.path.join(outdir, 'report.html'), 'w', encoding='utf-8') as f:
        f.write(isi)
    if final:
        with open(os.path.join(outdir, 'report_final.html'), 'w', encoding='utf-8') as f:
            f.write(isi)


# ---------------------------------------------------------------- main

def main():
    args = [a for a in sys.argv[1:]]
    final = '--final' in args
    args = [a for a in args if a != '--final']

    model = device = ''
    sisa = []
    i = 0
    while i < len(args):
        if args[i] == '--model' and i + 1 < len(args):
            model = args[i + 1]; i += 2
        elif args[i] == '--device' and i + 1 < len(args):
            device = args[i + 1]; i += 2
        else:
            sisa.append(args[i]); i += 1

    if not sisa:
        print(__doc__)
        return 1
    outdir = sisa[0]
    csv_path = os.path.join(outdir, 'marathon_summary.csv')

    if not os.path.isfile(csv_path):
        print('[ERROR] Tidak ada %s - jalankan marathon dulu.' % csv_path)
        return 1
    with open(csv_path, newline='', encoding='utf-8-sig') as f:
        rows = [r for r in csv.DictReader(f) if r.get('start')]
    if not rows:
        print('[ERROR] %s kosong.' % csv_path)
        return 1

    ok = [r for r in rows if r.get('status') == 'OK']
    if len(ok) < 2:
        print('  Belum ada loop sukses di luar loop pertama - laporan butuh minimal 2 loop OK.')
        return 1

    spec = None
    spec_path = os.path.join(outdir, 'machine_spec.json')
    if os.path.isfile(spec_path):
        try:
            with open(spec_path, encoding='utf-8-sig') as f:
                spec = json.load(f)
        except (ValueError, OSError):
            spec = None

    if spec:
        model = model or spec.get('Model', '')
        device = device or spec.get('Device', '')

    # Kelompokkan per tanggal kalender.
    urut = []
    grup = {}
    for r in rows:
        w = waktu(r.get('start'))
        if not w:
            continue
        k = w.strftime('%Y%m%d')
        if k not in grup:
            grup[k] = []
            urut.append(k)
        grup[k].append(r)
    urut.sort()

    harian = []
    dasar = None
    for k in urut:
        s = stats(grup[k])
        if dasar is None:
            dasar = s['med']
        ret = round(s['med'] / dasar, 3) if dasar else None
        harian.append({'key': k, 'tgl': tgl_indo(k), 'rows': grup[k], 'stat': s, 'ret': ret})

    v = cetak_konsol(rows, harian, spec)

    gen = dt.datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    meta = 'Model %s &middot; Device %s' % (e(model), e(device))
    tulis_harian(outdir, harian, meta, gen)
    tulis_indeks(outdir, rows, harian, spec, meta, gen, final)
    print('  Laporan HTML : %s' % os.path.join(outdir, 'report.html'))
    print()
    return 0 if v['tier'] != '-' else 0


if __name__ == '__main__':
    sys.exit(main())
