# Fitness and Nutrition Tracker Requirements

iPhone app for logging lifts and food. Obsidian markdown is the system of
record. All food reference data comes from free APIs.

## Storage Architecture

Markdown is the source of truth for flushed data. SQLite is a derived cache
plus a durable write buffer.

Rationale for markdown: durability, hand-editability, and no vendor holding the
history. Exposure to LLMs is a secondary benefit, not the justification, since
markdown or JSON can be emitted from any store on demand.

Constraint that drives the design: aggregation. Daily macro totals, estimated
1RM trends, and weekly volume per muscle group all require reading the whole
vault. Parsing every file per query does not scale past a few hundred days on
device.

### Stores

| Store | Contents | Source | Rebuildable |
| --- | --- | --- | --- |
| `index.sqlite` | Parsed entries for querying, plus the pending-emit queue | The vault, plus unflushed writes | Only when the queue is empty |
| `foods.sqlite` | Food reference data, read-only | USDA + Open Food Facts | Yes, from upstream |

### Write Path

Logging never touches the filesystem. The UI must not block on vault access.

1. An entry commits to `index.sqlite` in a single transaction, together with a
   row in the pending-emit queue.
2. The UI returns as soon as that transaction commits.
3. A flusher drains the queue and rewrites the affected markdown files.

### Flush Triggers

- Debounce: 5 to 10 seconds with no new entries. Batches rapid-fire set
  logging into one file write.
- App entering background.

Not on a clock. An end-of-day flush would depend on `BGTaskScheduler`, which
the system may defer indefinitely or skip entirely, and would leave a window of
up to 24 hours in which the vault is wrong.

### Flush Failure

Expected, not exceptional. Causes include a stale security-scoped bookmark,
an iCloud file not yet downloaded, and revoked folder access.

On failure the queue does not drain, entries remain durable in
`index.sqlite`, and the next successful flush catches up. Failure is surfaced
in the UI as a pending count, never as a lost entry.

### Invariants

- Markdown is authoritative for flushed data.
- The pending-emit queue is authoritative for unflushed data and must be
  durable, written in the same transaction as the entry itself.
- **A reindex from the vault is refused while the queue is non-empty.** This is
  the rule that loses data silently if unenforced. Enforce it in code, not by
  convention.
- Reads for anything numeric go to `index.sqlite`, never to the vault.

## Interface

Three log actions and nothing else. The home screen is three buttons, one per
entry type. Each action is a single screen that writes one entry and dismisses.

### Workout

Fields: exercise, weight (lb), reps.

- Exercise field autocompletes from exercises already in the vault.
- Weight and reps prefill from the last set logged for that exercise, since
  consecutive sets usually repeat. Logging a second set of the same weight is
  one tap.
- One entry per set. Sets are grouped by exercise at write time.
- A session starts from a named template (for example `Push A`) that prefills
  the exercise list, so logging is entering numbers rather than typing names.
  Templates live in the vault and are user-editable.

### Meal

Fields: food, quantity, slot.

- Slot is a fixed enum: `breakfast`, `lunch`, `dinner`, `snack`. Defaults to
  the slot matching the current hour, and is editable.
- Food is resolved by text search or barcode scan against `foods.sqlite`.
- Quantity in grams, or in servings when the entry carries a parseable serving
  size.
- Macros are computed at log time and written as literals, not recomputed on
  read. Upstream data revisions must not silently change past logs.

### Bodyweight

Fields: weight (lb), slot.

- Slot is a fixed enum: `morning`, `evening`. Defaults by current hour, and is
  editable.
- Morning fasted versus evening differs by several pounds, so the slot is the
  whole analytical signal. Clock precision would be noise.
- One reading per slot per day. A second write to the same slot replaces the
  first.

## File Layout

Split by the cadence of the data. A food entry is a point event that only means
something aggregated by day. A workout is a session with a start, an end, and a
structure, so it earns its own file.

