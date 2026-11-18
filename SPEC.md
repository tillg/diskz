# diskz — Specification (draft for discussion)

Status: draft, 2026-11-18. Nothing is built yet.
Each design point gives a **recommendation**, an *alternative*, and the tradeoff. The decisions taken are in section 13; where they were asked, the recommendation was chosen.
Platform claims marked **(to verify)** rest on memory, not on Apple's documentation; each is assigned to a milestone in section 11. Claims marked **(checked)** were confirmed on this Mac on 2026-11-18, against the SDK headers, the man pages, or a probe build.

## 1. Goal

diskz answers one question: **what grew on my disk, where, and since when?**

It keeps a history of how much space every directory uses, refreshes that history by itself while the Mac is idle, and shows the changes over time.

### Non-goals (v1)

- Deleting, cleaning up or moving anything. diskz is read-only.
- Per-file history. Directories are the unit; files only contribute to their directory's total.
- External drives, network shares, other Macs, sync between machines.
- Alerts and notifications, export, exclusion-rule editors (see "Possible later").

## 2. What "size" means

| Point | Recommendation | Alternative | Tradeoff |
|---|---|---|---|
| Size metric | **Allocated size** (blocks on disk) is the main number; logical size is stored alongside. | Logical size only. | Allocated matches "what frees up if I delete this"; logical matches Finder's "size" for sparse and compressed files. |
| Directory size | **Recursive** total of the subtree. | Own files only. | Recursive is what the user reads; own-size is kept internally for incremental updates. |
| Hard links | Count each inode **once** per scan, in the directory with the alphabetically lowest path. | Count in every directory. | Counting once keeps the total honest; attribution to one directory is arbitrary, but a fixed rule keeps it from jumping between scans. |
| APFS clones | Count **in full** in every location in v1. | Use the clone-aware "private size" attribute. It exists in the SDK **(checked)**; its cost and whether the bulk scan call returns it are undocumented **(to verify by benchmark)**. | Full counting overstates directories with many clones (e.g. duplicated VMs); private size is exact but may slow the scan. |

The directory total will **not** equal the "used" figure in Finder. The gap consists of local Time Machine snapshots, purgeable space, the sealed system volume, unreadable directories, and clone over-counting. The UI shows this as its own row, **"Not attributed"** = disk used − scanned total, so the numbers always add up. "Disk used" is the figure for the whole internal disk (capacity − free), so the system volume and swap fall into this row too.

## 3. Scan scope

- **Volume:** the internal Data volume only (`/System/Volumes/Data`, shown with normal paths such as `/Users/...`). The scan never crosses a mount point.
- **Symlinks** are not followed. **Packages** (`.app`, `.photoslibrary`) are ordinary directories in the data; the UI shows them as one item that can be opened.
- **Cloud files:** iCloud and other on-demand files that are not downloaded count as 0 allocated bytes. The scan must **never trigger a download**. macOS has a per-process setting that disables downloading on access **(checked: `setiopolicy_np` man page)**; a scan of the iCloud folder left all 2,174 cloud-only items cloud-only **(checked, milestone 1)**.
- **Unreadable directories** are recorded as *unknown*, never as 0, and listed in the scan status.
- *Alternative:* a user-chosen list of root folders (e.g. only the home folder). Smaller and needs fewer permissions, but hides system-level growth such as `/Library` and `/private/var`.

## 4. Permissions

Scanning the whole volume needs **Full Disk Access**. The grant belongs to the binary that does the scanning.

