#!/usr/bin/env bash
# Marathon & benchmark basecalling Dorado — versi Linux (Ubuntu 22.04 / 24.04 LTS).
#
# Padanan Basecall.ps1 untuk Windows. Menghasilkan berkas yang SAMA PERSIS
# (marathon_summary.csv, machine_spec.json, report*.html) sehingga hasil dari
# kedua platform dapat disandingkan secara sah.
#
# Vonis dan laporan HTML dihasilkan oleh report.py yang dipakai bersama kedua
# platform — ambangnya satu sumber, tidak ada penggandaan logika.

set -uo pipefail

# ---------------------------------------------------------------- default
DORADO=""
MODEL_CACHE=""
MODEL="dna_r10.4.1_e8.2_400bps_hac@v5.2.0_5mC_5hmC@v1"
POD5_INPUT="$HOME/pod5_pass"
OUTPUT="$HOME/Output_dorado_$(date +%Y%m%d)"
DAY_DURATION=7
KEEP_BAM=0
MIN_FREE_GB=0          # 0 = auto dari ukuran POD5
MAX_FAIL=3
RECURSIVE=0
DEVICE="cuda:all"
BATCH_SIZE=0
MAX_TEMP_C=0           # 0 = auto dari ambang slowdown GPU
MAX_READS=0
VIRTUAL_TB=1.3
VIRTUAL_RUNS=0
SETUP=0
DORADO_VERSION="2.1.2"
SETUP_DIR=""
DO_REPORT=0
DO_HW=0
SHOW_HELP=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT_PY="$SCRIPT_DIR/report.py"

# Ubuntu menyediakan python3; sebagian lingkungan lain hanya punya python.
PY=""
for c in python3 python; do command -v "$c" >/dev/null 2>&1 && { PY="$c"; break; }; done

C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YLW=$'\033[33m'
C_CYN=$'\033[36m'; C_GRY=$'\033[90m'; C_RST=$'\033[0m'

# ---------------------------------------------------------------- argumen
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--dorado)        DORADO="$2"; DORADO_EXPLICIT=1; shift 2 ;;
    -mc|--model-cache)  MODEL_CACHE="$2"; shift 2 ;;
    -m|--model)         MODEL="$2"; shift 2 ;;
    -i|--input)         POD5_INPUT="$2"; shift 2 ;;
    -o|--output)        OUTPUT="$2"; shift 2 ;;
    -dd|--duration)     DAY_DURATION="$2"; shift 2 ;;
    -kb|--keep-bam)     KEEP_BAM=1; shift ;;
    -mf|--min-free-gb)  MIN_FREE_GB="$2"; shift 2 ;;
    -mfail|--max-fail)  MAX_FAIL="$2"; shift 2 ;;
    -r|--recursive)     RECURSIVE=1; shift ;;
    -dev|--device)      DEVICE="$2"; shift 2 ;;
    -b|--batch-size)    BATCH_SIZE="$2"; shift 2 ;;
    -mt|--max-temp)     MAX_TEMP_C="$2"; shift 2 ;;
    -mr|--max-reads)    MAX_READS="$2"; shift 2 ;;
    -vt|--virtual-tb)   VIRTUAL_TB="$2"; shift 2 ;;
    -vr|--virtual-runs) VIRTUAL_RUNS="$2"; shift 2 ;;
    -su|--setup)        SETUP=1; shift ;;
    -dv|--dorado-version) DORADO_VERSION="$2"; shift 2 ;;
    -sd|--setup-dir)    SETUP_DIR="$2"; shift 2 ;;
    -hw|--hardware)     DO_HW=1; shift ;;
    -rep|--report)      DO_REPORT=1; shift ;;
    -h|--help)          SHOW_HELP=1; shift ;;
    *) echo "Flag tidak dikenal: $1" >&2; exit 2 ;;
  esac
done
DORADO_EXPLICIT="${DORADO_EXPLICIT:-0}"

# ---------------------------------------------------------------- util

have() { command -v "$1" >/dev/null 2>&1; }

# Sisa ruang bebas (GB) pada partisi yang menampung sebuah jalur.
free_gb() {
  local p="$1"
  while [[ ! -e "$p" && "$p" != "/" ]]; do p="$(dirname "$p")"; done
  df -P -BG "$p" 2>/dev/null | awk 'NR==2{gsub("G","",$4); print $4}'
}

pod5_bytes() {
  local depth=()
  [[ $RECURSIVE -eq 0 ]] && depth=(-maxdepth 1)
  [[ -d "$POD5_INPUT" ]] || { echo 0; return; }
  find "$POD5_INPUT" "${depth[@]}" -type f -name '*.pod5' -printf '%s\n' 2>/dev/null |
    awk '{s+=$1} END{printf "%d", s+0}'
}

pod5_count() {
  local depth=()
  [[ $RECURSIVE -eq 0 ]] && depth=(-maxdepth 1)
  [[ -d "$POD5_INPUT" ]] || { echo 0; return; }
  find "$POD5_INPUT" "${depth[@]}" -type f -name '*.pod5' 2>/dev/null | wc -l
}

# Suhu GPU tertinggi saat ini, atau -1 bila nvidia-smi tidak tersedia.
gpu_temp() {
  have nvidia-smi || { echo -1; return; }
  nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null |
    awk 'BEGIN{m=-1} /^[0-9]+$/{if($1>m)m=$1} END{print m}'
}

# Ambang slowdown GPU dikurangi margin 5 C; 87 bila tidak terbaca.
auto_max_temp() {
  have nvidia-smi || { echo 87; return; }
  local v
  v=$(nvidia-smi -q -d TEMPERATURE 2>/dev/null |
      awk -F: '/Slowdown Temp/{gsub(/[^0-9]/,"",$2); if($2>40) print $2}' |
      sort -n | head -1)
  [[ -n "$v" ]] && echo $((v - 5)) || echo 87
}

