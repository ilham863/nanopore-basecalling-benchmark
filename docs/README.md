# Basecall.ps1 — Marathon & Benchmark Basecalling Dorado

Menguji apakah sebuah mesin sanggup menjadi host basecalling untuk **PromethION 2 Solo**
atau **MinION Mk1B**, dan apakah kemampuan itu bertahan saat dipakai berhari-hari.

Skrip menjalankan Dorado berulang-ulang, mencatat metrik tiap loop, lalu mengeluarkan
**vonis kelayakan** dalam bentuk laporan konsol dan HTML.

---

## 0. Lingkungan

Skrip ini **khusus Windows**. Diuji pada Windows 11 Pro dengan **Windows PowerShell 5.1**
bawaan sistem — tidak perlu memasang PowerShell 7.

Ketergantungan yang membuatnya Windows-only: penahan sleep lewat `SetThreadExecutionState`,
pembacaan spesifikasi lewat WMI/CIM (`Win32_Processor`, `Win32_LogicalDisk`), huruf drive,
dan berkas rilis `dorado-<versi>-win64`.

### Kalau skrip ditolak saat pertama dijalankan

Windows menolak menjalankan skrip `.ps1` secara default. Dua cara, pilih salah satu:

```powershell
# A. Sekali jalan saja, tanpa mengubah setelan sistem
powershell -ExecutionPolicy Bypass -File .\Basecall.ps1 -h

# B. Izinkan untuk akun ini saja (cukup sekali, permanen)
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

Kalau berkasnya didapat lewat unduhan atau email, Windows juga menandainya sebagai
berasal dari internet. Lepas tandanya:

```powershell
Unblock-File .\Basecall.ps1
```

Jalankan dari **PowerShell biasa**, bukan Command Prompt. Hak administrator tidak
diperlukan, kecuali `-su` memasang Dorado ke lokasi yang butuh izin tulis.

---

## 1. Persiapan

### Dataset

Siapkan **satu folder POD5 berukuran 210 GB di NVMe** (bukan HDD).

| Item | Ruang |
|---|---|
| Dataset POD5 | 210 GB |
| BAM sementara (dihapus tiap loop) | ~29 GB |
| Log + laporan, 7 hari | < 1 GB |
| **Total bebas di NVMe** | **~240 GB** |

Dataset yang sama dipakai untuk seluruh tingkat pengujian (T1–T4) — tidak perlu
dataset kedua. Tingkat yang lebih tinggi dicapai dengan pengulangan otomatis.

> **Wajib di NVMe.** Dataset di HDD membuat pengujian mengukur kecepatan piringan,
> bukan kemampuan GPU, dan hasilnya tidak sah.
>
> **Minimal 2× RAM.** Di bawah itu Windows meng-cache seluruh dataset di RAM dan
> pass kedua tidak menyentuh disk sama sekali. Dengan RAM 32 GB, batas bawahnya
> 64 GB — 210 GB aman.

### Perangkat lunak

- **Dorado** — skrip mencari sendiri folder `dorado-#.#.#-win64` di akar drive dan
  memilih versi tertinggi. Kalau belum ada, pakai `-su` untuk memasangnya otomatis
  (lihat di bawah). Bisa juga ditunjuk manual dengan `-d`.
- **nvidia-smi** — harus ada di PATH agar metrik GPU terekam. Tanpa ini skrip tetap
  jalan, tapi kolom suhu, daya, dan clock akan kosong sehingga keabsahan tidak dapat
  dinilai.

### Pemasangan otomatis Dorado dan model

```powershell
.\Basecall.ps1 -su -i D:\pod5_210gb -o D:\marathon
```

`-su` **memeriksa dulu, baru memasang kalau belum ada**:

1. Kalau Dorado sudah terpasang di mana pun, unduhan dilewati sepenuhnya.
2. Kalau belum ada, zip resmi ONT diunduh dan diekstrak — versi default 2.1.2,
   ganti dengan `-dv`.
