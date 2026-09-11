# Runbook Deployment & Validasi — Marathon Basecalling

Prosedur baku pemasangan dan kualifikasi mesin uji basecalling Nanopore.
Dokumen ini dipakai sekali per mesin, dan diulang bila ada perubahan besar
(ganti GPU, ganti driver, ganti versi Dorado, ganti model).

| | |
|---|---|
| **Sasaran deploy** | Laptop uji, Windows 11, NVMe 1 TB |
| **Perangkat lunak** | `Basecall.ps1` + Dorado 2.1.2 win64 |
| **Keluaran** | Vonis kelayakan T1–T4 + status ketahanan |
| **Total waktu** | ~7 hari 4 jam (setup 1 jam, Uji A 3 jam, Uji B 7 hari) |

---

## 1. Kendali versi

Semua nilai di bawah **dikunci** selama satu siklus validasi. Mengubah salah satunya
membatalkan hasil dan menuntut validasi ulang dari Tahap 4.

| Komponen | Nilai | Dicatat di |
|---|---|---|
| Skrip | `Basecall.ps1`, commit git | `RunningParameter.txt` |
| Dorado | 2.1.2 win64 | `machine_spec.json` → `DoradoVer` |
| Model | `dna_r10.4.1_e8.2_400bps_hac@v5.2.0_5mC_5hmC@v1` | `machine_spec.json` → `Model` |
| Driver NVIDIA | apa adanya saat deploy | `machine_spec.json` → `GPU.Driver` |
| Dataset | 210 GB POD5, N50 23 kb | `machine_spec.json` → `Pod5Berkas`, `Pod5Ukuran` |

Ketiganya terekam otomatis oleh skrip. Tidak ada pencatatan manual.

---

## 2. Tata letak folder

Satu akar kerja, di drive yang sama dengan dataset. Jangan sebar ke beberapa drive —
`machine_spec.json` menandai drive mana yang dipakai, dan hasilnya lebih mudah dibaca
kalau semuanya di satu tempat.

```
C:\Pod5_passs210Gb\            <- dataset 210 GB (sudah ada)

C:\nanopore-bench\
├── bin\
│   └── Basecall.ps1
├── docs\
│   ├── README.md
│   ├── DEPLOY.md
│   └── SpesifikasiMarathon.pdf
└── hasil\
    ├── smoke\
    ├── bench\
    └── durability\
```

Dataset dibiarkan di tempatnya. Beri atribut read-only supaya tidak ada proses
yang mengubahnya selama pengujian:

```powershell
attrib +R C:\Pod5_passs210Gb\*.pod5
```

> **Dataset berada di drive sistem.** Sah selama C: adalah NVMe dan ruangnya cukup,
> tetapi menuntut dua hal: ruang bebas harus tetap di atas ambang otomatis sepanjang
> 7 hari, dan Windows Update ditunda agar tidak menulis besar-besaran ke drive yang
> sama saat pengujian berlangsung. Keduanya sudah jadi butir V-1.4 dan Tahap 2.

---

## 3. Tahapan deploy

### Tahap 1 — Salin berkas

```powershell
New-Item -ItemType Directory -Force C:\nanopore-bench\bin, C:\nanopore-bench\docs,
    C:\nanopore-bench\hasil | Out-Null
Copy-Item .\Basecall.ps1 C:\nanopore-bench\bin\
Copy-Item .\README.md, .\DEPLOY.md, .\SpesifikasiMarathon.pdf C:\nanopore-bench\docs\
```

### Tahap 2 — Siapkan lingkungan Windows