# BAM tak-sejajar dengan modifikasi ~ 9% ukuran POD5 (tabel ONT).
# Ambang disk = 1.5x satu BAM, minimal 20 GB.
auto_min_free() {
  awk -v b="$1" 'BEGIN{
    if (b<=0) {print 50; exit}
    n = int((b/1073741824)*0.09*1.5) + 1
    print (n<20 ? 20 : n)
  }'
}

# ---------------------------------------------------------------- cari dorado

find_dorado() {
  # 1. Jalur eksplisit dari -d
  if [[ $DORADO_EXPLICIT -eq 1 && -n "$DORADO" ]]; then
    if [[ -x "$DORADO" ]]; then echo "$DORADO|-d"; return 0; fi
    if have "$DORADO"; then echo "$(command -v "$DORADO")|PATH"; return 0; fi
  fi
  # 2. Folder dorado-#.#.#-linux-x64, versi tertinggi menang
  local best="" bestv="" d v
  for root in /opt "$HOME" /usr/local "$SCRIPT_DIR/.." /; do
    [[ -d "$root" ]] || continue
    for d in "$root"/dorado-*-linux-*; do
      [[ -x "$d/bin/dorado" ]] || continue
      v=$(basename "$d" | sed -E 's/^dorado-([0-9.]+)-linux.*/\1/')
      if [[ -z "$bestv" ]] || [[ "$(printf '%s\n%s\n' "$bestv" "$v" | sort -V | tail -1)" == "$v" ]]; then
        bestv="$v"; best="$d/bin/dorado"
      fi
    done
  done
  if [[ -n "$best" ]]; then echo "$best|versi tertinggi v$bestv"; return 0; fi
  # 3. PATH
  if have dorado; then echo "$(command -v dorado)|PATH"; return 0; fi
  return 1
}

# ---------------------------------------------------------------- setup

install_dorado() {
  local hit
  if hit=$(find_dorado); then
    echo "${C_GRN}[SETUP] Dorado sudah ada, unduhan dilewati.${C_RST}"
    echo "${C_GRY}        ${hit%%|*}  (${hit##*|})${C_RST}"
    echo "${hit%%|*}"; return 0
  fi

  local dir="${SETUP_DIR:-/opt}"
  local target="$dir/dorado-$DORADO_VERSION-linux-x64"
  local exe="$target/bin/dorado"
  if [[ -x "$exe" ]]; then
    echo "${C_GRN}[SETUP] Dorado sudah terpasang di $target.${C_RST}" >&2
    echo "$exe"; return 0
  fi

  local free; free=$(free_gb "$dir")
  if [[ -n "$free" && "$free" -lt 8 ]]; then
    echo "${C_RED}[ERROR] Sisa ruang $dir hanya ${free} GB, butuh minimal 8 GB.${C_RST}" >&2
    echo "${C_RED}        Pakai -sd <folder lain>.${C_RST}" >&2
    return 1
  fi
  if [[ ! -w "$dir" ]]; then
    echo "${C_RED}[ERROR] Tidak ada izin tulis ke $dir. Jalankan dengan sudo, atau pakai -sd \$HOME.${C_RST}" >&2
    return 1
  fi

  local url="https://cdn.oxfordnanoportal.com/software/analysis/dorado-$DORADO_VERSION-linux-x64.tar.gz"
  local tgz="/tmp/dorado-$DORADO_VERSION-linux-x64.tar.gz"
  echo "${C_YLW}[SETUP] Dorado tidak ditemukan. Mengunduh v$DORADO_VERSION...${C_RST}" >&2
  echo "${C_GRY}        $url${C_RST}" >&2

  if have curl; then
    curl -fL --progress-bar -o "$tgz" "$url" || { echo "${C_RED}[ERROR] Unduhan gagal.${C_RST}" >&2; return 1; }
  elif have wget; then
    wget -q --show-progress -O "$tgz" "$url" || { echo "${C_RED}[ERROR] Unduhan gagal.${C_RST}" >&2; return 1; }
  else
    echo "${C_RED}[ERROR] curl maupun wget tidak tersedia.${C_RST}" >&2; return 1
  fi

  echo "${C_CYN}[SETUP] Mengekstrak ke $dir ...${C_RST}" >&2
  tar -xzf "$tgz" -C "$dir" || { echo "${C_RED}[ERROR] Ekstraksi gagal.${C_RST}" >&2; return 1; }
  rm -f "$tgz"

  [[ -x "$exe" ]] || exe=$(find "$dir" -maxdepth 3 -type f -name dorado -perm -u+x 2>/dev/null | head -1)
  if [[ -n "$exe" && -x "$exe" ]]; then
    echo "${C_GRN}[SETUP] Dorado siap: $exe${C_RST}" >&2
    echo "$exe"; return 0
  fi
  echo "${C_RED}[ERROR] dorado tidak ketemu setelah ekstraksi.${C_RST}" >&2
  return 1
}

install_model() {
  local exe="$1" cache="$2"
  mkdir -p "$cache"
  # Model gabungan menghasilkan DUA folder: simplex dan mods. Keduanya harus ada.
  local simplex; simplex=$(echo "$MODEL" | sed -E 's/^(.*?@v[0-9.]+).*/\1/')
  local miss=0
  [[ -d "$cache/$MODEL" ]] || miss=1
  [[ "$simplex" == "$MODEL" || -d "$cache/$simplex" ]] || miss=1
  if [[ $miss -eq 0 ]]; then
    echo "${C_GRN}[SETUP] Model sudah ada di cache, unduhan dilewati.${C_RST}"
    return 0
  fi
  echo "${C_YLW}[SETUP] Mengunduh model: $MODEL${C_RST}"
  for flag in --models-directory --directory; do
    if "$exe" download --model "$MODEL" "$flag" "$cache" 2>&1 | sed "s/^/        /"; then
      echo "${C_GRN}[SETUP] Model siap.${C_RST}"; return 0
    fi
    echo "${C_YLW}[SETUP] Flag $flag ditolak, mencoba alternatif...${C_RST}"
  done
  echo "${C_YLW}[WARN] Unduhan model eksplisit gagal - dorado akan mengunduhnya sendiri di loop pertama.${C_RST}"
  return 0
}

