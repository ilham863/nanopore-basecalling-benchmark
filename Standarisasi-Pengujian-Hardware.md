# Standarisasi Pengujian Hardware (Benchmark) untuk Operasional Basecalling Nanopore (Dorado)

**Dokumen Usulan Kebijakan Pengadaan dan Kualifikasi Perangkat Komputasi**

| | |
|---|---|
| **Disusun oleh** | Tim Infrastruktur Bioinformatika |
| **Ditujukan kepada** | Manajemen / Pengambil Keputusan Pengadaan TI |
| **Tanggal** | 11 September 2026 |
| **Versi** | 1.0 |
| **Status** | Usulan untuk Persetujuan |

---

## 1. Ringkasan Eksekutif

### 1.1 Latar Belakang

Laboratorium mengoperasikan perangkat sekuensing Oxford Nanopore Technologies (ONT) —
MinION Mk1B dan PromethION 2 Solo. Kedua perangkat tersebut tidak melakukan komputasi
sendiri; keduanya hanya menghasilkan sinyal listrik mentah dalam format POD5, dan
menyerahkan seluruh beban penerjemahan sinyal menjadi urutan basa DNA (*basecalling*)
kepada komputer host melalui perangkat lunak Dorado.

Konsekuensinya jelas: **kualitas dan kelangsungan operasional sekuensing sepenuhnya
ditentukan oleh kemampuan komputer host.** Kesalahan dalam pengadaan perangkat komputasi
tidak hanya berarti pemborosan anggaran, tetapi berpotensi menghentikan layanan
sekuensing di tengah berjalannya sampel pelanggan.

Saat ini belum ada standar terukur yang dipakai lembaga untuk menilai apakah sebuah
perangkat layak dibeli sebagai host basecalling. Keputusan pengadaan masih bertumpu pada
perbandingan spesifikasi di atas kertas. Dokumen ini mengusulkan standar tersebut.

### 1.2 Ilusi Spesifikasi: Angka Brosur versus Realita Sustained Performance

Terdapat kekeliruan yang lazim terjadi dan berbiaya mahal: **menganggap nama komponen
pada brosur sebagai jaminan kinerja.**

Sebagai ilustrasi, sebuah laptop yang dipasarkan dengan GPU "RTX 4080 Mobile" tampak
setara — bahkan lebih unggul — dibandingkan PC desktop ber-GPU "RTX 4070". Secara
penamaan, angka 4080 lebih tinggi daripada 4070. Namun keduanya adalah produk yang
berbeda secara fundamental:

- **Batas daya (TDP) berbeda jauh.** Kartu desktop leluasa menarik daya penuh dari
  catu daya rumah. Kartu laptop dibatasi oleh kapasitas adaptor, sistem pendingin,
  dan kebijakan daya vendor — kerap hanya separuh dari padanan desktop-nya.
- **Kemampuan membuang panas berbeda.** Desktop memiliki ruang, aliran udara, dan
  pendingin berukuran besar. Laptop harus membuang panas yang sama melalui sasis
  setebal dua sentimeter.
- **Perilaku pada beban berkelanjutan berbeda total.** Inilah inti persoalannya.

Laptop dirancang untuk **beban puncak singkat** — merender video, menjalankan permainan
selama dua jam. Laptop **tidak** dirancang untuk komputasi penuh tanpa henti selama
berhari-hari. Ketika suhu mencapai ambang tertentu, driver secara otomatis menurunkan
kecepatan prosesor grafis demi keselamatan perangkat. Gejala ini disebut **thermal
throttling**, dan dampaknya bersifat diam-diam: perangkat tetap bekerja dan tidak
menampilkan pesan kesalahan apa pun, tetapi kecepatannya merosot.

Beban kerja *genomic sequencing* justru merupakan kebalikan dari beban yang diasumsikan
perancang laptop: **komputasi penuh, tanpa jeda, berlangsung berhari-hari.** Pada pola
beban seperti ini, laptop lazim menunjukkan kinerja awal yang meyakinkan pada jam-jam
pertama, lalu kehilangan sebagian besar kemampuannya setelah beberapa jam berikutnya.