```powershell
Unblock-File C:\nanopore-bench\bin\Basecall.ps1
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

Lalu setel daya dan pembaruan:

| Setelan | Nilai | Cara |
|---|---|---|
| Tutup layar | Do nothing | Control Panel → Power Options → Choose what closing the lid does |
| Sleep saat dicolok | Never | Settings → System → Power |
| Windows Update | Tunda 7 hari | Settings → Windows Update → Pause updates |
| Batas isi baterai | 80% | Aplikasi vendor (MyASUS / Lenovo Vantage / HP) |

Penahan sleep sudah ditangani skrip selama proses berjalan, tapi aksi tutup-layar
hanya bisa diatur dari Windows.

### Tahap 2b — Bila dioperasikan lewat remote (TeamViewer)

TeamViewer **aman** dipakai untuk menjalankan pengujian ini, dan lebih baik daripada
Remote Desktop: TeamViewer menempel pada sesi konsol yang sedang berjalan, sehingga
akses CUDA tetap utuh. Remote Desktop bawaan Windows memutus sesi konsol dan dapat
membuat Dorado kehilangan GPU di tengah jalan — **jangan pakai RDP**.

Yang perlu diperhatikan:

| Hal | Dampak | Tindakan |
|---|---|---|
| TeamViewer memakai GPU untuk menangkap dan meng-encode layar | Menyerobot VRAM dan waktu GPU | **Putuskan koneksi selama Uji A** |
| Browser di mesin uji juga memakai GPU | Sama | Jangan buka `report.html` di mesin uji saat Uji A |
| Sesi terputus | Tidak berpengaruh | Skrip terus jalan; penahan sleep tetap aktif |
| Layar terkunci setelah disconnect | Tidak berpengaruh | Dorado tidak butuh layar aktif |
| TeamViewer restart karena pembaruan | Tidak berpengaruh | Proses PowerShell tidak ikut mati |

**Pola kerja yang benar:**

1. Sambungkan TeamViewer, jalankan perintah Uji A.
2. **Putuskan koneksi TeamViewer.** Biarkan 3 jam.
3. Sambung kembali, jalankan `-rep`, baca hasilnya.

Untuk Uji B selama 7 hari, menyambung sesekali untuk memantau tidak masalah — beban
GPU dari TeamViewer kecil dan hanya berlangsung selama koneksi. Tetapi setiap koneksi
akan terlihat sebagai penurunan kecil pada loop yang sedang berjalan. Bila ingin
memantau tanpa jejak sama sekali, salin `report.html` dan `report_*.html` ke komputer
lain lalu buka di sana — berkasnya berdiri sendiri, tidak butuh apa pun dari mesin uji.

Memastikan tidak ada yang memakai GPU sebelum Uji A:

```powershell
nvidia-smi
```

Bagian **Processes** di bawah harus kosong, atau hanya berisi Dorado. Bila muncul
`TeamViewer`, `msedge`, `chrome`, atau `MinKNOW`, tutup dulu.

Gunakan jendela PowerShell biasa. Proses tetap hidup setelah TeamViewer diputus,
selama jendelanya tidak ditutup.

### Tahap 3 — Pasang Dorado dan model

```powershell
cd C:\nanopore-bench\bin
.\Basecall.ps1 -su -sd C:\ -i C:\Pod5_passs210Gb -o C:\nanopore-bench\hasil\smoke -dd 0
```

Perintah ini memeriksa lebih dulu; unduhan hanya terjadi bila Dorado atau model
belum ada. Tidak ada yang tertimpa.

### Tahap 4 — Validasi instalasi *(gerbang V-1)*

```powershell
.\Basecall.ps1 -h -i C:\Pod5_passs210Gb -o C:\nanopore-bench\hasil\smoke
```

Seluruh baris PRASYARAT harus `[OK]`. Lanjut hanya bila lolos.

### Tahap 5 — Uji fungsional *(gerbang V-2)*

```powershell
.\Basecall.ps1 -i C:\Pod5_passs210Gb -o C:\nanopore-bench\hasil\smoke -dd 0.02 -mr 20000 -r
```

### Tahap 6 — Uji A: kualifikasi kemampuan *(gerbang V-3)*

```powershell
.\Basecall.ps1 -i C:\Pod5_passs210Gb -o C:\nanopore-bench\hasil\bench -dd 0.2 -r -mr 150000
.\Basecall.ps1 -o C:\nanopore-bench\hasil\bench -rep
```

### Tahap 7 — Uji B: kualifikasi ketahanan *(gerbang V-4)*

```powershell
.\Basecall.ps1 -i C:\Pod5_passs210Gb -o C:\nanopore-bench\hasil\durability -dd 7 -r -vt 1.3
```

Jalankan dari jendela PowerShell yang tidak akan ditutup. Laporan diperbarui tiap loop,
jadi pemantauan cukup lewat `hasil\durability\report.html` tanpa menyentuh jendelanya.

---

## 4. Gerbang validasi

Setiap gerbang wajib lolos sebelum tahap berikutnya. Kolom **Hasil** diisi saat
pelaksanaan.

### V-1 — Kesiapan lingkungan

| ID | Kriteria | Ambang | Sumber bukti | Hasil |
|---|---|---|---|---|
| V-1.1 | `dorado.exe` terdeteksi | `[OK]` | keluaran `-h` | ☐ |
| V-1.2 | `nvidia-smi` ada di PATH | `[OK]` | keluaran `-h` | ☐ |
| V-1.3 | Dataset POD5 terbaca | `[OK]`, ±210 GB | keluaran `-h` | ☐ |
| V-1.4 | Ruang drive output | `[OK]`, ≥ ambang otomatis | keluaran `-h` | ☐ |
| V-1.5 | Daya adaptor terhubung | `[OK]` | keluaran `-h` | ☐ |
| V-1.6 | Dataset berada di NVMe, bukan HDD | benar | `machine_spec.json` → `Disk` | ☐ |
| V-1.7 | Ukuran dataset ≥ 2× RAM | ≥ 2× | `machine_spec.json` | ☐ |

> V-1.6 dan V-1.7 tidak dicek otomatis oleh skrip — keduanya diverifikasi manusia dari
> tabel Penyimpanan pada `report.html`. Dataset di HDD atau lebih kecil dari 2× RAM
> membuat seluruh hasil pengukuran tidak sah.

### V-2 — Fungsional

| ID | Kriteria | Ambang | Sumber bukti | Hasil |
|---|---|---|---|---|
| V-2.1 | Loop pertama selesai sukses | `SUKSES Loop ke-1` | konsol | ☐ |
| V-2.2 | Kode keluar Dorado nol | `exitcode = 0` | `marathon_summary.csv` | ☐ |
| V-2.3 | BAM terbentuk lalu terhapus | tidak ada `*.bam` tersisa | isi folder hasil | ☐ |
| V-2.4 | Metrik GPU terekam | suhu/daya/clock terisi | `marathon_summary.csv` | ☐ |
| V-2.5 | Laporan HTML terbentuk | `report.html` ada | folder hasil | ☐ |

### V-3 — Kemampuan (Uji A)

| ID | Kriteria | Ambang | Sumber bukti | Hasil |
|---|---|---|---|---|
| V-3.0 | Tidak ada sesi remote / browser aktif selama uji | terputus | catatan pelaksana | ☐ |
| V-3.1 | Jumlah loop sah | ≥ 4 di luar loop pertama | laporan `-rep` | ☐ |
| V-3.2 | Sebaran laju antar-loop | < 5% | laporan `-rep` | ☐ |
| V-3.3 | Daya GPU rata-rata | ≥ 70% TDP | laporan `-rep` | ☐ |
| V-3.4 | Clock SM rata-rata | ≥ 90% clock maks | laporan `-rep` | ☐ |
| V-3.5 | Tingkat tercapai | T1 / T2 / T3 / T4 | laporan `-rep` | ☐ |

Bila V-3.2 sampai V-3.4 gagal, angka laju **tidak boleh** dipakai sebagai hasil
kualifikasi — yang terukur kemungkinan penyimpanan, bukan GPU. Selesaikan dulu
penyebabnya, lalu ulangi Uji A.

### V-4 — Ketahanan (Uji B)

| ID | Kriteria | Ambang | Sumber bukti | Hasil |
|---|---|---|---|---|
| V-4.1 | Retensi laju | ≥ 0,90 | laporan `-rep` | ☐ |
| V-4.2 | Ketersediaan | ≥ 0,99 | laporan `-rep` | ☐ |
| V-4.3 | Gagal tak pulih | 0 | laporan `-rep` | ☐ |
| V-4.4 | Kehabisan VRAM | ≤ 1 | laporan `-rep` | ☐ |
| V-4.5 | Kenaikan suhu maksimum | ≤ +3 °C | laporan `-rep` | ☐ |
| V-4.6 | Durasi tercapai | ≥ 7 hari, tanpa restart | `report.html` | ☐ |

---

## 5. Keputusan akhir

Mesin dinyatakan **layak pada tingkat X** apabila lolos V-1, V-2, V-3 pada tingkat X,
**dan seluruh** V-4.

| Hasil | Keputusan |
|---|---|
| Lolos V-3 di T2–T4 **dan** seluruh V-4 | Layak sebagai host basecalling real-time pada tingkat itu |
| Lolos V-3 di T1 **dan** seluruh V-4 | Layak untuk MinION Mk1B real-time; P2 Solo hanya offline |
| Lolos V-3, gagal sebagian V-4 | **Hanya** untuk basecalling offline. Tidak untuk run real-time berhari-hari |
| Gagal V-3.2–V-3.4 | Hasil tidak sah. Perbaiki penyebab, ulangi Uji A |

> **Catatan kapasitas penyimpanan, terpisah dari hasil uji.** Laptop dengan NVMe 1 TB
> tidak dapat menampung satu flow cell P2 Solo (1,3 TB nominal, hingga 4,06 TB untuk
> dua flow cell pada keluaran maksimum). Berapa pun tingkat yang dicapai, penggunaan
> sebagai host P2 Solo **mensyaratkan penyimpanan eksternal NVMe** lewat USB4 atau
> Thunderbolt. Keterbatasan ini tidak diuji oleh marathon dan harus dinyatakan
> tersendiri pada laporan akhir.

---

## 6. Arsip bukti

Simpan seluruh isi folder `hasil\` sebagai satu arsip per siklus validasi:

```powershell
$tgl = Get-Date -Format 'yyyyMMdd'
Compress-Archive -Path C:\nanopore-bench\hasil\* `
                 -DestinationPath "C:\nanopore-bench\arsip\validasi_$tgl.zip"
```

