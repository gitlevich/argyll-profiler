# Argyll Profiler

A native macOS app that profiles your display with ArgyllCMS and a real instrument, so
Lightroom, Photoshop and other colour-managed apps show your photographs the way they
actually are. It bundles ArgyllCMS, drives it for you, and turns the whole thing into a
few clicks and two prompts: "put the instrument on its tile", "put it on the screen".

Download the latest `Argyll-Profiler-x.y.dmg` from
[Releases](https://github.com/gitlevich/argyll-profiler/releases), open it, drag the app
to Applications. It is signed and notarized.

## What you need

- macOS 13 or later on Apple silicon.
- An instrument Argyll supports. Tested with the X-Rite **i1 Pro 2** spectrophotometer and
  the **Calibrite Display Plus HL** colorimeter, which Argyll sees as an "i1 DisplayPro
  family" device together with the ColorMunki Display, i1 Display Pro / Studio and the
  Calibrite Display SL and Pro HL. Other Argyll-supported instruments should work but
  haven't been tried.
- Nothing else. ArgyllCMS is inside the app.

## Two words that are easy to confuse

**Preset** is the display's own mode, set in System Settings > Displays: Apple XDR
Display, Apple Display, Photography (P3-D65), and so on. A preset changes what the panel
emits: its white point, its brightness range, its gamut. The app never touches it.

**Profile** is a file (an ICC profile) that describes what the display does, so that
colour-managed apps can convert each image correctly for it. Making one does not change
the display. On Apple displays, macOS uses the Preset for everything it draws itself and
ignores the profile; the profile matters for apps that do their own colour management,
Lightroom Classic and Photoshop above all. That is why a bad profile shows up as a colour
cast in Lightroom and nowhere else.

Apple hides the "Color profile" menu for its own displays. To see or change the assigned
profile use ColorSync Utility (Applications > Utilities > Devices > Displays) or the
app's Compare screen.

## Profiling a display

1. In System Settings > Displays, put the display on the Preset you use every day, turn
   off "Automatically adjust brightness" and True Tone, and set the brightness to the
   level you edit at (120–300 cd/m² is the usual range; 500 is not). Don't change the
   preset again afterwards: a different preset is a different display to the profile.
2. Plug in the instrument and open the app. It lists your displays and instruments, tells
   you which instrument is the spectrophotometer and which the colorimeter, and lets you
   give an instrument a name of your own ("Call it").
3. Leave **Profile only** selected. Choose the patch count (175 is fine; 400 for the
   thorough version) and Quality. On a laptop with a large instrument that slides down
   the tilted screen, set the patch window to Bottom and Huge.
4. Press Start and follow the two cards: the spectrophotometer wants its white tile
   first, then the patch window; a colorimeter goes straight to the window. Measuring
   takes a few minutes.
5. The results screen shows the measured white point, luminance and how well the profile
   fits. With "Install the profile when done" on, the new profile is already assigned to
   the display. **Relaunch Lightroom or Photoshop**; they read the display profile when
   they start.

Profiles are named so you can tell them apart later, on disk and in every menu:
`StudioDisplay_i1Pro2_2026-09-28_1811.icc`, described as "Studio Display, i1 Pro 2
spectrophotometer, 2026-09-28 18:11 (Argyll Profiler 0.3, profile only, 175 patches)".

### MacBook Pro and Pro Display XDR: keep the factory profile

XDR displays are mini-LED panels with local dimming: the backlight behind a small
patch behaves differently from the backlight behind a whole photograph, so a profile
measured from patches describes a state the panel is not in when you look at an image;
the visible symptom is lifted, pale blacks. The factory profile ("Color LCD") describes
the intended response, and the dimming controller makes whole images match it. On these
displays keep the factory profile and use the app to verify the white point rather than
to install a profile. Edge-lit displays like the Studio Display profile well.

## Colorimeter or spectrophotometer, and the correction matrix

A spectrophotometer (i1 Pro 2) is the reference: it reads white point and saturated
colours correctly on any display, but it is slow, needs its white tile, and is noisy in
dark tones. A colorimeter (Display Plus HL) is fast, quiet in the dark tones and needs no
tile, but it reads a display accurately only through a correction for that panel's
backlight; without one, saturated colours are off.

If you own both, make a **correction matrix** once per display: select the colorimeter,
press "Make matrix…", choose the backlight type (Apple displays are "LCD, PFS phosphor,
IPS"), and follow the cards, colorimeter first, then the spectrophotometer on the same
spot. The app stores the matrix and applies it automatically whenever that colorimeter is
used on that display; the setup screen says so, and profiles made with it say
"matrix-corrected" in their description. From then on, profile with the colorimeter.

## Comparing profiles

"Compare profiles…" shows a reference image, the built-in patches or any photo you drop
on it, converted through profile A or profile B exactly as Lightroom would convert it.
The space bar switches, the A and B keys select, and the highlighted letter tells you
which is showing. "Numbers" prints the grey ramp through both profiles as device values
and flags any tint, which settles "is that a cast or my eyes?" with arithmetic.

Whichever profile is showing when you press Done stays assigned to the display. "Apple
factory profile" puts Apple's own profile back ("Color LCD" for a built-in display,
"Studio Display" for the external one).

## Calibrate, then profile

The other mode. Argyll works out an adjustment that pushes the display toward a chosen
white point and gamma, then measures the result. It exists for displays that have no
preset for the white you want. On Apple displays prefer a custom Preset (System Settings
> Displays > Preset > Customize Presets…): it lives in the display itself and survives
reconnects, which the software adjustment on recent macOS does not. If a display measures
a few hundred kelvin off its nominal white, that custom preset with a corrected white
point is the durable fix; the app's white point readout tells you how far off it is.

## Where things live

- Installed profiles: `~/Library/ColorSync/Profiles/`
- Measurements and the profile of each run: `~/Library/Application Support/ArgyllApp/Runs/<profile name>/`
- Correction matrices: `~/Library/Application Support/ArgyllApp/Corrections/`

## Building and releasing

`swift build`, `swift test`, and `Scripts/make-app.sh --install` bundles ArgyllCMS from
Homebrew (`brew install argyll-cms`), signs with your Developer ID if you have one, and
copies the app to /Applications. Releases are built by GitHub Actions on `v*` tags:
see `docs/ENGINE.md` for the engine and the release secrets, `BUGS.md` for the bugs found
along the way, and `BACKLOG.md` for what's next.

## License

MIT for this app; see `LICENSE`. ArgyllCMS is bundled unmodified under its own AGPL-3.0
license and runs as separate processes.
