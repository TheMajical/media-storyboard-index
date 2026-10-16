# media-storyboard-index

Turn a folder full of videos into a **single browsable HTML gallery with hover-preview storyboards**.

Instead of guessing what an unhelpfully named file is (`1080.mp4`, `video (2).mp4`, `64922f8e...`),
this tool samples several frames from every video, tiles them into one sprite image, and builds a
gallery where **hovering a thumbnail plays a quick flipbook of the video's highlights**. Each card
also shows the file's metadata and its full original path.

> Nothing is uploaded or modified — it only *reads* your videos and writes an `_index/` folder.

---

## Features

- 🎞️ **Hover preview** — 8 frames sampled across each video, animated on hover at a tunable speed.
- 🖼️ **Storyboard sprites** — one sprite image per video (flicker-free, cheap on disk).
- 🔎 **Search & sort** — filter by name, folder, ID, resolution or path; sort by id/name/folder/size/duration.
- 📄 **Full path on every card** with a copy button.
- 🧾 **CSV exports** — `index.csv` (spreadsheet) and `rename-map.csv` (batch-rename template).
- ♻️ **Incremental & safe to re-run** — new videos are added, deleted videos are dropped, existing
  ones keep their ID and storyboard (nothing is re-extracted).
- 💻 **Cross-platform** — PowerShell (Windows / PowerShell 7 on macOS & Linux) and a Bash script.

---

## Requirements

- **ffmpeg** (it bundles `ffprobe`).

| OS | Install |
|----|---------|
| Windows | `winget install Gyan.FFmpeg` |
| macOS | `brew install ffmpeg` |
| Debian/Ubuntu | `sudo apt install ffmpeg` |

- **PowerShell** (built into Windows; `pwsh` on macOS/Linux) **or** **Bash**.

---

## Usage

### Windows (double-click)
Copy `Update Index.cmd`, `update-index.ps1` and `template.html` into your video folder and
double-click **Update Index.cmd**. To scan a different folder:

```
"Update Index.cmd" "D:\Media\Videos"
```

### PowerShell (any OS)
```powershell
./update-index.ps1 -Base "D:\Media\Videos"
```

### Bash (macOS / Linux)
```bash
chmod +x update-index.sh
./update-index.sh --base ~/Videos
```

Then open **`<your folder>/_index/index.html`** in a browser.

---

## Options

| PowerShell | Bash | Default | Description |
|---|---|---|---|
| `-Base` | `--base` | `.` | Folder to scan |
| `-Frames` | `--frames` | `8` | Frames sampled per video |
| `-Cols` | `--cols` | `4` | Storyboard grid columns |
| `-GridRows` | `--rows` | `2` | Storyboard grid rows |
| `-SpeedMs` | `--speed` | `700` | Hover animation speed (ms per frame) |
| `-ThumbWidth` | `--width` | `240` | Tile width in pixels |
| `-Quiet` | `--quiet` | off | Less console output |

Example — a smoother 12-frame (4×3) storyboard:
```powershell
./update-index.ps1 -Frames 12 -Cols 4 -GridRows 3 -SpeedMs 500
```

---

## Output

Everything is written to a `_index/` folder next to your videos:

```
_index/
├─ index.html          the gallery (open this)
├─ index.csv           spreadsheet of every video
├─ rename-map.csv      fill the NewName column to batch-rename
├─ state.tsv           internal memory (IDs / added dates) — don't edit
└─ thumbs/
   └─ 001_sprite.jpg   one storyboard sprite per video
```

In the gallery you can also change the preview speed live via the **preview** dropdown.

---

## How it works

1. Scan the folder for video extensions.
2. For each **new** video, run `ffprobe` for duration/resolution/bitrate, then use `ffmpeg` to grab
   N frames spaced across the runtime and tile them into a single sprite.
3. Emit the JSON + HTML gallery from `template.html`, plus the CSV exports.
4. Remember each file's ID and first-seen date in `state.tsv` so re-runs are incremental.

Files that no longer exist are removed from the index and their sprites deleted automatically.

---

## Notes & privacy

- The tool never copies, renames or deletes your videos (only its own `_index/` output).
- `_index/` is git-ignored, so a repo built from this project stays clean.
- Large folders: the storyboard extraction is the slow part; only new files are processed on re-runs.

## License

MIT — see [LICENSE](LICENSE).