| Berkas | Alasan disimpan |
|---|---|
| `machine_spec.json` | Bukti konfigurasi mesin saat diuji |
| `marathon_summary.csv` | Data mentah, dapat dihitung ulang |
| `report_final.html` | Vonis yang dibekukan |
| `report_YYYYMMDD.html` | Jejak degradasi harian |
| `dorado_loop_*.log` | Diagnosa bila ada kegagalan |
| `RunningParameter.txt` | Parameter persis yang dipakai |

Log GPU (`gpu_loop_*.csv`) boleh dibuang setelah arsip dibuat bila ruang terbatas —
ringkasannya sudah masuk ke `marathon_summary.csv`.

---

## 7. Penghentian dan pemulihan

| Situasi | Tindakan |
|---|---|
| Perlu dihentikan | `Ctrl+C`. Proses anak dibersihkan, laporan tetap tersimpan |
| Skrip berhenti sendiri: gagal beruntun | Baca ekor `dorado_loop_*.log`. Umumnya nama model salah atau driver bermasalah |
| Skrip berhenti sendiri: ruang disk | Kosongkan drive, jalankan ulang. Hasil sebelumnya tetap di CSV |
| Listrik padam / restart Windows | V-4.6 gagal. Uji B **wajib diulang dari nol** dengan folder output baru |
| Hasil meragukan | Jalankan uji linearitas `-mr 75000`, bandingkan durasinya |
| Sesi remote terputus | Tidak berpengaruh. Pengujian lanjut, sambung kembali kapan saja |
| Jendela PowerShell tertutup | Pengujian berhenti. Uji B wajib diulang dari nol |

Menjalankan ulang ke folder output yang sama akan **menyambung** ke CSV yang ada,
bukan menimpanya. Untuk pengujian bersih, selalu pakai folder baru.

---

## 8. Lembar pengesahan

| | |
|---|---|
| Mesin | |
| Tanggal mulai | |
| Tanggal selesai | |
| Tingkat tercapai | T___ |
| Status ketahanan | ☐ Lulus ☐ Tidak lulus |
| Keputusan | ☐ Real-time ☐ Offline saja ☐ Ulangi |
| Catatan penyimpanan | |
| Diuji oleh | |
| Disetujui oleh | |

---

Dasar penetapan seluruh ambang pada dokumen ini — tingkat T1–T4, kapasitas POD5
P2 Solo, dan spesifikasi host resmi ONT — dijelaskan pada
[SpesifikasiMarathon.pdf](SpesifikasiMarathon.pdf).
Cara pemakaian harian ada di [README.md](README.md).
