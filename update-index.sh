#!/usr/bin/env bash
#
# update-index.sh - build/update a visual index of a media folder with
# hover-preview storyboards. Cross-platform companion to update-index.ps1.
#
# Usage:
#   ./update-index.sh [--base DIR] [--frames N] [--cols N] [--rows N]
#                     [--speed MS] [--width PX] [--quiet]
#
# Requires: ffmpeg (provides ffprobe) on PATH.

set -uo pipefail

BASE="."
FRAMES=8
COLS=4
ROWS=2
SPEED=700
WIDTH=240
QUIET=0

while [ $# -gt 0 ]; do
  case "$1" in
    --base)   BASE="$2"; shift 2;;
    --frames) FRAMES="$2"; shift 2;;
    --cols)   COLS="$2"; shift 2;;
    --rows)   ROWS="$2"; shift 2;;
    --speed)  SPEED="$2"; shift 2;;
    --width)  WIDTH="$2"; shift 2;;
    --quiet)  QUIET=1; shift;;
    -h|--help)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "unknown argument: $1" >&2; exit 1;;
  esac
done

command -v ffmpeg  >/dev/null 2>&1 || { echo "error: ffmpeg not found on PATH" >&2; exit 1; }
command -v ffprobe >/dev/null 2>&1 || { echo "error: ffprobe not found on PATH" >&2; exit 1; }
[ -d "$BASE" ] || { echo "error: base folder not found: $BASE" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="$SCRIPT_DIR/template.html"
BASE="$(cd "$BASE" && pwd)"
TITLE="$(basename "$BASE")"
INDEXDIR="$BASE/_index"
THUMBS="$INDEXDIR/thumbs"
FRAMEDIR="$INDEXDIR/_frames"
STATE="$INDEXDIR/state.tsv"
ROWS_FILE="$INDEXDIR/_rows.tsv"
SEEN="$INDEXDIR/_seen.txt"
ADDED="$INDEXDIR/_added.txt"
mkdir -p "$THUMBS" "$FRAMEDIR"

say() { [ "$QUIET" -eq 1 ] || echo "$@"; }
SEP=$(printf '\037')   # ASCII unit separator: not IFS-whitespace, so empty fields survive

TILEH=$(( WIDTH * 9 / 16 ))
VF="scale=${WIDTH}:${TILEH}:force_original_aspect_ratio=increase,crop=${WIDTH}:${TILEH}"

# ---- helpers ----
lookup_field() { # field-no, path
  [ -f "$STATE" ] || return 0
  awk -F'\t' -v p="$2" -v c="$1" '$3==p{print $c; exit}' "$STATE"
}
csvq() { local s="${1//\"/\"\"}"; printf '"%s"' "$s"; }
count_lines() { [ -f "$1" ] && awk 'END{print NR+0}' "$1" || echo 0; }
json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\r\n'; }
fmt_dur() { # seconds
  local s=$1
  [ "$s" -le 0 ] 2>/dev/null && { printf ''; return; }
  printf '%02d:%02d:%02d' $((s/3600)) $(((s%3600)/60)) $((s%60))
}
file_size() { stat -c%s "$1" 2>/dev/null || stat -f%z "$1" 2>/dev/null || echo 0; }
file_mtime() {
  if stat -c '%y' "$1" >/dev/null 2>&1; then
    stat -c '%y' "$1" | cut -c1-16            # GNU: 2026-10-16 14:00
  elif stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$1" >/dev/null 2>&1; then
    stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$1"    # BSD/macOS
  else
    echo ''
  fi
}
epoch_to_date() { date -d "@$1" +%Y-%m-%d 2>/dev/null || date -r "$1" +%Y-%m-%d 2>/dev/null || echo ''; }

# ---- max existing id ----
MAXID=0
if [ -f "$STATE" ]; then
  MAXID=$(awk -F'\t' '$1 ~ /^[0-9]+$/ && $1+0>m {m=$1+0} END{print m+0}' "$STATE")
fi
say "videos on disk: (scanning)   already indexed: $(count_lines "$STATE")"

# ---- scan + build rows ----
: > "$ROWS_FILE"; : > "$SEEN"; : > "$ADDED"
nextid=$((MAXID+1))

while IFS= read -r -d '' f; do
  printf '%s\n' "$f" >> "$SEEN"
  id=$(lookup_field 1 "$f")
  if [ -n "$id" ]; then
    added=$(lookup_field 2 "$f")
  else
    id=$(printf '%03d' "$nextid"); nextid=$((nextid+1))
    added=$(date +%F)
    printf '%s\n' "$f" >> "$ADDED"
  fi

  name=$(basename "$f")
  rel="${f#"$BASE"/}"
  folder=$(dirname "$rel"); [ "$folder" = "." ] && folder=""
  bytes=$(file_size "$f")
  smb=$(awk -v b="$bytes" 'BEGIN{printf "%.1f", b/1048576}')
  mod=$(file_mtime "$f")

  # probe metadata
  out=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height:format=duration,bit_rate -of default=noprint_wrappers=1 "$f" 2>/dev/null)
  width=$(printf '%s\n' "$out" | sed -n 's/^width=//p' | head -n1)
  height=$(printf '%s\n' "$out" | sed -n 's/^height=//p' | head -n1)
  dur=$(printf '%s\n' "$out" | sed -n 's/^duration=//p' | head -n1)
  br=$(printf '%s\n' "$out" | sed -n 's/^bit_rate=//p' | head -n1)

  case "$dur" in ''|*N/A*|*[!0-9.]*) dursec=0;; *) dursec=${dur%.*};; esac
  [ -n "$width" ] && [ -n "$height" ] && res="${width}x${height}" || res=""
  case "$br" in ''|*N/A*|*[!0-9.]*) bitrate="";; *) bitrate=$(awk -v b="$br" 'BEGIN{printf "%.2f Mbps", b/1e6}');; esac
  durstr=$(fmt_dur "$dursec")

  # decode trailing unix timestamp in the filename
  ndate=""
  if [[ "$name" =~ _([0-9]{9,12})\.[^.]+$ ]]; then
    n="${BASH_REMATCH[1]}"
    if [ "$n" -ge 946684800 ] && [ "$n" -le 2100000000 ]; then ndate=$(epoch_to_date "$n"); fi
  fi

  # ---- storyboard (only if missing) ----
  sprite="$THUMBS/${id}_sprite.jpg"
  if [ ! -s "$sprite" ]; then
    extract_times=""
    if [ "$dursec" -ge 3 ]; then
      k=1; while [ "$k" -le "$FRAMES" ]; do extract_times="$extract_times $((dursec*k/(FRAMES+1)))"; k=$((k+1)); done
    else
      extract_times="0"
    fi
    seq=0
    for t in $extract_times; do
      tmp="$FRAMEDIR/${id}_tmp.jpg"
      if ffmpeg -hide_banner -loglevel error -y -ss "$t" -noaccurate_seek -i "$f" -frames:v 1 -vf "$VF" -q:v 4 "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
        seq=$((seq+1)); mv "$tmp" "$FRAMEDIR/${id}_${seq}.jpg"
      else rm -f "$tmp"; fi
    done
    if [ "$seq" -eq 0 ]; then
      if ffmpeg -hide_banner -loglevel error -y -i "$f" -frames:v 1 -vf "$VF" -q:v 4 "$FRAMEDIR/${id}_1.jpg" 2>/dev/null; then seq=1; fi
    fi
    full=$((COLS*ROWS))
    if [ "$seq" -ge 1 ]; then
      last="$FRAMEDIR/${id}_${seq}.jpg"
      while [ "$seq" -lt "$full" ]; do seq=$((seq+1)); cp -f "$last" "$FRAMEDIR/${id}_${seq}.jpg"; done
      ffmpeg -hide_banner -loglevel error -y -start_number 1 -i "$FRAMEDIR/${id}_%d.jpg" -vf "tile=${COLS}x${ROWS}:padding=0" -frames:v 1 -q:v 4 "$sprite" 2>/dev/null
    fi
    rm -f "$FRAMEDIR/${id}_"*.jpg
  fi

  printf "%s${SEP}%s${SEP}%s${SEP}%s${SEP}%s${SEP}%s${SEP}%s${SEP}%s${SEP}%s${SEP}%s${SEP}%s\n" \
    "$id" "$name" "$folder" "$smb" "$durstr" "$res" "$bitrate" "$mod" "$ndate" "$added" "$f" >> "$ROWS_FILE"