- **First launch:** a screen explains why, opens the right System Settings pane, and detects when access has been granted.
- **Limits of the grant:** Full Disk Access is not root. Folders closed by ordinary file permissions, such as other users' home folders and root-only system folders, stay unknown either way. See decision 7.
- **Without the grant:** diskz still scans everything it can read and marks protected folders (Mail, Messages, Safari, other apps' containers) as unknown.
- **Development concern:** the grant is tied to the code signature. With ad-hoc signing every rebuild would probably lose it, so builds need a stable signing identity. No Apple source was found for this **(to verify by experiment before milestone 2)**. See decision 1 and section 14.

## 5. Change detection

| | Recommendation: full rescan | Alternative: FSEvents-driven |
|---|---|---|
| How | Walk the whole volume each scan, with the bulk-attribute API. | Persist the FSEvents event ID, rescan only directories reported as changed, full reconcile weekly. |
| Cost | Minutes of low-priority I/O per scan. | Seconds per scan. |
| Complexity | Low; one code path. | Higher: event replay, lost-history fallback, drift repair. |
| Platform support | Bulk-attribute call works and matches `du` byte for byte **(checked, milestone 1)**. | Event IDs persist across reboots when stored with the device UUID **(checked: FSEvents header)**. |

**Considered: a hash of each directory's listing** to find what changed. It does not shorten a scan: computing the hash means reading the listing, which is the scan itself, and a folder's listing does not change when something deeper inside it changes. What skips unchanged folders is macOS's own change log (FSEvents, right column). The useful part of the idea is already in section 7: a row is written only when a directory's size differs.

Start with full rescans and measure on the real disk. Add FSEvents only if a full scan misses the time budget in section 9.

## 6. Idle scanning

A scan **starts** when all of these hold:

- no keyboard or mouse input for 5 minutes
- on AC power (or battery above 50 %), and not in Low Power Mode
- thermal state is normal
- the last completed scan is more than 24 hours old (the minimum interval, a single setting so the frequency can be raised later; every scan stores its exact start and end time, so the history stays valid at any frequency)

Every scan **begins by recording disk used and free**, before walking any directory.

While scanning:

- disk I/O and CPU run at background priority
- the scan **pauses within 2 seconds** of user input and resumes at the next idle period from where it stopped
- a scan that cannot finish within 24 hours of starting is discarded and restarted

A manual "Scan now" ignores the idle conditions.

**Process model — recommendation:** one app that starts at login, lives in the menu bar, and scans in-process. *Alternative:* a separate background agent plus a UI app. The agent keeps scanning when the UI is quit, but it means two binaries, two permission grants and an IPC layer.

## 7. Data model and retention

SQLite database at `~/Library/Application Support/diskz/diskz.sqlite`.

- **`scans`**: start, end, status, volume used and free bytes.
- **`dirs`**: id, parent, name. One row per directory ever seen.
- **`sizes`**: directory, scan, allocated bytes, logical bytes, file count. A row is written **only when the value differs** from that directory's previous row.

Rules:

- **Cutoff:** directories whose subtree is under 1 MB get no history of their own; they count toward their parent.
- **Retention:** every scan for 30 days, then one per week for a year, then one per month. When a scan is thinned out, its rows move to the next kept scan, so no change is lost.
- **Budget:** the database stays under 1 GB; the UI shows its size.

*Alternative:* store a full copy of the tree per scan. Simpler queries, but roughly 50–100 MB per scan on a disk with about a million directories.

## 8. User interface

A normal window, opened from a **menu bar item** that shows the last scan time, scan progress and "Scan now".

| Task | View |
|---|---|
| How full is the disk, and how did that develop? | **Overview:** used and free space over time, with the "Not attributed" share. |
| What grew? | **Changes:** pick two dates; lists the top growing and shrinking directories with their delta. This is the main view. A directory is left out when one subdirectory explains at least 80 % of its change, so the list names the folder that grew, not every parent up to `/`. A folder that merely became readable (e.g. after granting Full Disk Access) is not listed as growth. |
| Where is the space now? | **Browser:** directory outline sortable by size and by change since a chosen date. |
| When did this folder grow? | **Directory detail:** size-over-time chart for one directory, with "Reveal in Finder". |
| Is scanning working? | **Status:** last and next scan, duration, unreadable directories, database size. |

## 9. Architecture and build

- **Language and UI:** Swift, SwiftUI, Swift Charts. Not sandboxed, because whole-disk scanning rules the sandbox out. Personal use, no App Store.
- **Modules:**
  - `DiskzCore`: scanner, store, diff queries. No UI code.
  - `diskz`: a command-line tool over the core (`scan`, `top`, `diff`), used for testing and scripting.
  - `Diskz.app`: menu bar item, window, idle scheduler.
- **Build:** this Mac has only the Command Line Tools, not Xcode. Recommendation: a SwiftPM package plus a small script that assembles and signs the `.app`. A probe package with SwiftUI, Swift Charts and a Swift Testing test builds and passes here without Xcode **(checked)**. XCTest was not found in the Command Line Tools, so tests use Swift Testing. *Alternative:* install Xcode and use an Xcode project; easier signing and previews, at the price of a 15 GB install and a project file.

## 10. Acceptance criteria

The numbers below, and the size estimates in section 7, are initial targets to calibrate in milestone 1.

| # | Requirement | Check |
|---|---|---|
| A1 | Sizes are correct | On a fixture tree with sparse files and symlinks, every directory total equals `du -sk`. With hard links added, the root total equals one `du -sk` of the root, and each linked file is counted in the lowest-path directory only. |
| A2 | The gap is stable | Two back-to-back scans of an idle Mac differ in "Not attributed" by less than 1 % of disk used. |
| A3 | Full scan is fast enough | A full scan of this Mac's Data volume finishes within 15 minutes at background priority. |
| A4 | Scanning stays out of the way | The scan pauses within 2 seconds of input; a paused scan resumes and produces the same totals as an uninterrupted one. |
| A5 | No downloads | Scanning a folder of evicted iCloud files leaves all of them evicted. |
| A6 | History is compact | 30 daily scans on this Mac grow the database by less than 200 MB. |
| A7 | Changes are found | After adding a 1 GB file to a fixture directory, the Changes view lists that directory first with +1 GB. |
| A8 | Missing access is visible | Without Full Disk Access, protected folders show as unknown and appear in Status. |

## 11. Milestones

1. **Scanner and store:** `DiskzCore` plus the `diskz` CLI; A1, A2, A3, A5, A6. Settles the open platform claims on the bulk-attribute call, private-size cost and cloud files.
2. **Idle scheduling:** menu bar app, login start, pause and resume; A4, A8. Two things to change in the scanner then: disk used/free must be stored even when a scan is cancelled, and the no-download setting is process-wide today, so it would also affect the app's own file access. Starts with the signing experiment: does Full Disk Access survive a rebuild? Also confirms that idle detection needs no extra permission.
3. **UI:** Changes, Browser, Directory detail, Overview, Status; A7.
4. **Only if A3 fails:** FSEvents-driven incremental scans.

### Milestone 1 results (2026-11-18)

Built: scanner, store, `diskz` CLI. 19 automated tests pass. Sizes in this section are binary gigabytes (1 GB = 2^30 bytes), as the CLI printed them at the time; the CLI has since switched to decimal units like Finder and Disk Utility, in which the same amounts read about 7 % higher. Measured on this Mac from a terminal **without** Full Disk Access:

| # | Result |
|---|---|
| A1 | Pass. Fixture tests equal `du`; `/usr` and `/Applications` (29.1 GB) equal `du` to the byte. |
| A2 | Pass. Two back-to-back scans: "Not attributed" 611.6 GB and 611.7 GB, a 0.01 % difference. |
| A3 | Pass for what was readable: 356 s at background priority (84 s at normal priority) for 2.8 million files. To repeat with Full Disk Access, which adds the protected folders. |
| A5 | Pass. 2,174 cloud-only items in the iCloud folder before and after the scan. |
| A6 | Estimate only: 2.7 MB after the first scan, 51 rows written by a repeat scan two minutes later. Needs real daily scans to confirm. |

**With Full Disk Access** (terminal granted, same day): 173.8 s at normal priority for 4.9 million files in 1.0 million directories; 533.7 GB scanned, 268 directories still unreadable (root-only system folders and the other user account). The newly readable 307 GB was not reported as growth: `diff` against the previous scan shows +203 MB. Database: 6.8 MB after three scans.

Open: 305 GB of 839 GB is still "Not attributed". The Data volume alone holds 875.6 GB according to `diskutil`, and it has no snapshots, so roughly 340 GB sits in places a normal user cannot read or is not file data at all. A scan as root (started through the password dialog, so without Full Disk Access) made the root-only folders readable: they hold only about 4 GB (`/Users/administrator` 1.1 GB, `/private/var` 11.3 GB against 10.0 GB, `.fseventsd` 0.5 GB). So the gap is not in root-only folders, and decision 7 stands. A scan as root **with** Full Disk Access read nearly everything (87 directories left): 548.8 GB scanned, including `.Spotlight-V100` 7.7 GB and `.DocumentRevisions-V100` 0.2 GB. Disk Utility reports 816.5 GB (binary) used on the Data volume, so about 268 GB is used by something no file walk can see. Purgeable space is only 2 GB and the volume lists no snapshots. The scan found 6,049,940 of the volume's 6,055,408 inodes (99.9 %), so the space does not belong to files the scan missed. Deleted-but-open files are ruled out too (largest: 31 MB). What remains is space the file system holds outside any visible file; not yet checked: whether it survives a restart, and what Disk Utility First Aid reports.

The bulk-attribute call works and is used. Private (clone-aware) size was not benchmarked, since clones are counted in full in v1.

## 12. Possible later

Scanning the folders that changed most in the past first (useful once scans can be interrupted), treemap view, growth alerts, external volumes, exclusion rules, CSV export, cleanup suggestions.

## 13. Decisions (2026-11-18)

| # | Topic | Decision |
|---|---|---|
| 1 | Build and signing | SwiftPM plus a build script, no Xcode. Signed with a self-signed certificate. |
| 2 | Scope | Whole internal Data volume, with Full Disk Access. |
| 3 | Process model | One menu bar app that scans in-process. |
| 4 | Scan frequency | At most once a day to start. Scan times are recorded and the interval is a setting, so the frequency can be raised later. |
| 5 | Clones | Counted in full in v1; the overshoot lands in "Not attributed". |
| 6 | History | Own history only for folders of 1 MB or more. Every scan for 30 days, weekly for a year, monthly after. |
| 7 | Accounts | Only the current account. Other accounts' folders show as unknown; no root helper. |
| 8 | Minimum macOS | This Mac's current version only (assumed, not asked). |

## 14. Still open

- Does Full Disk Access survive a rebuild with the self-signed certificate? Decided by experiment at the start of milestone 2; if not, decision 1 is revisited.
- Private (clone-aware) size: cost not benchmarked; only matters if decision 5 is revisited.
- What the remaining 305 GB "Not attributed" consists of. Root-only folders are ruled out (about 4 GB). Next check: whether the gap survives a restart, and Disk Utility First Aid on the Data volume.
