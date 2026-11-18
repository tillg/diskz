# diskz

Tracks which directories use the disk of a Mac, and how that changes over time.
It answers one question: **what grew, where, and since when?**

diskz is read-only: it never deletes, moves or cleans up anything.

## Status

| Part | State |
|---|---|
| Scanner, history database, `diskz` command-line tool | Built (milestone 1) |
| Menu bar app that scans by itself while the Mac is idle | Not built yet (milestone 2) |
| Window UI with changes over time | Not built yet (milestone 3) |

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

## Usage

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

To see everything, give your terminal app Full Disk Access in
System Settings → Privacy & Security → Full Disk Access, then restart the terminal.

## How it works

- **Scan:** walks the volume with `getattrlistbulk`, without following symlinks and without
  crossing into other mounted volumes. Disk used and free are measured first.
- **Sizes** are allocated bytes (what `du` reports), not Finder's logical sizes.
  A hard-linked file counts once. APFS clones count in full in each location.
- **Cloud-only files** (iCloud and similar) are not downloaded by a scan and count as 0.
- **History:** a SQLite database stores a directory's size only when it differs from the
  previous scan. Directories under 1 MB get no history of their own; they count toward their parent.
- **Retention:** every scan for 30 days, then one per week for a year, then one per 30 days.
- **`diff`** names the folder that changed, not every parent folder above it. A folder that
  merely became readable (for example after granting Full Disk Access) is not reported as growth.
