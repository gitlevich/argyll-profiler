# Backlog

Ideas agreed on but deliberately deferred until the colour results are right.

## Profile inspector: numeric grey-ramp comparison
Convert a grey ramp (100 / 95 / 90 / 80 / 50 / 20 %) through each selected profile, the
same way the Compare screen does, and show the device values side by side, with the
per-step difference highlighted. Answers "is that a cast or my eyes?" with numbers.
The prototype is `/tmp/greycheck.swift` from 2026-09-28; it belongs in the app next to
Compare, and could grow into a full profile inspector (white point, primaries, fit).

## Profile name as an editable dropdown
The Profile name field on the setup screen becomes a combo box: the suggested
provenance name on top, then the existing profiles for the selected display (so a
re-run can replace an earlier profile under the same name, or pick up a naming pattern),
and free text still allowed. Selecting an existing name warns that it will be replaced.

## Inline instrument rename
Replace the "Name…" button with click-to-edit on the instrument's label in the picker
row: click the name, it becomes a text field, Return commits, Escape cancels. Same
persistence as today (`instrumentNicknames` in UserDefaults).

## Colorimeter correction (matrix) inside the app
Once `ccxxmake` is proven from the command line: a "Correct this colorimeter for this
display" flow that runs the spectrophotometer and colorimeter in turn, stores the
`.ccmx`, and applies it (`-X`) automatically whenever that colorimeter is used on that
display. Show which correction is in force on the setup screen.

## Lightroom pass-through measurement
One measurement with the HL on a grey patch inside Lightroom Classic under two
profiles, to confirm that Lightroom's own conversion reaches the panel intact on this
macOS. Decides whether profiling matters for editing here or the preset alone does.

## Release
Photographer-facing README, LICENSE for the app's own code (MIT or Apache-2.0 beside
Argyll's AGPL), GitHub Release with the notarized DMG from `Scripts/release.sh`,
optionally a Homebrew cask.