# ---------------------------------------------------------------- spesifikasi

write_machine_spec() {
  local out="$1/machine_spec.json"
  local cpu cores threads ram osname gpus disks dver

  cpu=$(awk -F: '/^model name/{gsub(/^ +| +$/,"",$2); print $2; exit}' /proc/cpuinfo |
        sed -E 's/  +/ /g')
  cores=$(lscpu 2>/dev/null | awk -F: '/^Core\(s\) per socket/{gsub(/ /,"",$2); print $2; exit}')
  threads=$(nproc 2>/dev/null)
  ram=$(awk '/MemTotal/{printf "%.1f", $2/1048576}' /proc/meminfo)
  osname=$( (. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME") || uname -sr )
  dver=$("$DORADO" --version 2>&1 | head -1 | cut -c1-80)

  gpus="[]"
  if have nvidia-smi; then
    gpus=$(nvidia-smi --query-gpu=name,memory.total,driver_version,power.limit,clocks.max.sm \
             --format=csv,noheader,nounits 2>/dev/null |
      awk -F', *' 'BEGIN{printf "["} {
        if(NR>1) printf ","
        printf "{\"Nama\":\"%s\",\"VRAM\":\"%.1f GB\",\"Driver\":\"%s\",\"TDP\":\"%d W\",\"Clock\":\"%s MHz\"}",
               $1, $2/1024, $3, $4, $5
      } END{printf "]"}')
    [[ -z "$gpus" ]] && gpus="[]"
  fi

  local pod5_root out_root
  # $NF, bukan $6: nama filesystem boleh mengandung spasi.
  # Bentuk perintahnya disamakan persis dengan pendataan disk di bawah supaya
  # penamaan mount point konsisten dan penandaan peran cocok.
  pod5_root=$(df -P -BG "$POD5_INPUT" 2>/dev/null | awk 'NR==2{print $NF}')
  out_root=$(df -P -BG "$1" 2>/dev/null | awk 'NR==2{print $NF}')
  # Cadangan: cocokkan juga lewat nama filesystem, untuk sistem yang melaporkan
  # mount point berbeda antara kueri per-jalur dan pendataan menyeluruh.
  local pod5_src out_src
  pod5_src=$(df -P -BG "$POD5_INPUT" 2>/dev/null | awk 'NR==2{s="";for(i=1;i<=NF-5;i++)s=s (i>1?" ":"") $i; print s}')
  out_src=$(df -P -BG "$1" 2>/dev/null | awk 'NR==2{s="";for(i=1;i<=NF-5;i++)s=s (i>1?" ":"") $i; print s}')
  # Kolom dibaca DARI KANAN: nama filesystem boleh mengandung spasi tanpa
  # menggeser kolom lain. Urutan df -P: <source...> size used avail pcent target
  disks=$(df -P -BG -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | tail -n +2 |
    awk -v p="$pod5_root" -v o="$out_root" -v ps="$pod5_src" -v os="$out_src" 'BEGIN{printf "["; n=0} {
      target=$NF; pcent=$(NF-1); avail=$(NF-2); size=$(NF-4)
      src=""
      for(i=1;i<=NF-5;i++) src = src (i>1 ? " " : "") $i
      gsub("G","",size); gsub("G","",avail)
      peran=""
      if (target==p || (ps!="" && src==ps)) peran="dataset POD5"
      if (target==o || (os!="" && src==os)) peran = (peran=="" ? "output" : peran " + output")
      gsub(/"/,"",src); gsub(/"/,"",target)
      if(n++) printf ","
      printf "{\"Drive\":\"%s\",\"Label\":\"%s\",\"FS\":\"-\",\"Total\":\"%s GB\",\"Bebas\":\"%s GB\",\"Pakai\":\"%s\",\"Peran\":\"%s\"}",
             target, src, size, avail, pcent, peran
    } END{printf "]"}')

  local n b
  n=$(pod5_count); b=$(pod5_bytes)
  cat > "$out" <<JSON
{
  "Waktu": "$(date '+%Y-%m-%d %H:%M:%S')",
  "Host": "$(hostname)",
  "Platform": "Linux",
  "Mesin": "$(cat /sys/devices/virtual/dmi/id/product_name 2>/dev/null || echo '-')",
  "OS": "$osname ($(uname -r))",
  "CPU": "${cpu:--}",
  "CpuCore": "${cores:-?} core / ${threads:-?} thread",
  "RAM": "$ram GB",
  "GPU": $gpus,
  "Disk": $disks,
  "Dorado": "$DORADO",
  "DoradoVer": "$dver",
  "Model": "$MODEL",
  "ModelCache": "$MODEL_CACHE",
  "Device": "$DEVICE",
  "Pod5Dir": "$POD5_INPUT",
  "Pod5Berkas": $n,
  "Pod5Ukuran": "$(awk -v b="$b" 'BEGIN{printf "%.1f GB", b/1073741824}')"
}
JSON
}


# ---------------------------------------------------------------- hardware idle

# Menegakkan dua hal yang selama ini hanya bisa diperiksa manusia:
#   1. jenis media tiap drive (NVMe / SSD / HDD) - dataset uji tidak boleh di HDD
#   2. kondisi diam sistem - tidak ada beban lain yang mencemari pengukuran
hw_check() {
  local siap=0    # 0 = siap, 1 = ada temuan

  chk() {  # chk <status> <label> <detail>
    local c
    case "$1" in
      ok)  c="${C_GRN}[OK]${C_RST}" ;;
      bad) c="${C_RED}[!!]${C_RST}"; siap=1 ;;
      *)   c="${C_YLW}[??]${C_RST}" ;;
    esac
    printf "    %b %-14s${C_GRY}%s${C_RST}\n" "$c" "$2" "$3"
  }

  echo
  echo "${C_CYN}  PEMERIKSAAN HARDWARE IDLE${C_RST}"
  echo "${C_GRY}  $(date '+%Y-%m-%d %H:%M:%S') - $(hostname)${C_RST}"
  echo
  echo "  GPU"
  if have nvidia-smi; then
    while IFS=, read -r idx name temp util pw pl mu mt; do
      temp=$(echo "$temp" | tr -d ' '); util=$(echo "$util" | tr -d ' ')
      # GPU yang benar-benar diam: di bawah 50 C dan utilisasi di bawah 10%.
      local st=ok
      [[ "$temp" -ge 50 || "$util" -ge 10 ]] && st=bad
      chk "$st" "GPU $(echo "$idx" | tr -d ' ')" \
          "$(echo "$name" | sed 's/^ //') | ${temp} C | util ${util}% |$pw W dari$pl W | VRAM$mu dari$mt MiB"
    done < <(nvidia-smi --query-gpu=index,name,temperature.gpu,utilization.gpu,power.draw,power.limit,memory.used,memory.total \
               --format=csv,noheader,nounits 2>/dev/null)
    local apps
    apps=$(nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader 2>/dev/null)
    if [[ -n "$apps" ]]; then
      while read -r a; do chk bad 'proses GPU' "$a"; done <<< "$apps"
    else
      chk ok 'proses GPU' 'tidak ada proses komputasi yang memakai GPU'
    fi
  else
    chk bad 'nvidia-smi' 'tidak ada - GPU NVIDIA tidak terdeteksi'
  fi
  echo

  echo "  CPU DAN MEMORI"
  local cpu cores load1 pct
  cpu=$(awk -F: '/^model name/{gsub(/^ +| +$/,"",$2); print $2; exit}' /proc/cpuinfo)
  cores=$(nproc 2>/dev/null)
  load1=$(awk '{print $1}' /proc/loadavg)
  pct=$(awk -v l="$load1" -v c="${cores:-1}" 'BEGIN{printf "%d", (l/c)*100}')
  chk $([[ "$pct" -lt 20 ]] && echo ok || echo bad) 'CPU' \
      "${cpu:-?} | $cores thread | load1 $load1 (~${pct}%)"

  # Suhu CPU: lm-sensors bila ada, kalau tidak pakai thermal zone kernel.
  local ctemp=""
  if have sensors; then
    ctemp=$(sensors 2>/dev/null | awk '/(Package id 0|Tdie|Tctl)/{gsub(/[^0-9.]/,"",$NF); print $NF; exit}')
  fi
  if [[ -z "$ctemp" && -r /sys/class/thermal/thermal_zone0/temp ]]; then
    ctemp=$(awk '{printf "%.1f", $1/1000}' /sys/class/thermal/thermal_zone0/temp)
  fi
  if [[ -n "$ctemp" ]]; then
    chk $(awk -v t="$ctemp" 'BEGIN{print (t<60 ? "ok" : "bad")}') 'suhu CPU' "$ctemp C"
  else
    chk unknown 'suhu CPU' 'tidak terbaca - pasang lm-sensors: sudo apt install lm-sensors'
  fi

  local mt mu mp
  mt=$(awk '/MemTotal/{printf "%.1f", $2/1048576}' /proc/meminfo)
  # MemAvailable tidak ada pada kernel lama maupun /proc tiruan; mundur ke MemFree.
  mu=$(awk '/^MemAvailable:/{a=$2} /^MemFree:/{f=$2} /^MemTotal:/{t=$2}
            END{ if(a=="") a=f; printf "%.1f", (t-a)/1048576 }' /proc/meminfo)
  mp=$(awk -v u="$mu" -v t="$mt" 'BEGIN{printf "%d", (u/t)*100}')
  chk $([[ "$mp" -lt 40 ]] && echo ok || echo bad) 'RAM' "$mu dari $mt GB terpakai (${mp}%)"
  echo

  echo "  PENYIMPANAN"
  local pod5_dev out_dev
  pod5_dev=$(df -P "$POD5_INPUT" 2>/dev/null | awk 'NR==2{print $1}')
  out_dev=$(df -P "$OUTPUT" 2>/dev/null | awk 'NR==2{print $1}')
  while read -r dev size avail target; do
    [[ -z "$dev" ]] && continue
    # rota=1 berarti piringan berputar (HDD); tran=nvme membedakan NVMe dari SATA SSD.
    local base rota tran jenis
    base=$(lsblk -no PKNAME "$dev" 2>/dev/null | head -1)
    [[ -z "$base" ]] && base=$(basename "$dev" | sed -E 's/p?[0-9]+$//')
    rota=$(cat "/sys/block/$base/queue/rotational" 2>/dev/null)
    tran=$(lsblk -dno TRAN "/dev/$base" 2>/dev/null | tr -d ' ')
    case "$rota" in
      0) jenis=$([[ "$tran" == "nvme" ]] && echo "NVMe SSD" || echo "SATA SSD") ;;
      1) jenis="HDD" ;;
      *) jenis="tidak terbaca" ;;
    esac
    local peran="" st=ok
    [[ "$dev" == "$pod5_dev" ]] && peran="dataset POD5"
    [[ "$dev" == "$out_dev"  ]] && peran="${peran:+$peran + }output"
    # HDD sah untuk arsip, tetapi TIDAK untuk dataset uji maupun output.
    [[ "$jenis" == "HDD" && -n "$peran" ]] && st=bad
    [[ "$jenis" == "tidak terbaca" ]] && st=unknown
    chk "$st" "$target" "$(printf '%-9s' "$jenis") | $size, bebas $avail${peran:+  <- $peran}"
  done < <(df -P -BG -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | tail -n +2 |
           awk '{print $1, $(NF-4), $(NF-2), $NF}')
  echo

  echo "  PROSES YANG MENGGANGGU PENGUJIAN"
  local ada=0 g
  for g in minknow MinKNOW teamviewerd anydesk chrome chromium firefox; do
    if pgrep -x "$g" >/dev/null 2>&1 || pgrep -f "^$g" >/dev/null 2>&1; then
      chk bad 'berjalan' "$g ($(pgrep -c -f "$g" 2>/dev/null || echo 1) proses)"
      ada=1
    fi
  done
  if [[ $ada -eq 0 ]]; then
    chk ok 'bersih' 'tidak ada aplikasi pengganggu yang berjalan'
  else
    echo "${C_YLW}    Tutup dulu sebelum menjalankan Uji A; semuanya merebut VRAM atau CPU.${C_RST}"
  fi
  echo

  if [[ -r /sys/class/power_supply/AC/online ]]; then
    echo "  DAYA"
    if [[ "$(cat /sys/class/power_supply/AC/online)" == "1" ]]; then
      chk ok 'adaptor' 'terhubung'
    else
      chk bad 'adaptor' 'MASIH BATERAI - dGPU akan dibatasi'
    fi
    echo
  fi

  echo "  KESIMPULAN"
  if [[ $siap -eq 0 ]]; then
    echo "${C_GRN}    Mesin dalam kondisi diam dan siap untuk benchmark maupun MinKNOW.${C_RST}"
  else
    echo "${C_RED}    Ada butir bertanda [!!] - benahi dulu sebelum menjalankan Uji A,${C_RST}"
    echo "${C_RED}    karena angka yang dihasilkan tidak akan mencerminkan kemampuan sesungguhnya.${C_RST}"
  fi
  echo
  return $siap
}

