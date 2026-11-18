# <img src="logo.svg" width="48" align="top" alt=""> diskz

Tracks which directories use the disk of a Mac, and how that changes over time.
It answers one question: **what grew, where, and since when?**

diskz is read-only: it never deletes, moves or cleans up anything.

## Status

| Part | State |
|---|---|
| Scanner, history database, `diskz` command-line tool | Built (milestone 1) |
| Menu bar app that scans by itself while the Mac is idle | Built (milestone 2) |
| Window with changes over time | Built (milestone 3) |

The design, the decisions taken and the measured results are in [SPEC.md](SPEC.md).

## Requirements

- macOS 27
- Xcode Command Line Tools (full Xcode is not needed)

## Build and test

```sh
swift build -c release      # binary: .build/out/Products/Release/diskz
swift test
```

The tests scan real temporary directories and compare the results with `du`; nothing is mocked.

## The menu bar app

```sh
scripts/make-signing-cert.sh   # once: creates the self-signed certificate "diskz-dev"
scripts/build-app.sh           # builds and signs ~/Applications/Diskz.app
open ~/Applications/Diskz.app
```

The logo is `logo.svg`. The app icon and the menu bar icon in `Resources/` are rendered from it
by `scripts/make-icon.sh` (needs `rsvg-convert`); rerun that only when the logo changes.

Diskz shows its logo in the menu bar; "Open diskz" in its menu opens the window. It scans the internal Data
volume by itself when all of these hold:

- no keyboard or mouse input for 5 minutes
- on AC power, or on battery above 50 %
- Low Power Mode is off and the Mac is not hot
- the last completed scan is more than 24 hours old

A running scan pauses within about a second of your next input and continues where it stopped
once the Mac is idle again. Its menu offers:

| Item | What it does |
|---|---|
| Open diskz | opens the window |
| Status lines | what diskz is doing or waiting for, and the result of the last scan |
| Grant Full Disk Access… | opens the right System Settings pane (shown only while access is missing) |
| Scan now / Finish scan now | scans regardless of the idle conditions |
| Start at login | off until you switch it on |

The window has five sections:

| Section | Answers |
|---|---|
| Growers | What grew lately? Pick last day, 7 days, 30 days or all history; folders are ranked by how much they gained, with a small trend line and a word for how they grew (steady, one jump, up and down, was < 1 MB). Rows inside another listed folder are marked with an arrow; don't add them up. |
| Changes | What grew or shrank between two scans you pick? Largest change first. |
| Browser | Where is the space now? A table of subfolders with size and change; double-click to open a folder, back and forward buttons (⌘[ and ⌘]) as in Finder. |
| Overview | How full is the disk, and how did that develop? Includes the "not attributed" share. |
| Status | Is scanning working? Last scan, database size, Full Disk Access (with a button to grant it), and the folders that could not be read. |

Selecting a folder in Growers, Changes or Browser shows its size over time and a "Reveal in Finder" button.
Paths are shown without the `/System/Volumes/Data` prefix where that names the same folder.

For development, `Diskz --snapshot DIR [--db FILE | --demo SCANS] [--no-access]` renders every section to PNG
files and exits, without scanning or touching the real database.

Details:

- The app and the command-line tool share one database, so `diskz top` and `diskz diff` show the app's scans.
- The app logs to `~/Library/Logs/diskz.log`, including why it is not scanning.
- The certificate gives the app a stable signature, so macOS keeps its Full Disk Access grant
  when the app is rebuilt. Remove it with `security delete-identity -c diskz-dev`.
- Two settings can be changed, for example to test:
  `defaults write com.github.tillg.diskz minIdleSeconds -float 300` and
  `defaults write com.github.tillg.diskz minIntervalHours -float 24`.

## Command-line usage

```sh
diskz scan                  # scan the internal Data volume and record the result
diskz scan ~/Projects       # scan one folder instead
diskz scans                 # list recorded scans
diskz top                   # largest directories under the scanned root
diskz top /Users/me -n 10   # largest subdirectories of one folder
diskz diff                  # what grew or shrank between the last two scans of the same folder
diskz diff 3 7              # ... between scan 3 and scan 7
```

Options:

| Option | Meaning | Default |
|---|---|---|
| `--db FILE` | database file | `~/Library/Application Support/diskz/diskz.sqlite` |
| `--scan ID` | scan to show with `top` | the latest |
| `-n COUNT` | number of lines for `top` and `diff` | 25 |

## Full Disk Access

Without it, macOS hides many folders (Mail, Messages, Safari, other apps' data) from the scan.
diskz shows those as `unknown`, never as 0, and counts their space as "not attributed".

To see everything, give Diskz.app (and your terminal app, if you use the command-line tool)
Full Disk Access in System Settings → Privacy & Security → Full Disk Access, then restart it.

## How it works

- **Scan:** walks the volume with `getattrlistbulk`, without following symlinks and without
  crossing into other mounted volumes. Disk used and free are measured first.
- **Sizes** are allocated bytes (what `du` reports), not Finder's logical sizes.
  A hard-linked file counts once. APFS clones count in full in each location.
- **Cloud-only files** (iCloud and similar) are not downloaded by a scan and count as 0.
- **History:** a SQLite database stores a directory's size only when it differs from the
  previous scan. Directories under 1 MB get no history of their own; they count toward their parent.
- **Retention:** every scan for 30 days, then one per week for a year, then one per 30 days.
- **`diff`** names the folder that changed, not every parent folder above it, and a tree that is
  entirely new or entirely gone as its top folder only. A folder that
  merely became readable (for example after granting Full Disk Access) is not reported as growth.
