<#
.SYNOPSIS
    Dorado basecaller marathon loop.

.EXAMPLE
    .\BasecallScript.ps1 -h

.EXAMPLE
    .\BasecallScript.ps1 -i D:\pod5_pass -o D:\hasil -dd 3

.EXAMPLE
    .\BasecallScript.ps1 -Dorado "C:\dorado\bin\dorado.exe" -Model "dna_r10.4.1_e8.2_400bps_hac@v5.2.0"
#>

[CmdletBinding()]
param(
    # -d / -Dorado : lokasi dorado.exe
    [Alias('d')]
    [string]$Dorado      = "C:\dorado-2.0.0-win64\bin\dorado.exe",

    # -mc / -ModelCache : folder cache model (--models-directory)
    [Alias('mc')]
    [string]$ModelCache  = "C:\dorado-2.0.0-win64\bin\models",

    # -m / -Model : nama model basecalling
    [Alias('m')]
    [string]$Model       = "dna_r10.4.1_e8.2_400bps_hac@v5.2.0_5mC_5hmC@v1",

    # -i / -Input / -Pod5Input : folder input POD5
    [Alias('i', 'input')]
    [string]$Pod5Input   = "D:\pod5_pass",

    # -o / -Output : folder output (default: D:\Output_dorado_<timestamp>)
    [Alias('o')]
    [string]$Output      = "D:\Output_dorado_$(Get-Date -Format 'yyyyMMdd')",

    # -dd / -Duration / -DayDuration : lama marathon dalam hari
    [Alias('dd', 'duration')]
    [ValidateRange(0, 3650)]
    [double]$DayDuration = 7,

    # -kb / -KeepBam : simpan BAM tiap loop (default: dihapus setelah divalidasi)
    [Alias('kb')]
    [switch]$KeepBam,

    # -mf / -MinFreeGB : berhenti kalau sisa ruang drive output di bawah ini.
    # 0 = auto, dihitung dari ukuran POD5 input (BAM ~ 9% POD5 menurut tabel ONT).
    [Alias('mf')]
    [ValidateRange(0, 100000)]
    [int]$MinFreeGB = 0,

    # -mfail / -MaxFail : berhenti setelah sekian loop gagal beruntun
    [Alias('mfail')]
    [ValidateRange(1, 1000)]
    [int]$MaxFail = 3,

    # -r / -Recursive : sisir subfolder POD5 (barcode dsb)
    [Alias('r')]
    [switch]$Recursive,

    # -dev / -Device : target dorado, mis. cuda:all / cuda:0 / cpu
    [Alias('dev')]
    [string]$Device = 'cuda:all',

    # -b / -BatchSize : batch dorado. 0 = auto (dorado yang pilih sesuai VRAM tiap mesin).
    # Kalau tetap OOM, skrip otomatis turunkan batch sendiri - tidak perlu diatur manual.
    [Alias('b')]
    [ValidateRange(0, 4096)]
    [int]$BatchSize = 0,

    # -mt / -MaxTempC : tunggu GPU dingin dulu kalau suhu di atas ini sebelum loop baru.
    # 0 = auto, diambil dari ambang slowdown GPU itu sendiri dikurangi 5 C.
    [Alias('mt')]
    [ValidateRange(0, 120)]
    [int]$MaxTempC = 0,

    # -mr / -MaxReads : batasi jumlah read per loop. 0 = semua.
    # Untuk benchmark ADIL antar mesin: beban kerjanya harus persis sama, bukan "sama-sama 1 jam".
    [Alias('mr')]
    [ValidateRange(0, 100000000)]
    [int]$MaxReads = 0,

    # -vt / -VirtualTB : ukuran satu "run virtual" dalam TB POD5. Default 1.3 = satu flow cell P2 Solo.
    # Dipakai supaya POD5 0.5 TB bisa mengemulasi beban 1.3 TB: loop diulang sampai
    # akumulasi data yang dibasecall setara satu run penuh. 0 = matikan pelacakan ini.
    [Alias('vt')]
    [double]$VirtualTB = 1.3,

    # -vr / -VirtualRuns : berhenti setelah sekian run virtual selesai. 0 = jalan sampai -dd habis.
    [Alias('vr')]
    [ValidateRange(0, 1000)]
    [double]$VirtualRuns = 0,

    # -as / -AllowSleep : izinkan Windows tidur (default: ditahan supaya marathon tidak putus)
    [Alias('as')]
    [switch]$AllowSleep,

    # -su / -Setup : cek dulu; kalau dorado atau model belum ada, baru diunduh
    [Alias('su')]
    [switch]$Setup,

    # -dv / -DoradoVersion : versi yang diunduh -su
    [Alias('dv')]
    [string]$DoradoVersion = '2.1.2',

    # -sd / -SetupDir : tujuan pemasangan dorado. Kosong = drive dengan ruang terbanyak.
    [Alias('sd')]
    [string]$SetupDir = '',

    # -hw / -Hardware : periksa kondisi diam mesin (suhu, beban, jenis disk), lalu keluar
    [Alias('hw')]
    [switch]$Hardware,

    # -rep / -Report : baca marathon_summary.csv di -o, keluarkan vonis kelayakan, lalu keluar
    [Alias('rep')]
    [switch]$Report,

    # -h / -Help : tampilkan cara pakai + cek prasyarat, lalu keluar
    [Alias('h')]
    [switch]$Help
)

Clear-Host

# Untuk deteksi baterai/adaptor pada laptop (PowerStatus).
Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue

# ========================================================================
# 1. CONFIGURATION (nilai berasal dari flag di atas / default)
# ========================================================================
$EndTime = (Get-Date).AddDays($DayDuration)

# ========================================================================
# 2. VALIDATION (Memastikan Semua Jalur Siap Sebelum Running)
# ========================================================================

# --- Cari dorado: folder dorado-#.#.#-win64 versi tertinggi, jalur eksplisit, atau PATH ---

# Kumpulkan folder induk yang masuk akal untuk disisir (kedalaman 1 saja, jadi cepat).
function Get-DoradoSearchRoots {
    param([string]$HintPath)

    $roots = New-Object System.Collections.Generic.List[string]

    # Folder yang memuat folder versi dari jalur default / -d, mis. C:\ dari C:\dorado-2.0.0-win64\bin\dorado.exe
    $verFolder = Split-Path (Split-Path $HintPath -Parent) -Parent
    if ($verFolder) {
        $parent = Split-Path $verFolder -Parent
        if ($parent) { $roots.Add($parent) }
    }

    # Semua drive fixed yang siap (hindari Get-PSDrive: drive jaringan bisa menggantung)
    foreach ($drv in [System.IO.DriveInfo]::GetDrives()) {
        if ($drv.IsReady -and $drv.DriveType -eq 'Fixed') { $roots.Add($drv.RootDirectory.FullName) }
    }

    foreach ($p in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, "$env:LOCALAPPDATA\Programs")) {
        if ($p) { $roots.Add($p) }
    }

    return $roots | Where-Object { $_ } | Select-Object -Unique
}

# Semua instalasi dorado-#.#.#-win64 yang punya bin\dorado.exe, versi TERBESAR di depan.
function Find-DoradoInstalls {
    param([string]$HintPath)

    $found = @()
    foreach ($root in (Get-DoradoSearchRoots -HintPath $HintPath)) {
        $dirs = Get-ChildItem -LiteralPath $root -Directory -Filter 'dorado-*-win64' -ErrorAction SilentlyContinue
        foreach ($dir in $dirs) {
            $m = [regex]::Match($dir.Name, '^dorado-(\d+)\.(\d+)\.(\d+)-win64$')
            if (-not $m.Success) { continue }
            $exe = Join-Path $dir.FullName 'bin\dorado.exe'
            if (!(Test-Path -LiteralPath $exe -PathType Leaf)) { continue }
            $found += [PSCustomObject]@{
                Version = [version]("{0}.{1}.{2}" -f $m.Groups[1].Value, $m.Groups[2].Value, $m.Groups[3].Value)
                Source  = $exe
            }
        }
    }

    return $found | Sort-Object Version -Descending -Unique
}

function Get-DoradoFromPath {
    param([string]$Name)
    $cmd = Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue |
           Select-Object -First 1
    if ($cmd) { return [PSCustomObject]@{ Source = $cmd.Source; From = 'PATH' } }
    return $null
}

function Resolve-Dorado {
    param([string]$Path, [bool]$Explicit)

    # A. Kalau -d diberikan user, jalur itu yang menang.
    if ($Explicit) {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            return [PSCustomObject]@{ Source = (Resolve-Path -LiteralPath $Path).ProviderPath; From = '-d' }
        }
        # Mungkin cuma nama perintah, mis. -d dorado
        $hit = Get-DoradoFromPath -Name $Path
        if ($hit) { return $hit }

        # Jalur lengkap tapi foldernya salah -> cari nama filenya di PATH
        $leaf = Split-Path -Path $Path -Leaf
        if ($leaf -and $leaf -ne $Path) {
            $hit = Get-DoradoFromPath -Name $leaf
            if ($hit) { return $hit }
        }
    }

    # B. Sisir folder dorado-#.#.#-win64, pakai versi tertinggi.
    $installs = @(Find-DoradoInstalls -HintPath $Path)
    if ($installs.Count -gt 0) {
        $best = $installs[0]
        $others = ($installs | Select-Object -Skip 1 | ForEach-Object { $_.Version }) -join ', '
        return [PSCustomObject]@{
            Source = $best.Source
            From   = "versi tertinggi v$($best.Version)$(if ($others) { " (lain: $others)" })"
        }
    }

    # C. Terakhir: jalur default apa adanya, lalu PATH.
    if (!$Explicit) {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            return [PSCustomObject]@{ Source = (Resolve-Path -LiteralPath $Path).ProviderPath; From = 'default' }
        }
        $hit = Get-DoradoFromPath -Name 'dorado'
        if ($hit) { return $hit }
    }

    return $null
}

# $PSBoundParameters di dalam sebuah fungsi merujuk ke parameter FUNGSI itu,
# bukan parameter script, jadi statusnya ditangkap di sini dulu.
$DoradoExplicit = $PSBoundParameters.ContainsKey('Dorado')
$McExplicit     = $PSBoundParameters.ContainsKey('ModelCache')

# --- Auto-detect guardrail: dipakai kalau -mf / -mt tidak diisi user ---

# Ambang slowdown GPU (suhu saat driver mulai menurunkan clock), dikurangi margin 5 C.
# Diambil dari GPU-nya sendiri, jadi cocok untuk laptop maupun tower tanpa disetel manual.
function Get-AutoMaxTempC {
    $fallback = 87
    try {
        if (-not (Get-Command 'nvidia-smi.exe' -CommandType Application -ErrorAction SilentlyContinue)) { return $fallback }
        $q = & nvidia-smi.exe -q -d TEMPERATURE 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $q) { return $fallback }
        $slow = @($q | Select-String -Pattern 'Slowdown Temp\s*:\s*(\d+)' -AllMatches |
                       ForEach-Object { [int]$_.Matches[0].Groups[1].Value } |
                       Where-Object { $_ -gt 40 })
        if ($slow) { return (($slow | Measure-Object -Minimum).Minimum - 5) }
    } catch { }
    return $fallback
}

# Total byte POD5 di folder input (dipakai untuk memperkirakan besar BAM per loop).
function Get-Pod5Bytes {
    param([string]$Path, [bool]$Deep)
    try {
        if (!(Test-Path -LiteralPath $Path -PathType Container)) { return 0L }
        $sum = (Get-ChildItem -LiteralPath $Path -Filter *.pod5 -File -Recurse:$Deep -ErrorAction SilentlyContinue |
                Measure-Object Length -Sum).Sum
        if ($sum) { return [long]$sum }
    } catch { }
    return 0L
}

# BAM tak-sejajar dengan modifikasi ~ 9% ukuran POD5 (tabel ONT: 60 GB BAM per 700 GB POD5).
# Ambang disk = 1.5x satu BAM, supaya masih muat satu loop penuh plus ruang napas.
function Get-AutoMinFreeGB {
    param([long]$Pod5Bytes)
    if ($Pod5Bytes -le 0) { return 50 }
    $bamGB = ($Pod5Bytes / 1GB) * 0.09
    $need  = [math]::Ceiling($bamGB * 1.5)
    if ($need -lt 20) { $need = 20 }
    return [int]$need
}


# ========================================================================
# LAPORAN KELAYAKAN (-rep) - menilai hasil, bukan menjalankan basecalling
# ========================================================================

# Ambang laju tiap tingkat, dalam GB POD5-setara per jam.
# Diturunkan dari POD5 target dibagi durasi run standar 72 jam.
$script:Tiers = @(
    [PSCustomObject]@{ Name='T4'; Rate=57; Desc='P2 Solo, 2 flow cell, keluaran maksimum (TMO)' }
    [PSCustomObject]@{ Name='T3'; Rate=37; Desc='P2 Solo, 2 flow cell, keluaran nominal' }
    [PSCustomObject]@{ Name='T2'; Rate=19; Desc='P2 Solo, 1 flow cell' }
    [PSCustomObject]@{ Name='T1'; Rate=3;  Desc='MinION Mk1B, 1 flow cell' }
)

function Get-Median {
    param([double[]]$Values)
    if (-not $Values -or $Values.Count -eq 0) { return $null }
    $v = @($Values | Sort-Object)
    $n = $v.Count
    if ($n % 2 -eq 1) { return $v[[int](($n - 1) / 2)] }
    return (($v[[int]($n / 2) - 1] + $v[[int]($n / 2)]) / 2)
}

function ConvertTo-Time {
    param([string]$Text)
    $dt = [datetime]::MinValue
    $ok = [datetime]::TryParseExact($Text, 'yyyy-MM-dd HH:mm:ss',
              [Globalization.CultureInfo]::InvariantCulture, 0, [ref]$dt)
    if ($ok) { return $dt }
    return $null
}

