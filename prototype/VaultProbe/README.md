# Vault Probe

Throwaway app answering one question from
[#2](https://github.com/egsnowden/health-app/issues/2): can the app write to an
Obsidian vault on a real device without producing conflicted copies, and how
long does a coordinated write take?

Delete this directory once the finding is recorded on the issue. Nothing here
is production code.

## Status: not yet run

The source is complete; the findings are not. This machine has Command Line
Tools only, no Xcode and no iOS SDK, so the app cannot be built or deployed
from here. Running it needs Xcode, a physical iPhone, Obsidian installed on
that phone, and a vault syncing through iCloud Drive or Obsidian Sync.

## Setup

1. Xcode, new project, iOS App, SwiftUI, name it `VaultProbe`.
2. Delete the generated `VaultProbeApp.swift` and `ContentView.swift`.
3. Drag in the five `.swift` files from this directory.
4. Run on a physical device. The simulator is useless here — it has no
   Obsidian and no real iCloud sync.

No entitlement and no `Info.plist` key is required. That is itself worth
confirming, since `requirements.md` claims a free Apple ID is sufficient
because the vault is reached as a user-picked folder rather than an owned
iCloud container.

## Runs

Do them in order. Run 1 gates everything else, and run 3 is the control that
makes runs 4 onward meaningful.

**1. Bookmark survival.** Pick the vault folder. Force-quit the app, relaunch,
tap *Resolve stored bookmark*. Then reboot the phone and resolve again. Record
whether it resolved, and whether it came back `STALE`.

**2. Baseline latency.** Obsidian fully closed. Coordinated burst of 20.
Record min, median, max.

**3. Control: can this test even detect a conflict?** Open
`probe-target.md` in Obsidian, leave it on screen, switch to the probe, set
mode to `FileManager`, burst of 20, then *Scan vault*.

If this produces **no** conflict, stop. The test is not sensitive and every
later result is meaningless. Make it harsher — type into the file in Obsidian
between writes — until a raw write does produce one.

**4. The real question.** Same as run 3 but mode `NSFileCoordinator`. Scan.

**5. Repeat 3 and 4 under each sync backend.** iCloud Drive, then Obsidian
Sync. These are different implementations and may differ.

**6. Harshest case.** File open in Obsidian *and* being edited while a
coordinated burst runs. This is the realistic failure, since Obsidian caches
open files.

## Record per run

Sync backend, Obsidian state (closed / open / open-and-editing), write mode,
burst size, failures, min/median/max ms, and what *Scan vault* reported from
all three detectors.

## What each outcome means

| Result | Consequence for `requirements.md` |
| --- | --- |
| Coordinated clean, raw conflicts | The storage design stands as written. Record the latency and set the flush debounce from it. |
| Both conflict | `NSFileCoordinator` does not buy safety here, and the write path changes rather than being tuned. The conflict *detection* path in `requirements.md` stops being a fallback and becomes the primary mechanism. |
| Neither conflicts | Inconclusive, not good news. Go to run 6 before concluding anything. |
| Bookmark fails after reboot | The highest-severity outcome. Access would need re-picking on every reboot, which breaks the whole premise of a background flusher. |

Latency reading: a coordinated write in the low tens of milliseconds means the
5–10 second debounce in `requirements.md` is about batching file rewrites, not
about hiding latency. Hundreds of milliseconds means the flusher must be off
the main thread and the debounce is load-bearing.

## Three API details to verify at compile and first run

These are the parts most likely to be wrong, and the device is the authority,
not the docs.

1. `VaultBookmark` creates the bookmark with `bookmarkData(options: [])`. That
   is the usual iOS recipe for a document-picker URL, but if run 1 fails to
   resolve after relaunch, try `.withSecurityScope`.
2. `NSFileVersion.unresolvedConflictVersionsOfItem(at:)` and
   `.ubiquitousItemHasUnresolvedConflictsKey` are iCloud mechanisms. Under
   Obsidian Sync they will probably report nothing even when a conflict
   exists, which is exactly why `ConflictScanner` also scans for Obsidian's
   own ` N.md` filename pattern.
3. The scanner treats any basename ending in a space and digits as a suspect.
   That will false-positive on a legitimately named file, so eyeball the
   vault before trusting a hit.
