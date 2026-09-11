# Standarisasi Benchmark Basecalling Nanopore

Paket lengkap standarisasi pengujian hardware untuk operasional basecalling Dorado —
dokumen kebijakan, skrip pengujian otomatis (Windows & Ubuntu), dan prosedur pelaksanaan.

## Dukungan platform

| Platform | Skrip | Shell | Status |
|---|---|---|---|
| **Windows 10/11** | `bin/Basecall.ps1` | Windows PowerShell 5.1 | Diuji |
| **Ubuntu 22.04 / 24.04 LTS** | `bin/basecall.sh` | Bash 4+ | Diuji sebatas logika; lihat catatan di bawah |

Keduanya memakai flag yang sama, menghasilkan berkas yang sama
(`marathon_summary.csv`, `machine_spec.json`, `report*.html`), dan memakai ambang
kelulusan yang sama. **Hasil dari kedua platform dapat disandingkan secara sah.**

| Flag | Windows | Ubuntu |
|---|---|---|
| Bantuan | `-h` | `-h` / `--help` |
| Periksa kondisi diam | `-hw` | `-hw` / `--hardware` |
| Input POD5 | `-i` | `-i` / `--input` |
| Output | `-o` | `-o` / `--output` |
| Durasi hari | `-dd` | `-dd` / `--duration` |
| Recursive | `-r` | `-r` / `--recursive` |
| Batas read | `-mr` | `-mr` / `--max-reads` |
| TB per run virtual | `-vt` | `-vt` / `--virtual-tb` |
| Pasang dorado+model | `-su` | `-su` / `--setup` |
| Vonis kelayakan | `-rep` | `-rep` / `--report` |

Perbedaan yang melekat pada platform:

| Hal | Windows | Ubuntu |
|---|---|---|
| Paket Dorado | `dorado-<ver>-win64.zip` | `dorado-<ver>-linux-x64.tar.gz` |
| Lokasi pasang bawaan | drive paling lega | `/opt` |
| Penahan sleep | `SetThreadExecutionState` | `systemd-inhibit` |
| Pembacaan spesifikasi | WMI/CIM | `/proc`, `lscpu`, `df` |
| Generator laporan | tertanam di skrip | `bin/report.py` |
| Kebutuhan tambahan | — | `python3` (`sudo apt install python3`) |

## Isi paket

| Berkas | Untuk siapa | Isi |
|---|---|---|
| **`Standarisasi-Pengujian-Hardware.pdf`** | **Manajemen** | Dokumen kebijakan: latar belakang, metodologi, kriteria kelulusan |
| `Standarisasi-Pengujian-Hardware.md` | Penyusun | Sumber dokumen di atas, untuk disunting |
| `bin/Basecall.ps1` | Pelaksana (Windows) | Skrip pengujian otomatis |
| `bin/basecall.sh` | Pelaksana (Ubuntu) | Skrip pengujian otomatis |
| `bin/report.py` | Keduanya | Generator vonis + laporan HTML |
| `bin/md2html.py` | Penyusun | Konverter Markdown → HTML untuk regenerasi PDF |
| `docs/README.md` | Pelaksana | Petunjuk pengoperasian skrip |
| `docs/DEPLOY.md` | Pelaksana | Runbook deployment + lembar validasi bertanda tangan |
| `docs/SpesifikasiMarathon.pdf` | Teknis | Dasar penetapan seluruh ambang + rujukan resmi ONT |

## Menjalankan pengujian

**Windows:**

```powershell
cd bin
.\Basecall.ps1 -hw  -i C:\Pod5_passs210Gb -o ..\hasil\bench
.\Basecall.ps1 -su  -i C:\Pod5_passs210Gb -o ..\hasil\smoke      -dd 0
.\Basecall.ps1      -i C:\Pod5_passs210Gb -o ..\hasil\smoke      -dd 0.02 -mr 20000 -r
.\Basecall.ps1      -i C:\Pod5_passs210Gb -o ..\hasil\bench      -dd 0.2  -mr 150000 -r
.\Basecall.ps1      -i C:\Pod5_passs210Gb -o ..\hasil\durability -dd 7 -r -vt 1.3
.\Basecall.ps1      -o ..\hasil\durability -rep
```

**Ubuntu:**

```bash
cd bin
chmod +x basecall.sh
./basecall.sh      -hw -i /data/pod5_210gb -o ../hasil/bench
sudo ./basecall.sh -su -i /data/pod5_210gb -o ../hasil/smoke      -dd 0
./basecall.sh          -i /data/pod5_210gb -o ../hasil/smoke      -dd 0.02 -mr 20000 -r
./basecall.sh          -i /data/pod5_210gb -o ../hasil/bench      -dd 0.2  -mr 150000 -r
./basecall.sh          -i /data/pod5_210gb -o ../hasil/durability -dd 7 -r -vt 1.3
./basecall.sh          -o ../hasil/durability -rep
```