### 1.3 Usulan: Benchmark sebagai Quality Control Wajib Pengadaan

Kami mengusulkan agar pengujian yang diuraikan pada dokumen ini ditetapkan sebagai
**prosedur Quality Control (QC) wajib** yang dijalankan **sebelum** keputusan pembelian
perangkat komputasi untuk keperluan basecalling.

Pengujian ini menjawab satu pertanyaan yang tidak dapat dijawab oleh brosur mana pun:

> *Apakah perangkat ini mampu mempertahankan kinerjanya selama tujuh hari penuh pada
> beban basecalling yang sesungguhnya?*

Seluruh proses telah diotomatisasi dan tersedia untuk **kedua sistem operasi yang
didukung ONT** — Windows 10/11 maupun Ubuntu 22.04/24.04 LTS. Kedua versi memakai
parameter, format keluaran, dan ambang kelulusan yang identik, sehingga hasil pengujian
lintas platform dapat disandingkan secara sah. Pengujian menghasilkan laporan terukur
beserta vonis kelulusan tanpa memerlukan penilaian subjektif operator.

---

## 2. Realita Operasional: Mengapa Uji Ketahanan Ditetapkan 7 Hari

### 2.1 Fenomena Lag Basecalling

Pertanyaan yang wajar diajukan: bila satu flow cell hanya beroperasi maksimal 72 jam,
mengapa pengujian ketahanan ditetapkan selama 7 hari?

Jawabannya terletak pada ketidakseimbangan antara **laju produksi data** dan **laju
komputasi**.

Perangkat sekuensing menghasilkan data mentah POD5 secara terus-menerus dan pada laju
yang relatif tetap. Sementara itu, kecepatan komputer host menerjemahkan data tersebut
sangat bergantung pada model basecalling yang dipilih:

| Model | Tingkat akurasi | Kebutuhan komputasi |
|---|---|---|
| FAST | Paling rendah | Paling ringan |
| **HAC** (High Accuracy) | Tinggi — **standar operasional** | Berat |
| **SUP** (Super Accurate) | Tertinggi | Sangat berat |

Operasional laboratorium menuntut akurasi tinggi, sehingga model HAC atau SUP-lah yang
dipakai — bukan FAST. Pada kedua model tersebut, **laju produksi data mentah kerap
melampaui laju komputasi GPU.**

Akibatnya terbentuk **antrean data yang terus menumpuk selama sekuensing berlangsung**.
Ketika perangkat sekuensing telah berhenti pada jam ke-72, komputer host belum selesai
bekerja. Perangkat komputasi harus melanjutkan pemrosesan antrean tersebut — dalam
praktiknya berlangsung hingga hari kelima sampai ketujuh tanpa henti.

Inilah yang kami sebut **Lag Basecalling**: selisih waktu antara berakhirnya sekuensing
dan tuntasnya komputasi.

### 2.2 Implikasi terhadap Rancangan Pengujian

Beban sesungguhnya yang ditanggung perangkat komputasi karena itu **bukan 72 jam,
melainkan 5 hingga 7 hari komputasi penuh tanpa jeda.**

Dari sinilah durasi pengujian ditetapkan:

- **Uji 1 jam** hanya mengukur kinerja puncak. Setiap perangkat tampak baik pada tahap ini.
- **Uji 24 jam** mulai memperlihatkan gejala penurunan, namun belum konklusif.
- **Uji 7 hari** mereplikasi kondisi operasional terburuk yang nyata terjadi di lapangan.

Perbedaannya bersifat menentukan. Perangkat yang tampak sehat pada 24 jam pertama dapat
kehilangan sebagian besar kemampuannya pada hari keempat akibat akumulasi panas,
penurunan efektivitas pasta termal, atau penumpukan debu pada sistem pendingin.
**Pengujian tujuh hari membuktikan ketahanan yang sesungguhnya, bukan kinerja sesaat.**

---

## 3. Standarisasi Golden Dataset dan Efisiensi Pengujian

### 3.1 Target Beban Kerja

Standar ini mengacu pada keluaran nyata kedua perangkat yang dioperasikan laboratorium,
berdasarkan tabel estimasi penyimpanan resmi ONT:

