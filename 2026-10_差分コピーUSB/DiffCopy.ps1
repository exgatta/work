<#
  DiffCopy.ps1
  ネットワークフォルダから「まだコピーしていないファイル」だけを、このスクリプトが置かれた
  USB メモリへコピーする。コピー済みの記録は USB 内の _state\copied.csv に持つので、
  USB からファイルを別 PC へ移して空にしても差分判定ができる。

  使い方（通常は同じフォルダの .bat から起動する）:
    DiffCopy.ps1                 差分をコピーする
    DiffCopy.ps1 -DryRun         コピー対象を表示するだけ（記録もコピーもしない）
    DiffCopy.ps1 -RegisterOnly   今あるファイルを全部「コピー済み」として記録する（初回用）

  設定は同じフォルダの config.json を読む。
  Windows 標準の PowerShell 5.1 で動く範囲の文法だけを使うこと。
#>
[CmdletBinding()]
param(
    [string]$BaseDir = "",
    [switch]$DryRun,
    [switch]$RegisterOnly
)

$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------
# 基本パス
# ------------------------------------------------------------
if (-not $BaseDir) { $BaseDir = $PSScriptRoot }
if (-not $BaseDir -and $MyInvocation.MyCommand.Path) {
    $BaseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
}
if (-not $BaseDir) {
    Write-Host "スクリプトの場所が特定できません。-BaseDir でフォルダを指定してください。" -ForegroundColor Red
    exit 1
}
$BaseDir = (Get-Item -LiteralPath $BaseDir).FullName

$ConfigPath   = Join-Path $BaseDir 'config.json'
$StateDir     = Join-Path $BaseDir '_state'
$ManifestPath = Join-Path $StateDir 'copied.csv'
$LogDir       = Join-Path $BaseDir 'logs'

$Mode = 'copy'
if ($DryRun)       { $Mode = 'dryrun' }
if ($RegisterOnly) { $Mode = 'register' }

# ------------------------------------------------------------
# ログ
# ------------------------------------------------------------
if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }
$RunStamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$LogPath  = Join-Path $LogDir ("{0}_{1}.log" -f $RunStamp, $Mode)
$script:LogWriter = New-Object System.IO.StreamWriter($LogPath, $false, (New-Object System.Text.UTF8Encoding($true)))

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR','OK')][string]$Level = 'INFO',
        [switch]$ConsoleOnly
    )
    $line = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    if (-not $ConsoleOnly) { $script:LogWriter.WriteLine($line) }
    switch ($Level) {
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'OK'    { Write-Host $line -ForegroundColor Green }
        default { Write-Host $line }
    }
}

function Format-Size {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return ("{0:N2} GB" -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ("{0:N1} MB" -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ("{0:N0} KB" -f ($Bytes / 1KB)) }
    return ("{0} B" -f $Bytes)
}

function ConvertTo-CsvField {
    param([string]$Value)
    return '"' + $Value.Replace('"', '""') + '"'
}

function Test-AnyLike {
    param([string]$Text, [string[]]$Patterns)
    foreach ($p in $Patterns) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        if ($Text -like $p) { return $true }
    }
    return $false
}

# ------------------------------------------------------------
# 設定
# ------------------------------------------------------------
$Config = @{
    SourcePath              = ''
    DestSubFolder           = 'data'
    RunFolderFormat         = 'yyyy-MM-dd'
    Recurse                 = $true
    IncludeFileNames        = @('*')
    ExcludeFileNames        = @('~$*', 'Thumbs.db', 'desktop.ini', '*.tmp')
    ExcludeFolders          = @()
    SkipIfModifiedWithinSec = 60
    CopyUpdatedFiles        = $false
    RequireRemovableDrive   = $true
    AllowedVolumeSerial     = ''
    FreeSpaceMarginMB       = 200
    LogKeepDays             = 90
}