# ---------------------------------------------------------------- bantuan

show_help() {
  cat <<EOF

  basecall.sh - marathon basecalling Dorado (Linux)

  PEMAKAIAN
    ./basecall.sh [-i <folder pod5>] [-o <folder>] [-dd <hari>] [-h]

  FLAG (semua opsional - nilai sekarang di kurung siku)
    -d,  --dorado         lokasi dorado              [${DORADO:-deteksi otomatis}]
    -mc, --model-cache    folder cache model         [${MODEL_CACHE:-<folder dorado>/models}]
    -m,  --model          nama model                 [$MODEL]
    -i,  --input          folder POD5                [$POD5_INPUT]
    -o,  --output         folder hasil               [$OUTPUT]
    -dd, --duration       lama marathon, hari        [$DAY_DURATION]
    -dev, --device        target dorado              [$DEVICE]
    -r,  --recursive      sisir subfolder POD5       [$RECURSIVE]
    -kb, --keep-bam       simpan BAM tiap loop       [$KEEP_BAM]
    -mf, --min-free-gb    stop kalau sisa disk < ini [$MIN_FREE_GB${MIN_FREE_AUTO:+ auto}]
    -mfail, --max-fail    stop setelah gagal beruntun[$MAX_FAIL]
    -b,  --batch-size     batch dorado (0=auto)      [$BATCH_SIZE]
    -mr, --max-reads      read per loop (0=semua)    [$MAX_READS]
    -vt, --virtual-tb     TB POD5 per run virtual    [$VIRTUAL_TB]
    -vr, --virtual-runs   stop setelah N run         [$VIRTUAL_RUNS]
    -mt, --max-temp       jeda dingin di atas suhu   [$MAX_TEMP_C${MAX_TEMP_AUTO:+ auto}]
    -su, --setup          pasang dorado+model bila perlu
    -dv, --dorado-version versi dorado untuk -su     [$DORADO_VERSION]
    -sd, --setup-dir      tujuan pasang dorado       [${SETUP_DIR:-/opt}]
    -hw, --hardware       periksa kondisi diam mesin
    -rep, --report        vonis kelayakan dari hasil
    -h,  --help           bantuan ini

  PRASYARAT
EOF
  local d n b tb
  if d=$(find_dorado); then
    printf "    ${C_GRN}[OK]${C_RST} %-12s ${C_GRY}%s  (%s)${C_RST}\n" 'dorado' "${d%%|*}" "${d##*|}"
  else
    printf "    ${C_RED}[!!]${C_RST} %-12s ${C_GRY}tidak ketemu - pakai -su untuk memasang, atau -d${C_RST}\n" 'dorado'
  fi
  if have nvidia-smi; then
    printf "    ${C_GRN}[OK]${C_RST} %-12s ${C_GRY}%s${C_RST}\n" 'nvidia-smi' "$(command -v nvidia-smi)"
  else
    printf "    ${C_RED}[!!]${C_RST} %-12s ${C_GRY}tidak ada - metrik GPU tidak terekam${C_RST}\n" 'nvidia-smi'
  fi
  n=$(pod5_count); b=$(pod5_bytes)
  tb=$(awk -v b="$b" 'BEGIN{printf "%.2f", b/1099511627776}')
  if [[ "$n" -gt 0 ]]; then
    printf "    ${C_GRN}[OK]${C_RST} %-12s ${C_GRY}%s  (%s berkas .pod5, %s TB)${C_RST}\n" 'input POD5' "$POD5_INPUT" "$n" "$tb"
  else
    printf "    ${C_RED}[!!]${C_RST} %-12s ${C_GRY}%s tidak ada / kosong${C_RST}\n" 'input POD5' "$POD5_INPUT"
  fi
  local fg; fg=$(free_gb "$OUTPUT")
  if [[ -n "$fg" && "$fg" -ge "$MIN_FREE_GB" ]]; then
    printf "    ${C_GRN}[OK]${C_RST} %-12s ${C_GRY}sisa %s GB (butuh >= %s GB)${C_RST}\n" 'drive output' "$fg" "$MIN_FREE_GB"
  else
    printf "    ${C_RED}[!!]${C_RST} %-12s ${C_GRY}sisa ${fg:-?} GB, butuh >= %s GB${C_RST}\n" 'drive output' "$MIN_FREE_GB"
  fi
  if [[ -r /sys/class/power_supply/AC/online ]]; then
    if [[ "$(cat /sys/class/power_supply/AC/online)" == "1" ]]; then
      printf "    ${C_GRN}[OK]${C_RST} %-12s ${C_GRY}terhubung adaptor (laptop)${C_RST}\n" 'daya'
    else
      printf "    ${C_RED}[!!]${C_RST} %-12s ${C_GRY}MASIH BATERAI - colok adaptor${C_RST}\n" 'daya'
    fi
  fi
  echo
  echo "  Marathon berhenti sendiri setelah -dd hari, atau tekan Ctrl+C."
  echo
}

