# hifconverter

Converts Sony HLG `.HIF` stills into Display P3 HEIC files that Preview and Photos treat as adaptive HDR. Each HEIC has an SDR base plus an ISO 21496-1 gain map. Preview names a converted photo “Display P3 Primaries; PQ (Adaptive Gain Curve …)”. The hex after the curve changes from picture to picture.

The original `.HIF` is left unchanged. Output is a sibling `Name.heic`, or a file in a directory you choose. A destination ending in `.hif` is refused.

Requires macOS 15 or later. Building from source also needs Swift 6.

## Install

Download [HIFConverter.dmg](https://github.com/fuzzy01/hifconverter/releases/latest/download/HIFConverter.dmg) from the GitHub releases. Open the image and drag HIF Converter onto the Applications alias.

A download is marked as quarantined. After the app is in `/Applications`, clear that flag:

```sh
xattr -dr com.apple.quarantine /Applications/HIFConverter.app
```

The bundle name on disk is `HIFConverter.app`. The image is the Apple silicon build.

## Source and build

```sh
git clone https://github.com/fuzzy01/hifconverter.git
cd hifconverter
./Scripts/make-app.sh
open HIFConverter.app
```

`make-app.sh` compiles the package, copies the `HIFConverter` binary and icon into `HIFConverter.app`, and ad-hoc signs the bundle. Open that app on the Mac that built it. The same build produces the `hifconvert` command. From the repository, `swift run hifconvert` compiles it if needed and runs it.

`./Scripts/make-dmg.sh` runs that build and writes `HIFConverter.dmg`, the image attached to the GitHub release. Building with `./Scripts/make-app.sh` on the same Mac never sets the quarantine flag.

Swift 6 comes with the Xcode Command Line Tools. If `swift` is missing:

```sh
xcode-select --install
```

## Using the app

HIF Converter is the same conversion as `hifconvert`, in one window. Drop `.HIF` files or a folder onto the queue, or click Open. A folder is scanned recursively and only `.HIF` files are added. The original file is left unchanged.

Each row shows the file name, the pixel size, and the status. Select a row to preview it. The preview is a small SDR picture and, when the frame has highlights above white, the HDR picture beside it. Both use the lift and tone map that Convert will write. The row’s peak is the 99.9th percentile of that lifted picture. Changing Lift, Peak, or Shoulder reloads the preview.

The top of the queue has Open, Clear, Convert, and Cancel. Clear empties the queue and the counts, and is available only while a conversion is not running. Convert is Command-R. The queue writes one file at a time. Cancel (Escape) stops after the file already in progress. The status line counts files written, failed, and skipped.

The side panel is the conversion settings, matching the command-line flags:

- **Lift, stops.** `0` keeps the decoded brightness. A positive value brightens every tone. A negative value darkens.
- **Peak, cd/m².** Nominal HLG peak for the content-headroom tag. The default is 1000. Reference white stays 203 cd/m².
- **Shoulder.** Match frame uses that photo’s measured peak, clamped between 1.5 and the nominal peak. Standard uses the nominal peak for every frame. The lift scales that headroom.
- **Quality.** HEIC quality from 0.1 through 1. The default is 0.85.
- **If the HEIC exists.** Fail leaves the existing file and reports it. Add HDR suffix writes `Name HDR.heic`, then `Name HDR 2.heic`. Overwrite replaces an existing `.heic`. Skip leaves it and counts it as skipped.
- **Output.** Choose a folder, or Same folder to write `Name.heic` next to each HIF. A missing folder is created.

The window restores these settings the next time it opens. Set defaults puts back lift 0, match frame, peak 1000, quality 0.85, fail when the HEIC exists, and output next to each HIF, and remembers those. A HEIC written earlier stays at that brightness until you convert it again.

On a wide window the queue is on the left and the preview and settings are on the right. On a narrow window the queue is on top.

## Using the command line utility

```sh
swift run hifconvert photo.HIF
swift run hifconvert --out-dir output card/
swift run hifconvert --on-collision overwrite --out-dir output card/
```

A folder argument is scanned recursively. Only `.HIF` files are converted. Each line is `ok`, `skipped`, or `failed`. The command exits 0 when every file is ok or skipped, 1 when any file fails, and 2 on a bad flag.

```
hifconvert [--peak-nits 1000] [--lift 0] [--shoulder match|standard] [--quality 0.85]
           [--out-dir directory] [--on-collision fail|suffix|overwrite|skip]
           file-or-folder ...
```

| Flag | Default | Effect |
|---|---|---|
| `--lift` | `0` | Stops added after the HLG decode. `0` keeps the decoded brightness. A negative value darkens the HEIC. |
| `--peak-nits` | `1000` | HLG peak used for the content-headroom tag, in cd/m². Reference white stays 203 cd/m². |
| `--shoulder` | `match` | Headroom of the SDR tone map. `match` uses the frame’s own measured peak, clamped between 1.5 and the nominal peak. `standard` uses that peak for every frame. The headroom is then scaled by the lift, and the same number is stored as the content-headroom tag. |
| `--quality` | `0.85` | HEIC quality, from just above 0 through 1. |
| `--out-dir` | sibling of the source | Directory for the HEIC files. It is created if missing. |
| `--on-collision` | `fail` | What to do when the HEIC name is already there. |

Collision choices:

- `fail` reports `Name.heic already exists` and continues with the next file.
- `suffix` writes `Name HDR.heic`, then `Name HDR 2.heic`, and so on.
- `overwrite` replaces an existing `.heic`.
- `skip` leaves the existing HEIC and reports it as skipped.

HEICs written with an earlier lift stay at that brightness until you reconvert them.

## What the HEIC contains

ImageIO decodes the Sony HLG picture. The converter applies `--lift` to that linear picture, tone-maps the SDR base down to white, and keeps the highlights in the gain map. Camera metadata is copied onto the HEIC, including exposure, aperture, ISO, exposure compensation, metering mode, lens, date, GPS, IPTC, and MakerNote. The HIF color-space tag is left off so the HEIC is not marked HLG. EXIF orientation is applied to the pixels, and the HEIC is tagged upright.

A frame that stays within SDR white after the lift is written as a Display P3 HEIC with no gain map. A file ImageIO cannot decode fails with `decoded without HLG headroom`.

## Checks

```sh
swift run hifconvert-check
```

Prints `ok` when the conversion checks pass. This package runs those checks as an executable because the Command Line Tools do not include XCTest.