`sudo` hanya diperlukan pada `-su` bila memasang Dorado ke `/opt`. Untuk memasang
tanpa hak akses root, pakai `-sd "$HOME"`.

Untuk maraton 7 hari lewat SSH, jalankan di dalam `tmux` atau `screen` supaya
pengujian tidak ikut mati ketika sesi terputus:

```bash
tmux new -s marathon
./basecall.sh -i /data/pod5_210gb -o ../hasil/durability -dd 7 -r -vt 1.3
# lepas dengan Ctrl+B lalu D; sambung lagi dengan: tmux attach -t marathon
```


## Alur operasional lengkap

Standarisasi ini menempati tahap **kualifikasi**, sebelum mesin dipakai produksi.

```
TAHAP 1  Kualifikasi mesin (sekali per mesin, ~7 hari)
         -hw  → periksa kondisi diam
         -su  → pasang dorado + model
         -dd 0.02  → uji asap
         -dd 0.2 -mr 150000  → Uji A, tetapkan tingkat T1-T4
         -dd 7 -vt 1.3       → Uji B, tetapkan lulus/tidak ketahanan
                    ↓
TAHAP 2  Produksi: MinKNOW sekuensing + live basecalling
         -hw  → jalankan lagi tepat sebelum run, pastikan mesin bersih
                    ↓
TAHAP 3  Tiering berjalan: POD5 yang selesai dibasecall pindah ke HDD,
         BAM tetap ditulis ke NVMe
```

### Tahap 1 — Kualifikasi

Dijalankan sekali per mesin, dan diulang bila ada perubahan besar (ganti GPU, driver,
versi Dorado, atau model). Menghasilkan vonis T1–T4 beserta status ketahanan.

### Tahap 2 — Sebelum setiap run produksi

Jalankan `-hw` sekali lagi. Perintah ini instan dan memeriksa hal-hal yang berubah
dari hari ke hari: suhu diam, beban CPU dan RAM, aplikasi yang merebut GPU, serta
ruang kosong. Mesin yang lulus kualifikasi tetap bisa gagal hari ini karena Chrome
lupa ditutup atau disk hampir penuh.

### Tahap 3 — Tiering POD5 ke HDD saat run berjalan

Selama live basecalling berlangsung, tiga aliran data bekerja bersamaan di NVMe:
MinKNOW menulis POD5 baru, Dorado membaca POD5 tersebut, dan BAM ditulis sebagai
keluaran. POD5 yang **sudah selesai dibasecall** tidak lagi dibutuhkan di NVMe dan
dapat dipindahkan ke HDD tanpa menunggu run selesai. BAM tetap berada di NVMe.

| Data | Media | Alasan |
|---|---|---|
| POD5 yang belum / sedang dibasecall | NVMe | Sedang ditulis dan dibaca bersamaan |
| POD5 yang sudah selesai dibasecall | **HDD** | Arsip: tulis sekali, jarang dibaca |
| BAM keluaran | **NVMe** | Terus ditulis, lalu dipakai analisis hilir |
| Dataset Golden untuk benchmark | **NVMe, selalu** | Di HDD membuat pengukuran tidak sah |

Pola ini tepat: POD5 wajib disimpan untuk reproduksibilitas dan kemungkinan
basecalling ulang dengan model yang lebih baru, tetapi setelah dibasecall pola
aksesnya berubah menjadi *tulis sekali, jarang dibaca* — persis beban kerja yang
cocok untuk HDD, dan jauh lebih murah per terabyte. Menahan POD5 dingin di NVMe
memboroskan tier yang mahal dan langka.

**Empat syarat yang tidak boleh dilanggar:**

1. **Pindahkan hanya berkas yang sudah tuntas dibasecall.** Berkas yang masih dalam
   antrean atau sedang dibaca tidak boleh disentuh. Patokan praktis: pindahkan hanya
   berkas yang tidak sedang dibuka proses mana pun, dan berumur lebih dari satu jam.
2. **Jangan memindahkan dari folder yang sedang dipantau MinKNOW** tanpa memastikan
   MinKNOW telah selesai dengan berkas tersebut — berkas yang hilang dari folder
   pantauan dapat membuat MinKNOW melaporkan galat.
