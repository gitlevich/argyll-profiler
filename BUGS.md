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