# ---------------------------------------------------------------- guardrail otomatis

POD5_BYTES=$(pod5_bytes)
MIN_FREE_AUTO=""
if [[ "$MIN_FREE_GB" -eq 0 ]]; then MIN_FREE_GB=$(auto_min_free "$POD5_BYTES"); MIN_FREE_AUTO=1; fi
MAX_TEMP_AUTO=""
if [[ "$MAX_TEMP_C" -eq 0 ]]; then MAX_TEMP_C=$(auto_max_temp); MAX_TEMP_AUTO=1; fi

[[ $SHOW_HELP -eq 1 ]] && { show_help; exit 0; }
[[ $DO_HW -eq 1 ]] && { hw_check; exit $?; }

if [[ $DO_REPORT -eq 1 ]]; then
  [[ -n "$PY" ]] || {
    echo "${C_RED}[ERROR] python3 tidak ada - laporan tidak bisa dibuat.${C_RST}"
    echo "${C_RED}        Pasang dengan: sudo apt install python3${C_RST}"
    exit 1
  }
  "$PY" "$REPORT_PY" "$OUTPUT" --final --model "$MODEL" --device "$DEVICE"
  exit $?
fi

# ---------------------------------------------------------------- setup

if [[ $SETUP -eq 1 ]]; then
  echo; echo "${C_CYN}  SETUP - memeriksa dorado dan model${C_RST}"; echo
  if ! DORADO=$(install_dorado | tail -1); then
    echo "${C_RED}[ERROR] Setup dorado gagal. Marathon dibatalkan.${C_RST}"; exit 1
  fi
  DORADO_EXPLICIT=1
  [[ -n "$MODEL_CACHE" ]] || MODEL_CACHE="$(dirname "$(dirname "$DORADO")")/models"
  install_model "$DORADO" "$MODEL_CACHE"
  echo
