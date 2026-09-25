# Macro Tracker

An iPhone logger that writes workouts, meals, and bodyweight into an Obsidian
markdown vault. This file is the glossary. The spec lives in
`requirements.md`.

## Logging

**Entry**:
One logged fact of one of three kinds: a single set, a single food, or a single
bodyweight reading. The smallest thing the user creates.
_Avoid_: record, item, row

**Slot**:
A fixed-enum position within a day that replaces a wall-clock time.
`breakfast`, `lunch`, `dinner`, `snack` for meals; `morning`, `evening` for
bodyweight.
_Avoid_: time, mealtime, period

**Session**:
One workout, from one template, on one day. Owns its own vault file.
_Avoid_: workout, day, block

## Workout

**Warmup set**:
A set performed to prepare for heavier work, marked at log time and excluded
from volume. Not inferable later from weight alone.
_Avoid_: light set, prep set

**Working set**:
Any set that is not a warmup. The unit that volume counts.

**Top set**:
The heaviest working set of an exercise in a session. The only set that carries
RPE.

**Total external load**:
The weight written to a set, always summed across implements and always
excluding the lifter's own bodyweight. The 40s are 80; an unweighted pull-up is
0.
_Avoid_: weight per hand, total weight

**Total system load**:
Total external load plus the day's morning bodyweight reading. Derived, never
logged, and only meaningful for bodyweight exercises.

**Implement type**:
A property of a canonical exercise saying how its load is applied (barbell,
dumbbell, machine, bodyweight). Tells a reader which loading convention a
number follows.

**Volume**:
Working sets per exercise per week. Reported per exercise, never per muscle
group.
_Avoid_: tonnage, workload, sets

## Food

**Food reference**:
A pointer to the upstream reference record a meal entry resolved against,
written `fdc:<id>` or `off:<barcode>`. Identity for a food, including for
deciding whether two entries merge.
_Avoid_: food ID, entry ID, food key

**Vault**:
The user-picked Obsidian folder. Authoritative for flushed data.
_Avoid_: library, notes folder, store