done < <(find "$BASE" -type f \
          \( -iname '*.mp4' -o -iname '*.mkv' -o -iname '*.mov' -o -iname '*.avi' \
             -o -iname '*.wmv' -o -iname '*.flv' -o -iname '*.webm' -o -iname '*.m4v' \
             -o -iname '*.mpg' -o -iname '*.mpeg' -o -iname '*.ts' -o -iname '*.m2ts' \
             -o -iname '*.3gp' -o -iname '*.ogv' -o -iname '*.vid' \) \
          -not -path '*/_index/*' -print0)

say "videos on disk: $(count_lines "$ROWS_FILE")"

# ---- removed (in state but not seen) ----
REMOVED="$INDEXDIR/_removed.txt"; : > "$REMOVED"
if [ -f "$STATE" ]; then
  while IFS=$'\t' read -r sid sadd spath; do
    [ -z "${sid:-}" ] && continue
    if ! grep -Fxq "$spath" "$SEEN"; then
      printf '%s\n' "$spath" >> "$REMOVED"
      rm -f "$THUMBS/${sid}_sprite.jpg"
    fi
  done < "$STATE"
fi

# ---- write state.tsv ----
sort -t"$SEP" -k1,1n "$ROWS_FILE" | awk -F"$SEP" '{printf "%s\t%s\t%s\n",$1,$10,$11}' > "$STATE"