| Perangkat | Keluaran | POD5 per run | Keterangan |
|---|---|---|---|
| MinION Mk1B | 30 Gbases | **210 GB** | 1 flow cell |
| PromethION 2 Solo | 190 Gbases | **1,3 TB** | 1 flow cell, keluaran nominal |
| PromethION 2 Solo | 580 Gbases | 4,06 TB | 2 flow cell, keluaran maksimum teoretis |

### 3.2 Persoalan Efisiensi Pengujian

Menyalin dataset berukuran 1,3 TB ke setiap perangkat yang hendak diuji **tidak layak
dijalankan secara operasional**:

- Proses penyalinan memakan waktu berjam-jam untuk setiap unit.
- Sebagian besar laptop tidak memiliki kapasitas penyimpanan internal yang memadai.
- Dataset sebesar itu harus digandakan berulang kali untuk pengujian paralel.

### 3.3 Solusi: Golden Dataset dan Pengulangan Virtual

Standar ini menetapkan penggunaan **Golden Dataset** — satu berkas acuan yang identik
dan dipakai pada seluruh pengujian, berukuran **210 GB**.

| Aspek | Ketentuan |
|---|---|
| Ukuran | **210 GB POD5** (setara 1 flow cell MinION Mk1B) |
| Lokasi penyimpanan | **Wajib NVMe SSD** |
| Sifat | Identik di seluruh mesin yang diuji, read-only |
| Karakteristik | N50 baca 23 kb, kimia R10.4.1 |

Skrip pengujian **mengulang Golden Dataset secara virtual tanpa henti** hingga tercapai
salah satu dari dua batas: akumulasi beban setara 1,3 TB, atau durasi 7 hari.

Pendekatan ini sah secara teknis karena beban komputasi basecalling sebanding dengan
**jumlah sinyal yang diproses**, bukan dengan keunikan datanya. Memproses dataset
210 GB sebanyak 6,3 kali membebani GPU secara setara dengan memproses satu dataset
1,3 TB.

Pengulangan data yang sama bahkan memberi keunggulan metodologis: karena setiap
putaran mengerjakan beban yang identik, **selisih waktu antar-putaran menjadi ukuran
degradasi yang bersih.** Bila putaran pada hari ketujuh berlangsung lebih lambat
daripada putaran pada hari pertama, penyebabnya dapat dipastikan kondisi perangkat —
bukan kebetulan komposisi data.

> **Ketentuan teknis wajib.** Golden Dataset harus berukuran **sekurang-kurangnya dua
> kali kapasitas RAM** mesin yang diuji. Bila dataset lebih kecil daripada RAM, sistem
> operasi akan menyimpan seluruhnya di memori sehingga putaran kedua dan seterusnya
> tidak lagi menyentuh penyimpanan — hasil pengukuran menjadi tidak sah.

Penetapan 210 GB berangkat dari ketentuan tersebut, diuji terhadap konfigurasi mesin
yang dimiliki laboratorium:

| Konfigurasi mesin | RAM | Batas minimum dataset (2× RAM) | Golden Dataset 210 GB |
|---|---|---|---|
| Workstation kelas menengah | 32 GB | 64 GB | Memenuhi |
| Workstation kelas atas | 64 GB | 128 GB | Memenuhi |
| Cadangan untuk mesin mendatang | 96 GB | 192 GB | Memenuhi |

Ukuran 210 GB dipilih karena merupakan **satu-satunya nilai yang sekaligus memenuhi
tiga syarat**: melampaui dua kali kapasitas RAM pada seluruh konfigurasi yang ada,
setara dengan keluaran nyata satu flow cell MinION Mk1B sehingga tingkat T1 dapat
diukur sebagai satu putaran utuh, dan tetap muat pada penyimpanan NVMe 1 TB bersama
ruang kerja yang dibutuhkan.

> **Ketentuan penyimpanan.** Golden Dataset wajib ditempatkan pada NVMe SSD. Dataset
> yang diletakkan pada hard disk mekanis akan membuat pengujian mengukur kecepatan
> piringan, bukan kemampuan GPU, sehingga seluruh angka yang dihasilkan tidak
> merepresentasikan apa yang hendak dinilai.

