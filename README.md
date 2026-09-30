# hifconverter

Converts Sony HLG `.HIF` stills into Display P3 HEIC files that Preview and Photos treat as adaptive HDR. Each HEIC has an SDR base plus an ISO 21496-1 gain map. Preview names a converted photo “Display P3 Primaries; PQ (Adaptive Gain Curve …)”. The hex after the curve changes from picture to picture.

The original `.HIF` is left unchanged. Output is a sibling `Name.heic`, or a file in a directory you choose. A destination ending in `.hif` is refused.

Requires macOS 15 or later and Swift 6.

## Run

```sh
swift run hifconvert photo.HIF
swift run hifconvert --out-dir output card/
swift run hifconvert --lift 0 --on-collision overwrite --out-dir output card/
```

A folder argument is scanned recursively. Only `.HIF` files are converted. Each line is `ok`, `skipped`, or `failed`. The command exits 0 when every file is ok or skipped, 1 when any file fails, and 2 on a bad flag.

```
hifconvert [--peak-nits 1000] [--lift 1.5] [--shoulder standard|match] [--quality 0.85]
           [--out-dir directory] [--on-collision fail|suffix|overwrite|skip]
           file-or-folder ...
```

| Flag | Default | Effect |
|---|---|---|
| `--lift` | `1.5` | Stops added after the HLG decode. `0` keeps the decoded brightness. A negative value darkens the HEIC. |
| `--peak-nits` | `1000` | HLG peak used for the content-headroom tag, in cd/m². Reference white stays 203 cd/m². |
| `--shoulder` | `standard` | `standard` tags every frame with that peak. `match` tags the frame’s own measured peak, clamped between 1.5 and the nominal peak. The tag is then scaled by the lift. |
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

ImageIO decodes the Sony HLG picture. The converter applies `--lift` to that linear picture, clips the SDR base at white, and keeps the highlights in the gain map. Camera metadata (EXIF, GPS, IPTC, MakerNote) is copied onto the HEIC. EXIF orientation is applied to the pixels, and the HEIC is tagged upright.

A frame that stays within SDR white after the lift is written as a Display P3 HEIC with no gain map. A file ImageIO cannot decode fails with `decoded without HLG headroom`.

## Checks

```sh
swift run hifconvert-check
```

Prints `ok` when the conversion checks pass. This package runs those checks as an executable because the Command Line Tools do not include XCTest.
