<#
.SYNOPSIS
  Build / update a visual index of a media folder with hover-preview storyboards.

.DESCRIPTION
  Scans a folder for video files, extracts a storyboard sprite (several frames
  sampled across each video), and generates index.html (hover-preview gallery),
  index.csv (spreadsheet) and rename-map.csv (batch-rename template).

  It is incremental and safe to re-run:
    * new videos are added with new IDs and a fresh storyboard,
    * existing videos keep their ID and storyboard (nothing is re-extracted),
    * entries for deleted videos are dropped (and their storyboard removed).

  Requires ffmpeg (which provides ffprobe) available on PATH.

.PARAMETER Base
  Folder to scan. Defaults to the current directory.

.PARAMETER Frames
  Number of frames sampled per video (default 8).

.PARAMETER Cols / GridRows
  Storyboard grid layout (default 4 x 2 = 8 tiles).

.PARAMETER SpeedMs
  Default hover animation speed, milliseconds per frame (default 700).

.PARAMETER ThumbWidth
  Width in pixels of each storyboard tile (default 240).

.EXAMPLE
  ./update-index.ps1 -Base "D:\Media\Videos"
.EXAMPLE
  ./update-index.ps1 -Frames 12 -Cols 4 -GridRows 3 -SpeedMs 1000
#>
[CmdletBinding()]
param(
  [string]$Base = '.',
  [int]$Frames = 8,
  [int]$Cols = 4,
  [int]$GridRows = 2,
  [int]$SpeedMs = 700,
  [int]$ThumbWidth = 240,
  [switch]$Quiet
)

$ErrorActionPreference = 'Continue'

if (-not (Test-Path -LiteralPath $Base)) { throw "Base folder not found: $Base" }
$Base     = (Resolve-Path -LiteralPath $Base).Path
$indexDir = Join-Path $Base '_index'
$thumbDir = Join-Path $indexDir 'thumbs'
$frameDir = Join-Path $indexDir '_frames'
New-Item -ItemType Directory -Force -Path $thumbDir, $frameDir | Out-Null

function Say($m) { if (-not $Quiet) { Write-Host $m } }

function Find-Tool([string]$name) {
  $c = Get-Command $name -ErrorAction SilentlyContinue
  if ($c) { return $c.Source }
  $roots = @("$env:LOCALAPPDATA\Microsoft\WinGet\Packages", 'C:\Program Files', 'C:\ffmpeg') | Where-Object { $_ -and (Test-Path $_) }
  foreach ($r in $roots) {
    $p = Get-ChildItem -Path $r -Recurse -Filter "$name.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($p) { return $p.FullName }
  }
  return $null
}

$ffmpeg  = Find-Tool 'ffmpeg'
$ffprobe = Find-Tool 'ffprobe'
if (-not $ffmpeg)  { throw "ffmpeg not found. Install it and make sure it is on PATH (https://ffmpeg.org)." }
if (-not $ffprobe) { $ffprobe = Join-Path (Split-Path $ffmpeg) 'ffprobe.exe' }

$tileH = [int][math]::Round($ThumbWidth * 9 / 16)

function Probe([string]$file) {
  $json = & $ffprobe -v error -select_streams v:0 -show_entries stream=width,height:format=duration,bit_rate -of json $file 2>$null | Out-String
  try { return ($json | ConvertFrom-Json) } catch { return $null }
}
function FmtDur([double]$sec) {
  if ($sec -le 0) { return '' }
  return ('{0:hh\:mm\:ss}' -f ([TimeSpan]::FromSeconds($sec)))
}

# ---- load existing state (preserve IDs / first-seen dates) ----
$statePath = Join-Path $indexDir 'state.tsv'
$state     = @{}
$maxId     = 0
if (Test-Path -LiteralPath $statePath) {
  foreach ($line in (Get-Content -LiteralPath $statePath)) {
    if (-not $line) { continue }
    $p = $line -split "`t"
    if ($p.Count -lt 3 -or $p[0] -eq 'ID') { continue }
    $state[$p[2]] = [PSCustomObject]@{ ID = $p[0]; Added = $p[1] }
    $n = 0; if ([int]::TryParse($p[0], [ref]$n) -and $n -gt $maxId) { $maxId = $n }
  }
}