---

## 4. Metodologi dan Metrik Pengujian

### 4.1 Struktur Pengujian

Pengujian terbagi menjadi dua tahap yang menjawab pertanyaan berbeda dan karena itu
memiliki kriteria kelulusan tersendiri.

| | Uji A — Kemampuan | Uji B — Ketahanan |
|---|---|---|
| Pertanyaan | Seberapa cepat perangkat ini? | Sanggupkah dipakai berkelanjutan? |
| Durasi | 2–4 jam | 7 hari |
| Kondisi | Mesin dingin, tanpa beban lain | Berjalan terus tanpa gangguan |
| Metrik utama | Laju absolut | Stabilitas laju |
| Frekuensi | Diulang tiga kali | Sekali per perangkat |

Pemisahan ini penting. Pengujian tujuh hari menghasilkan angka kecepatan yang telah
tercemar penurunan termal sehingga tidak sah dipakai membandingkan antar-perangkat.
Sebaliknya, pengujian pendek tidak mungkin mengungkap degradasi. Satu angka tunggal
tidak dapat mewakili keduanya.

### 4.2 Cakupan dan Batas Pengujian

Penting bagi pembaca untuk memahami apa yang diukur standar ini, dan apa yang tidak.

| Diuji oleh standar ini | Tidak diuji, diverifikasi terpisah |
|---|---|
| Kemampuan komputasi GPU pada beban berkelanjutan | Kapasitas menampung satu run penuh |
| Ketahanan termal selama 7 hari | Beban tulis POD5 oleh MinKNOW saat sekuensing |
| Kecukupan VRAM terhadap model produksi | Lalu lintas pemindahan arsip ke HDD |
| Kestabilan driver dan pustaka GPU | Kinerja jaringan dan analisis hilir |

Pemisahan ini disengaja. Pengujian dijalankan pada kondisi terkendali — hanya membaca
POD5 dan menulis keluaran — agar angka yang dihasilkan mencerminkan kemampuan
komputasi dan dapat dibandingkan antar-mesin. Menyertakan beban tulis MinKNOW dan
pemindahan arsip ke dalam pengujian akan membuat hasil bergantung pada konfigurasi
penyimpanan masing-masing mesin, sehingga tidak lagi setara untuk diperbandingkan.

Kebutuhan penyimpanan operasional dinilai secara terpisah melalui perhitungan laju
tulis, yang pada keluaran maksimum PromethION 2 Solo hanya mencapai 16 MB/detik —
jauh di bawah kemampuan NVMe maupun HDD, sehingga bukan merupakan faktor pembatas.

### 4.3 Metrik yang Dicatat Otomatis

Seluruh metrik direkam oleh skrip tanpa intervensi operator, dan tersimpan sebagai
berkas yang dapat diaudit ulang.

**1. Laju Basecalling (GB POD5 per jam)**

Metrik utama kemampuan. Dihitung dari volume data yang diproses dibagi waktu yang
dibutuhkan. Nilai yang dilaporkan adalah **median** seluruh putaran, bukan rata-rata,
agar satu pencilan tidak menggeser hasil. Putaran pertama selalu dikeluarkan dari
perhitungan karena mencakup pengunduhan model dan kondisi cache yang belum panas.

**2. Retensi Laju**

Metrik utama ketahanan, dan merupakan **indikator terpenting dalam dokumen ini.**

```
Retensi Laju  =  Laju median hari ke-7  ÷  Laju median hari ke-1
```

Nilai 1,00 berarti perangkat tidak mengalami penurunan sama sekali. Nilai 0,60 berarti
perangkat kehilangan 40% kemampuannya ketika dipakai berkelanjutan. **Ambang kelulusan
ditetapkan pada 0,90** — perangkat tidak boleh kehilangan lebih dari sepersepuluh
kemampuannya.

Metrik inilah yang membedakan perangkat yang benar-benar layak operasional dari
perangkat yang sekadar terlihat cepat pada pengujian singkat.

**3. Suhu Maksimum GPU**