$exitCode = 0
try {
    Write-Log ("===== 差分コピー 開始 [モード: {0}] =====" -f $Mode)
    Write-Log ("実行フォルダ: {0}" -f $BaseDir)

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "設定ファイルがありません: $ConfigPath"
    }
    $json = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($key in @($Config.Keys)) {
        $prop = $json.PSObject.Properties[$key]
        if ($null -ne $prop -and $null -ne $prop.Value) { $Config[$key] = $prop.Value }
    }
    foreach ($key in @('IncludeFileNames', 'ExcludeFileNames', 'ExcludeFolders')) {
        $Config[$key] = @($Config[$key] | ForEach-Object { [string]$_ })
    }
    if ($Config.IncludeFileNames.Count -eq 0) { $Config.IncludeFileNames = @('*') }

    if ([string]::IsNullOrWhiteSpace($Config.SourcePath)) {
        throw "config.json の SourcePath（コピー元フォルダ）が空です。例: \\\\server\\share\\daily"
    }

    # --------------------------------------------------------
    # USB の確認
    # --------------------------------------------------------
    $driveRoot = [System.IO.Path]::GetPathRoot($BaseDir)
    $drive = $null
    try { $drive = New-Object System.IO.DriveInfo($driveRoot) } catch { $drive = $null }

    if ($null -eq $drive -or -not $drive.IsReady) {
        if ($Config.RequireRemovableDrive) {
            throw "実行フォルダのドライブが特定できません（$driveRoot）。USB メモリ上の .bat から実行してください。"
        }
    }
    else {
        Write-Log ("実行ドライブ: {0} 種別={1} ラベル='{2}' 空き={3}" -f $driveRoot, $drive.DriveType, $drive.VolumeLabel, (Format-Size $drive.AvailableFreeSpace))
        if ($Config.RequireRemovableDrive -and $drive.DriveType -ne 'Removable') {
            throw "実行ドライブ $driveRoot はリムーバブルドライブではありません。USB メモリ上から実行してください（config.json の RequireRemovableDrive を false にすると無効化できます）。"
        }
    }

    if ($env:OS -eq 'Windows_NT') {
        $serial = $null
        try {
            $letter = $driveRoot.TrimEnd('\')
            $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $letter) -ErrorAction Stop
            if ($disk) { $serial = [string]$disk.VolumeSerialNumber }
        } catch { $serial = $null }
        if ($serial) {
            Write-Log ("ボリュームシリアル: {0}" -f $serial)
            if (-not [string]::IsNullOrWhiteSpace($Config.AllowedVolumeSerial)) {
                $allowed = ([string]$Config.AllowedVolumeSerial).Replace('-', '').ToUpperInvariant()
                if ($serial.Replace('-', '').ToUpperInvariant() -ne $allowed) {
                    throw "この USB はシリアル番号が一致しません（実際: $serial / 設定: $($Config.AllowedVolumeSerial)）。"
                }
            }
        }
        elseif (-not [string]::IsNullOrWhiteSpace($Config.AllowedVolumeSerial)) {
            Write-Log "ボリュームシリアルを取得できなかったため、AllowedVolumeSerial の照合をスキップしました。" 'WARN'
        }
    }

    # --------------------------------------------------------
    # コピー元の確認
    # --------------------------------------------------------
    $src = [string]$Config.SourcePath
    if (-not (Test-Path -LiteralPath $src -PathType Container)) {
        throw "コピー元フォルダにアクセスできません: $src （ネットワーク接続・権限・パスの綴りを確認してください）"
    }
    $srcRoot = (Get-Item -LiteralPath $src).FullName.TrimEnd('\', '/')
    Write-Log ("コピー元: {0}" -f $srcRoot)

    # --------------------------------------------------------
    # コピー先
    # --------------------------------------------------------
    $destBase = [string]$Config.DestSubFolder
    if (-not [System.IO.Path]::IsPathRooted($destBase)) { $destBase = Join-Path $BaseDir $destBase }
    if (-not [string]::IsNullOrWhiteSpace($Config.RunFolderFormat)) {
        $destBase = Join-Path $destBase (Get-Date -Format ([string]$Config.RunFolderFormat))
    }
    if ($Mode -eq 'copy') { Write-Log ("コピー先: {0}" -f $destBase) }

    # --------------------------------------------------------
    # コピー済み一覧の読み込み
    # --------------------------------------------------------
    if (-not (Test-Path -LiteralPath $StateDir)) { New-Item -ItemType Directory -Path $StateDir | Out-Null }
    $known = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([System.StringComparer]::OrdinalIgnoreCase)
    if (Test-Path -LiteralPath $ManifestPath) {
        $rows = @(Import-Csv -LiteralPath $ManifestPath -Encoding UTF8)
        foreach ($r in $rows) {
            if ($null -ne $r.RelativePath -and $r.RelativePath -ne '') { $known[$r.RelativePath] = $r }
        }
        Write-Log ("コピー済み記録: {0} 件 ({1})" -f $known.Count, $ManifestPath)
        if ($Mode -ne 'dryrun') {
            Copy-Item -LiteralPath $ManifestPath -Destination ($ManifestPath + '.bak') -Force
        }
    }
    else {
        Write-Log "コピー済み記録はまだありません（初回）。" 'WARN'
    }

    # --------------------------------------------------------
    # コピー元の走査
    # --------------------------------------------------------
    $scanErrors = @()
    $gciParams = @{ LiteralPath = $srcRoot; File = $true; ErrorAction = 'SilentlyContinue'; ErrorVariable = 'scanErrors' }
    if ($Config.Recurse) { $gciParams['Recurse'] = $true }
    $allFiles = @(Get-ChildItem @gciParams)
    foreach ($e in $scanErrors) { Write-Log ("走査エラー: {0}" -f $e.Exception.Message) 'WARN' }
    Write-Log ("コピー元のファイル数: {0}" -f $allFiles.Count)

    $nowUtc = (Get-Date).ToUniversalTime()
    $targets   = New-Object System.Collections.Generic.List[object]
    $cntExcluded = 0; $cntKnown = 0; $cntUpdatedSkipped = 0; $cntRecent = 0

    foreach ($f in $allFiles) {
        $rel = $f.FullName.Substring($srcRoot.Length).TrimStart('\', '/')
        $relDir = Split-Path -Parent $rel
        if ($null -eq $relDir) { $relDir = '' }

        if (-not (Test-AnyLike $f.Name $Config.IncludeFileNames)) { $cntExcluded++; continue }
        if (Test-AnyLike $f.Name $Config.ExcludeFileNames)        { $cntExcluded++; continue }
        if ($relDir -ne '' -and $Config.ExcludeFolders.Count -gt 0) {
            $hit = Test-AnyLike $relDir $Config.ExcludeFolders
            if (-not $hit) {
                foreach ($seg in $relDir.Split([char[]]@('\', '/'))) {
                    if (Test-AnyLike $seg $Config.ExcludeFolders) { $hit = $true; break }
                }
            }
            if ($hit) { $cntExcluded++; continue }
        }

        $lastUtc = $f.LastWriteTimeUtc.ToString('o')
        $reason = 'new'
        if ($known.ContainsKey($rel)) {
            $k = $known[$rel]
            $changed = ([string]$k.Size -ne [string]$f.Length) -or ([string]$k.LastWriteUtc -ne $lastUtc)
            if (-not $changed) { $cntKnown++; continue }
            if (-not $Config.CopyUpdatedFiles) {
                $cntUpdatedSkipped++
                Write-Log ("更新あり（対象外）: {0}" -f $rel)
                continue
            }
            $reason = 'updated'
        }

        if ($Config.SkipIfModifiedWithinSec -gt 0) {
            $age = ($nowUtc - $f.LastWriteTimeUtc).TotalSeconds
            if ($age -lt $Config.SkipIfModifiedWithinSec) {
                $cntRecent++
                Write-Log ("書き込み中の可能性があるため今回は見送り（{0:N0} 秒前に更新）: {1}" -f $age, $rel) 'WARN'
                continue
            }
        }

        $targets.Add([pscustomobject]@{
            File = $f; Rel = $rel; RelDir = $relDir; LastUtc = $lastUtc; Reason = $reason
        })
    }

    $totalBytes = 0L
    foreach ($t in $targets) { $totalBytes += $t.File.Length }

    Write-Log ("判定結果: 対象 {0} 件 ({1}) / コピー済み {2} / 除外 {3} / 更新あり対象外 {4} / 見送り {5}" -f `
        $targets.Count, (Format-Size $totalBytes), $cntKnown, $cntExcluded, $cntUpdatedSkipped, $cntRecent)

    # --------------------------------------------------------
    # モード別処理
    # --------------------------------------------------------
    $cntCopied = 0; $cntFailed = 0; $copiedBytes = 0L
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    if ($targets.Count -eq 0) {
        Write-Log "新しいファイルはありません。" 'OK'
    }
    elseif ($Mode -eq 'dryrun') {
        Write-Log "----- コピー対象（確認のみ・実際にはコピーしません） -----"
        foreach ($t in $targets) {
            Write-Log ("  [{0}] {1}  ({2})" -f $t.Reason, $t.Rel, (Format-Size $t.File.Length))
        }
    }
    else {
        $isNew = -not (Test-Path -LiteralPath $ManifestPath)
        $mw = New-Object System.IO.StreamWriter($ManifestPath, $true, (New-Object System.Text.UTF8Encoding($true)))
        try {
            if ($isNew) { $mw.WriteLine('RelativePath,Size,LastWriteUtc,CopiedAt,Mode') }

            if ($Mode -eq 'register') {
                foreach ($t in $targets) {
                    $mw.WriteLine(("{0},{1},{2},{3},{4}" -f (ConvertTo-CsvField $t.Rel), $t.File.Length, $t.LastUtc, (Get-Date -Format 'o'), 'register'))
                    $cntCopied++
                }
                $mw.Flush()
                Write-Log ("{0} 件を「コピー済み」として登録しました（コピーはしていません）。次回から差分だけが対象になります。" -f $cntCopied) 'OK'
            }
            else {
                if ($null -ne $drive -and $drive.IsReady) {
                    $need = $totalBytes + ([long]$Config.FreeSpaceMarginMB * 1MB)
                    if ($drive.AvailableFreeSpace -lt $need) {
                        throw ("USB の空き容量が足りません。必要 {0}（余裕 {1} MB 込み）/ 空き {2}" -f (Format-Size $need), $Config.FreeSpaceMarginMB, (Format-Size $drive.AvailableFreeSpace))
                    }
                }

                $i = 0
                foreach ($t in $targets) {
                    $i++
                    $destDir = $destBase
                    if ($t.RelDir -ne '') { $destDir = Join-Path $destBase $t.RelDir }
                    $destPath = Join-Path $destDir $t.File.Name
                    try {
                        if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
                        Copy-Item -LiteralPath $t.File.FullName -Destination $destPath -Force
                        $copied = Get-Item -LiteralPath $destPath
                        if ($copied.Length -ne $t.File.Length) {
                            throw ("コピー後のサイズが一致しません（元 {0} / 先 {1}）" -f $t.File.Length, $copied.Length)
                        }
                        $mw.WriteLine(("{0},{1},{2},{3},{4}" -f (ConvertTo-CsvField $t.Rel), $t.File.Length, $t.LastUtc, (Get-Date -Format 'o'), $t.Reason))
                        $mw.Flush()
                        $cntCopied++
                        $copiedBytes += $t.File.Length
                        Write-Log ("[{0}/{1}] コピー: {2} ({3})" -f $i, $targets.Count, $t.Rel, (Format-Size $t.File.Length))
                    }
                    catch {
                        $cntFailed++
                        Write-Log ("[{0}/{1}] 失敗: {2} -> {3}" -f $i, $targets.Count, $t.Rel, $_.Exception.Message) 'ERROR'
                    }
                }
            }
        }
        finally {
            $mw.Dispose()
        }
    }

    $sw.Stop()

    # --------------------------------------------------------
    # 古いログの削除
    # --------------------------------------------------------
    if ($Config.LogKeepDays -gt 0) {
        $limit = (Get-Date).AddDays(-1 * [int]$Config.LogKeepDays)
        Get-ChildItem -LiteralPath $LogDir -Filter '*.log' -File | Where-Object { $_.LastWriteTime -lt $limit -and $_.FullName -ne $LogPath } | Remove-Item -Force -ErrorAction SilentlyContinue
    }

    # --------------------------------------------------------
    # まとめ
    # --------------------------------------------------------
    Write-Log "===== 結果 ====="
    switch ($Mode) {
        'dryrun'   { Write-Log ("コピー対象: {0} 件 ({1})。実行するには「差分コピー実行.bat」を使ってください。" -f $targets.Count, (Format-Size $totalBytes)) 'OK' }
        'register' { Write-Log ("登録: {0} 件" -f $cntCopied) 'OK' }
        default {
            $lvl = 'OK'; if ($cntFailed -gt 0) { $lvl = 'WARN' }
            Write-Log ("コピー成功: {0} 件 ({1}) / 失敗: {2} 件 / 所要 {3:N0} 秒" -f $cntCopied, (Format-Size $copiedBytes), $cntFailed, $sw.Elapsed.TotalSeconds) $lvl
            if ($cntCopied -gt 0) { Write-Log ("保存先: {0}" -f $destBase) }
            if ($cntFailed -gt 0) {
                Write-Log "失敗したファイルは記録していないので、次回実行時にもう一度コピーを試みます。" 'WARN'
                $exitCode = 2
            }
        }
    }
    if ($cntRecent -gt 0) { Write-Log ("{0} 件は更新直後のため見送りました。次回実行時に対象になります。" -f $cntRecent) 'WARN' }
    Write-Log ("ログ: {0}" -f $LogPath)
}
catch {
    Write-Log ("中断: {0}" -f $_.Exception.Message) 'ERROR'
    $exitCode = 1
}
finally {
    if ($script:LogWriter) { $script:LogWriter.Dispose() }
}

exit $exitCode
