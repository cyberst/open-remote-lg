# Remote artwork preparation

1. Read [catalog-research.md](catalog-research.md) for the chosen regional faces, sources and year limitations.
2. Draw or generate an original front-view illustration of the remote (no photographs or LG artwork) on a plain white background. Save it in an inbox folder outside the repository, named with the remote's id (for example `magic-mr19.png`).
3. From the repository root, on macOS 14+ with Apple's Swift command-line tools installed, run:

```sh
swift tools/remotes/process.swift "/path/to/remote-inbox/" "build/processed-remotes"
```

4. Measure each key on the source image into `keymaps/<id>.json`, then run `swift tools/remotes/map-keys.swift` (usage at the top of the file) to write normalised key rects into `remotes.json` and draw a check overlay.

No package installation, API key or third-party framework is needed. `process.swift` accepts top-level `.png`, `.jpg`, `.jpeg` and `.webp` files (case-insensitive extensions), corrects EXIF orientation through ImageIO, and reads the inbox without writing to it. Each base filename is the output id; keep only one extension per id. Inputs are decoded at up to 4096 pixels on their longest edge to bound memory.

Vision's `VNGenerateForegroundInstanceMaskRequest` is attempted first. If Vision is unavailable, returns no foreground or produces an unusable mask, the processor prints the reason and uses a four-connected white-threshold flood fill from the edges. The fallback removes connected near-white pixels (RGB components ≥238, channel spread ≤20), keeping enclosed white keys/labels. Largest-component filtering discards isolated specks; the solid silhouette's enclosed holes are filled. Inputs with existing transparency around most of their border keep their original alpha.

The processor crops to visible content, adds transparent margin equal to approximately 0.5% of content height per edge, preserves proportions, and resamples to exactly 2400 pixels high. It writes `<outdir>/<id>.png` and a labelled JPEG `contact-sheet.jpg` showing **all PNG outputs already in that output directory**, on a checkerboard background. Existing matching outputs and the sheet are replaced atomically; the input and `remotes.json` are untouched. Measured output dimensions are printed to the terminal. A failed file is reported, other inputs continue, and the process exits nonzero if any input failed. A previous output for a failed input may remain: check errors before accepting the sheet.

If needed, append `--mask=flood` to force the deterministic fallback, or `--mask=vision` to require Vision and report its failure instead of falling back. These options also help compare silhouettes. Do not run an output directory containing the contact sheet as the source inbox: the JPEG sheet is not a remote source.

Review transparent edges against light and dark backgrounds, verify that every service key and its original logo survived, and compare all labels/rows against the source links. Dark cast shadows or a non-white background can survive the fallback; fix the source in ChatGPT or inspect a Vision result. Segmentation cannot repair a wrong layout, a clipped remote or garbled print. Upscaling to 2400 does not create genuine fine detail. Do not accept images on the basis of dimensions alone.

After approval, set each entry's `imageSize` to the measured `[width, 2400]`. Entries with `[0, 2400]` and empty `keys` are **preparation data** pending artwork and per-key maps; MR19 already has processed artwork and a map. Map keys against the final processed PNGs and verify overlays; if an existing image is replaced, recheck its rectangles. Service keys retain their original logos and open their own apps via `app:<id or title match>`; see the research notes. Preserve all six physical shortcuts on newer faces.

## Strict lossless delivery

The app ships **lossless WebP**, decoded by the existing ImageIO/UIImage loader on iOS 17+.
Prepare PNGs in `build/processed-remotes`, outside the synchronized `OpenRemote/` folder, so intermediate
PNGs and the contact sheet never enter the app. After reviewing the processed artwork, encode it:

```sh
brew install webp oxipng zopfli
swiftc -O tools/remotes/verify-images.swift -o build/verify-images
for png in build/processed-remotes/*.png; do
  name="$(basename "$png" .png)"
  webp="build/processed-remotes/$name.webp"
  cwebp -z 9 -exact -metadata icc "$png" -o "$webp" || exit 1
  build/verify-images --pair "$png" "$webp" || exit 1
  cp "$webp" "OpenRemote/Resources/Remotes/$name.webp"
done
```