Direkam setiap sepuluh detik sepanjang pengujian. Yang dinilai bukan semata nilai
puncaknya, melainkan **kecenderungannya**: suhu maksimum harian yang terus menaik dari
hari ke hari menandakan sistem pendingin tidak sanggup mencapai keseimbangan termal.

**4. Konsumsi Daya GPU terhadap TDP**

Metrik keabsahan pengukuran. Dinyatakan sebagai rasio daya rata-rata terhadap batas
daya maksimum kartu yang terpasang.

GPU yang benar-benar bekerja menarik daya mendekati batas maksimumnya. GPU yang justru
sedang menunggu pasokan data akan menarik daya jauh di bawah batas tersebut. Rasio ini
karena itu membuktikan bahwa yang terukur memang kemampuan komputasi, bukan keterbatasan
penyimpanan.

> **Catatan metodologis.** Standar ini **tidak** menggunakan metrik *GPU Utilization*
> yang lazim ditampilkan perkakas pemantauan. Metrik tersebut hanya mengukur ada atau
> tidaknya proses yang berjalan pada GPU, bukan besarnya kapasitas yang benar-benar
> terpakai. Nilainya nyaris selalu menunjukkan angka di atas 90% sehingga tidak mampu
> membedakan pengujian yang sah dari pengujian yang tertahan penyimpanan. Konsumsi daya
> dan frekuensi kerja prosesor grafis merupakan indikator yang jauh lebih dapat
> dipertanggungjawabkan.

### 4.4 Klasifikasi Tingkat Kemampuan

Hasil Uji A dipetakan ke dalam empat tingkat baku. Ambang laju diturunkan dari volume
POD5 yang dihasilkan masing-masing skenario dibagi durasi run standar 72 jam — yaitu
kecepatan minimum agar komputer host mampu mengimbangi produksi data secara langsung.

| Tingkat | Laju minimum | Kesetaraan operasional |
|---|---|---|
| **T4** | 57 GB/jam | PromethION 2 Solo, 2 flow cell, keluaran maksimum |
| **T3** | 37 GB/jam | PromethION 2 Solo, 2 flow cell, keluaran nominal |
| **T2** | 19 GB/jam | PromethION 2 Solo, 1 flow cell |
| **T1** | 3 GB/jam | MinION Mk1B, 1 flow cell |

Perangkat yang tidak mencapai T1 tetap dapat dimanfaatkan untuk basecalling secara
tunda (*offline*) setelah sekuensing selesai, namun tidak layak sebagai host
basecalling langsung.

---

## 5. Kriteria Kelulusan dan Kesimpulan

### 5.1 Kriteria Kelulusan

Perangkat dinyatakan **LULUS pada tingkat tertentu** apabila memenuhi seluruh butir
berikut.

| No | Kriteria | Ambang Kelulusan | Makna Kegagalan |
|---|---|---|---|
| 1 | Tingkat kemampuan (Uji A) | Tercapai T1–T4 | Terlalu lambat untuk basecalling langsung |
| 2 | **Retensi laju** | **≥ 0,90** | **Kinerja merosot saat dipakai berhari-hari** |
| 3 | Ketersediaan putaran | ≥ 0,99 | Sering gagal, operasional tidak dapat diandalkan |
| 4 | Kegagalan tanpa pemulihan | 0 kejadian | Terdapat kegagalan permanen |
| 5 | Kehabisan memori GPU (OOM) | ≤ 1 kejadian | VRAM tidak memadai untuk beban produksi |
| 6 | Kenaikan suhu maksimum | ≤ +3 °C | Pendinginan tidak mencapai keseimbangan |
| 7 | Konsumsi daya GPU | ≥ 70% TDP | Pengukuran tidak sah, tertahan penyimpanan |
| 8 | Sebaran laju antar-putaran | < 5% | Hasil tidak konsisten, tidak dapat dipercaya |

**Keputusan akhir:**

| Kondisi | Keputusan |
|---|---|
| Seluruh kriteria terpenuhi pada tingkat T2–T4 | **Layak** sebagai host basecalling langsung PromethION 2 Solo |
| Seluruh kriteria terpenuhi pada tingkat T1 | **Layak** untuk MinION Mk1B; PromethION hanya secara tunda |
| Kriteria kemampuan lulus, ketahanan gagal | **Tidak layak** untuk operasional langsung. Penggunaan terbatas pada basecalling tunda |
| Kriteria keabsahan gagal (butir 7 atau 8) | **Hasil dinyatakan batal.** Perbaiki penyebab, ulangi pengujian |