fi

if hit=$(find_dorado); then
  DORADO="${hit%%|*}"
  [[ "${hit##*|}" == "-d" ]] || echo "${C_CYN}[INFO] Dorado dipilih otomatis: ${hit##*|}${C_RST}"
else
  echo "${C_RED}[ERROR] Dorado tidak ditemukan. Pakai -su untuk memasang, atau -d <jalur>.${C_RST}"
  exit 1
fi
[[ -n "$MODEL_CACHE" ]] || MODEL_CACHE="$(dirname "$(dirname "$DORADO")")/models"

[[ -d "$POD5_INPUT" ]] || { echo "${C_RED}[ERROR] Folder POD5 '$POD5_INPUT' tidak ada!${C_RST}"; exit 1; }
mkdir -p "$OUTPUT" "$MODEL_CACHE"

END_EPOCH=$(awk -v d="$DAY_DURATION" 'BEGIN{printf "%d", systime() + d*86400}')

{
  echo "Dorado      : $DORADO"
  echo "Model       : $MODEL"
  echo "Model cache : $MODEL_CACHE"
  echo "Input POD5  : $POD5_INPUT"
  echo "Output      : $OUTPUT"
  echo "Device      : $DEVICE"
  echo "Recursive   : $RECURSIVE"
  echo "Durasi      : $DAY_DURATION hari (selesai $(date -d "@$END_EPOCH" '+%Y-%m-%d %H:%M:%S'))"
  echo "Simpan BAM  : $KEEP_BAM"
  echo "Batch/Suhu  : batchsize $([[ $BATCH_SIZE -gt 0 ]] && echo "$BATCH_SIZE" || echo auto), jeda dingin di atas $MAX_TEMP_C C"
  echo "Disk guard  : min sisa $MIN_FREE_GB GB"
  echo "Max reads   : $([[ $MAX_READS -gt 0 ]] && echo "$MAX_READS per loop" || echo 'semua read')"
  echo "Run virtual : $VIRTUAL_TB TB/run"
} | tee "$OUTPUT/RunningParameter.txt" | sed "s/^/${C_GRY}/;s/\$/${C_RST}/"

write_machine_spec "$OUTPUT"

SUMMARY="$OUTPUT/marathon_summary.csv"
[[ -f "$SUMMARY" ]] || echo 'loop,start,end,seconds,exitcode,batchsize,bam_gb,gb_per_hour,pod5_equiv_gb,cum_tb,virtual_runs,gpu_max_temp_c,gpu_avg_util_pct,gpu_avg_power_w,gpu_avg_clock_mhz,status' > "$SUMMARY"

