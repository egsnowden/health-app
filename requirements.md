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
1RM trends, and weekly set volume per exercise all require reading the whole
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

## Queries

Five numeric queries are in scope for in-app display. They fix the field list:
every field below either serves one of them or is justified as insurance
against an irreversible loss.

1. Rolling 7-day average kcal and protein.
2. Morning bodyweight trend over the last 8 weeks.
3. Estimated 1RM per exercise, by week.
4. Weekly set volume per exercise.
5. Calorie intake against bodyweight change over an arbitrary window.

Volume is reported per exercise, not per muscle group. A muscle-group rollup
needs a mapping from canonical exercise to muscle group, which is a lookup
table rather than a logged field, so it can be added later and applied
retroactively.

Set count and tonnage are both derivable from weight and reps, so choosing
between them is a presentation decision rather than a capture decision.

## Interface

Three log actions and nothing else. The home screen is three buttons, one per
entry type. Each action is a single screen that writes one entry and dismisses.

### Workout

| Field | Required | Needed by |
| --- | --- | --- |
| exercise | yes | 3, 4 |
| weight (lb) | yes | 3, 4 |
| reps | yes | 3, 4 |
| warmup | defaults to false | 4 |
| rpe | optional, top set only | 3 |

- One entry per set. Sets are grouped by exercise at write time.
- Exercise field autocompletes from exercises already in the vault.
- Weight and reps prefill from the last set logged for that exercise, since
  consecutive sets usually repeat. Logging a second set of the same weight is
  one tap.
- A session starts from a named template (for example `Push A`) that prefills
  the exercise list, so logging is entering numbers rather than typing names.
  Templates live in the vault and are user-editable.

Warmup sets are recorded but excluded from volume. The flag is not derivable
after the fact: a light set before a heavy one and a back-off set after it look
identical, and a percentage-of-top-set rule misreads both back-off sets and
deload weeks. Left uncaptured, set counts inflate by roughly a third, and
inconsistently.

RPE is recorded on the top set only. An estimate taken from a set left well
short of failure reads low, and since query 3 is a trend, a bias that moves
with daily effort is indistinguishable from a change in strength. Per-set RPE
adds logging friction without adding signal. Where RPE is absent the estimate
still stands, but it means "best set performed" rather than a corrected 1RM.

#### Loading Convention

Weight is always the total external load. Dumbbells are summed, so the 40s are
logged as 80. Bodyweight exercises record added weight only, so an unweighted
pull-up is 0 and a weighted one is 25.

The convention has to be fixed because the number is otherwise unrecoverable.
Nothing in `Dumbbell Press: 40x8` says whether 40 was per hand or total. The
canonical exercise carries its implement type, which tells the parser which
reading applies. The UI may still display and prefill dumbbells per hand.

Total system load for a bodyweight exercise is added weight plus that day's
morning bodyweight reading, falling back to the most recent reading when the
day has none. This needs no extra field, since bodyweight is already logged
for query 2.

### Meal

| Field | Required | Needed by |
| --- | --- | --- |
| food name | yes | none directly; the human-readable line |
| food reference | yes | none; insurance |
| quantity | yes | none directly; audit trail for the macro literals |
| slot | yes | none; day ordering and the file layout |
| kcal | yes | 1, 5 |
| protein | yes | 1 |
| carbs | yes | none; insurance |
| fat | yes | none; insurance |

- Slot is a fixed enum: `breakfast`, `lunch`, `dinner`, `snack`. Defaults to
  the slot matching the current hour, and is editable.
- Food is resolved by text search or barcode scan against `foods.sqlite`.
- Quantity in grams, or in servings when the entry carries a parseable serving
  size. Grams are always what reaches the file, since servings convert to
  grams and not the reverse.
- Macros are computed at log time and written as literals, not recomputed on
  read. Upstream data revisions must not silently change past logs.

The food reference is the source record the line resolved against, written as
`fdc:<id>` for FoodData Central or `off:<barcode>` for Open Food Facts. Food
names are not unique in either source, so without it a mistaken entry cannot
be re-resolved and a saved meal can only name a string. It is a pointer to
reference data rather than a per-entry ID, so it does not conflict with the
identity rule below. It lives in the markdown and not only in `index.sqlite`,
because markdown is authoritative for flushed data and a reindex would
otherwise drop it.

Carbs and fat serve no query. They are kept because they cost one literal each
at log time, they are read by hand in the daily frontmatter, and they become
unrecoverable once the upstream record is revised.

### Bodyweight

| Field | Required | Needed by |
| --- | --- | --- |
| weight (lb) | yes | 2, 5 |
| slot | yes | 2 |

- Slot is a fixed enum: `morning`, `evening`. Defaults by current hour, and is
  editable.
- Morning fasted versus evening differs by several pounds, so the slot is the
  whole analytical signal. Clock precision would be noise.
- One reading per slot per day. A second write to the same slot replaces the
  first.
- Recorded to 0.1 lb, matching what a scale reports.

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

Identical means the same food reference, not the same name. Two records that
both read "Chicken breast" are different foods with different macros and must
not merge.

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
- Oats, 80g (fdc:169705) — 302 kcal, P11 C54 F5

### Lunch
- Chicken breast, 200g (fdc:171477) — 330 kcal, P62 C0 F7

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

- Squat: 135x5w, 225x5, 245x5, 265x5@8
- RDL: 185x8, 185x8, 185x8
```

Each set is `<weight>x<reps>[w][@<rpe>]`, comma-separated in performed order.
A `w` suffix marks a warmup, and `@` gives the RPE of the set it follows.

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