Keep `remotes.json` image names as `<id>.webp`. Map keys using the processed PNG before delivery;
dimensions, coordinates and every RGBA value are identical in the WebP. `-exact` is mandatory: without it,
WebP may discard RGB underneath fully transparent pixels. Never use `-near_lossless` below 100, PNG alpha
cleanup, pngquant, resizing or lossy re-encoding for this delivery step. HEIC quality 1 is not a guarantee
of lossless RGBA and is not used. Preserve an input's colour profile; the current processed art decodes as sRGB.

For repository PNGs (for example the app icon), run:

```sh
python3 tools/remotes/optimize-pngs.py --verifier build/verify-images \
  OpenRemote/Resources/Assets.xcassets/AppIcon.appiconset
```

This tries `oxipng -o max -z --fast` (15 Zopfli iterations) and `zopflipng --iterations=15`, retaining
the smallest candidate that passes verification. Gamma/chromaticity, display metadata and EXIF orientation are retained;
provenance/text metadata may be stripped. Unsupported decoder layouts are rejected, never silently
converted. If both tools choose a grayscale/indexed representation that the verifier rejects, try
`oxipng --nc --nb` with the same compression settings and verify that candidate. No JPEGs were present
in this optimization pass. For future JPEGs use `jpegtran -optimize -copy all` and verify; preserve ICC and
orientation metadata, and never decode/re-encode JPEG pixels.

`verify-images.swift` compares dimensions and **every straight RGBA8 byte**, including hidden RGB under
alpha 0, then compares ICC profiles and a colour-managed sRGB rendering. A premultiplied drawing alone
cannot prove hidden RGB was preserved. To audit the whole change, extract the original images from the
parent revision into a temporary tree with matching paths, then run:

```sh
swift tools/remotes/verify-images.swift --tree /path/to/original-images .
```

Tree mode accepts a `.webp` replacement when the original PNG path is absent. `RemoteImageTests` also
checks the 14 original RGBA hashes, sRGB, dimensions and both production loader paths on iOS. For direct
old/new simulator byte comparisons, temporarily copy the original PNG bytes to
`OpenRemoteTests/LosslessImageFixtures/original-<id>.baseline` before building tests, then remove that
directory. The `.baseline` extension prevents Xcode from changing the reference via CgBI conversion;
these files belong only to the test bundle. Run tests on iPhone 17 with `-demo` in the test host's launch
arguments, disabling parallel testing so no cloned or other simulator is used.

Build/benchmark artifacts may live in ignored `.image-optimization/`; delete DerivedData after measuring.

## Synthetic verification

```sh
swift tools/remotes/test-process.swift
```

This draws its own dark rounded rectangle on white using Core Graphics, with an enclosed white key and asymmetric red/blue markers; no product imagery is used. It runs the real processor on synthetic PNG/JPEG inputs, checks alpha, crop/proportions, orientation, white-key preservation, exact 2400-pixel height, JPEG sheet dimensions, already-transparent input, unchanged source bytes, duplicate-id rejection, output-inside-inbox rejection and all-white-source rejection. Fixtures live in a unique system temporary directory and are removed automatically. Add `--keep` to retain the synthetic files for visual inspection; no fixture is committed.

Verified here on macOS with Swift 6.4: all checks passed; the generated two-column JPEG sheet was visually inspected. Vision's model could not initialise on this host (`Could not build inference plan - ANECF error: failed to load ANE model … Error= (DESIGN)`), so the default path's automatic fallback was exercised successfully. A successful Vision segmentation remains to be visually checked on a host where that model runs. WebP decoding is provided by ImageIO (the host advertises `org.webmproject.webp`); synthetic fixtures cover PNG and JPEG, not WebP encoding.