# ---- write index.csv ----
{
  printf '"ID","Name","Folder","SizeMB","Duration","Resolution","Bitrate","Modified","NameDate","Added","Path"\n'
  sort -t"$SEP" -k1,1n "$ROWS_FILE" | while IFS="$SEP" read -r id name folder smb dur res br mod ndate added path; do
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
      "$(csvq "$id")" "$(csvq "$name")" "$(csvq "$folder")" "$(csvq "$smb")" "$(csvq "$dur")" \
      "$(csvq "$res")" "$(csvq "$br")" "$(csvq "$mod")" "$(csvq "$ndate")" "$(csvq "$added")" "$(csvq "$path")"
  done
} > "$INDEXDIR/index.csv"

# ---- write rename-map.csv ----
{
  printf '"ID","Folder","Name","NewName"\n'
  sort -t"$SEP" -k1,1n "$ROWS_FILE" | while IFS="$SEP" read -r id name folder smb dur res br mod ndate added path; do
    printf '%s,%s,%s,""\n' "$(csvq "$id")" "$(csvq "$folder")" "$(csvq "$name")"
  done
} > "$INDEXDIR/rename-map.csv"

# ---- build JSON ----
JSON="["
first=1
while IFS="$SEP" read -r id name folder smb dur res br mod ndate added path; do
  [ "$first" -eq 0 ] && JSON="$JSON,"
  first=0
  JSON="$JSON{\"ID\":\"$id\",\"Name\":\"$(json_escape "$name")\",\"Folder\":\"$(json_escape "$folder")\",\"Path\":\"$(json_escape "$path")\",\"SizeMB\":$smb,\"Duration\":\"$(json_escape "$dur")\",\"Resolution\":\"$(json_escape "$res")\",\"NameDate\":\"$ndate\",\"Added\":\"$added\",\"Sprite\":\"thumbs/${id}_sprite.jpg\"}"
done < <(sort -t"$SEP" -k1,1n "$ROWS_FILE")
JSON="$JSON]"

# ---- render HTML from template ----
if [ -f "$TEMPLATE" ]; then
  html=$(cat "$TEMPLATE")
  html=${html//__DATA__/$JSON}
  html=${html//__TITLE__/$TITLE}
  html=${html//__COLS__/$COLS}
  html=${html//__ROWS__/$ROWS}
  html=${html//__SPEED__/$SPEED}
  printf '%s' "$html" > "$INDEXDIR/index.html"
else
  echo "warning: template.html not found next to the script; skipped index.html" >&2
fi

# ---- report ----
say ""
say "=== SUMMARY ==="
say "indexed total : $(count_lines "$ROWS_FILE")"
say "added (new)   : $(count_lines "$ADDED")"
[ -s "$ADDED" ] && while IFS= read -r a; do say "   + $a"; done < "$ADDED"
say "removed       : $(count_lines "$REMOVED")"
[ -s "$REMOVED" ] && while IFS= read -r d; do say "   - $d"; done < "$REMOVED"
say "index.html    : $INDEXDIR/index.html"