# Laju POD5-setara per jam untuk satu baris ringkasan.
function Get-RowRate {
    param($Row)
    $secs = 0.0; $equiv = 0.0
    [void][double]::TryParse($Row.seconds, [ref]$secs)
    [void][double]::TryParse($Row.pod5_equiv_gb, [ref]$equiv)
    if ($secs -le 0) { return $null }
    return $equiv / ($secs / 3600.0)
}

function Show-Report {
    param([string]$Csv)

    if (!(Test-Path -LiteralPath $Csv)) {
        Write-Host "[ERROR] Tidak ada $Csv - jalankan marathon dulu, atau tunjuk foldernya dengan -o." -ForegroundColor Red
        return 1
    }
    $rows = @(Import-Csv -LiteralPath $Csv -ErrorAction SilentlyContinue)
    if ($rows.Count -eq 0) {
        Write-Host "[ERROR] $Csv kosong." -ForegroundColor Red
        return 1
    }

    $ok = @($rows | Where-Object { $_.status -eq 'OK' })
    # Loop pertama selalu lebih lambat: unduh model dan cache disk masih dingin.
    $bench = @($ok | Select-Object -Skip 1)

    Write-Host ""
    Write-Host "  LAPORAN KELAYAKAN BASECALLING" -ForegroundColor Cyan
    Write-Host "  $Csv" -ForegroundColor DarkGray
    Write-Host ""

    if ($bench.Count -eq 0) {
        Write-Host "  Belum ada loop sukses di luar loop pertama - laporan butuh minimal 2 loop OK." -ForegroundColor Yellow
        Write-Host ""
        return 1
    }

    # ---------------- Cakupan pengujian ----------------
    $t0 = ConvertTo-Time $rows[0].start
    $t1 = ConvertTo-Time $rows[-1].end
    $spanH = if ($t0 -and $t1) { [math]::Round(($t1 - $t0).TotalHours, 1) } else { 0 }
    $cumTB = $rows[-1].cum_tb

    Write-Host "  CAKUPAN" -ForegroundColor White
    Write-Host ("    {0,-22}{1}" -f 'Total loop',      $rows.Count)          -ForegroundColor Gray
    Write-Host ("    {0,-22}{1}" -f 'Loop sukses',     $ok.Count)            -ForegroundColor Gray
    Write-Host ("    {0,-22}{1} jam" -f 'Durasi',      $spanH)               -ForegroundColor Gray
    Write-Host ("    {0,-22}{1} TB POD5-setara" -f 'Data diproses', $cumTB)  -ForegroundColor Gray
    Write-Host ""

    # ---------------- A. Benchmark kemampuan ----------------
    $rates = @($bench | ForEach-Object { Get-RowRate $_ } | Where-Object { $_ -ne $null })
    $med   = Get-Median -Values $rates
    $med   = [math]::Round($med, 1)
    $spread = 0
    if ($rates.Count -gt 1 -and $med -gt 0) {
        $mn = ($rates | Measure-Object -Minimum).Minimum
        $mx = ($rates | Measure-Object -Maximum).Maximum
        $spread = [math]::Round((($mx - $mn) / $med) * 100, 1)
    }

    Write-Host "  UJI A - KEMAMPUAN" -ForegroundColor White
    Write-Host ("    {0,-22}{1} GB POD5/jam  (median {2} loop, loop pertama dibuang)" -f `
        'Laju terukur', $med, $bench.Count) -ForegroundColor Gray
    Write-Host ("    {0,-22}{1}%" -f 'Sebaran antar-loop', $spread) -ForegroundColor Gray
    Write-Host ""

    $reached = $null
    foreach ($t in $script:Tiers) {
        $pass = ($med -ge $t.Rate)
        if ($pass -and -not $reached) { $reached = $t }
        $mark = if ($pass) { '[LULUS]' } else { '[  -  ]' }
        $col  = if ($pass) { 'Green' } else { 'DarkGray' }
        Write-Host ("    {0} {1,-4}{2,5} GB/jam   {3}" -f $mark, $t.Name, $t.Rate, $t.Desc) -ForegroundColor $col
    }
    Write-Host ""

    # ---------------- Keabsahan pengukuran ----------------
    $pw = @($bench | ForEach-Object { $_.gpu_avg_power_w } | Where-Object { $_ -match '\d' } | ForEach-Object { [double]$_ })
    $ck = @($bench | ForEach-Object { $_.gpu_avg_clock_mhz } | Where-Object { $_ -match '\d' } | ForEach-Object { [double]$_ })
    $avgPw = if ($pw) { [math]::Round(($pw | Measure-Object -Average).Average, 0) } else { $null }
    $avgCk = if ($ck) { [math]::Round(($ck | Measure-Object -Average).Average, 0) } else { $null }

    $limPw = $null; $limCk = $null
    try {
        if (Get-Command 'nvidia-smi.exe' -CommandType Application -ErrorAction SilentlyContinue) {
            $q = & nvidia-smi.exe --query-gpu=power.limit,clocks.max.sm --format=csv,noheader,nounits 2>$null
            if ($LASTEXITCODE -eq 0 -and $q) {
                $parts = ("$($q | Select-Object -First 1)" -split ',')
                if ($parts.Count -ge 2) { $limPw = [double]$parts[0].Trim(); $limCk = [double]$parts[1].Trim() }
            }
        }
    } catch { }

    Write-Host "  KEABSAHAN PENGUKURAN" -ForegroundColor White
    $validIssues = @()

    if ($null -ne $avgPw -and $limPw) {
        $pct = [math]::Round(($avgPw / $limPw) * 100, 0)
        $good = ($pct -ge 70)
        if (-not $good) { $validIssues += "daya hanya $pct% TDP - GPU kemungkinan menunggu data" }
        Write-Host ("    {0} {1,-20}{2} W dari {3} W ({4}% TDP, syarat >= 70%)" -f `
            $(if ($good) {'[OK]'} else {'[!!]'}), 'Daya rata-rata', $avgPw, $limPw, $pct) `
            -ForegroundColor $(if ($good) {'Green'} else {'Red'})
    } elseif ($null -ne $avgPw) {
        Write-Host ("    [??] {0,-20}{1} W (TDP tidak terbaca, rasio tak dihitung)" -f 'Daya rata-rata', $avgPw) -ForegroundColor DarkYellow
    } else {
        Write-Host ("    [??] {0,-20}tidak terekam" -f 'Daya rata-rata') -ForegroundColor DarkYellow
    }

    if ($null -ne $avgCk -and $limCk) {
        $pct = [math]::Round(($avgCk / $limCk) * 100, 0)
        $good = ($pct -ge 90)
        if (-not $good) { $validIssues += "clock SM hanya $pct% dari maksimum - ada pembatasan termal atau daya" }
        Write-Host ("    {0} {1,-20}{2} MHz dari {3} MHz ({4}%, syarat >= 90%)" -f `
            $(if ($good) {'[OK]'} else {'[!!]'}), 'Clock SM rata-rata', $avgCk, $limCk, $pct) `
            -ForegroundColor $(if ($good) {'Green'} else {'Red'})
    } elseif ($null -ne $avgCk) {
        Write-Host ("    [??] {0,-20}{1} MHz (batas tidak terbaca)" -f 'Clock SM rata-rata', $avgCk) -ForegroundColor DarkYellow
    }

    $spreadOk = ($spread -lt 5)
    if (-not $spreadOk) { $validIssues += "sebaran antar-loop $spread% melebihi 5%" }
    Write-Host ("    {0} {1,-20}{2}% (syarat < 5%)" -f `
        $(if ($spreadOk) {'[OK]'} else {'[!!]'}), 'Sebaran laju', $spread) `
        -ForegroundColor $(if ($spreadOk) {'Green'} else {'Red'})
    Write-Host ""

    # ---------------- B. Durability ----------------
    # Bandingkan jendela awal dan akhir. Kalau pengujian cukup panjang, pakai 24 jam
    # di tiap ujung; kalau lebih pendek, pakai seperempat loop di tiap ujung.
    $durOk = $true; $durNotes = @()
    $useWindow = ($spanH -ge 48)
    if ($useWindow -and $t0 -and $t1) {
        $early = @($bench | Where-Object { $d = ConvertTo-Time $_.start; $d -and ($d - $t0).TotalHours -le 24 })
        $late  = @($bench | Where-Object { $d = ConvertTo-Time $_.start; $d -and ($t1 - $d).TotalHours -le 24 })
    } else {
        $qn = [math]::Max(1, [int][math]::Floor($bench.Count / 4))
        $early = @($bench | Select-Object -First $qn)
        $late  = @($bench | Select-Object -Last  $qn)
    }

    Write-Host "  UJI B - KETAHANAN" -ForegroundColor White

    $rEarly = Get-Median -Values @($early | ForEach-Object { Get-RowRate $_ } | Where-Object { $_ -ne $null })
    $rLate  = Get-Median -Values @($late  | ForEach-Object { Get-RowRate $_ } | Where-Object { $_ -ne $null })
    if ($rEarly -and $rEarly -gt 0 -and $rLate) {
        $ret = [math]::Round($rLate / $rEarly, 3)
        $good = ($ret -ge 0.90)
        if (-not $good) { $durOk = $false; $durNotes += "laju merosot ke $([math]::Round($ret*100,0))% dari awal" }
        Write-Host ("    {0} {1,-22}{2}  (akhir {3} / awal {4} GB/jam, syarat >= 0.90)" -f `
            $(if ($good) {'[OK]'} else {'[!!]'}), 'Retensi laju', $ret,
            [math]::Round($rLate,1), [math]::Round($rEarly,1)) `
            -ForegroundColor $(if ($good) {'Green'} else {'Red'})
    } else {
        Write-Host ("    [??] {0,-22}data belum cukup" -f 'Retensi laju') -ForegroundColor DarkYellow
    }

    $avail = [math]::Round($ok.Count / $rows.Count, 3)
    $good = ($avail -ge 0.99)
    if (-not $good) { $durOk = $false; $durNotes += "ketersediaan $avail di bawah 0.99" }
    Write-Host ("    {0} {1,-22}{2}  ({3} OK dari {4} loop, syarat >= 0.99)" -f `
        $(if ($good) {'[OK]'} else {'[!!]'}), 'Ketersediaan', $avail, $ok.Count, $rows.Count) `
        -ForegroundColor $(if ($good) {'Green'} else {'Red'})

    $hardFail = @($rows | Where-Object { $_.status -eq 'FAIL' }).Count
    $good = ($hardFail -eq 0)
    if (-not $good) { $durOk = $false; $durNotes += "$hardFail loop gagal tanpa pemulihan" }
    Write-Host ("    {0} {1,-22}{2}  (syarat 0)" -f `
        $(if ($good) {'[OK]'} else {'[!!]'}), 'Gagal tak pulih', $hardFail) `
        -ForegroundColor $(if ($good) {'Green'} else {'Red'})

    $oomCount = @($rows | Where-Object { $_.status -eq 'OOM' }).Count
    $good = ($oomCount -le 1)
    if (-not $good) { $durOk = $false; $durNotes += "$oomCount kali kehabisan VRAM" }
    Write-Host ("    {0} {1,-22}{2}  (syarat <= 1)" -f `
        $(if ($good) {'[OK]'} else {'[!!]'}), 'Kehabisan VRAM', $oomCount) `
        -ForegroundColor $(if ($good) {'Green'} else {'Red'})

    $tE = @($early | ForEach-Object { $_.gpu_max_temp_c } | Where-Object { $_ -match '\d' } | ForEach-Object { [int]$_ })
    $tL = @($late  | ForEach-Object { $_.gpu_max_temp_c } | Where-Object { $_ -match '\d' } | ForEach-Object { [int]$_ })
    if ($tE -and $tL) {
        $dT = [int](($tL | Measure-Object -Maximum).Maximum - ($tE | Measure-Object -Maximum).Maximum)
        $good = ($dT -le 3)
        if (-not $good) { $durNotes += "suhu maksimum naik $dT C dari awal ke akhir" }
        Write-Host ("    {0} {1,-22}{2} C  (syarat <= +3 C)" -f `
            $(if ($good) {'[OK]'} else {'[!!]'}), 'Kenaikan suhu', $dT) `
            -ForegroundColor $(if ($good) {'Green'} else {'DarkYellow'})
    }
    Write-Host ""

    # ---------------- Vonis ----------------
    Write-Host "  VONIS" -ForegroundColor White
    if (-not $reached) {
        Write-Host "    Laju $med GB/jam di bawah T1 - tidak memadai untuk basecalling real-time." -ForegroundColor Red
        Write-Host "    Masih layak dipakai untuk basecalling offline setelah run selesai." -ForegroundColor Gray
    } else {
        Write-Host ("    Tingkat tercapai : {0} - {1}" -f $reached.Name, $reached.Desc) -ForegroundColor Green
        if ($durOk) {
            Write-Host ("    Ketahanan        : LULUS - sanggup dipakai berkelanjutan pada tingkat {0}." -f $reached.Name) -ForegroundColor Green
        } else {
            Write-Host "    Ketahanan        : TIDAK LULUS - hanya layak untuk basecalling offline." -ForegroundColor Red
            foreach ($n in $durNotes) { Write-Host "                       - $n" -ForegroundColor DarkYellow }
        }
    }
    if ($validIssues.Count -gt 0) {
        Write-Host ""
        Write-Host "    Peringatan keabsahan - angka di atas belum tentu menggambarkan GPU:" -ForegroundColor DarkYellow
        foreach ($n in $validIssues) { Write-Host "      - $n" -ForegroundColor DarkYellow }
    }
    Write-Host ""
    return 0
}


# ========================================================================
# LAPORAN HARIAN HTML - report_<tanggal>.html + report.html sebagai indeks
# ========================================================================
# Dibuat ulang dari marathon_summary.csv setiap loop selesai, jadi laporan
# selalu mutakhir walau marathon masih berjalan. Berkas CSV tidak diubah.

function Get-TierName {
    param([double]$Rate)
    foreach ($t in $script:Tiers) { if ($Rate -ge $t.Rate) { return $t.Name } }
    return '-'
}

function ConvertTo-Html {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    return ($Text -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;')
}

function Get-ReportCss {
    return @'
<style>
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
a{color:#0b3d62}
.foot{margin-top:28px;padding-top:12px;border-top:1px solid #dbe3ea;font-size:12px;color:#5a6a78}
@media(max-width:700px){td,th{white-space:normal}}
</style>
'@
}

# Ringkasan statistik satu kelompok baris (satu hari, atau seluruh run).
function Get-DayStats {
    param($Rows)

    # Catatan PS 5.1: @($list) pada List[object] berisi objek CSV melempar
    # "Argument types do not match". Pipa aman, jadi konversi lewat pipa.
    $all = @($Rows | ForEach-Object { $_ })
    $ok  = @($all | Where-Object { $_.status -eq 'OK' })

    # Kolom numerik diambil satu per satu; baris yang bukan angka diabaikan.
    $rates = @()
    $equiv = @(); $temps = @(); $pows = @(); $clks = @()
    foreach ($r in $ok) {
        $v = Get-RowRate $r
        if ($null -ne $v) { $rates += [double]$v }
        if ("$($r.pod5_equiv_gb)"     -match '^\s*[\d.]+\s*$') { $equiv += [double]$r.pod5_equiv_gb }
        if ("$($r.gpu_max_temp_c)"    -match '^\s*[\d.]+\s*$') { $temps += [double]$r.gpu_max_temp_c }
        if ("$($r.gpu_avg_power_w)"   -match '^\s*[\d.]+\s*$') { $pows  += [double]$r.gpu_avg_power_w }
        if ("$($r.gpu_avg_clock_mhz)" -match '^\s*[\d.]+\s*$') { $clks  += [double]$r.gpu_avg_clock_mhz }
    }

    $medRate = 0.0; $minRate = 0.0; $maxRate = 0.0
    if ($rates.Count -gt 0) {
        $m = Get-Median -Values $rates
        if ($null -ne $m) { $medRate = [math]::Round([double]$m, 1) }
        $minRate = [math]::Round(($rates | Measure-Object -Minimum).Minimum, 1)
        $maxRate = [math]::Round(($rates | Measure-Object -Maximum).Maximum, 1)
    }

    $sumEquiv = 0.0
    if ($equiv.Count -gt 0) { $sumEquiv = [math]::Round(($equiv | Measure-Object -Sum).Sum, 1) }

    $maxTemp = $null
    if ($temps.Count -gt 0) { $maxTemp = [int](($temps | Measure-Object -Maximum).Maximum) }

    $avgPow = $null
    if ($pows.Count -gt 0) { $avgPow = [math]::Round(($pows | Measure-Object -Average).Average, 0) }

    $avgClk = $null
    if ($clks.Count -gt 0) { $avgClk = [math]::Round(($clks | Measure-Object -Average).Average, 0) }

    $res = New-Object PSObject
    $res | Add-Member NoteProperty Total    $all.Count
    $res | Add-Member NoteProperty Ok       $ok.Count
    $res | Add-Member NoteProperty Fail     (@($all | Where-Object { $_.status -eq 'FAIL' }).Count)
    $res | Add-Member NoteProperty Oom      (@($all | Where-Object { $_.status -eq 'OOM'  }).Count)
    $res | Add-Member NoteProperty MedRate  $medRate
    $res | Add-Member NoteProperty MinRate  $minRate
    $res | Add-Member NoteProperty MaxRate  $maxRate
    $res | Add-Member NoteProperty EquivGB  $sumEquiv
    $res | Add-Member NoteProperty MaxTemp  $maxTemp
    $res | Add-Member NoteProperty AvgPower $avgPow
    $res | Add-Member NoteProperty AvgClock $avgClk
    return $res
}

# Vonis kelayakan dalam bentuk data, dipakai oleh report.html.
# Ambangnya sama persis dengan laporan konsol: T1-T4 untuk kemampuan,
# ditambah kriteria ketahanan.
function Get-VerdictData {
    param($Rows, $DayIndex)

    $all   = @($Rows | ForEach-Object { $_ })
    $ok    = @($all | Where-Object { $_.status -eq 'OK' })
    $bench = @($ok | Select-Object -Skip 1)          # loop pertama selalu dibuang

    $rates = @()
    foreach ($r in $bench) {
        $v = Get-RowRate $r
        if ($null -ne $v) { $rates += [double]$v }
    }
    $med = 0.0
    if ($rates.Count -gt 0) {
        $m = Get-Median -Values $rates
        if ($null -ne $m) { $med = [math]::Round([double]$m, 1) }
    }

    $notes = @()
    $durOk = $true

    $ret = $null
    # Hari parsial di ujung (marathon mulai sore, atau berhenti pagi) hanya berisi
    # beberapa loop dan angkanya tidak stabil. Hari dengan < 3 loop sukses dibuang
    # dari pembandingan retensi supaya vonis tidak digeser oleh hari yang timpang.
    $days = @($DayIndex | ForEach-Object { $_ } | Where-Object { $_.Stat.Ok -ge 3 })
    if ($days.Count -lt 2) { $days = @($DayIndex | ForEach-Object { $_ }) }
    if ($days.Count -ge 2) {
        $first = [double]$days[0].Stat.MedRate
        $last  = [double]$days[$days.Count - 1].Stat.MedRate
        if ($first -gt 0) {
            $ret = [math]::Round($last / $first, 3)
            if ($ret -lt 0.90) {
                $durOk = $false
                $pct = [math]::Round($ret * 100, 0)
                $notes += "Retensi laju $ret, di bawah syarat 0,90 - laju hari terakhir tinggal $pct% dari hari pertama."
            }
        }
    }

    $avail = 0.0
    if ($all.Count -gt 0) { $avail = [math]::Round($ok.Count / $all.Count, 3) }
    if ($avail -lt 0.99) { $durOk = $false; $notes += "Ketersediaan $avail, di bawah syarat 0,99." }

    $hardFail = @($all | Where-Object { $_.status -eq 'FAIL' }).Count
    if ($hardFail -gt 0) { $durOk = $false; $notes += "$hardFail loop gagal tanpa pemulihan." }

    $oom = @($all | Where-Object { $_.status -eq 'OOM' }).Count
    if ($oom -gt 1) { $durOk = $false; $notes += "$oom kali kehabisan VRAM, syarat maksimal 1 kali." }

    $res = New-Object PSObject
    $res | Add-Member -MemberType NoteProperty -Name MedRate -Value $med
    $res | Add-Member -MemberType NoteProperty -Name Tier    -Value (Get-TierName -Rate $med)
    $res | Add-Member -MemberType NoteProperty -Name DurOk   -Value $durOk
    $res | Add-Member -MemberType NoteProperty -Name Notes   -Value $notes
    $res | Add-Member -MemberType NoteProperty -Name Ret     -Value $ret
    $res | Add-Member -MemberType NoteProperty -Name Avail   -Value $avail
    $res | Add-Member -MemberType NoteProperty -Name Fail    -Value $hardFail
    $res | Add-Member -MemberType NoteProperty -Name Oom     -Value $oom
    return $res
}

function New-DailyReports {
    param([string]$Csv, [string]$OutDir, [string]$ModelName = '', [string]$DeviceName = '',
          [switch]$Final)

    if (!(Test-Path -LiteralPath $Csv)) { return }
    $rows = @(Import-Csv -LiteralPath $Csv -ErrorAction SilentlyContinue)
    if ($rows.Count -eq 0) { return }

    # Kelompokkan per tanggal kalender dari waktu mulai loop.
    $byDay = @{}
    foreach ($r in $rows) {
        $d = ConvertTo-Time $r.start
        if (-not $d) { continue }
        $key = $d.ToString('yyyyMMdd')
        if (-not $byDay.ContainsKey($key)) { $byDay[$key] = @() }
        $byDay[$key] += $r
    }
    $days = @($byDay.Keys | Sort-Object)
    if ($days.Count -eq 0) { return }

    $css      = Get-ReportCss
    $gen      = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $baseStat = Get-DayStats -Rows $byDay[$days[0]]
    $meta     = "Model $(ConvertTo-Html $ModelName) &middot; Device $(ConvertTo-Html $DeviceName)"

    # ---------- satu berkas per hari ----------
    $index = @()
    for ($i = 0; $i -lt $days.Count; $i++) {
        $key  = $days[$i]
        $day  = $byDay[$key]
        $st   = Get-DayStats -Rows $day
        $tier = Get-TierName -Rate $st.MedRate
        $tgl  = ([datetime]::ParseExact($key, 'yyyyMMdd', $null)).ToString('dd MMMM yyyy')

        # Retensi terhadap hari pertama: inti penilaian ketahanan.
        $ret = $null
        if ($baseStat.MedRate -gt 0) { $ret = [math]::Round($st.MedRate / $baseStat.MedRate, 3) }

        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.AppendLine('<!doctype html><html lang="id"><head><meta charset="utf-8">')
        [void]$sb.AppendLine("<title>Laporan Harian $tgl</title>")
        [void]$sb.AppendLine('<meta name="viewport" content="width=device-width,initial-scale=1">')
        [void]$sb.AppendLine($css + '</head><body><div class="wrap">')
        [void]$sb.AppendLine("<h1>Laporan Marathon Basecalling &mdash; Hari ke-$($i + 1)</h1>")
        [void]$sb.AppendLine("<div class=`"sub`">$tgl &middot; $meta</div>")

        [void]$sb.AppendLine('<div class="cards">')
        [void]$sb.AppendLine("<div class=`"card`"><div class=`"k`">Laju median</div><div class=`"v`">$($st.MedRate)</div><div class=`"n`">GB POD5/jam</div></div>")
        [void]$sb.AppendLine("<div class=`"card`"><div class=`"k`">Tingkat</div><div class=`"v`">$tier</div><div class=`"n`">berdasar laju hari ini</div></div>")
        [void]$sb.AppendLine("<div class=`"card`"><div class=`"k`">Data diproses</div><div class=`"v`">$($st.EquivGB)</div><div class=`"n`">GB POD5-setara</div></div>")
        [void]$sb.AppendLine("<div class=`"card`"><div class=`"k`">Loop</div><div class=`"v`">$($st.Ok)/$($st.Total)</div><div class=`"n`">sukses / total</div></div>")
        if ($null -ne $ret) {
            [void]$sb.AppendLine("<div class=`"card`"><div class=`"k`">Retensi</div><div class=`"v`">$ret</div><div class=`"n`">vs hari pertama</div></div>")
        }
        if ($null -ne $st.MaxTemp) {
            [void]$sb.AppendLine("<div class=`"card`"><div class=`"k`">Suhu maks</div><div class=`"v`">$($st.MaxTemp)</div><div class=`"n`">&deg;C</div></div>")
        }
        [void]$sb.AppendLine('</div>')

        if ($null -ne $ret -and $ret -lt 0.90) {
            [void]$sb.AppendLine("<div class=`"note bad`"><b>Retensi di bawah ambang.</b> Laju hari ini tinggal $([math]::Round($ret * 100, 0))% dari hari pertama, sedangkan syarat ketahanan adalah minimal 90%. Periksa suhu dan clock SM pada tabel di bawah.</div>")
        }
        if ($st.Fail -gt 0) {
            [void]$sb.AppendLine("<div class=`"note bad`"><b>$($st.Fail) loop gagal tanpa pemulihan.</b> Periksa berkas dorado_loop_*.log pada hari ini.</div>")
        }
        if ($st.Oom -gt 0) {
            [void]$sb.AppendLine("<div class=`"note warn`"><b>$($st.Oom) kali kehabisan VRAM.</b> Batch diturunkan otomatis; nilai efektifnya terlihat pada kolom Batch.</div>")
        }

        [void]$sb.AppendLine('<h2>Rincian per loop</h2><table>')
        [void]$sb.AppendLine('<tr><th>Loop</th><th>Mulai</th><th class="n">Durasi</th><th class="n">Batch</th><th class="n">POD5-setara</th><th class="n">Laju</th><th class="n">Suhu</th><th class="n">Daya</th><th class="n">Clock SM</th><th>Status</th></tr>')
        foreach ($r in $day) {
            $rt  = Get-RowRate $r
            $rts = if ($null -ne $rt) { [math]::Round($rt, 1) } else { '' }
            $mnt = if ($r.seconds -match '\d') { [math]::Round([double]$r.seconds / 60, 0) } else { '' }
            $cls = switch ($r.status) { 'OK' { 'ok' } 'OOM' { 'oom' } default { 'fail' } }
            $jam = ''
            $dt  = ConvertTo-Time $r.start
            if ($dt) { $jam = $dt.ToString('HH:mm:ss') }
            [void]$sb.AppendLine(("<tr><td>{0}</td><td>{1}</td><td class=`"n`">{2} mnt</td><td class=`"n`">{3}</td><td class=`"n`">{4} GB</td><td class=`"n`">{5}</td><td class=`"n`">{6}</td><td class=`"n`">{7}</td><td class=`"n`">{8}</td><td class=`"{9}`">{10}</td></tr>" -f `
                (ConvertTo-Html $r.loop), $jam, $mnt, (ConvertTo-Html $r.batchsize), (ConvertTo-Html $r.pod5_equiv_gb), `
                $rts, (ConvertTo-Html $r.gpu_max_temp_c), (ConvertTo-Html $r.gpu_avg_power_w), `
                (ConvertTo-Html $r.gpu_avg_clock_mhz), $cls, (ConvertTo-Html $r.status)))
        }
        [void]$sb.AppendLine('</table>')
        [void]$sb.AppendLine("<div class=`"foot`">Dibuat $gen dari marathon_summary.csv &middot; <a href=`"report.html`">Kembali ke indeks</a></div>")
        [void]$sb.AppendLine('</div></body></html>')

        $path = Join-Path $OutDir "report_$key.html"
        Set-Content -LiteralPath $path -Encoding utf8 -Value $sb.ToString()

        $ent = New-Object PSObject
        $ent | Add-Member -MemberType NoteProperty -Name Key  -Value $key
        $ent | Add-Member -MemberType NoteProperty -Name Tgl  -Value $tgl
        $ent | Add-Member -MemberType NoteProperty -Name Hari -Value ($i + 1)
        $ent | Add-Member -MemberType NoteProperty -Name Stat -Value $st
        $ent | Add-Member -MemberType NoteProperty -Name Tier -Value $tier
        $ent | Add-Member -MemberType NoteProperty -Name Ret  -Value $ret
        $index += $ent
    }

    # ---------- indeks report.html ----------
    $all  = Get-DayStats -Rows $rows
    $tAll = Get-TierName -Rate $all.MedRate
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('<!doctype html><html lang="id"><head><meta charset="utf-8">')
    [void]$sb.AppendLine('<title>Marathon Basecalling - Ringkasan</title>')
    [void]$sb.AppendLine('<meta name="viewport" content="width=device-width,initial-scale=1">')
    [void]$sb.AppendLine($css + '</head><body><div class="wrap">')
    [void]$sb.AppendLine('<h1>Marathon Basecalling &mdash; Ringkasan</h1>')
    [void]$sb.AppendLine("<div class=`"sub`">$meta &middot; $($days.Count) hari pengujian</div>")

    [void]$sb.AppendLine('<div class="cards">')
    [void]$sb.AppendLine("<div class=`"card`"><div class=`"k`">Laju median</div><div class=`"v`">$($all.MedRate)</div><div class=`"n`">GB POD5/jam</div></div>")
    [void]$sb.AppendLine("<div class=`"card`"><div class=`"k`">Tingkat</div><div class=`"v`">$tAll</div><div class=`"n`">keseluruhan</div></div>")
    [void]$sb.AppendLine("<div class=`"card`"><div class=`"k`">Total data</div><div class=`"v`">$([math]::Round($all.EquivGB / 1024, 2))</div><div class=`"n`">TB POD5-setara</div></div>")
    [void]$sb.AppendLine("<div class=`"card`"><div class=`"k`">Loop</div><div class=`"v`">$($all.Ok)/$($all.Total)</div><div class=`"n`">sukses / total</div></div>")
    [void]$sb.AppendLine('</div>')

    # ---------- vonis ----------
    $v = Get-VerdictData -Rows $rows -DayIndex $index
    $judul = if ($Final) { 'Vonis akhir' } else { 'Vonis sementara' }
    [void]$sb.AppendLine("<h2>$judul</h2>")

    $vNotes = @($v.Notes)
    if ($v.Tier -eq '-') {
        [void]$sb.AppendLine("<div class=`"note bad`"><b>Tidak mencapai T1.</b> Laju $($v.MedRate) GB POD5/jam berada di bawah ambang 3 GB/jam, sehingga mesin ini tidak memadai untuk basecalling real-time. Masih layak dipakai untuk basecalling offline setelah run sekuensing selesai.</div>")
    } else {
        $desc = ($script:Tiers | Where-Object { $_.Name -eq $v.Tier } | Select-Object -First 1).Desc
        [void]$sb.AppendLine("<div class=`"note`"><b>Tingkat tercapai: $($v.Tier)</b> &mdash; $desc.<br>Laju median $($v.MedRate) GB POD5/jam, dihitung dari loop sukses di luar loop pertama.</div>")

        if ($v.DurOk) {
            [void]$sb.AppendLine("<div class=`"note`" style=`"border-left-color:#1e7a46;background:#f2faf5`"><b>Ketahanan: LULUS.</b> Seluruh kriteria terpenuhi, sehingga mesin ini sanggup dipakai berkelanjutan pada tingkat $($v.Tier), termasuk untuk basecalling real-time.</div>")
        } else {
            $li = ($vNotes | ForEach-Object { "<li>$(ConvertTo-Html $_)</li>" }) -join ''
            [void]$sb.AppendLine("<div class=`"note bad`"><b>Ketahanan: TIDAK LULUS.</b> Mesin mencapai $($v.Tier) pada kondisi terbaiknya, namun tidak mempertahankannya. Hanya layak untuk basecalling offline.<ul>$li</ul></div>")
        }
    }
    if (-not $Final) {
        [void]$sb.AppendLine('<div class="note warn">Marathon masih berjalan. Vonis di atas dihitung dari data yang terkumpul sejauh ini dan akan diperbarui setiap loop selesai.</div>')
    }

    # Spesifikasi mesin: dari machine_spec.json kalau ada (mesin yang diuji),
    # kalau tidak ada baru diambil dari mesin saat ini.
    $specPath = Join-Path $OutDir 'machine_spec.json'
    $spec = Read-MachineSpec -Path $specPath
    $specLive = $false
    if (-not $spec) {
        try { $spec = Get-MachineSpec -ModelName $ModelName -DeviceName $DeviceName; $specLive = $true } catch { }
    }
    if ($spec) {
        [void]$sb.AppendLine((Get-SpecHtml -Spec $spec))
        if ($specLive) {
            [void]$sb.AppendLine('<div class="note warn">Spesifikasi di atas dibaca dari komputer yang membuka laporan ini, karena machine_spec.json tidak ditemukan di folder hasil. Untuk marathon yang dijalankan skrip versi ini, berkas tersebut selalu ada.</div>')
        }
    }

    [void]$sb.AppendLine('<h2>Per hari</h2><table>')
    [void]$sb.AppendLine('<tr><th>Hari</th><th>Tanggal</th><th class="n">Loop</th><th class="n">Laju median</th><th class="n">Tingkat</th><th class="n">Retensi</th><th class="n">Suhu maks</th><th class="n">Data</th><th>Laporan</th></tr>')
    foreach ($d in $index) {
        $retTxt = if ($null -ne $d.Ret) { $d.Ret } else { '-' }
        $retCls = if ($null -ne $d.Ret -and $d.Ret -lt 0.90) { ' class="fail"' } else { '' }
        [void]$sb.AppendLine(("<tr><td>{0}</td><td>{1}</td><td class=`"n`">{2}/{3}</td><td class=`"n`">{4}</td><td class=`"n`">{5}</td><td class=`"n`"{6}>{7}</td><td class=`"n`">{8}</td><td class=`"n`">{9} GB</td><td><a href=`"report_{10}.html`">buka</a></td></tr>" -f `
            $d.Hari, $d.Tgl, $d.Stat.Ok, $d.Stat.Total, $d.Stat.MedRate, $d.Tier, `
            $retCls, $retTxt, $d.Stat.MaxTemp, $d.Stat.EquivGB, $d.Key))
    }
    [void]$sb.AppendLine('</table>')
    [void]$sb.AppendLine('<div class="note">Retensi adalah laju median hari tersebut dibagi laju median hari pertama. Syarat kelulusan ketahanan adalah minimal 0,90 pada hari terakhir.</div>')
    [void]$sb.AppendLine("<div class=`"foot`">Dibuat $gen dari marathon_summary.csv</div>")
    [void]$sb.AppendLine('</div></body></html>')
    Set-Content -LiteralPath (Join-Path $OutDir 'report.html') -Encoding utf8 -Value $sb.ToString()

    # Saat marathon tuntas, bekukan salinannya sebagai hasil akhir supaya tidak
    # tertimpa kalau folder yang sama dipakai lagi di kemudian hari.
    if ($Final) {
        Set-Content -LiteralPath (Join-Path $OutDir 'report_final.html') -Encoding utf8 -Value $sb.ToString()
    }
}


function Get-FreeGB {
    param([string]$Root)
    $d = [System.IO.DriveInfo]::GetDrives() |
         Where-Object { $_.IsReady -and $_.RootDirectory.FullName -eq $Root } |
         Select-Object -First 1
    if ($d) { return [math]::Round($d.AvailableFreeSpace / 1GB, 1) }
    return -1
}

# ========================================================================
# SETUP (-su) - pasang Dorado dan model HANYA kalau belum ada
# ========================================================================

# Drive fixed dengan ruang bebas terbanyak, dipakai kalau -sd tidak diisi.
function Get-BestSetupDrive {
    $best = $null; $bestFree = -1
    foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
        if (-not $d.IsReady -or $d.DriveType -ne 'Fixed') { continue }
        if ($d.AvailableFreeSpace -gt $bestFree) {
            $bestFree = $d.AvailableFreeSpace
            $best     = $d.RootDirectory.FullName
        }
    }
    if ($best) { return $best }
    return 'C:\'
}

function Install-DoradoIfMissing {
    param([string]$HintPath, [bool]$Explicit, [string]$Version, [string]$Dir)

    # 1. Cek dulu - kalau sudah ada, tidak mengunduh apa pun.
    $found = Resolve-Dorado -Path $HintPath -Explicit $Explicit
    if ($found) {
        Write-Host "[SETUP] Dorado sudah ada, unduhan dilewati." -ForegroundColor Green
        Write-Host "        $($found.Source)  ($($found.From))" -ForegroundColor DarkGray
        return $found.Source
    }

    if (-not $Dir) { $Dir = Get-BestSetupDrive }
    $target = Join-Path $Dir "dorado-$Version-win64"
    $exe    = Join-Path $target 'bin\dorado.exe'

    if (Test-Path -LiteralPath $exe -PathType Leaf) {
        Write-Host "[SETUP] Dorado sudah terpasang di $target." -ForegroundColor Green
        return $exe
    }

    # 2. Ruang: zip sekitar 1 GB, hasil ekstrak beberapa GB. Minta 8 GB supaya aman.
    $root = [System.IO.Path]::GetPathRoot($target)
    $free = Get-FreeGB -Root $root
    if ($free -ge 0 -and $free -lt 8) {
        Write-Host "[ERROR] Sisa ruang $root hanya $free GB, butuh minimal 8 GB untuk Dorado." -ForegroundColor Red
        Write-Host "        Pakai -sd <drive lain>, mis. -sd D:\" -ForegroundColor Red
        return $null
    }

    $url = "https://cdn.oxfordnanoportal.com/software/analysis/dorado-$Version-win64.zip"
    $zip = Join-Path $env:TEMP "dorado-$Version-win64.zip"

    Write-Host "[SETUP] Dorado tidak ditemukan. Mengunduh v$Version..." -ForegroundColor Yellow
    Write-Host "        $url" -ForegroundColor DarkGray
    Write-Host "        Tujuan: $target  (sisa ruang $free GB)" -ForegroundColor DarkGray

    try {
        if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue }
        # TLS 1.2 wajib disetel eksplisit di PowerShell 5.1.
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        # ProgressPreference dimatikan: bar kemajuan Invoke-WebRequest memperlambat
        # unduhan besar secara drastis di PS 5.1.
        $oldProgress = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        $sw = [Diagnostics.Stopwatch]::StartNew()
        Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
        $sw.Stop()
        $ProgressPreference = $oldProgress
    } catch {
        $ProgressPreference = 'Continue'
        Write-Host "[ERROR] Unduhan gagal: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }

    if (!(Test-Path -LiteralPath $zip)) {
        Write-Host "[ERROR] Berkas hasil unduhan tidak ada." -ForegroundColor Red
        return $null
    }
    $mb = [math]::Round((Get-Item -LiteralPath $zip).Length / 1MB, 1)
    Write-Host ("[SETUP] Terunduh {0} MB dalam {1:n0} detik. Mengekstrak..." -f $mb, $sw.Elapsed.TotalSeconds) -ForegroundColor DarkCyan

    try {
        # Zip memuat folder dorado-<ver>-win64 di dalamnya, jadi diekstrak ke induknya.
        Expand-Archive -LiteralPath $zip -DestinationPath $Dir -Force
    } catch {
        Write-Host "[ERROR] Ekstraksi gagal: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
    Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue

    if (!(Test-Path -LiteralPath $exe -PathType Leaf)) {
        # Sebagian rilis memakai nama folder berbeda - cari dorado.exe di bawah $Dir.
        $hit = Get-ChildItem -LiteralPath $Dir -Filter 'dorado.exe' -Recurse -File -ErrorAction SilentlyContinue |
               Select-Object -First 1
        if ($hit) { $exe = $hit.FullName }
    }
    if (Test-Path -LiteralPath $exe -PathType Leaf) {
        Write-Host "[SETUP] Dorado siap: $exe" -ForegroundColor Green
        return $exe
    }
    Write-Host "[ERROR] dorado.exe tidak ketemu setelah ekstraksi." -ForegroundColor Red
    return $null
}

function Install-ModelIfMissing {
    param([string]$Exe, [string]$ModelName, [string]$Cache)

    if (!(Test-Path -LiteralPath $Cache)) { New-Item -ItemType Directory -Force -Path $Cache | Out-Null }

    # Model gabungan "simplex@ver_mods@ver" menghasilkan DUA folder: simplex dan mods.
    # Keduanya harus ada supaya unduhan boleh dilewati.
    $need = @($ModelName)
    $m = [regex]::Match($ModelName, '^(.*?@v[\d.]+)')
    if ($m.Success -and $m.Groups[1].Value -ne $ModelName) { $need += $m.Groups[1].Value }

    $missing = @($need | Where-Object { !(Test-Path -LiteralPath (Join-Path $Cache $_) -PathType Container) })
    if ($missing.Count -eq 0) {
        Write-Host "[SETUP] Model sudah ada di cache, unduhan dilewati." -ForegroundColor Green
        foreach ($n in $need) { Write-Host "        $n" -ForegroundColor DarkGray }
        return $true
    }

    Write-Host "[SETUP] Mengunduh model: $ModelName" -ForegroundColor Yellow
    Write-Host "        Cache: $Cache" -ForegroundColor DarkGray

    # Nama flag folder model berbeda antar versi dorado, jadi dicoba berurutan.
    foreach ($flag in @('--models-directory', '--directory')) {
        try {
            & $Exe download --model $ModelName $flag $Cache 2>&1 | ForEach-Object {
                Write-Host "        $_" -ForegroundColor DarkGray
            }
            if ($LASTEXITCODE -eq 0) {
                Write-Host "[SETUP] Model siap." -ForegroundColor Green
                return $true
            }
            Write-Host "[SETUP] Flag $flag ditolak, mencoba alternatif..." -ForegroundColor DarkYellow
        } catch {
            Write-Host "[SETUP] $flag gagal: $($_.Exception.Message)" -ForegroundColor DarkYellow
        }
    }

    Write-Host "[WARN] Unduhan model eksplisit gagal." -ForegroundColor Yellow
    Write-Host "       Tidak fatal: dorado basecaller akan mengunduhnya sendiri saat loop pertama." -ForegroundColor DarkGray
    return $false
}


# ========================================================================
# SPESIFIKASI MESIN - direkam saat marathon mulai, ditampilkan di report.html
# ========================================================================
# Disimpan ke machine_spec.json supaya laporan yang dibaca belakangan (atau di
# komputer lain lewat -rep) tetap menampilkan spesifikasi mesin YANG DIUJI,
# bukan spesifikasi mesin yang kebetulan membuka laporannya.

function Get-MachineSpec {
    param([string]$DoradoPath = '', [string]$ModelName = '', [string]$ModelCachePath = '',
          [string]$Pod5Path = '', [string]$OutputPath = '', [string]$DeviceName = '')

    $spec = New-Object PSObject
    $add  = { param($n, $v) $spec | Add-Member -MemberType NoteProperty -Name $n -Value $v -Force }

    & $add 'Waktu'    (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    & $add 'Host'     $env:COMPUTERNAME

    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        & $add 'OS' ("{0} (build {1})" -f $os.Caption.Trim(), $os.BuildNumber)
    } catch { & $add 'OS' 'tidak terbaca' }

    try {
        $cpu = @(Get-CimInstance Win32_Processor -ErrorAction Stop)[0]
        & $add 'CPU'      $cpu.Name.Trim()
        & $add 'CpuCore'  ("{0} core / {1} thread" -f $cpu.NumberOfCores, $cpu.NumberOfLogicalProcessors)
    } catch { & $add 'CPU' 'tidak terbaca'; & $add 'CpuCore' '' }

    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        & $add 'RAM'    ("{0} GB" -f [math]::Round($cs.TotalPhysicalMemory / 1GB, 1))
        & $add 'Mesin'  ("{0} {1}" -f $cs.Manufacturer, $cs.Model).Trim()
    } catch { & $add 'RAM' 'tidak terbaca'; & $add 'Mesin' '' }

    # --- GPU lewat nvidia-smi; kalau tak ada, mundur ke daftar adapter Windows ---
    $gpus = @()
    try {
        if (Get-Command 'nvidia-smi.exe' -CommandType Application -ErrorAction SilentlyContinue) {
            $q = & nvidia-smi.exe --query-gpu=name,memory.total,driver_version,power.limit,clocks.max.sm `
                    --format=csv,noheader,nounits 2>$null
            if ($LASTEXITCODE -eq 0 -and $q) {
                foreach ($line in @($q)) {
                    $p = @($line -split ',' | ForEach-Object { $_.Trim() })
                    if ($p.Count -ge 5) {
                        $g = New-Object PSObject
                        $g | Add-Member NoteProperty Nama   $p[0]
                        $g | Add-Member NoteProperty VRAM   ("{0} GB" -f [math]::Round([double]$p[1] / 1024, 1))
                        $g | Add-Member NoteProperty Driver $p[2]
                        $g | Add-Member NoteProperty TDP    ("{0} W" -f [math]::Round([double]$p[3], 0))
                        $g | Add-Member NoteProperty Clock  ("{0} MHz" -f $p[4])
                        $gpus += $g
                    }
                }
            }
        }
    } catch { }
    if ($gpus.Count -eq 0) {
        try {
            foreach ($v in @(Get-CimInstance Win32_VideoController -ErrorAction Stop)) {
                $g = New-Object PSObject
                $g | Add-Member NoteProperty Nama   $v.Name
                $g | Add-Member NoteProperty VRAM   $(if ($v.AdapterRAM -gt 0) { "{0} GB" -f [math]::Round($v.AdapterRAM / 1GB, 1) } else { '-' })
                $g | Add-Member NoteProperty Driver $v.DriverVersion
                $g | Add-Member NoteProperty TDP    '-'
                $g | Add-Member NoteProperty Clock  '-'
                $gpus += $g
            }
        } catch { }
    }
    & $add 'GPU' $gpus

    # --- Storage: semua drive fixed, ditandai mana yang menampung data uji ---
    $disks = @()
    try {
        $pod5Root = if ($Pod5Path)   { [System.IO.Path]::GetPathRoot((Resolve-Path -LiteralPath $Pod5Path -ErrorAction SilentlyContinue)) } else { '' }
        $outRoot  = if ($OutputPath) { [System.IO.Path]::GetPathRoot($OutputPath) } else { '' }
        foreach ($d in Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction Stop) {
            $root  = "$($d.DeviceID)\"
            $peran = @()
            if ($pod5Root -and $root -eq $pod5Root) { $peran += 'dataset POD5' }
            if ($outRoot  -and $root -eq $outRoot)  { $peran += 'output' }
            $k = New-Object PSObject
            $k | Add-Member NoteProperty Drive  $d.DeviceID
            $k | Add-Member NoteProperty Label  $(if ($d.VolumeName) { $d.VolumeName } else { '-' })
            $k | Add-Member NoteProperty FS     $d.FileSystem
            $k | Add-Member NoteProperty Total  ("{0} GB" -f [math]::Round($d.Size / 1GB, 1))
            $k | Add-Member NoteProperty Bebas  ("{0} GB" -f [math]::Round($d.FreeSpace / 1GB, 1))
            $k | Add-Member NoteProperty Pakai  ("{0}%" -f $(if ($d.Size -gt 0) { [math]::Round((($d.Size - $d.FreeSpace) / $d.Size) * 100, 0) } else { 0 }))
            $k | Add-Member NoteProperty Peran  $(if ($peran.Count) { $peran -join ' + ' } else { '' })
            $disks += $k
        }
    } catch { }
    & $add 'Disk' $disks

    # --- Konfigurasi basecalling ---
    $dv = ''
    try {
        if ($DoradoPath -and (Test-Path -LiteralPath $DoradoPath -PathType Leaf)) {
            $out = & $DoradoPath --version 2>&1
            $dv  = (@($out) -join ' ').Trim()
            if ($dv.Length -gt 80) { $dv = $dv.Substring(0, 80) }
        }
    } catch { }
    & $add 'Dorado'      $DoradoPath
    & $add 'DoradoVer'   $dv
    & $add 'Model'       $ModelName
    & $add 'ModelCache'  $ModelCachePath
    & $add 'Device'      $DeviceName
    & $add 'Pod5Dir'     $Pod5Path

    # --- Dataset ---
    try {
        if ($Pod5Path -and (Test-Path -LiteralPath $Pod5Path -PathType Container)) {
            $f = @(Get-ChildItem -LiteralPath $Pod5Path -Filter *.pod5 -File -Recurse -ErrorAction SilentlyContinue)
            $sz = 0
            if ($f.Count -gt 0) { $sz = ($f | Measure-Object Length -Sum).Sum }
            & $add 'Pod5Berkas'  $f.Count
            & $add 'Pod5Ukuran'  ("{0} GB" -f [math]::Round($sz / 1GB, 1))
        }
    } catch { }

    return $spec
}

function Save-MachineSpec {
    param($Spec, [string]$Path)
    try { $Spec | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Path -Encoding utf8 } catch { }
}

function Read-MachineSpec {
    param([string]$Path)
    try {
        if (Test-Path -LiteralPath $Path) {
            return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
        }
    } catch { }
    return $null
}

# Render spesifikasi jadi potongan HTML untuk report.html.
function Get-SpecHtml {
    param($Spec)
    if (-not $Spec) { return '' }

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('<h2>Spesifikasi mesin uji</h2>')

    [void]$sb.AppendLine('<table>')
    [void]$sb.AppendLine('<tr><th style="width:170px">Komponen</th><th>Keterangan</th></tr>')
    $baris = @(
        @('Host',      "$(ConvertTo-Html $Spec.Host)"),
        @('Mesin',     "$(ConvertTo-Html $Spec.Mesin)"),
        @('Sistem operasi', "$(ConvertTo-Html $Spec.OS)"),
        @('CPU',       "$(ConvertTo-Html $Spec.CPU) &middot; $(ConvertTo-Html $Spec.CpuCore)"),
        @('RAM',       "$(ConvertTo-Html $Spec.RAM)")
    )
    foreach ($b in $baris) {
        if ($b[1] -and $b[1].Trim() -ne '' -and $b[1].Trim() -ne '&middot;') {
            [void]$sb.AppendLine("<tr><td><b>$($b[0])</b></td><td>$($b[1])</td></tr>")
        }
    }
    [void]$sb.AppendLine('</table>')

    $gpus = @($Spec.GPU)
    if ($gpus.Count -gt 0) {
        [void]$sb.AppendLine('<h2>GPU</h2><table>')
        [void]$sb.AppendLine('<tr><th>Kartu</th><th class="n">VRAM</th><th class="n">TDP</th><th class="n">Clock maks</th><th>Driver</th></tr>')
        foreach ($g in $gpus) {
            [void]$sb.AppendLine(("<tr><td>{0}</td><td class=`"n`">{1}</td><td class=`"n`">{2}</td><td class=`"n`">{3}</td><td>{4}</td></tr>" -f `
                (ConvertTo-Html $g.Nama), (ConvertTo-Html $g.VRAM), (ConvertTo-Html $g.TDP), `
                (ConvertTo-Html $g.Clock), (ConvertTo-Html $g.Driver)))
        }
        [void]$sb.AppendLine('</table>')
    }

    $disks = @($Spec.Disk)
    if ($disks.Count -gt 0) {
        [void]$sb.AppendLine('<h2>Penyimpanan</h2><table>')
        [void]$sb.AppendLine('<tr><th>Drive</th><th>Label</th><th>FS</th><th class="n">Kapasitas</th><th class="n">Bebas</th><th class="n">Terpakai</th><th>Peran</th></tr>')
        foreach ($k in $disks) {
            $hl = if ($k.Peran) { ' style="background:#eef6fb"' } else { '' }
            [void]$sb.AppendLine(("<tr{0}><td><b>{1}</b></td><td>{2}</td><td>{3}</td><td class=`"n`">{4}</td><td class=`"n`">{5}</td><td class=`"n`">{6}</td><td>{7}</td></tr>" -f `
                $hl, (ConvertTo-Html $k.Drive), (ConvertTo-Html $k.Label), (ConvertTo-Html $k.FS), `
                (ConvertTo-Html $k.Total), (ConvertTo-Html $k.Bebas), (ConvertTo-Html $k.Pakai), (ConvertTo-Html $k.Peran)))
        }
        [void]$sb.AppendLine('</table>')
    }

    [void]$sb.AppendLine('<h2>Konfigurasi basecalling</h2><table>')
    [void]$sb.AppendLine('<tr><th style="width:170px">Item</th><th>Nilai</th></tr>')
    $cfg = @(
        @('Model',        (ConvertTo-Html $Spec.Model)),
        @('Dorado',       (ConvertTo-Html $Spec.Dorado)),
        @('Versi dorado', (ConvertTo-Html $Spec.DoradoVer)),
        @('Cache model',  (ConvertTo-Html $Spec.ModelCache)),
        @('Device',       (ConvertTo-Html $Spec.Device)),
        @('Folder POD5',  (ConvertTo-Html $Spec.Pod5Dir)),
        @('Dataset',      $(if ($Spec.Pod5Berkas) { "$($Spec.Pod5Berkas) berkas &middot; $(ConvertTo-Html $Spec.Pod5Ukuran)" } else { '' })),
        @('Direkam',      (ConvertTo-Html $Spec.Waktu))
    )
    foreach ($c in $cfg) {
        if ($c[1] -and "$($c[1])".Trim() -ne '') {
            [void]$sb.AppendLine("<tr><td><b>$($c[0])</b></td><td>$($c[1])</td></tr>")
        }
    }
    [void]$sb.AppendLine('</table>')

    return $sb.ToString()
}


# ========================================================================
# PEMERIKSAAN HARDWARE IDLE (-hw) - dijalankan SEBELUM benchmark maupun MinKNOW
# ========================================================================
# Menegakkan dua hal yang selama ini hanya bisa diperiksa manusia:
#   1. jenis media tiap drive (NVMe / SSD / HDD) - dataset uji tidak boleh di HDD
#   2. kondisi diam sistem - tidak ada beban lain yang mencemari pengukuran

function Get-DiskMediaMap {
    # Peta huruf drive -> jenis media fisiknya. Modul Storage tidak selalu ada,
    # jadi kegagalan di sini tidak boleh menghentikan apa pun.
    $map = @{}
    try {
        foreach ($part in (Get-Partition -ErrorAction Stop | Where-Object { $_.DriveLetter })) {
            $disk = Get-PhysicalDisk -ErrorAction SilentlyContinue |
                    Where-Object { $_.DeviceId -eq "$($part.DiskNumber)" } | Select-Object -First 1
            if (-not $disk) { continue }
            $jenis = switch ("$($disk.MediaType)") {
                'SSD'  { if ("$($disk.BusType)" -eq 'NVMe') { 'NVMe SSD' } else { 'SATA SSD' } }
                'HDD'  { 'HDD' }
                default { if ("$($disk.BusType)" -eq 'NVMe') { 'NVMe SSD' } else { "$($disk.MediaType)" } }
            }
            $map["$($part.DriveLetter):"] = [PSCustomObject]@{
                Jenis = $jenis; Bus = "$($disk.BusType)"; Model = "$($disk.FriendlyName)"
            }
        }
    } catch { }
    return $map
}

function Show-HardwareIdle {
    param([string]$Pod5Path = '', [string]$OutPath = '')

    function Check {
        param([string]$Label, [string]$State, [string]$Detail)
        $mark = switch ($State) { 'ok' { '[OK]' } 'bad' { '[!!]' } default { '[??]' } }
        $col  = switch ($State) { 'ok' { 'Green' } 'bad' { 'Red' } default { 'DarkYellow' } }
        Write-Host "    $mark " -ForegroundColor $col -NoNewline
        Write-Host ("{0,-14}" -f $Label) -NoNewline
        Write-Host $Detail -ForegroundColor DarkGray
    }

    Write-Host ""
    Write-Host "  PEMERIKSAAN HARDWARE IDLE" -ForegroundColor Cyan
    Write-Host "  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $env:COMPUTERNAME" -ForegroundColor DarkGray
    Write-Host ""

    $siap = $true

    # ---------------- GPU ----------------
    Write-Host "  GPU" -ForegroundColor White
    $gpuIdleOk = $true
    if (Get-Command 'nvidia-smi.exe' -CommandType Application -ErrorAction SilentlyContinue) {
        $q = & nvidia-smi.exe --query-gpu=index,name,temperature.gpu,utilization.gpu,power.draw,power.limit,memory.used,memory.total `
                --format=csv,noheader,nounits 2>$null
        if ($LASTEXITCODE -eq 0 -and $q) {
            foreach ($line in @($q)) {
                $p = @($line -split ',' | ForEach-Object { $_.Trim() })
                if ($p.Count -lt 8) { continue }
                $suhu = [int]$p[2]; $util = [int]$p[3]
                # GPU yang benar-benar diam: di bawah 50 C dan utilisasi di bawah 10%.
                $state = if ($suhu -lt 50 -and $util -lt 10) { 'ok' } else { 'bad' }
                if ($state -eq 'bad') { $gpuIdleOk = $false; $siap = $false }
                Check "GPU $($p[0])" $state ("{0} | {1} C | util {2}% | {3} W dari {4} W | VRAM {5} dari {6} MiB" -f `
                        $p[1], $suhu, $util, $p[4], $p[5], $p[6], $p[7])
            }
            # Proses lain yang sedang memakai GPU akan mencemari pengukuran.
            $apps = & nvidia-smi.exe --query-compute-apps=pid,process_name,used_memory --format=csv,noheader 2>$null
            if ($LASTEXITCODE -eq 0 -and $apps) {
                foreach ($a in @($apps)) { Check 'proses GPU' 'bad' $a; $siap = $false }
            } else {
                Check 'proses GPU' 'ok' 'tidak ada proses komputasi yang memakai GPU'
            }
        } else {
            Check 'nvidia-smi' 'unknown' 'gagal dijalankan'
        }
    } else {
        Check 'nvidia-smi' 'bad' 'tidak ada di PATH - GPU NVIDIA tidak terdeteksi'
        $siap = $false
    }
    Write-Host ""

    # ---------------- CPU, RAM ----------------
    Write-Host "  CPU DAN MEMORI" -ForegroundColor White
    try {
        $cpu = @(Get-CimInstance Win32_Processor -ErrorAction Stop)[0]
        Check 'CPU' 'ok' ("{0} | {1} core / {2} thread | beban {3}%" -f `
                $cpu.Name.Trim(), $cpu.NumberOfCores, $cpu.NumberOfLogicalProcessors, $cpu.LoadPercentage)
        if ([int]$cpu.LoadPercentage -gt 20) {
            Check 'beban CPU' 'bad' "beban $($cpu.LoadPercentage)% terlalu tinggi untuk kondisi diam"
            $siap = $false
        }
    } catch { Check 'CPU' 'unknown' 'tidak terbaca' }

    # Suhu CPU lewat WMI hanya tersedia pada sebagian mainboard; kerap ditolak
    # pada laptop konsumen. Ketiadaannya bukan kegagalan.
    $cpuTemp = $null
    try {
        $tz = Get-CimInstance -Namespace 'root/wmi' -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop
        if ($tz) { $cpuTemp = [math]::Round((($tz | Measure-Object CurrentTemperature -Maximum).Maximum / 10) - 273.15, 1) }
    } catch { }
    if ($null -ne $cpuTemp) {
        Check 'suhu CPU' $(if ($cpuTemp -lt 60) { 'ok' } else { 'bad' }) "$cpuTemp C"
    } else {
        Check 'suhu CPU' 'unknown' 'tidak tersedia lewat WMI - pakai HWiNFO64 bila perlu angka pasti'
    }

    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $totalGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
        $freeGB  = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
        $pakai   = [math]::Round((($totalGB - $freeGB) / $totalGB) * 100, 0)
        Check 'RAM' $(if ($pakai -lt 40) { 'ok' } else { 'bad' }) "$($totalGB - $freeGB) dari $totalGB GB terpakai ($pakai%)"
        if ($pakai -ge 40) { $siap = $false }
    } catch { Check 'RAM' 'unknown' 'tidak terbaca' }
    Write-Host ""

    # ---------------- Penyimpanan ----------------
    Write-Host "  PENYIMPANAN" -ForegroundColor White
    $media = Get-DiskMediaMap
    $pod5Root = if ($Pod5Path) { [System.IO.Path]::GetPathRoot($Pod5Path).TrimEnd('\') } else { '' }
    $outRoot  = if ($OutPath)  { [System.IO.Path]::GetPathRoot($OutPath).TrimEnd('\') }  else { '' }

    foreach ($d in (Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction SilentlyContinue)) {
        $id = "$($d.DeviceID)"
        $m  = $media[$id]
        $jenis = if ($m) { $m.Jenis } else { 'tidak terbaca' }
        $totalGB = [math]::Round($d.Size / 1GB, 1)
        $bebasGB = [math]::Round($d.FreeSpace / 1GB, 1)
        $peran = @()
        if ($pod5Root -and $id -eq $pod5Root) { $peran += 'dataset POD5' }
        if ($outRoot  -and $id -eq $outRoot)  { $peran += 'output' }
        $peranTxt = if ($peran.Count) { "  <- $($peran -join ' + ')" } else { '' }

        # HDD sah untuk arsip, tetapi TIDAK untuk dataset uji maupun output.
        $state = 'ok'
        if ($jenis -eq 'HDD' -and $peran.Count -gt 0) { $state = 'bad'; $siap = $false }
        elseif ($jenis -eq 'tidak terbaca') { $state = 'unknown' }
        Check $id $state ("{0,-9} | {1} GB, bebas {2} GB{3}" -f $jenis, $totalGB, $bebasGB, $peranTxt)
    }
    if ($pod5Root -and $media[$pod5Root] -and $media[$pod5Root].Jenis -eq 'HDD') {
        Write-Host "    Dataset uji berada di HDD - hasil pengukuran TIDAK SAH." -ForegroundColor Red
    }
    Write-Host ""

    # ---------------- Proses pengganggu ----------------
    Write-Host "  PROSES YANG MENGGANGGU PENGUJIAN" -ForegroundColor White
    $ganggu = @('MinKNOW', 'minknow', 'TeamViewer', 'AnyDesk', 'chrome', 'msedge', 'firefox', 'Teams')
    $found = @()
    foreach ($g in $ganggu) {
        $pr = Get-Process -Name $g -ErrorAction SilentlyContinue
        if ($pr) { $found += "$g ($(@($pr).Count) proses)" }
    }
    if ($found.Count -gt 0) {
        foreach ($f in $found) { Check 'berjalan' 'bad' $f }
        Write-Host "    Tutup dulu sebelum menjalankan Uji A; semuanya merebut VRAM atau CPU." -ForegroundColor DarkYellow
        $siap = $false
    } else {
        Check 'bersih' 'ok' 'tidak ada aplikasi pengganggu yang berjalan'
    }
    Write-Host ""

    # ---------------- Daya ----------------
    $ps = [System.Windows.Forms.SystemInformation]::PowerStatus 2>$null
    if ($ps -and $ps.BatteryChargeStatus -ne 'NoSystemBattery') {
        Write-Host "  DAYA" -ForegroundColor White
        $onAC = ($ps.PowerLineStatus -eq 'Online')
        Check 'adaptor' $(if ($onAC) { 'ok' } else { 'bad' }) `
              $(if ($onAC) { 'terhubung' } else { 'MASIH BATERAI - dGPU akan dibatasi' })
        if (-not $onAC) { $siap = $false }
        Write-Host ""
    }

    # ---------------- Kesimpulan ----------------
    Write-Host "  KESIMPULAN" -ForegroundColor White
    if ($siap) {
        Write-Host "    Mesin dalam kondisi diam dan siap untuk benchmark maupun MinKNOW." -ForegroundColor Green
    } else {
        Write-Host "    Ada butir bertanda [!!] - benahi dulu sebelum menjalankan Uji A," -ForegroundColor Red
        Write-Host "    karena angka yang dihasilkan tidak akan mencerminkan kemampuan sesungguhnya." -ForegroundColor Red
    }
    Write-Host ""
    if ($siap) { return 0 } else { return 1 }
}

function Show-Usage {
    $me = if ($PSCommandPath) { Split-Path -Leaf $PSCommandPath } else { 'BasecallScript.ps1' }

    function Write-Check {
        param([string]$Label, [bool]$Ok, [string]$Detail)
        $mark = if ($Ok) { '[OK] ' } else { '[!!] ' }
        $col  = if ($Ok) { 'Green' } else { 'Red' }
        Write-Host "    $mark" -ForegroundColor $col -NoNewline
        Write-Host ("{0,-12} " -f $Label) -NoNewline
        Write-Host $Detail -ForegroundColor DarkGray
    }

    Write-Host ""
    Write-Host "  $me - marathon basecalling Dorado" -ForegroundColor Cyan
    Write-Host ""

    Write-Host "  PEMAKAIAN" -ForegroundColor White
    Write-Host "    .\$me [-d <dorado.exe>] [-mc <folder>] [-m <model>]"
    Write-Host "    $(' ' * ($me.Length + 2)) [-i <folder pod5>] [-o <folder>] [-dd <hari>] [-h]"
    Write-Host ""

    # Semua flag opsional; tanpa flag dipakai nilai default di kurung siku.
    Write-Host "  FLAG (semua opsional - nilai sekarang di kurung siku)" -ForegroundColor White
    $mcShown = if ($McExplicit) { $ModelCache } else { '<folder dorado terpilih>\models' }
    $rows = @(
        @('-d,  -Dorado',      'lokasi dorado.exe',            $Dorado),
        @('-mc, -ModelCache',  'folder cache model',           $mcShown),
        @('-m,  -Model',       'nama model basecalling',       $Model),
        @('-i,  -Input',       'folder input POD5',            $Pod5Input),
        @('-o,  -Output',      'folder output',                $Output),
        @('-dd, -Duration',    'lama marathon, hari (0-3650)', "$DayDuration"),
        @('-dev, -Device',     'target dorado',                $Device),
        @('-r,  -Recursive',   'sisir subfolder POD5',         "$Recursive"),
        @('-kb, -KeepBam',     'simpan BAM tiap loop',         "$KeepBam"),
        @('-mf, -MinFreeGB',   'stop kalau sisa disk < ini',   "$MinFreeGB$(if ($MinFreeAuto) { ' auto' })"),
        @('-mfail, -MaxFail',  'stop setelah gagal beruntun',  "$MaxFail"),
        @('-b,  -BatchSize',   'batch dorado (0=auto)',        "$BatchSize"),
        @('-mr, -MaxReads',    'read per loop (0=semua)',      "$MaxReads"),
        @('-vt, -VirtualTB',   'TB POD5 per run virtual',      "$VirtualTB"),
        @('-vr, -VirtualRuns', 'stop setelah N run (0=off)',   "$VirtualRuns"),
        @('-mt, -MaxTempC',    'jeda dingin di atas suhu ini', "$MaxTempC$(if ($MaxTempAuto) { ' auto' })"),
        @('-as, -AllowSleep',  'izinkan Windows tidur',        "$AllowSleep"),
        @('-su, -Setup',       'pasang dorado+model bila perlu', ''),
        @('-dv, -DoradoVersion','versi dorado untuk -su',       $DoradoVersion),
        @('-sd, -SetupDir',    'tujuan pasang dorado',         $(if ($SetupDir) { $SetupDir } else { '<drive paling lega>' })),
        @('-hw, -Hardware',    'periksa kondisi diam mesin',   ''),
        @('-rep, -Report',     'vonis kelayakan dari hasil',   ''),
        @('-h,  -Help',        'tampilkan bantuan ini',        '')
    )
    foreach ($r in $rows) {
        Write-Host ("    {0,-18}{1,-30}" -f $r[0], $r[1]) -NoNewline
        if ($r[2]) { Write-Host "[$($r[2])]" -ForegroundColor DarkGray } else { Write-Host "" }
    }
    Write-Host ""

    # --- Prasyarat: dicek beneran, bukan cuma didaftar ---
    Write-Host "  PRASYARAT" -ForegroundColor White

    $d = Resolve-Dorado -Path $Dorado -Explicit $DoradoExplicit
    if ($d) { Write-Check 'dorado.exe' $true "$($d.Source)  ($($d.From))" }
    else    { Write-Check 'dorado.exe' $false "tidak ketemu - pakai -d, atau taruh folder dorado-#.#.#-win64 di akar drive" }

    $smi = Get-Command 'nvidia-smi.exe' -CommandType Application -ErrorAction SilentlyContinue |
           Select-Object -First 1
    if ($smi) { Write-Check 'nvidia-smi' $true $smi.Source }
    else      { Write-Check 'nvidia-smi' $false 'tidak ada di PATH - logging GPU akan gagal tiap loop' }

    if (Test-Path -LiteralPath $Pod5Input -PathType Container) {
        $p5 = @(Get-ChildItem -LiteralPath $Pod5Input -Filter *.pod5 -File -Recurse:$Recursive -ErrorAction SilentlyContinue)
        $n  = $p5.Count
        $tb = if ($n) { [math]::Round((($p5 | Measure-Object Length -Sum).Sum) / 1TB, 2) } else { 0 }
        Write-Check 'input POD5' ($n -gt 0) "$Pod5Input  ($n berkas .pod5, $tb TB)"
    } else {
        Write-Check 'input POD5' $false "$Pod5Input tidak ada - wajib, pakai -i"
    }

    # Cek drive tujuan, bukan foldernya: folder output memang dibuat belakangan.
    $outRoot = [System.IO.Path]::GetPathRoot($Output)
    $drv = [System.IO.DriveInfo]::GetDrives() |
           Where-Object { $_.IsReady -and $_.RootDirectory.FullName -eq $outRoot } |
           Select-Object -First 1
    if ($drv) {
        $gb = [math]::Round($drv.AvailableFreeSpace / 1GB, 1)
        Write-Check 'drive output' ($gb -ge $MinFreeGB) "$outRoot sisa $gb GB (butuh >= $MinFreeGB GB; BAM 1.3 TB POD5 ~ 114 GB per loop)"
    } else {
        Write-Check 'drive output' $false "drive $outRoot tidak ada / tidak siap - pakai -o"
    }

    # Laptop: marathon 7 hari mustahil kalau masih di baterai atau layar mati bikin tidur.
    $ps = [System.Windows.Forms.SystemInformation]::PowerStatus 2>$null
    if ($ps -and $ps.BatteryChargeStatus -ne 'NoSystemBattery') {
        $onAC = ($ps.PowerLineStatus -eq 'Online')
        Write-Check 'daya' $onAC $(if ($onAC) { 'terhubung adaptor (laptop)' } else { 'MASIH BATERAI - colok adaptor sebelum marathon' })
    }
    Write-Host ""

    Write-Host "  CONTOH" -ForegroundColor White
    Write-Host "    .\$me -i D:\pod5_pass -o D:\hasil -dd 3" -ForegroundColor DarkGray
    Write-Host "    .\$me -d C:\dorado-2.1.1-win64\bin\dorado.exe -m dna_r10.4.1_e8.2_400bps_hac@v5.2.0" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Marathon berhenti sendiri setelah -dd hari, atau tekan Ctrl+C." -ForegroundColor DarkGray
    Write-Host ""
}

# --- Resolusi guardrail otomatis (dilakukan sekali, sebelum help maupun marathon) ---
$Pod5Bytes = Get-Pod5Bytes -Path $Pod5Input -Deep $Recursive

$MinFreeAuto = ($MinFreeGB -eq 0)
if ($MinFreeAuto) { $MinFreeGB = Get-AutoMinFreeGB -Pod5Bytes $Pod5Bytes }

$MaxTempAuto = ($MaxTempC -eq 0)
if ($MaxTempAuto) { $MaxTempC = Get-AutoMaxTempC }

if ($Help) { Show-Usage; exit 0 }

if ($Hardware) {
    Clear-Host
    exit (Show-HardwareIdle -Pod5Path $Pod5Input -OutPath $Output)
}

if ($Report) {
    Clear-Host
    $csvPath = Join-Path $Output 'marathon_summary.csv'
    $rc = Show-Report -Csv $csvPath
    try {
        New-DailyReports -Csv $csvPath -OutDir $Output -ModelName $Model -DeviceName $Device -Final
        $idxHtml = Join-Path $Output 'report.html'
        if (Test-Path -LiteralPath $idxHtml) {
            Write-Host "  Laporan HTML : $idxHtml" -ForegroundColor Cyan
            Write-Host ""
        }
    } catch { }
    exit $rc
}

if ($Setup) {
    Write-Host ""
    Write-Host "  SETUP - memeriksa dorado dan model" -ForegroundColor Cyan
    Write-Host ""
    $exe = Install-DoradoIfMissing -HintPath $Dorado -Explicit $DoradoExplicit `
                                   -Version $DoradoVersion -Dir $SetupDir
    if (-not $exe) {
        Write-Host "[ERROR] Setup dorado gagal. Marathon dibatalkan." -ForegroundColor Red
        exit 1
    }
    $Dorado = $exe
    $DoradoExplicit = $true
    $cacheForSetup = if ($McExplicit) { $ModelCache } else { Join-Path (Split-Path $exe -Parent) 'models' }
    [void](Install-ModelIfMissing -Exe $exe -ModelName $Model -Cache $cacheForSetup)
    Write-Host ""
}

$DoradoFound = Resolve-Dorado -Path $Dorado -Explicit $DoradoExplicit
if (-not $DoradoFound) {
    Write-Host "[ERROR] Dorado tidak ditemukan: tidak ada folder dorado-#.#.#-win64, '$Dorado' tidak ada, dan tidak ada di PATH!" -ForegroundColor Red
    Write-Host "        Pakai -d <jalur\dorado.exe>, atau tambahkan folder bin dorado ke PATH." -ForegroundColor Red
    exit 1
}
if ($DoradoFound.From -ne '-d') {
    Write-Host "[INFO] Dorado dipilih otomatis: $($DoradoFound.From)" -ForegroundColor DarkCyan
}
$Dorado = $DoradoFound.Source

# Kalau -mc tidak diberikan, ikutkan cache model ke folder dorado yang terpilih,
# supaya tidak membuat folder models di bawah versi dorado yang tidak dipakai.
if (-not $McExplicit) {
    $ModelCache = Join-Path (Split-Path $Dorado -Parent) 'models'
}

$ParamLines = @(
    "Dorado      : $Dorado"
    "Model       : $Model"
    "Model cache : $ModelCache"
    "Input POD5  : $Pod5Input"
    "Output      : $Output"
    "Device      : $Device"
    "Recursive   : $Recursive"
    "Durasi      : $DayDuration hari (selesai $EndTime)"
    "Simpan BAM  : $KeepBam"
    "Batch/Suhu  : batchsize $(if ($BatchSize -gt 0) { $BatchSize } else { 'auto (dorado sesuaikan VRAM)' }), jeda dingin di atas $MaxTempC C$(if ($MaxTempAuto) { ' (auto)' })"
    "Disk guard  : min sisa $MinFreeGB GB$(if ($MinFreeAuto) { " (auto dari $([math]::Round($Pod5Bytes/1TB,2)) TB POD5)" })"
    "Max reads   : $(if ($MaxReads -gt 0) { "$MaxReads per loop" } else { 'semua read' })"
    "Run virtual : $(if ($VirtualTB -gt 0) { "$VirtualTB TB/run$(if ($VirtualRuns -gt 0) { ", stop di $VirtualRuns run" })" } else { 'nonaktif' })"
)

foreach ($line in $ParamLines) { Write-Host $line -ForegroundColor DarkGray }

if (!(Test-Path $Pod5Input))  { Write-Host "[ERROR] Folder Input POD5 '$Pod5Input' tidak ditemukan!" -ForegroundColor Red; exit 1 }
if (!(Test-Path $Output))     { New-Item -ItemType Directory -Force -Path $Output | Out-Null }
if (!(Test-Path $ModelCache)) { New-Item -ItemType Directory -Force -Path $ModelCache | Out-Null }

$ParamFile = Join-Path $Output "RunningParameter.txt"
Set-Content -LiteralPath $ParamFile -Encoding utf8 -Value $ParamLines

# Spesifikasi direkam sekali di awal, supaya laporan yang dibaca belakangan tetap
# menampilkan mesin YANG DIUJI - bukan mesin yang kebetulan membuka laporannya.
$SpecFile = Join-Path $Output 'machine_spec.json'
try {
    $MachineSpec = Get-MachineSpec -DoradoPath $Dorado -ModelName $Model -ModelCachePath $ModelCache `
                                   -Pod5Path $Pod5Input -OutputPath $Output -DeviceName $Device
    Save-MachineSpec -Spec $MachineSpec -Path $SpecFile
} catch { }

Write-Host "Looping Marathon Dorado Dimulai (Keamanan Pipeline Dioptimalkan)." -ForegroundColor Cyan
Write-Host "Tekan [Ctrl + C] untuk menghentikan pengujian marathon ini." -ForegroundColor Yellow
Write-Host "------------------------------------------------------------------------"

$loopCount   = 1
$failStreak  = 0
$EffBatch    = $BatchSize   # 0 = biarkan dorado yang pilih sesuai VRAM mesin ini
$CumEquivGB  = 0.0          # akumulasi POD5-setara yang sudah dibasecall (lintas loop)
$RunsDone    = 0.0          # $CumEquivGB dinyatakan dalam satuan run virtual ($VirtualTB)
$SummaryCsv  = Join-Path $Output "marathon_summary.csv"
if (!(Test-Path -LiteralPath $SummaryCsv)) {
    Set-Content -LiteralPath $SummaryCsv -Encoding utf8 `
        -Value 'loop,start,end,seconds,exitcode,batchsize,bam_gb,gb_per_hour,pod5_equiv_gb,cum_tb,virtual_runs,gpu_max_temp_c,gpu_avg_util_pct,gpu_avg_power_w,gpu_avg_clock_mhz,status'
}

$OutRootDrive = [System.IO.Path]::GetPathRoot($Output)

# Resolusi nvidia-smi sekali saja. Kalau tidak ada, logging GPU dilewati -
# marathon TIDAK boleh mati cuma karena tool monitoring tidak terpasang.
$NvSmi = (Get-Command 'nvidia-smi.exe' -CommandType Application -ErrorAction SilentlyContinue |
          Select-Object -First 1).Source
if (-not $NvSmi) {
    Write-Host "[WARN] nvidia-smi tidak ada di PATH - logging suhu/utilisasi GPU dilewati." -ForegroundColor Yellow
}

# --- Tahan Windows supaya tidak tidur/hibernate di tengah marathon (penting di laptop) ---
# SetThreadExecutionState hanya berlaku selama proses ini hidup, jadi tidak mengubah
# setelan daya user secara permanen - begitu skrip selesai, semuanya kembali normal.
Add-Type -Namespace Win32 -Name Power -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)]
public static extern uint SetThreadExecutionState(uint esFlags);
'@ -ErrorAction SilentlyContinue

function Set-KeepAwake {
    param([bool]$On)
    try {
        if ($On) { [void][Win32.Power]::SetThreadExecutionState(0x80000000 -bor 0x00000001 -bor 0x00000040) }  # CONTINUOUS|SYSTEM|AWAYMODE
        else     { [void][Win32.Power]::SetThreadExecutionState(0x80000000) }                                   # CONTINUOUS saja = lepas
    } catch { }
}

# Suhu GPU tertinggi saat ini (semua GPU), atau -1 kalau nvidia-smi tidak ada.
function Get-GpuTempC {
    try {
        if (-not (Get-Command 'nvidia-smi.exe' -CommandType Application -ErrorAction SilentlyContinue)) { return -1 }
        $t = & nvidia-smi.exe --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $t) { return -1 }
        return ([int[]]($t | Where-Object { $_ -match '^\s*\d+\s*$' })) | Sort-Object -Descending | Select-Object -First 1
    } catch { return -1 }
}

# Ringkasan metrik GPU satu loop dari CSV nvidia-smi.
#
# Kolom dicari berdasarkan KECOCOKAN SEBAGIAN nama, bukan nama persis: header
# nvidia-smi bisa tampil sebagai " utilization.gpu" atau " utilization.gpu [%]"
# tergantung versi driver, dan pencocokan persis diam-diam menghasilkan kolom kosong.
function Get-GpuStats {
    param([string]$Csv)
    $res = [PSCustomObject]@{ MaxTemp = ''; AvgUtil = ''; AvgPower = ''; AvgClock = '' }
    try {
        if (!(Test-Path -LiteralPath $Csv)) { return $res }
        $rows = @(Import-Csv -LiteralPath $Csv -ErrorAction SilentlyContinue)
        if (-not $rows) { return $res }

        $cols = $rows[0].PSObject.Properties.Name
        function Pick {
            param($Rows, $Cols, [string]$Needle)
            $c = $Cols | Where-Object { $_ -like "*$Needle*" } | Select-Object -First 1
            if (-not $c) { return @() }
            return @($Rows | ForEach-Object { $_.$c } |
                     Where-Object { $_ -match '^\s*[\d.]+\s*$' } | ForEach-Object { [double]$_ })
        }

        $temps  = Pick $rows $cols 'temperature.gpu'
        $utils  = Pick $rows $cols 'utilization.gpu'
        $powers = Pick $rows $cols 'power.draw'
        $clocks = Pick $rows $cols 'clocks'

        if ($temps)  { $res.MaxTemp  = [int](($temps | Measure-Object -Maximum).Maximum) }
        if ($utils)  { $res.AvgUtil  = [math]::Round(($utils  | Measure-Object -Average).Average, 0) }
        if ($powers) { $res.AvgPower = [math]::Round(($powers | Measure-Object -Average).Average, 0) }
        if ($clocks) { $res.AvgClock = [math]::Round(($clocks | Measure-Object -Average).Average, 0) }
    } catch { }
    return $res
}

# ========================================================================
# 3. MARATHON LOOP (Direct Native Execution - No CMD Wrapper)
# ========================================================================
# Proses anak dilacak supaya Ctrl+C tidak meninggalkan dorado/nvidia-smi hidup.
$script:LiveProcs = New-Object System.Collections.Generic.List[object]

function Stop-LiveProcs {
    foreach ($p in $script:LiveProcs) {
        try { if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } } catch { }
    }
    $script:LiveProcs.Clear()
}

if (-not $AllowSleep) {
    Set-KeepAwake -On $true
    Write-Host "[INFO] Windows ditahan agar tidak tidur selama marathon (pakai -as untuk mematikan)." -ForegroundColor DarkCyan
}

try {
while ((Get-Date) -lt $EndTime) {

    # --- Guard disk: BAM 1.3 TB POD5 ~ 114 GB per loop, jangan sampai drive penuh ---
    $freeGB = Get-FreeGB -Root $OutRootDrive
    if ($freeGB -ge 0 -and $freeGB -lt $MinFreeGB) {
        Write-Host "[STOP] Sisa ruang $OutRootDrive tinggal $freeGB GB (< $MinFreeGB GB). Marathon dihentikan." -ForegroundColor Red
        break
    }

    # --- Guard suhu: laptop paling sering mati/throttle karena panas, bukan karena error ---
    $t0 = Get-GpuTempC
    while ($t0 -ge 0 -and $t0 -gt $MaxTempC -and (Get-Date) -lt $EndTime) {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] GPU $t0 C > $MaxTempC C - jeda 120 detik biar dingin dulu." -ForegroundColor DarkYellow
        Start-Sleep -Seconds 120
        $t0 = Get-GpuTempC
    }
    if ((Get-Date) -ge $EndTime) { break }

    $TS = Get-Date -Format "yyyyMMdd_HHmmss"

    $GpuLog  = "$Output\gpu_loop_${loopCount}_$TS.csv"
    $LogFile = "$Output\dorado_loop_${loopCount}_$TS.log"
    $OutBam  = "$Output\calls_loop_${loopCount}_$TS.bam"

    $tStart    = Get-Date
    $timeStart = $tStart.ToString("HH:mm:ss")
    Write-Host "[$timeStart] Memulai Loop ke-${loopCount} (sisa disk $freeGB GB): $OutBam" -ForegroundColor Yellow

    # 1. Background GPU Logger (nounits = langsung bisa diolah Import-Csv / pandas)
    $gpuArgs = "--query-gpu=timestamp,temperature.gpu,utilization.gpu,utilization.memory,memory.used,power.draw,clocks.sm --format=csv,nounits -l 10"
    $gpuProc = $null
    if ($NvSmi) {
        try {
            $gpuProc = Start-Process $NvSmi -ArgumentList $gpuArgs -WindowStyle Hidden `
                -PassThru -RedirectStandardOutput $GpuLog
        } catch {
            Write-Host "[WARN] gagal menjalankan nvidia-smi: $($_.Exception.Message)" -ForegroundColor DarkYellow
        }
    }
    if ($gpuProc) { $null = $gpuProc.Handle; $script:LiveProcs.Add($gpuProc) }

    # 2. Native PowerShell Argument Array (Clean & Direct)
    $doradoArgs = @(
        "basecaller",
        $Model,
        $Pod5Input,
        "--models-directory", $ModelCache,
        "--device", $Device
    )
    if ($Recursive)      { $doradoArgs += "--recursive" }
    if ($EffBatch  -gt 0) { $doradoArgs += @("--batchsize", "$EffBatch") }
    if ($MaxReads  -gt 0) { $doradoArgs += @("--max-reads",  "$MaxReads") }

    # 3. Direct Execution with Safe Streaming Redirection
    #    stdout = BAM, stderr = log dorado ASLI (bukan hasil scraping buffer konsol).
    $process = $null
    try {
        $process = Start-Process -FilePath $Dorado -ArgumentList $doradoArgs `
            -RedirectStandardOutput $OutBam -RedirectStandardError $LogFile `
            -NoNewWindow -PassThru
    } catch {
        Write-Host "[ERROR] Gagal menjalankan dorado: $($_.Exception.Message)" -ForegroundColor Red
    }
    # PENTING: Start-Process -PassThru mengembalikan objek yang ExitCode-nya KOSONG
    # kecuali handle proses diakses sebelum proses keluar. Tanpa baris ini, tiap loop
    # dinilai GAGAL dan marathon berhenti di loop ke-3 walau dorado sebenarnya sukses.
    if ($process) { $null = $process.Handle }

    if (-not $process) {
        if ($gpuProc) { Stop-Process -Id $gpuProc.Id -Force -ErrorAction SilentlyContinue }
        $failStreak++
        if ($failStreak -ge $MaxFail) { Write-Host "[STOP] dorado gagal dijalankan $failStreak kali beruntun." -ForegroundColor Red; break }
        Start-Sleep -Seconds 15
        $loopCount++
        continue
    }
    $script:LiveProcs.Add($process)

    try {
        # Cek tiap 10 detik; kalau sudah lewat batas marathon, hentikan pass yang sedang jalan
        # supaya -dd 7 benar-benar berarti 7 hari, bukan 7 hari + sisa satu pass 1.3 TB.
        while (-not $process.WaitForExit(10000)) {
            if ((Get-Date) -ge $EndTime) {
                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Batas $DayDuration hari tercapai - menghentikan loop ke-${loopCount}." -ForegroundColor Yellow
                Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
                $process.WaitForExit(30000) | Out-Null
                break
            }
        }
    }
    finally {
        if ($gpuProc) { Stop-Process -Id $gpuProc.Id -Force -ErrorAction SilentlyContinue }
        $script:LiveProcs.Clear()
    }

    # ----------------------------------------------------------------====
    # 4. LOGIKA VALIDASI ROBUST
    # ----------------------------------------------------------------====
    $code = try { $process.ExitCode } catch { $null }

    $bamBytes = 0L
    if (Test-Path -LiteralPath $OutBam) { $bamBytes = (Get-Item -LiteralPath $OutBam).Length }
    $bamGB = [math]::Round($bamBytes / 1GB, 2)

    $tEnd  = Get-Date
    $secs  = [math]::Round(($tEnd - $tStart).TotalSeconds, 0)
    $rate  = if ($secs -gt 0) { [math]::Round($bamGB / ($secs / 3600), 2) } else { 0 }

    # Exit code adalah sumber kebenaran; log cuma pelengkap diagnosa.
    $IsSuccess = ($code -eq 0) -and ($bamBytes -gt 0)
    $isOom     = $false

    if ($IsSuccess) {
        $failStreak = 0
        Write-Host "[$($tEnd.ToString('HH:mm:ss'))] SUKSES Loop ke-${loopCount}: $bamGB GB dalam $secs s ($rate GB/jam)." -ForegroundColor Green
    } else {
        # VRAM tiap mesin beda-beda, jadi kalau auto-batch dorado kebesaran dan OOM,
        # turunkan sendiri dan coba lagi - tanpa perlu disetel manual per mesin.
        $isOom = $false
        if (Test-Path -LiteralPath $LogFile) {
            $tail = Get-Content -LiteralPath $LogFile -Tail 40 -ErrorAction SilentlyContinue
            $isOom = [bool]($tail -match 'out of memory|OutOfMemory|CUDA error: out|cudaErrorMemoryAllocation')
        }

        if ($isOom -and $EffBatch -ne 64) {
            $EffBatch = if ($EffBatch -le 0) { 384 } else { [math]::Max(64, [int]($EffBatch / 2)) }
            Write-Host "[$($tEnd.ToString('HH:mm:ss'))] Loop ke-${loopCount} kehabisan VRAM - batchsize diturunkan ke $EffBatch, ulangi." -ForegroundColor DarkYellow
        } else {
            $failStreak++
        }

        Write-Host "[$($tEnd.ToString('HH:mm:ss'))] GAGAL Loop ke-${loopCount} (exit=$code, bam=$bamGB GB) - gagal beruntun ke-$failStreak." -ForegroundColor Red
        if (Test-Path -LiteralPath $LogFile) {
            # Ekor log dorado jauh lebih informatif daripada baris pertama.
            Get-Content -LiteralPath $LogFile -Tail 5 -ErrorAction SilentlyContinue |
                ForEach-Object { Write-Host "  [dorado] $_" -ForegroundColor DarkYellow }
        }
    }

    # 5. Buang BAM setelah divalidasi - 1.3 TB POD5 menghasilkan ~114 GB BAM per loop,
    #    dan untuk uji marathon isinya tidak dipakai. Pakai -kb kalau mau disimpan.
    if (-not $KeepBam -and (Test-Path -LiteralPath $OutBam)) {
        Remove-Item -LiteralPath $OutBam -Force -ErrorAction SilentlyContinue
    }

    # Berapa POD5 yang setara sudah diproses loop ini. Diturunkan dari ukuran BAM
    # (BAM ~ 9% POD5), jadi tetap benar walau loop dipotong -mr atau kena batas waktu.
    $equivGB = if ($bamGB -gt 0) { [math]::Round($bamGB / 0.09, 1) } else { 0 }
    $CumEquivGB += $equivGB
    $cumTB = [math]::Round($CumEquivGB / 1024, 3)
    if ($VirtualTB -gt 0) {
        $RunsDone = [math]::Round($CumEquivGB / ($VirtualTB * 1024), 2)
        Write-Host "  Emulasi: +$equivGB GB POD5-setara | total $cumTB TB = $RunsDone run virtual ($VirtualTB TB/run)" -ForegroundColor DarkGray
    }

    $status = if ($IsSuccess) { 'OK' } elseif ($isOom) { 'OOM' } else { 'FAIL' }
    $g = Get-GpuStats -Csv $GpuLog
    if ($g.MaxTemp -ne '') {
        # Daya dan clock SM jauh lebih jujur daripada utilization.gpu, yang hanya mengukur
        # ADA/TIDAKNYA kernel berjalan - bukan seberapa besar kapasitas GPU yang terpakai.
        Write-Host ("  GPU: suhu maks {0} C | util {1}% | daya {2} W | clock SM {3} MHz" -f `
            $g.MaxTemp, $g.AvgUtil, $g.AvgPower, $g.AvgClock) -ForegroundColor DarkGray
    }
    Add-Content -LiteralPath $SummaryCsv -Encoding utf8 -Value (
        "{0},{1},{2},{3},{4},{5},{6},{7},{8},{9},{10},{11},{12},{13},{14},{15}" -f $loopCount,
            $tStart.ToString('yyyy-MM-dd HH:mm:ss'), $tEnd.ToString('yyyy-MM-dd HH:mm:ss'),
            $secs, $code, $(if ($EffBatch -gt 0) { $EffBatch } else { 'auto' }),
            $bamGB, $rate, $equivGB, $cumTB, $RunsDone,
            $g.MaxTemp, $g.AvgUtil, $g.AvgPower, $g.AvgClock, $status)

    # Laporan HTML dibangun ulang tiap loop: murah, dan membuat hasil bisa dibaca
    # kapan saja tanpa menunggu marathon 7 hari selesai.
    try { New-DailyReports -Csv $SummaryCsv -OutDir $Output -ModelName $Model -DeviceName $Device } catch { }

    if ($VirtualRuns -gt 0 -and $VirtualTB -gt 0 -and $RunsDone -ge $VirtualRuns) {
        Write-Host "[SELESAI] Target $VirtualRuns run virtual tercapai ($cumTB TB POD5-setara)." -ForegroundColor Green
        break
    }
    if ($failStreak -ge $MaxFail) {
        Write-Host "[STOP] $failStreak loop gagal beruntun - kemungkinan salah model/driver, bukan masalah sesaat." -ForegroundColor Red
        Write-Host "       Periksa $LogFile lalu jalankan ulang." -ForegroundColor Red
        break
    }
    if (-not $IsSuccess) { Start-Sleep -Seconds 15 }

    $loopCount++
    Write-Host "------------------------------------------------------------------------"
}
}
finally {
    Stop-LiveProcs
    if (-not $AllowSleep) { Set-KeepAwake -On $false }
    Write-Host ""
    if ($VirtualTB -gt 0 -and $CumEquivGB -gt 0) {
        Write-Host ("Total dibasecall: {0} TB POD5-setara = {1} run virtual @ {2} TB." -f `
            [math]::Round($CumEquivGB / 1024, 3), $RunsDone, $VirtualTB) -ForegroundColor Cyan
    }
    Write-Host "Marathon selesai. Ringkasan per loop: $SummaryCsv" -ForegroundColor Cyan
    try { [void](Show-Report -Csv $SummaryCsv) } catch { }
    try {
        New-DailyReports -Csv $SummaryCsv -OutDir $Output -ModelName $Model -DeviceName $Device -Final
        # Hanya diumumkan kalau berkasnya benar-benar terbentuk: kalau marathon
        # berhenti sebelum ada satu pun loop, tidak ada laporan untuk dibuka.
        $finalHtml = Join-Path $Output 'report_final.html'
        if (Test-Path -LiteralPath $finalHtml) {
            Write-Host "  Hasil akhir  : $finalHtml" -ForegroundColor Cyan
            Write-Host "  Indeks harian: $(Join-Path $Output 'report.html')" -ForegroundColor Cyan
            Write-Host ""
        }
    } catch { }
}