have nvidia-smi || echo "${C_YLW}[WARN] nvidia-smi tidak ada - metrik GPU dilewati.${C_RST}"
[[ -n "$PY" ]] || echo "${C_YLW}[WARN] python3 tidak ada - laporan HTML dan vonis dilewati.${C_RST}"

# Proses anak dibersihkan supaya Ctrl+C tidak meninggalkan dorado/nvidia-smi hidup.
DORADO_PID=""; GPU_PID=""
cleanup() {
  [[ -n "$GPU_PID" ]] && kill "$GPU_PID" 2>/dev/null
  [[ -n "$DORADO_PID" ]] && kill "$DORADO_PID" 2>/dev/null
  wait 2>/dev/null
}
trap cleanup EXIT INT TERM

echo "${C_CYN}Looping Marathon Dorado Dimulai.${C_RST}"
echo "${C_YLW}Tekan [Ctrl + C] untuk menghentikan.${C_RST}"
echo "------------------------------------------------------------------------"

LOOP=1; FAIL_STREAK=0; EFF_BATCH=$BATCH_SIZE; CUM_EQUIV=0; RUNS_DONE=0

while [[ $(date +%s) -lt $END_EPOCH ]]; do

  # --- guard disk ---
  FREE=$(free_gb "$OUTPUT")
  if [[ -n "$FREE" && "$FREE" -lt "$MIN_FREE_GB" ]]; then
    echo "${C_RED}[STOP] Sisa ruang tinggal ${FREE} GB (< $MIN_FREE_GB GB). Marathon dihentikan.${C_RST}"
    break
  fi

  # --- guard suhu ---
  T=$(gpu_temp)
  while [[ "$T" -ge 0 && "$T" -gt "$MAX_TEMP_C" && $(date +%s) -lt $END_EPOCH ]]; do
    echo "${C_YLW}[$(date +%H:%M:%S)] GPU ${T} C > ${MAX_TEMP_C} C - jeda 120 detik.${C_RST}"
    sleep 120
    T=$(gpu_temp)
  done
  [[ $(date +%s) -ge $END_EPOCH ]] && break

  TS=$(date +%Y%m%d_%H%M%S)
  GPU_LOG="$OUTPUT/gpu_loop_${LOOP}_$TS.csv"
  LOG_FILE="$OUTPUT/dorado_loop_${LOOP}_$TS.log"
  OUT_BAM="$OUTPUT/calls_loop_${LOOP}_$TS.bam"
  T_START=$(date +%s); START_STR=$(date '+%Y-%m-%d %H:%M:%S')

  echo "${C_YLW}[$(date +%H:%M:%S)] Memulai Loop ke-${LOOP} (sisa disk ${FREE} GB)${C_RST}"

  GPU_PID=""
  if have nvidia-smi; then
    nvidia-smi --query-gpu=timestamp,temperature.gpu,utilization.gpu,utilization.memory,memory.used,power.draw,clocks.sm \
      --format=csv,nounits -l 10 > "$GPU_LOG" 2>/dev/null &
    GPU_PID=$!
  fi

  ARGS=(basecaller "$MODEL" "$POD5_INPUT" --models-directory "$MODEL_CACHE" --device "$DEVICE")
  [[ $RECURSIVE -eq 1 ]] && ARGS+=(--recursive)
  [[ $EFF_BATCH -gt 0 ]] && ARGS+=(--batchsize "$EFF_BATCH")
  [[ $MAX_READS -gt 0 ]] && ARGS+=(--max-reads "$MAX_READS")

  # systemd-inhibit menahan sistem tidur selama proses berjalan, tanpa mengubah
  # setelan daya secara permanen. Kalau tidak tersedia, dorado dijalankan langsung.
  if have systemd-inhibit; then
    systemd-inhibit --what=idle:sleep:handle-lid-switch --why="Marathon basecalling" \
      "$DORADO" "${ARGS[@]}" > "$OUT_BAM" 2> "$LOG_FILE" &
  else
    "$DORADO" "${ARGS[@]}" > "$OUT_BAM" 2> "$LOG_FILE" &
  fi
  DORADO_PID=$!

  # Hentikan pass yang sedang jalan begitu batas marathon tercapai, supaya
  # -dd 7 benar-benar berarti 7 hari.
  while kill -0 "$DORADO_PID" 2>/dev/null; do
    sleep 10
    if [[ $(date +%s) -ge $END_EPOCH ]]; then
      echo "${C_YLW}[$(date +%H:%M:%S)] Batas $DAY_DURATION hari tercapai - menghentikan loop.${C_RST}"
      kill "$DORADO_PID" 2>/dev/null; sleep 5; kill -9 "$DORADO_PID" 2>/dev/null
      break
    fi
  done
  wait "$DORADO_PID"; CODE=$?
  DORADO_PID=""
  [[ -n "$GPU_PID" ]] && { kill "$GPU_PID" 2>/dev/null; GPU_PID=""; }

  T_END=$(date +%s); END_STR=$(date '+%Y-%m-%d %H:%M:%S'); SECS=$((T_END - T_START))
  BAM_BYTES=$(stat -c%s "$OUT_BAM" 2>/dev/null || echo 0)
  BAM_GB=$(awk -v b="$BAM_BYTES" 'BEGIN{printf "%.2f", b/1073741824}')
  RATE=$(awk -v g="$BAM_GB" -v s="$SECS" 'BEGIN{printf "%.2f", (s>0? g/(s/3600) : 0)}')

  IS_OK=0; IS_OOM=0
  [[ "$CODE" -eq 0 && "$BAM_BYTES" -gt 0 ]] && IS_OK=1

  if [[ $IS_OK -eq 1 ]]; then
    FAIL_STREAK=0
    echo "${C_GRN}[$(date +%H:%M:%S)] SUKSES Loop ke-${LOOP}: $BAM_GB GB dalam ${SECS}s ($RATE GB/jam).${C_RST}"
  else
    if grep -qiE 'out of memory|OutOfMemory|CUDA error: out|cudaErrorMemoryAllocation' "$LOG_FILE" 2>/dev/null; then
      IS_OOM=1
    fi
    if [[ $IS_OOM -eq 1 && "$EFF_BATCH" -ne 64 ]]; then
      if [[ "$EFF_BATCH" -le 0 ]]; then EFF_BATCH=384; else
        EFF_BATCH=$(( EFF_BATCH / 2 )); [[ $EFF_BATCH -lt 64 ]] && EFF_BATCH=64
      fi
      echo "${C_YLW}[$(date +%H:%M:%S)] Kehabisan VRAM - batchsize diturunkan ke $EFF_BATCH.${C_RST}"
    else
      FAIL_STREAK=$((FAIL_STREAK + 1))
    fi
    echo "${C_RED}[$(date +%H:%M:%S)] GAGAL Loop ke-${LOOP} (exit=$CODE, bam=$BAM_GB GB) - beruntun ke-$FAIL_STREAK.${C_RST}"
    tail -5 "$LOG_FILE" 2>/dev/null | sed "s/^/  ${C_GRY}[dorado] /;s/\$/${C_RST}/"
  fi

  [[ $KEEP_BAM -eq 0 ]] && rm -f "$OUT_BAM"

  EQUIV=$(awk -v g="$BAM_GB" 'BEGIN{printf "%.1f", (g>0 ? g/0.09 : 0)}')
  CUM_EQUIV=$(awk -v a="$CUM_EQUIV" -v b="$EQUIV" 'BEGIN{printf "%.1f", a+b}')
  CUM_TB=$(awk -v c="$CUM_EQUIV" 'BEGIN{printf "%.3f", c/1024}')
  RUNS_DONE=$(awk -v c="$CUM_EQUIV" -v v="$VIRTUAL_TB" 'BEGIN{printf "%.2f", (v>0 ? c/(v*1024) : 0)}')
  echo "${C_GRY}  Emulasi: +$EQUIV GB POD5-setara | total $CUM_TB TB = $RUNS_DONE run virtual${C_RST}"

  # Ringkasan metrik GPU loop ini. Kolom dicari berdasarkan kecocokan sebagian
  # nama supaya tahan terhadap perbedaan header antar versi driver.
  read -r G_TEMP G_UTIL G_POW G_CLK <<< "$(
    awk -F', *' 'NR==1{
        for(i=1;i<=NF;i++){
          if($i ~ /temperature\.gpu/) t=i
          if($i ~ /utilization\.gpu/) u=i
          if($i ~ /power\.draw/)      p=i
          if($i ~ /clocks/)           c=i
        }; next
      }
      { if(t && $t+0>mt) mt=$t+0
        if(u){su+=$u; nu++}
        if(p){sp+=$p; np++}
        if(c){sc+=$c; nc++} }
      END{ printf "%d %d %d %d", mt, (nu?su/nu:0), (np?sp/np:0), (nc?sc/nc:0) }' \
      "$GPU_LOG" 2>/dev/null || echo "0 0 0 0"
  )"
  if [[ "${G_TEMP:-0}" -gt 0 ]]; then
    echo "${C_GRY}  GPU: suhu maks ${G_TEMP} C | util ${G_UTIL}% | daya ${G_POW} W | clock SM ${G_CLK} MHz${C_RST}"
  else
    G_TEMP=""; G_UTIL=""; G_POW=""; G_CLK=""
  fi

  STATUS=$([[ $IS_OK -eq 1 ]] && echo OK || { [[ $IS_OOM -eq 1 ]] && echo OOM || echo FAIL; })
  echo "$LOOP,$START_STR,$END_STR,$SECS,$CODE,$([[ $EFF_BATCH -gt 0 ]] && echo "$EFF_BATCH" || echo auto),$BAM_GB,$RATE,$EQUIV,$CUM_TB,$RUNS_DONE,$G_TEMP,$G_UTIL,$G_POW,$G_CLK,$STATUS" >> "$SUMMARY"

  # Laporan dibangun ulang tiap loop supaya bisa dibaca tanpa menunggu 7 hari.
  [[ -n "$PY" ]] && "$PY" "$REPORT_PY" "$OUTPUT" --model "$MODEL" --device "$DEVICE" >/dev/null 2>&1

  if awk -v r="$RUNS_DONE" -v t="$VIRTUAL_RUNS" 'BEGIN{exit !(t>0 && r>=t)}'; then
    echo "${C_GRN}[SELESAI] Target $VIRTUAL_RUNS run virtual tercapai ($CUM_TB TB).${C_RST}"; break
  fi
  if [[ "$FAIL_STREAK" -ge "$MAX_FAIL" ]]; then
    echo "${C_RED}[STOP] $FAIL_STREAK loop gagal beruntun. Periksa $LOG_FILE.${C_RST}"; break
  fi
  [[ $IS_OK -eq 1 ]] || sleep 15

  LOOP=$((LOOP + 1))
  echo "------------------------------------------------------------------------"
done

echo
echo "${C_CYN}Total dibasecall: $CUM_TB TB POD5-setara = $RUNS_DONE run virtual @ $VIRTUAL_TB TB.${C_RST}"
echo "${C_CYN}Marathon selesai. Ringkasan per loop: $SUMMARY${C_RST}"
if [[ -n "$PY" ]]; then
  "$PY" "$REPORT_PY" "$OUTPUT" --final --model "$MODEL" --device "$DEVICE"
else
  echo "${C_YLW}[WARN] python3 tidak ada - laporan HTML dilewati. Pasang: sudo apt install python3${C_RST}"
fi