### 5.2 Catatan Kapasitas Penyimpanan

Terpisah dari hasil pengujian kinerja, terdapat satu persyaratan yang bersifat mutlak
dan tidak dapat dikompensasi oleh komponen mana pun.

Satu flow cell PromethION 2 Solo menghasilkan 1,3 TB data POD5 pada keluaran nominal,
dan mencapai 4,06 TB pada konfigurasi dua flow cell keluaran maksimum. ONT
merekomendasikan penyimpanan SSD berkapasitas 8 TB sebagai satu volume tunggal.

**Perangkat dengan penyimpanan internal 1 TB tidak dapat menampung satu run PromethION
2 Solo, berapa pun tingkat kemampuan yang dicapainya dalam pengujian ini.** Penggunaan
perangkat demikian sebagai host PromethION mensyaratkan penambahan penyimpanan eksternal
berkecepatan tinggi melalui antarmuka USB4 atau Thunderbolt.

Persyaratan ini wajib dicantumkan tersendiri pada setiap laporan hasil pengujian.

### 5.3 Kesimpulan dan Rekomendasi

Pengadaan perangkat komputasi untuk basecalling yang bertumpu pada perbandingan
spesifikasi di atas kertas mengandung risiko nyata: **perangkat mahal yang terbukti
gagal memenuhi kebutuhan operasional laboratorium.** Risiko ini tidak dapat dideteksi
melalui pengujian singkat maupun melalui pembacaan brosur, karena gejalanya baru muncul
setelah perangkat bekerja berhari-hari tanpa henti — persis pada kondisi yang setiap
hari dihadapi laboratorium.

Standarisasi yang diusulkan dalam dokumen ini memberikan tiga manfaat langsung:

- **Keputusan pengadaan berbasis bukti terukur.** Setiap calon perangkat memperoleh
  vonis kelayakan yang objektif dan dapat diaudit, bukan sekadar perbandingan nama
  komponen.
- **Perlindungan terhadap kelangsungan layanan.** Kegagalan perangkat di tengah
  sekuensing sampel pelanggan dapat dicegah sebelum perangkat dibeli, bukan ditemukan
  setelahnya.
- **Perbandingan yang setara antar-perangkat dan antar-waktu.** Dengan Golden Dataset
  dan beban kerja yang dikunci, hasil pengujian dari mesin dan periode yang berbeda
  dapat disandingkan secara sah.

**Rekomendasi:** agar prosedur pengujian ini ditetapkan sebagai persyaratan Quality
Control wajib bagi seluruh pengadaan perangkat komputasi yang diperuntukkan bagi
operasional basecalling, dan diulang setiap terjadi perubahan besar pada perangkat
keras maupun perangkat lunak yang dipakai.

---

## Lampiran

| Dokumen | Isi |
|---|---|
| `bin/Basecall.ps1` | Skrip pengujian otomatis — Windows 10/11 |
| `bin/basecall.sh` | Skrip pengujian otomatis — Ubuntu 22.04/24.04 LTS |
| `bin/report.py` | Generator vonis dan laporan, dipakai bersama kedua platform |
| `docs/README.md` | Petunjuk pengoperasian skrip |
| `docs/DEPLOY.md` | Runbook deployment dan lembar validasi |
| `docs/SpesifikasiMarathon.pdf` | Dasar teknis penetapan seluruh ambang, beserta rujukan resmi ONT |

**Rujukan:**

- Oxford Nanopore Technologies — *PromethION 2 Solo device and IT specifications*
- Oxford Nanopore Technologies — *PromethION 2 Solo Technical Specification*
- Oxford Nanopore Technologies — *MinKNOW user guide*, asumsi keluaran flow cell dan perhitungan *keep-up*
- Oxford Nanopore Technologies — tabel estimasi penyimpanan MinION Mk1B dan PromethION 2 Solo, N50 baca 23 kb