```
Daily/2026-09-25.md            food, bodyweight, links to sessions
Lifts/2026-09-25-push-a.md     one workout session, from a template
```

Roughly two files per day, about 700 a year. Rejected alternatives:

- One file per food entry, at 2,000 to 3,000 files a year. Degrades iCloud sync
  and Obsidian's mobile index, makes a day unreadable as a unit, and removes the
  daily frontmatter rollup.
- One file per exercise per day (`2026-09-25-squat.md`). Multiplies file count
  by the length of the session and discards the fact that the exercises were one
  session.

Session filenames collide only when the same session runs twice in a day.
Resolve with a `-2` suffix.

## Identity and Editing

**The path is the identity. The file is the smallest editable unit.**

No per-entry IDs. Editing or deleting an entry rewrites its whole file, which is
safe because files stay small and the app is the sole writer. This is the reason
entry IDs are unnecessary, and it only holds while files stay small, so the
layout above is a correctness requirement rather than a preference.

### No Timestamps

Nothing stores a wall-clock time. Entries carry a date and a slot.

This removes the timezone problem outright: a date plus a slot has no UTC offset
to record, misread, or migrate. It also moves day-boundary ambiguity to the
user, where it belongs. A 1am snack is assigned by picking a slot at log time
rather than by an automatic rule that will be wrong some of the time.

Eating windows and nutrient timing are explicitly out of scope, which is what
makes this safe. Adding them later would require timestamps and would not be
backfillable.

Slot enums are fixed. Free-text slots would drift exactly as exercise names do.

### Duplicate Entries

Without times, two identical food entries in one slot are indistinguishable.
They merge by summing quantity. Two 80g oats at breakfast is 160g oats, which
is the correct reading regardless.

### Daily Note

```markdown
---
schema: 1
date: 2026-09-25
kcal: 2340
protein_g: 186
carbs_g: 240
fat_g: 71
---

## Food

### Breakfast
- Oats, 80g — 302 kcal, P11 C54 F5

### Lunch
- Chicken breast, 200g — 330 kcal, P62 C0 F7

## Bodyweight
- morning: 178.4 lb
- evening: 180.1 lb

## Lifts
![[Lifts/2026-09-25-push-a]]
```

Sections are created on first write for that day. A day with no lifts has no
`## Lifts` heading, and an unused slot has no heading.

Bodyweight is not in frontmatter. Point readings do not roll up to a daily
scalar, and two slots are allowed. Trend queries read them from `index.sqlite`.

### Session File

```markdown
---
schema: 1
date: 2026-09-25
template: Push A
---

- Squat: 225x5, 245x5, 265x5
- RDL: 185x8, 185x8, 185x8
```

Embedded into the daily note with `![[...]]` so the day still reads as a unit
in Obsidian.

### Schema Version

Every file carries `schema: 1` in frontmatter. One line, and it cannot be added
retroactively to files already written. The parser dispatches on it.

### Frontmatter Totals

Recomputed lazily, on flush, not on every entry. A food entry appends a line to
`## Food`; the rollup is rewritten when the flusher runs.

Frontmatter exists for human and LLM reading. It is not a query path, so it
does not need to be correct between flushes. `index.sqlite` serves every
numeric query immediately.

## iOS Constraints

The hardest part of the project. Budget accordingly.

- App sandboxing prevents writing to an arbitrary folder. Access to the vault
  uses the document picker plus a persisted security-scoped bookmark. This
  needs no entitlement. The vault still syncs through iCloud Drive or Obsidian
  Sync; the app reaches it as a user-picked folder rather than owning an iCloud
  container, which would be entitlement-gated.
- Obsidian on iOS syncs via iCloud Drive or Obsidian Sync and caches open files.
  Writing a file Obsidian currently has open produces conflicted copies
  (`2026-09-25 1.md`).

Required mitigations:

- All writes go through `NSFileCoordinator`, not raw `FileManager`.
- Batched flushes rather than per-entry writes, which narrows the collision
  window to a few writes per day. See Write Path.