# ---- enumerate videos ----
$exts = '.mp4','.mkv','.mov','.avi','.wmv','.flv','.webm','.m4v','.mpg','.mpeg','.ts','.m2ts','.3gp','.ogv','.vid'
$vids = Get-ChildItem -LiteralPath $Base -Recurse -Force -File -ErrorAction SilentlyContinue |
        Where-Object { $exts -contains $_.Extension.ToLower() -and $_.FullName -notlike "*$([IO.Path]::DirectorySeparatorChar)_index$([IO.Path]::DirectorySeparatorChar)*" } |
        Sort-Object FullName
Say ("videos on disk: " + $vids.Count + "   (already indexed: " + $state.Count + ")")

$rows      = New-Object System.Collections.Generic.List[object]
$seen      = New-Object System.Collections.Generic.HashSet[string]
$addedList = New-Object System.Collections.Generic.List[string]
$nextId    = $maxId + 1

foreach ($v in $vids) {
  [void]$seen.Add($v.FullName)
  $st = $state[$v.FullName]
  if ($st) {
    $id    = $st.ID
    $added = $st.Added
  } else {
    $id    = '{0:D3}' -f $nextId; $nextId++
    $added = (Get-Date).ToString('yyyy-MM-dd')
    [void]$addedList.Add($v.FullName)
  }

  $o   = Probe $v.FullName
  $dur = 0; $res = ''; $bitrate = ''
  if ($o) {
    if ($o.format.duration) { $dur = [double]$o.format.duration }
    if ($o.format.bit_rate) { $bitrate = ('{0:N2} Mbps' -f ([double]$o.format.bit_rate / 1e6)) }
    if ($o.streams -and $o.streams[0].width) { $res = "$($o.streams[0].width)x$($o.streams[0].height)" }
  }

  $decDate = ''
  $dm = [regex]::Match($v.BaseName, '_(\d{9,12})$')
  if ($dm.Success) {
    $n = [int64]$dm.Groups[1].Value
    if ($n -ge 946684800 -and $n -le 2100000000) { $decDate = [DateTimeOffset]::FromUnixTimeSeconds($n).ToString('yyyy-MM-dd') }
  }

  [void]$rows.Add([PSCustomObject]@{
    ID         = $id
    Name       = $v.Name
    Folder     = $v.DirectoryName.Substring($Base.Length).TrimStart('\', '/')
    SizeMB     = [math]::Round($v.Length / 1MB, 1)
    Duration   = FmtDur $dur
    Resolution = $res
    Bitrate    = $bitrate
    Modified   = $v.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
    NameDate   = $decDate
    Added      = $added
    DurSeconds = [int]$dur
    Path       = $v.FullName
  })
}

# ---- storyboards (only when missing) ----
$need = $rows | Where-Object { -not (Test-Path -LiteralPath (Join-Path $thumbDir ($_.ID + '_sprite.jpg'))) }
if ($need) { Say ("building storyboards for " + @($need).Count + " file(s)...") }
$n = 0
foreach ($r in $need) {
  $n++
  $sprite = Join-Path $thumbDir ($r.ID + '_sprite.jpg')
  $D = [int]$r.DurSeconds
  $times = @()
  if ($D -ge 3) { for ($k = 1; $k -le $Frames; $k++) { $times += [int]([double]$D * $k / ($Frames + 1)) } } else { $times = @(0) }

  $vf = "scale=$ThumbWidth`:$tileH`:force_original_aspect_ratio=increase,crop=$ThumbWidth`:$tileH"
  $made = @()
  for ($k = 0; $k -lt $times.Count; $k++) {
    $out = Join-Path $frameDir ("{0}_{1}.jpg" -f $r.ID, ($k + 1))
    & $ffmpeg -hide_banner -loglevel error -y -ss $times[$k] -noaccurate_seek -i $r.Path -frames:v 1 -vf $vf -q:v 4 $out 2>$null
    if (Test-Path -LiteralPath $out) { $made += $out } else { Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue }
  }
  if ($made.Count -eq 0) {
    $out = Join-Path $frameDir ($r.ID + '_1.jpg')
    & $ffmpeg -hide_banner -loglevel error -y -i $r.Path -frames:v 1 -vf $vf -q:v 4 $out 2>$null
    if (Test-Path -LiteralPath $out) { $made += $out }
  }
  if ($made.Count -ge 1) {
    $last = $made[-1]
    for ($k = $made.Count; $k -lt ($Cols * $GridRows); $k++) {
      $dst = Join-Path $frameDir ("{0}_{1}.jpg" -f $r.ID, ($k + 1))
      Copy-Item -LiteralPath $last -Destination $dst -Force
      $made += $dst
    }
    & $ffmpeg -hide_banner -loglevel error -y -start_number 1 -i (Join-Path $frameDir ($r.ID + '_%d.jpg')) -vf ("tile={0}x{1}:padding=0" -f $Cols, $GridRows) -frames:v 1 -q:v 4 $sprite 2>$null
  }
  Remove-Item -Path (Join-Path $frameDir ($r.ID + '_*.jpg')) -Force -ErrorAction SilentlyContinue
  if ($n % 20 -eq 0) { Say ("  ... $n / " + @($need).Count) }
}

# ---- removed ----
$removedList = @($state.Keys | Where-Object { -not $seen.Contains($_) })
foreach ($rp in $removedList) {
  $rid = $state[$rp].ID
  if ($rid) { Remove-Item -LiteralPath (Join-Path $thumbDir ($rid + '_sprite.jpg')) -Force -ErrorAction SilentlyContinue }
}

# ---- write outputs ----
$ordered = $rows | Sort-Object { [int]$_.ID }
$ordered | Select-Object ID,Name,Folder,SizeMB,Duration,Resolution,Bitrate,Modified,NameDate,Added,Path |
           Export-Csv -LiteralPath (Join-Path $indexDir 'index.csv') -NoTypeInformation -Encoding UTF8
$ordered | Select-Object ID,Folder,Name,@{N='NewName';E={''}} |
           Export-Csv -LiteralPath (Join-Path $indexDir 'rename-map.csv') -NoTypeInformation -Encoding UTF8
$ordered | ForEach-Object { "{0}`t{1}`t{2}" -f $_.ID, $_.Added, $_.Path } |
           Set-Content -LiteralPath $statePath -Encoding UTF8

$data = $ordered | Select-Object ID,Name,Folder,Path,SizeMB,Duration,Resolution,NameDate,Added,
                                      @{N='Sprite';E={ 'thumbs/' + $_.ID + '_sprite.jpg' }}
$dataJson = $data | ConvertTo-Json -Depth 4 -Compress

$templatePath = Join-Path $PSScriptRoot 'template.html'
if (-not (Test-Path -LiteralPath $templatePath)) { throw "template.html not found next to the script ($templatePath)." }
$html = Get-Content -LiteralPath $templatePath -Raw
$html = $html.Replace('__DATA__', $dataJson).Replace('__TITLE__', (Split-Path $Base -Leaf)).
             Replace('__COLS__', "$Cols").Replace('__ROWS__', "$GridRows").Replace('__SPEED__', "$SpeedMs")
$htmlPath = Join-Path $indexDir 'index.html'
$html | Set-Content -LiteralPath $htmlPath -Encoding UTF8

Say ''
Say '=== SUMMARY ==='
Say ("indexed total : " + $ordered.Count)
Say ("added (new)   : " + $addedList.Count)
foreach ($a in $addedList) { Say ("   + " + $a) }
Say ("removed       : " + $removedList.Count)
foreach ($d in $removedList) { Say ("   - " + $d) }
Say ("index.html    : " + $htmlPath)