3. Tujuan pemasangan otomatis memilih drive fixed dengan ruang bebas terbanyak.
   Tentukan sendiri dengan `-sd D:\`. Butuh minimal 8 GB; kalau kurang, skrip
   menolak dan menyebutkan drive mana yang sempit.
4. Model dicek di cache. Karena model bermodifikasi menghasilkan dua folder
   (simplex dan mods), keduanya harus ada — kalau salah satu hilang, model diunduh.
   Kalau unduhan eksplisit gagal, tidak fatal: Dorado mengunduhnya sendiri saat
   loop pertama.

`-su` bisa digabung dengan perintah maraton biasa — setup dijalankan dulu, lalu
maraton lanjut memakai Dorado yang baru terpasang.

### Persiapan laptop untuk uji 7 hari

1. Adaptor daya terhubung sepanjang pengujian.
2. Laptop diganjal 2–3 cm agar saluran udara bawah tidak tertutup.
3. Lid dibiarkan terbuka; setel aksi tutup-layar ke *Do nothing*.
4. Tunda Windows Update selama seminggu — restart otomatis satu-satunya hal yang
   tidak bisa dicegah skrip.
5. Aktifkan pembatas pengisian baterai 80% bila vendor menyediakannya.
6. Jangan pakai laptop untuk pekerjaan lain (browser dan Teams merebut VRAM).

`report.html` memuat spesifikasi lengkap mesin uji: CPU, RAM, OS, GPU (nama, VRAM,
TDP, clock maksimum, versi driver), seluruh drive beserta kapasitas dan ruang bebasnya
dengan penanda drive mana yang menampung dataset dan output, serta konfigurasi
basecalling (model, versi Dorado, cache, device, jumlah dan ukuran berkas POD5).

Spesifikasi direkam ke `machine_spec.json` saat maraton **mulai**, jadi laporan yang
dibuka belakangan — atau lewat `-rep` di komputer lain — tetap menampilkan mesin yang
diuji, bukan mesin yang kebetulan membuka laporannya.

Skrip menahan Windows agar tidak tidur selama proses berjalan. Ini **tidak** mengubah
setelan daya secara permanen — begitu skrip berhenti, semuanya kembali normal.

---

## 2. Menjalankan

Ganti `D:\pod5_210gb` dengan lokasi dataset sesungguhnya.

### Langkah 1 — Cek prasyarat (instan)

```powershell
.\Basecall.ps1 -h -i D:\pod5_210gb -o D:\marathon
```

Semua baris di bagian **PRASYARAT** harus `[OK]`. Perbaiki dulu yang `[!!]`.

### Langkah 2 — Uji asap, ~30 menit

```powershell
.\Basecall.ps1 -i D:\pod5_210gb -o D:\smoke -dd 0.02 -mr 20000 -r
```

Tunggu sampai muncul `SUKSES Loop ke-1`. Ini memastikan model terunduh, GPU terpakai,
dan BAM terbentuk lalu terhapus. Jangan lewati langkah ini.

### Langkah 3 — Uji A: benchmark kemampuan, ~3 jam

```powershell
.\Basecall.ps1 -i D:\pod5_210gb -o D:\bench -dd 0.2 -r -mr 150000
```

Mesin harus dalam keadaan dingin dan tidak dipakai hal lain. Target 4–5 loop.
Kalau satu loop jauh dari ~30 menit, sesuaikan `-mr` secara proporsional
(loop 60 menit → turunkan ke `-mr 75000`).

### Langkah 4 — Uji B: durability, 7 hari

```powershell
.\Basecall.ps1 -i D:\pod5_210gb -o D:\durability -dd 7 -r -vt 1.3
```

Berhenti sendiri setelah 7 hari, atau tekan `Ctrl+C` kapan saja. Laporan HTML
diperbarui setiap loop selesai, jadi bisa dipantau sambil berjalan.

### Langkah 5 — Baca vonis

```powershell
.\Basecall.ps1 -o D:\durability -rep
```

Mode ini hanya membaca hasil — tidak butuh dorado maupun GPU, jadi bisa dipakai
membaca hasil dari mesin lain.

---

## 3. Hasil

Seluruh berkas ditulis ke folder `-o`.

| Berkas | Isi |
|---|---|
| `report.html` | Indeks: vonis + tabel semua hari |
| `report_YYYYMMDD.html` | Satu per hari: ringkasan + rincian tiap loop |
| `report_final.html` | Hasil akhir, dibekukan saat maraton tuntas |
| `marathon_summary.csv` | Data mentah per loop |
| `machine_spec.json` | Spesifikasi mesin, direkam saat maraton mulai |
| `dorado_loop_*.log` | Keluaran asli Dorado (stderr) |
| `gpu_loop_*.csv` | Metrik GPU tiap 10 detik |
| `RunningParameter.txt` | Parameter yang dipakai |

BAM dihapus otomatis setiap loop selesai. Pakai `-kb` kalau ingin disimpan.

### Membaca tingkat kemampuan

| Tingkat | Laju minimum | Artinya |
|---|---|---|
| **T4** | 57 GB/jam | P2 Solo, 2 flow cell, keluaran maksimum (TMO) |
| **T3** | 37 GB/jam | P2 Solo, 2 flow cell, keluaran nominal |
| **T2** | 19 GB/jam | P2 Solo, 1 flow cell |
| **T1** | 3 GB/jam | MinION Mk1B, 1 flow cell |

Di bawah T1: tidak memadai untuk basecalling real-time, tapi masih layak untuk
basecalling offline setelah run sekuensing selesai.

### Kriteria ketahanan

| Kriteria | Lulus |
|---|---|
| Retensi laju (akhir ÷ awal) | ≥ 0,90 |
| Ketersediaan (loop OK ÷ total) | ≥ 0,99 |
| Gagal tak pulih | 0 |
| Kehabisan VRAM | ≤ 1 |
| Kenaikan suhu maksimum | ≤ +3 °C |

Mesin dinyatakan layak pada suatu tingkat apabila **lulus Uji A di tingkat itu**
**dan** **lulus seluruh kriteria Uji B**. Lulus A tapi gagal B berarti hanya layak
untuk basecalling offline.

### Keabsahan pengukuran

| Indikator | Ambang |
|---|---|
| Daya rata-rata GPU | ≥ 70% TDP |
| Clock SM rata-rata | ≥ 90% clock maksimum |
| Sebaran laju antar-loop | < 5% |

Kolom `utilization.gpu` **tidak** dipakai sebagai penentu. Metrik itu hanya mengukur
ada atau tidaknya kernel yang berjalan, bukan besarnya kapasitas yang terpakai,
sehingga nilainya hampir selalu di atas 90% dan tidak bisa membedakan pengujian yang
sah dari yang tertahan penyimpanan. Daya dan clock jauh lebih jujur.

Bila masih ragu, jalankan setengah beban dan bandingkan durasinya:

```powershell
.\Basecall.ps1 -i D:\pod5_210gb -o D:\bench_half -dd 0.25 -r -mr 75000
```

Sistem yang benar-benar dibatasi GPU menyelesaikan separuh beban dalam kira-kira
separuh waktu.

---

## 4. Daftar flag

Semua opsional. Nilai sekarang selalu terlihat lewat `-h`.

| Flag | Arti | Default |
|---|---|---|
| `-d`, `-Dorado` | lokasi `dorado.exe` | deteksi otomatis, versi tertinggi |
| `-mc`, `-ModelCache` | folder cache model | `<folder dorado>\models` |
| `-m`, `-Model` | nama model | `dna_r10.4.1_e8.2_400bps_hac@v5.2.0_5mC_5hmC@v1` |
| `-i`, `-Input` | folder POD5 | `D:\pod5_pass` |
| `-o`, `-Output` | folder hasil | `D:\Output_dorado_<tanggal>` |
| `-dd`, `-Duration` | lama maraton, hari | `7` |
| `-dev`, `-Device` | target dorado | `cuda:all` |
| `-r`, `-Recursive` | sisir subfolder POD5 | mati |
| `-kb`, `-KeepBam` | simpan BAM tiap loop | mati (dihapus) |
| `-mf`, `-MinFreeGB` | stop kalau sisa disk kurang | otomatis dari ukuran POD5 |
| `-mfail`, `-MaxFail` | stop setelah gagal beruntun | `3` |
| `-b`, `-BatchSize` | batch dorado | otomatis, turun sendiri bila OOM |
| `-mr`, `-MaxReads` | batas read per loop | semua |
| `-vt`, `-VirtualTB` | TB POD5 per run virtual | `1.3` |
| `-vr`, `-VirtualRuns` | stop setelah N run virtual | mati |
| `-mt`, `-MaxTempC` | jeda dingin di atas suhu ini | otomatis dari ambang GPU |
| `-as`, `-AllowSleep` | izinkan Windows tidur | mati (tidur ditahan) |
| `-su`, `-Setup` | pasang dorado + model bila belum ada | — |
| `-dv`, `-DoradoVersion` | versi dorado untuk `-su` | `2.1.2` |
| `-sd`, `-SetupDir` | tujuan pemasangan dorado | drive paling lega |
| `-rep`, `-Report` | baca hasil, keluarkan vonis | — |
| `-h`, `-Help` | bantuan + cek prasyarat | — |

---

## 5. Kalau bermasalah

| Gejala | Kemungkinan sebab |
|---|---|
| Berhenti setelah 3 loop gagal beruntun | Nama model salah, atau driver bermasalah. Lihat ekor `dorado_loop_*.log`. |
| `[WARN] nvidia-smi tidak ada di PATH` | Metrik GPU dilewati. Maraton tetap jalan, tapi keabsahan tak bisa dinilai. |
| Batch turun berkali-kali | VRAM direbut aplikasi lain. Tutup browser dan MinKNOW. |
| Loop berjeda "biar dingin dulu" | Normal. GPU melewati ambang suhu; skrip menunggu 120 detik. |
| `[STOP] Sisa ruang ... ` | Disk hampir penuh. Kosongkan, atau turunkan `-mf`. |
| Daya GPU jauh di bawah TDP | Dataset kemungkinan bukan di NVMe, atau tertahan I/O. |
| Kolom GPU kosong di CSV | `nvidia-smi` tidak jalan saat loop itu. Cek PATH. |
| `-su` menolak: ruang kurang | Drive tujuan di bawah 8 GB. Pakai `-sd <drive lain>`. |
| `-su` gagal mengunduh | Cek koneksi. Bisa juga unduh manual lalu ekstrak ke akar drive. |

Maraton berhenti sendiri setelah `-dd` hari. `Ctrl+C` aman kapan saja — proses anak
dibersihkan, laporan tetap tersimpan.

---

## Lampiran

Dasar penetapan tingkat T1–T4, kapasitas POD5 maksimum P2 Solo, spesifikasi host
resmi ONT, dan penurunan seluruh angka ambang dijelaskan pada
[SpesifikasiMarathon.pdf](SpesifikasiMarathon.pdf).