- The app is the only writer for log files. Obsidian is read-only on them by
  convention. Templates are the exception and are read-only to the app.
- A conflicted copy is detected on the next flush and surfaced to the user for
  manual resolution. The app does not attempt an automatic merge.

## Food Data Sources

### USDA FoodData Central

- Generic and whole foods (chicken breast, oats, olive oil).
- Government-maintained, full nutrient profiles including fiber and sugar
  alongside the four macros.
- Free API key, high rate limits, bulk CSV exports published.
- Gaps: no barcode lookup, thin branded product coverage.

### Open Food Facts

- 2.5M+ packaged products indexed by barcode (EAN/UPC), global coverage.
- Free, no API key required, full database dump published.
- Backs the barcode scanner.
- Gaps: crowd-sourced, so per-100g values and serving sizes are inconsistent.

### Resolution Order

1. Barcode scan resolves against local `foods.sqlite`.
2. Text search resolves against local `foods.sqlite`.
3. Miss on a barcode hits the live Open Food Facts API, then writes back to the
   local store.

## Food Reference Data Build

`foods.sqlite` is built offline and shipped with the app, not assembled on
device and not queried live per request.

- Bulk-load the FoodData Central CSV exports and the Open Food Facts dump.
- Reconcile both upstream shapes into one internal schema at build time.
- FTS5 index on food name.
- Ship as a bundled asset, refreshed on app update or background download.
- Rebuild monthly.

Result: sub-10ms search, offline capability, no rate limits.

Open Food Facts entries must pass validation at build time:

- `nutriments.energy-kcal_100g`, protein, carbohydrates, and fat all present.
- Macros reconcile to stated calories within tolerance at 4/4/9 kcal per gram.
- Serving size present and parseable, or the product is stored as per-100g only.

Entries failing validation are rejected rather than surfaced with holes.

## Build and Distribution

Personal-use app on a personally owned device. No entitlement-gated capability
is required, so a free Apple ID is sufficient to build and run.

Free-tier costs: provisioning profiles, App IDs, and registered devices expire
7 days after issuance, so the app must be reinstalled from Xcode weekly. Limit
of 3 devices.

The paid developer account ($99/yr) removes the 7-day expiry and unlocks
entitlements. Defer it until the weekly reinstall becomes intolerable or a
deferred capability below is wanted.

## Out of Scope

- Restaurant and chain menu data. Not covered by the free sources.
- Natural-language meal logging. Buildable later by passing the input string to
  an LLM with a search tool over `foods.sqlite`.
- MyFitnessPal integration. No public API exists.
- Multi-user and sharing. Single user by design.
- Eating windows and nutrient timing. Excluded by decision, not deferred. The
  no-timestamp format depends on this staying out, and the data would not be
  backfillable if it changed.

### HealthKit

Deferred, not rejected.

Writing macros to HealthKit is duplicative. The markdown vault is the system of
record, so HealthKit would hold a second copy of numbers already logged.

The value is inbound, not outbound: HealthKit is the only practical source for
data not typed by hand, such as bodyweight from a connected scale or workouts
and active energy from an Apple Watch. It is worth adding only once such a
device is in use.

Costs if added: the $99 entitlement, per-type authorization plumbing, and read
denials that return empty results indistinguishable from no data.

Reversal is cheap. HealthKit would enter as a read-only importer that writes
into markdown, touching neither the file schema, the index, nor the food data.
Relevant identifiers: `bodyMass`, `activeEnergyBurned`, `workoutType`.

Note that dropping HealthKit does not reduce platform lock-in. A native iOS app
is already Apple-only. The reason to defer is complexity with no current
payoff.

## References

- https://fdc.nal.usda.gov/api-guide.html
- https://world.openfoodfacts.org/data
- https://developer.apple.com/documentation/foundation/nsfilecoordinator
- https://developer.apple.com/support/compare-memberships/
