# Bugs

Tracked over time. Each entry names the failing test that reproduces it.

## 1. Multi-line Argyll prompts classified as `.other` — fixed 2026-09-28

Argyll prints the tile prompt over three lines ("Place the instrument on its reflective
white reference…", "and then hit any key to continue,", "or hit Esc or Q to abort:") and
the display prompt over two. The parser only looked at one line at a time, so both came
out as `.other`. Found on the first real `dispread` run.

Fix: classify from the last four complete lines plus the unterminated tail, and only when
the tail ends in ":" (Argyll is blocked on a key).
Test: `ArgyllOutputParserTests.testWhiteTilePromptSpansThreeLines`,
`testDisplayPromptUsesPrecedingLine`, `testPromptsAreStableAcrossChunkBoundaries`.

## 2. Results screen missing luminance, white point and fit — fixed 2026-09-28

`ProfilingSession.run()` returned before the event consumer had handled colprof's last
lines, so `finish()` captured a summary with the harvested fields still empty. Seen on
the first app run: the results screen showed only the profile name and location.

Fix: the run task awaits the consumer task before calling `finish`/`fail`.
Test: `RunModelTests.testSummaryIsCompleteWhenRunReturnsBeforeEventsDrain`.

## 3. Profile description shows "?" between fields — fixed 2026-09-28

The provenance line written with `colprof -D` used "·" as a separator. colprof stores the
ICC v2 description tag as 7-bit ASCII, so System Settings and the Compare screen showed
"Studio Display ? i1 DisplayPro ? …". The Compare caption also truncated the middle of
that long string, hiding the instrument and date.

Fix: ASCII separators and "gamma" instead of "γ", with a final non-ASCII scrub; the Compare
caption shows the file name and the full description as a tooltip; the i1d3 family is
named "i1 DisplayPro" instead of Argyll's "i1 DisplayPro, ColorMunki Display".
Test: `RunModelTests.testProfileDescriptionIsPlainASCII`.

## 4. Compare showed no difference between profiles — fixed 2026-09-28

Switching the display's assigned profile through ColorSync changed nothing on screen.
Measured with the HL on a colour-managed grey patch: sRGB grey 0.5 read 63 cd/m² with
the i1Pro 2 profile, with Generic RGB (gamma 1.8, should read ~45) and with the window
tagged Generic RGB. On this macOS with the Studio Display the OS converts what apps draw
to the panel's preset colorimetry and never consults the assigned ICC profile; the
window's declared colour space is ignored too. The assigned profile only matters to apps
that convert their own pixels (Lightroom, Photoshop).

Fix: the Compare screen converts the reference image through the active profile itself
(`ProfileRenderer`), the way Lightroom does, and shows the result re-tagged as sRGB.
A/B now differ on screen by the profiles' real difference.
Test: `RunModelTests.testProfileRendererConvertsThroughTheProfile`.

## 5. Instrument nickname and correction matrix vanished after replugging the HL — fixed 2026-09-28

Nicknames were keyed by Argyll's port name ("hid1: (X-Rite i1 DisplayPro, ColorMunki
Display)"), which changes on every replug ("hid33: (…)"). After the HL was reconnected
the app fell back to "i1 DisplayPro family", and since the correction file is named from
the nickname, the matrix was no longer found either.

Fix: key nicknames by the instrument model name; old port-keyed entries are retired on
the next save.
Test: `RunModelTests.testInstrumentKindsAndNicknames` (replugged-name assertion).

## 6. Correction flow hung at "Select device 1 - 4:" — fixed 2026-09-29

The in-app matrix flow (and the CLI) stalled after choosing "select an instrument":
ccxxmake's "Select device N - M:" prompt was never recognised, so no port number was
sent. It ends in "N - M:" rather than the usual "hit any key" phrase, and depending on
how the pty chunked the bytes it arrived either as a complete line or as an unterminated
tail; the parser checked only one path.

Fix: recognise the device-selector regex in both `classify` (line path) and the tail
path. Also: Cancel now terminates ccxxmake (its menu ignores Escape), and ccxxmake is
bundled with the app.
Test: `ArgyllOutputParserTests.testDeviceSelectPromptAcrossChunkSplits`.
