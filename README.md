# Photo Merge

A small, native macOS app that joins two photos top–bottom or left–right. Drag photos into the window, choose the direction, and save. The same executable also provides a CLI. No Electron, web server, third-party dependencies, network access, or image uploads.

Requires **macOS 13 or later**. Builds for Apple Silicon and Intel.

## Build and launch

Install Xcode or Apple's Command Line Tools, then run:

```sh
./scripts/build-app.sh             # build for this Mac
open "dist/Photo Merge.app"
```

For a universal Apple Silicon + Intel app:

```sh
./scripts/build-app.sh --universal
```

Copy `dist/Photo Merge.app` to `/Applications` if desired. The build also creates `dist/photo-merge`, a standalone CLI executable. Both artifacts bundle only native code and use macOS system frameworks. Local builds are ad-hoc signed; public distribution requires Developer ID signing and notarization.

## Desktop app

- Drop one photo onto each card, or drop two photos onto either card.
- Click a card or use **File → Choose Photos…** (`⌘O`) to browse.
- Choose **Top–bottom** or **Left–right**. The first photo goes on top or left.
- Unequal photos are **centered**, with transparent padding on either side (an odd extra pixel goes on the right or bottom).
- **Photo sizes** offers **Keep original sizes**, **Match Photo 1** (default), and **Match Photo 2**. Matching uses the selected slot as the reference: equal widths for top–bottom, equal heights for left–right. Only the other photo is scaled, preserving aspect ratio with dimensions rounded to the nearest pixel. There is no stretching or cropping.
- **Swap order** switches the photos. The selected reference remains Photo 1 or Photo 2 in the new order.
- **Merge & Save…** (`⌘S`) writes a PNG and reveals it in Finder.
- Cards support keyboard focus, Space/Return, and accessibility labels.

The displayed thumbnails are previews only. Export always uses the full-resolution source pixels.

## CLI

```sh
./dist/photo-merge --layout vertical first.jpg second.heic -o combined.png
./dist/photo-merge --layout horizontal left.png right.tiff -o panorama.png
./dist/photo-merge first.jpg second.jpg -o combined.png --overwrite
./dist/photo-merge --layout vertical --match-size first first.jpg second.jpg -o matched.png
./dist/photo-merge --help
```

Omitting all arguments opens the GUI. Vertical is the default layout, and size matching defaults to Photo 1. Use `--match-size original` to keep both original sizes. Quote paths containing spaces. Use `--` before input filenames that begin with `-`. Errors go to stderr with exit code 1; success exits 0. Existing output files require `--overwrite`; an input file can never be used as the output.

## Image fidelity

- **Original-size mode: no resizing, cropping, interpolation, or lossy recompression.** Camera orientation is applied using integer pixel permutations.
- Optional size matching uses high-quality resampling with premultiplied floating-point channels to preserve transparent edges. The reference photo is not resampled. Downscaling removes detail and upscaling cannot create original detail; keep original sizes for unchanged pixels. PNG encoding remains lossless in every mode.
- **16-bit RGBA PNG output**, with lossless compression and an embedded color profile. JPEG/HEIC inputs are decoded once; their existing compression cannot be undone.
- Inputs with the same RGB color space retain that space. Other combinations are color-managed into wide-gamut **ProPhoto RGB (ROMM RGB)** at 16-bit precision. Profile conversion can change numerical channel values; arbitrary images with different profiles cannot share one PNG profile while retaining both original encodings exactly.
- Unequal dimensions are padded with transparent pixels, centered on the cross-axis. Vertical output is `max(widths) × sum(heights)`; horizontal output is `sum(widths) × max(heights)`.
- Transparency is kept as unassociated alpha, avoiding a premultiplication round trip in the compositor.
- Supports single-frame images decoded by macOS Image I/O, including ordinary JPEG, PNG, HEIC, and TIFF. RAW, floating-point images, detected HDR gain maps, and multi-frame files are rejected rather than silently flattened. This is an SDR photo workflow, not an HDR or RAW editor.
- EXIF/GPS/camera metadata is not copied to the combined image. The embedded output color profile and normalized orientation describe the new image.
- Export is limited to 125 million pixels and 100,000 pixels per side. Large images can still require several gigabytes of working memory; 16-bit PNGs may be much larger than input JPEGs.

## Development

```sh
swift build
swift test
swift run photo-merge --help
```

`PhotoMergeCore` handles decoding, color management, orientation, pixel placement, and safe PNG writes. `PhotoMerge` provides the AppKit UI and CLI. Tests check centering, either size reference, proportional scaling, oriented and transparent resizing, CLI size matching, exact 16-bit pixels and alpha, all eight EXIF orientations, both arrangements, padding, mixed profiles, PNG round trips, invalid input, and overwrite/input-file protection.

## Photo Flip companion

The build also creates **`dist/Photo Flip.app`** and `dist/photo-flip`.

1. Launch Photo Flip to choose a PNG, use `⌘O`, drag a PNG onto the displayed photo, or use Finder's **Open With → Photo Flip**.
2. The top photo (vertical merge) or left photo (horizontal merge) appears first.
3. Press **Space** or **click the photo area** to flip to the other photo. Every flip rotates horizontally around a vertical axis, regardless of the merge arrangement. The new face is shown normally, not mirrored.

The animation uses Core Animation with perspective and easing. Input during a flip is ignored so repeated clicks or held Space cannot interrupt it. Loading another image resets the view to Photo 1. The viewer shows only the photo: no menu, title bar, border, buttons, status text, or Dock icon. Its transparent window automatically fits both faces on screen without cropping. Press **Escape**, **⌘Q**, or **⌘W** to quit; **Option-drag** moves it. A file picker appears only when opening a file, and an alert appears for errors. The viewer never rewrites the merged image.

```sh
./dist/photo-flip merged.png
open "dist/Photo Flip.app"
```

New GUI and CLI merges embed a small, versioned JSON record in a standard PNG **iTXt** chunk named `PhotoMerge`. It records canvas size, layout, and both photo rectangles in top-left pixel coordinates. This allows exact extraction of unequal, centered, oriented, or resized photos without including the transparent padding. It does not store source paths or camera/GPS metadata and does not alter image pixels. Ordinary PNG viewers can still open the file.

For older files, or files whose metadata was removed by another editor, the viewer starts with a vertical 50/50 split. Press **V** for top–bottom or **H** for left–right, then use **Left/Right arrows** to adjust the first photo's share by one percentage point. These keyboard controls keep the image free of UI. This manual fallback includes existing padding; exact original boundaries are unavailable without metadata. Invalid or stale PhotoMerge metadata is rejected with an error rather than silently showing the wrong crop.