3. **Verifikasi integritas setelah menyalin, sebelum menghapus sumbernya.** POD5
   tidak dapat dibuat ulang; flow cell sudah habis terpakai.
4. **Satu salinan di HDD bukan cadangan.** HDD tunggal tetap satu titik kegagalan.
   Untuk data yang tidak tergantikan, sediakan salinan kedua di media terpisah.

Memeriksa berkas mana yang aman dipindahkan:

```powershell
# Windows - POD5 yang tidak sedang dibuka proses mana pun dan berumur lebih dari 1 jam
Get-ChildItem C:\pod5_run\*.pod5 | Where-Object { $_.LastWriteTime -lt (Get-Date).AddHours(-1) } |
  ForEach-Object {
    try { $fs = [IO.File]::Open($_.FullName,'Open','Read','None'); $fs.Close(); $_ } catch { }
  }
```

```bash
# Linux - lsof menyaring berkas yang masih dibuka proses lain
find /data/pod5_run -name '*.pod5' -mmin +60 |
  while read -r f; do lsof -- "$f" >/dev/null 2>&1 || echo "$f"; done
```

Menyalin dengan verifikasi, lalu menghapus sumbernya:

```powershell
robocopy C:\pod5_run E:\arsip\run_20260911 *.pod5 /MOV /MINAGE:1 /R:2 /W:5 /LOG+:E:\arsip\salin.log
```

```bash
rsync -av --checksum --remove-source-files --files-from=daftar_aman.txt \
      / /mnt/hdd/arsip/run_20260911/
```

`robocopy /MOV` menghapus sumber hanya setelah penyalinan berhasil, dan `/MINAGE:1`
membatasi pada berkas berumur minimal satu hari. `rsync --checksum` memverifikasi isi
berkas, bukan sekadar ukuran dan tanggalnya.

## Memperbarui dokumen PDF

Sunting berkas `.md`, lalu bangun ulang:

```powershell
python .\bin\md2html.py .\Standarisasi-Pengujian-Hardware.md .\Standarisasi-Pengujian-Hardware.html
& "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe" --headless=new --disable-gpu `
  --no-pdf-header-footer --print-to-pdf=".\Standarisasi-Pengujian-Hardware.pdf" `
  ".\Standarisasi-Pengujian-Hardware.html"
```

```bash
python3 bin/md2html.py Standarisasi-Pengujian-Hardware.md Standarisasi-Pengujian-Hardware.html
google-chrome --headless --no-pdf-header-footer \
  --print-to-pdf=Standarisasi-Pengujian-Hardware.pdf Standarisasi-Pengujian-Hardware.html
```

Berkas `.md` adalah sumber kebenaran; `.html` dan `.pdf` merupakan hasil turunan yang
dibangun ulang, bukan disunting langsung.

## Ringkasan kriteria kelulusan

| Kriteria | Ambang |
|---|---|
| Tingkat kemampuan | T1–T4 tercapai |
| **Retensi laju hari-1 vs hari-7** | **≥ 0,90** |
| Ketersediaan putaran | ≥ 0,99 |
| Kegagalan tanpa pemulihan | 0 |
| Kehabisan memori GPU | ≤ 1 |
| Kenaikan suhu maksimum | ≤ +3 °C |
| Konsumsi daya GPU | ≥ 70% TDP |
| Sebaran laju antar-putaran | < 5% |

| Tingkat | Laju minimum | Kesetaraan |
|---|---|---|
| T4 | 57 GB/jam | P2 Solo, 2 flow cell, keluaran maksimum |
| T3 | 37 GB/jam | P2 Solo, 2 flow cell, nominal |
| T2 | 19 GB/jam | P2 Solo, 1 flow cell |
| T1 | 3 GB/jam | MinION Mk1B, 1 flow cell |

## Catatan pengujian skrip Ubuntu

Logika `basecall.sh` diuji dengan Dorado tiruan: parsing argumen, deteksi Dorado,
guardrail otomatis, loop maraton, penegakan batas durasi, penghapusan BAM, penulisan
`marathon_summary.csv` dengan skema identik, dan pembuatan `machine_spec.json` yang
valid. `report.py` diuji terhadap data 7 hari dan menghasilkan vonis yang identik
dengan versi PowerShell.

Yang **belum** dapat diverifikasi karena tidak tersedia di lingkungan pengembangan:
jalur unduhan Dorado untuk Linux, pembacaan metrik GPU melalui `nvidia-smi`, dan
penandaan peran drive pada `machine_spec.json`. Jalankan uji asap (`-dd 0.02`) pada
mesin Ubuntu sasaran sebelum memulai maraton 7 hari.
