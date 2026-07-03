# OpenDys-B

Font-hosting repo and Microsoft Intune **Remediations** package for deploying
dyslexia-friendly and brand fonts to a managed Windows estate.

It does two jobs:

1. **Hosts the OpenDyslexic fonts** — both the unmodified classic build (`OpenDyslexic`,
   `OpenDyslexicAlta`, `OpenDyslexicMono`) and `OpenDys B`, a renamed, OFL-compliant
   build of the newer OpenDyslexic 3 redesign — served as raw files the detection
   script pulls on demand, so no runtime dependency on DaFont.
2. **Holds the Intune Remediations scripts** (`Detect-*` / `Remediate-*`) that
   install the whole font set on each device and self-heal it.

## Contents

| File | Purpose |
|------|---------|
| `Detect-CustomFonts.ps1` | Intune **detection** script. The font list lives here — this is the only file you edit to add/change a font. Exit 1 = something needs installing. |
| `Remediate-CustomFonts.ps1` | Intune **remediation** script. Downloads and installs whatever detection staged. No font list — never needs editing to add a font. |
| `OpenDyslexic-*.otf`, `OpenDyslexicAlta-*.otf`, `OpenDyslexicMono-Regular.otf` | The classic OpenDyslexic build (unmodified, keeps its original name), mirrored from the author's repo `antijingoist/open-dyslexic`. |
| `OpenDysB-Regular.otf`, `-Bold`, `-Italic`, `-BoldItalic` | The `OpenDys B` font (internal family name `OpenDys B`), the renamed OpenDyslexic 3 redesign. |
| `OFL.txt` | SIL Open Font License 1.1 — **must** stay beside the font files (see Licensing). |

## The fonts deployed

The detection list currently ships four families:

| Family | Source |
|--------|--------|
| **Lato** | google-webfonts-helper zip (all weights, one URL) |
| **Josefin Sans** | official `google/fonts` repo (variable upright + italic) |
| **OpenDyslexic** | this repo — the unmodified classic build (keeps its original name; also brings OpenDyslexicAlta + OpenDyslexicMono). Mirrored from `antijingoist/open-dyslexic`; DaFont left commented as a fallback in the config. |
| **OpenDys B** | this repo — the renamed OpenDyslexic 3 redesign |

`OpenDyslexic` (classic) and `OpenDys B` (redesign) have **different internal
family names**, so both appear as separate, selectable entries in the font menu
with no shadowing.

## How the scripts work

Each font entry declares a `Version` and a list of `Urls`. Detection records a
**fingerprint** (`Version` + a hash of the URLs) plus the exact installed
filenames. It re-stages a font whenever the fingerprint changes (you bumped
`Version` or edited a URL) or a recorded file has gone missing. Remediation then
downloads each URL (source-agnostic — handles a `.zip` or a single `.ttf`/`.otf`,
and rejects HTML error pages), removes any orphaned files from the previous
build, force-installs the new set machine-wide (`AddFontResourceEx` +
`WM_FONTCHANGE`, no reboot), and records the new state.

Changing a source URL or bumping `Version` is therefore an automatic, clean
force-replace across every device on the next cycle.

### Adding or changing a font

Edit the `CONFIG` block in `Detect-CustomFonts.ps1` **only**:

```powershell
@{ FamilyName = 'My Font'
   Version    = '1'                        # bump to force a reinstall
   Urls       = @(
       'https://example.com/myfont.zip'    # .zip OR a single .ttf/.otf
   ) }
```

Paste every `Url` into a browser first — you should get a font/zip download,
never an HTML page.

## Deploying in Intune

1. **Devices → Remediations → Create**.
2. Detection script = `Detect-CustomFonts.ps1`; remediation script =
   `Remediate-CustomFonts.ps1`.
3. Settings: **Run this script using the logged-on credentials = No** (must be
   SYSTEM for a machine-wide install), **Run script in 64-bit PowerShell = Yes**,
   files saved **UTF-8** (these are).
4. Assign, schedule (e.g. daily 01:00). Pilot on one device first with **Run
   remediation on demand**, then watch
   `C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\CustomFontDeployment.log`
   (tagged `[DETECT]` / `[REMEDIATE]`).

> **The `OpenDyslexic` and `OpenDys B` raw URLs point at the `main` branch.** They
> only resolve once the font files are on `main`, so merge this branch to `main`
> before the first device run. Lato and Josefin Sans download from external
> sources and are unaffected.

Because devices that ran an earlier script have no recorded fingerprint, the
first run of this package reconciles every font automatically — machines that
picked up the GitHub redesign as "OpenDyslexic" get it force-replaced with the
classic build under that name, and pick up `OpenDys B` as a separate entry. No
manual cleanup.

## Licensing

All font files are OpenDyslexic © Abbie Gonzalez, under the SIL Open Font
License 1.1, in [`OFL.txt`](OFL.txt), with Reserved Font Name *OpenDyslexic*.
Redistribution here — including on a public repo — is permitted provided
`OFL.txt` travels with the fonts; keep them together.

- **Classic build** (`OpenDyslexic-*.otf`, `OpenDyslexicAlta-*.otf`,
  `OpenDyslexicMono-Regular.otf`) — **unmodified originals**, mirrored from the
  author's repo. They legitimately carry the reserved name because they are the
  unchanged font.
- **`OpenDysB-*.otf`** — a **Modified Version**: its internal family name is
  `OpenDys B` (it does **not** carry the reserved name), and the original
  copyright and license notices are retained, as the OFL requires for a
  modified build.
- **Scripts** (`*.ps1`) — internal deployment tooling for Sector12;
  provided as-is. The OFL applies only to the font files.
