# Darkslide

A native macOS front end for the darktable raw engine. Proof of concept.

SwiftUI interface, darktable 5.6.2 doing all the processing, and edits stored in darktable's own XMP sidecars, so a photo can move between this app and darktable at any point.

It was called Develop until October 2026. On its first launch as Darkslide it brings over Develop's settings, its support folder and its caches (`FormerName.swift`), and Photos edits saved under the old name still open.

## Architecture

```
Darkslide.app (Swift, SwiftUI)              darkroom-helper (C, links libdarktable)
  EditorModel ── JSON lines on stdin ──▶    dt_init (headless, in-memory library)
              ◀── JSON lines on stdout ──   one image, one long-lived pixelpipe
  Canvas      ◀── shared frame file ─────   BGRA8 (SDR) or float RGBA (HDR)
```

- **Separate process.** darktable has a lot of global state and pulls in GTK's libraries. Keeping it in a helper keeps the Swift app clean, and if the engine crashes, the app restarts it and reopens the photo.
- **Metal.** darktable's GPU code runs on Metal through MetalCL (`Engine/metalcl`): a library providing the 40 OpenCL functions darktable loads, running kernels that `Engine/metal/cl2metal.py` translates to Metal. darktable is unchanged; it loads MetalCL through its `opencl_library` setting. Its output matches Apple's OpenCL to within 1 level in 8 bits; renders are 15 to 25% faster, and kernels load in 0.02 s against 1.8 s. Settings › Graphics processing switches between Metal (default), Apple OpenCL and CPU only. Details and numbers are in `Engine/metal/README.md`.
- **GPU.** darktable's OpenCL path is switched on (darktable leaves it off on macOS). On an M3 Pro with denoise, local contrast and diffuse or sharpen enabled, it is 4–5× faster than the CPU (about 0.75 s against 3–4 s per change at 2800 px), and the output matches the CPU's to within 0.04 levels on average. Apple's OpenCL is deprecated, which is why MetalCL (above) is now the default.
- **Draft renders.** While a slider is dragged, frames render at half size; a full-size frame follows when edits pause.
- **Warm pipeline.** The helper keeps the image and pipeline open between edits, and darktable's pipe cache means moving a slider only reruns the pipe from that module: about 50 ms per exposure change on a 24 MP raw at 2120 px, against 175 ms when the whole pipe reruns. On the GPU this needs Engine/patches/0003: darktable only copies GPU results back into the cache for the module focused in its interface, so headless nothing was cached until the helper started naming the module being edited.
- **Generated controls.** Every darktable module publishes metadata for its settings (names, ranges, defaults, enum values). The helper sends that to the app, which builds sliders, pickers and toggles from it. Curves, masks and other array-valued settings are counted and listed as "needs a custom editor".
- **XMP is the save format.** The helper's library is in memory. Opening a photo reads any existing sidecar (from this app or from darktable), and Save writes it back. darktable's own sidecar writing is set to "never" after start-up (a `--conf` override would also block Save) and switched to "always" only while saving. Real darktable reads it without changes (checked with darktable-cli 5.6.2).

### HDR preview

darktable can export HDR (PQ and HLG, Rec.2020 and P3) but can't show HDR while you edit. Here, the HDR toggle (⇧⌘H) switches the pipeline's output to unclipped linear Rec.2020 float. The app then converts it the way the chosen export profile will encode it, and shows it with EDR:

| Output colour profile | Linear 1.0 means | Shown as |
| --- | --- | --- |
| PQ (Rec.2020 or P3) | 10,000 nits | nits ÷ 203 |
| HLG (Rec.2020 or P3) | nominal peak | BT.2100 OOTF for a 1000-nit display, ÷ 203 |
| anything else | SDR white | as is |

These mappings come from darktable's own profile code (`common/colorspaces.c`), which applies the BT.2100 curves with no extra scaling and clips the signal at 1.0. P3 targets are converted from Rec.2020, and out-of-gamut values are clipped as the export would clip them. 203 nits is the BT.2408 HDR reference white, used as 1.0 on the EDR scale.

The inspector shows:

- a luminance histogram in stops around reference white, with this display's headroom, the format's peak and the peak limit marked; it ends just above the brightest level the export can hold (the peak limit, or the format's peak: HLG about +2.3 stops), not at +6 for every image
- the peak in stops and nits
- how much of the image is above reference white, beyond this display, and clipped by the format

The toolbar warning button tints pixels this display can't show.

The HDR card has two further controls, following Greg Benz's advice on HDR photos:

- **Peak** sets how far above reference white the highlights reach. For a raw it's where the engine's HDR curve rises to (see HDR profiles below); for an HDR source the app rolls the brightest highlights off smoothly towards it (from a stop below the limit, luminance eases towards it with hue kept). A lower peak glows rather than glares, and looks more alike across displays. It applies to the HDR view and to gain map JPEGs, and through the curve to HEIF and JPEG XL from a raw.
- **Preview as** shows a gain map JPEG as a display with less headroom would: viewers blend the SDR base and the HDR rendition per pixel in log space, weighted by the display's headroom over the image's (the ISO 21496-1 weighting). It uses whichever SDR base the export is set to make.

Both are sliders that don't touch the engine: the engine keeps the last HDR render's pipe output (and the SDR base rendered for it), so a change only reruns the app's HDR pass and the blend, about 15–30 ms. Switching between SDR and HDR drops darktable's cached output from colorout onwards, not the whole cache, since only colorout and gamma depend on the display profile.

### HDR sources

Gain map, HLG and PQ images, and raws decoded by macOS, reach darktable already rendered: SDR white at 1.0, highlights above, and no tone mapper. Two things follow.
- **SDR.** An SDR render or export would clip everything above white (a quarter of an iPhone HDR photo, often the sky). So SDR renders of an HDR source are its HDR render with the highlights rolled off in the app (`GainMapPreview.rollOffToSDR`): below half of white nothing changes, and above it each pixel's largest channel eases to the image's peak at white, hue kept. Core Image's `CIToneMapHeadroom` darkened the midtones by a stop or so; this keeps them as the photo's own SDR base has them (median within 2% on an iPhone HDR HEIC). SDR exports go through Core Image the same way, from a linear float export.
- **HDR profiles.** darktable's PQ and HLG profiles put linear 1.0 at the format's peak, so a photo would come out over two stops too bright, its midtones and skin as well as its highlights. For every photo with an HLG or PQ profile, the engine keeps two hidden instances named "HDR white" just before the output profile: exposure brings SDR white to 203 nits (−2.3 EV for HLG, −5.6 EV for PQ), and for HLG, levels on luminance with a 1/1.2 power undoes the display's system gamma (BT.2100's inverse OOTF). They change with the profile, in the same history step, so undo takes both back. For a rendered photo (anything but an HDR source) a third instance, an RGB curve before the exposure, takes the highlights above SDR white: it follows SDR exactly up to 0.55 display-linear (about 76% in sRGB), then rises as x + (peak − 1)·t³ to the peak at SDR white, scaling each pixel by its brightest channel so lights keep their colour. Its output is divided by the peak, as curve nodes stop at 1, and the exposure adds log2(peak) back. The peak is the HDR card's limit, or the format's (4.9× for HLG), within 16×. The tone mapper stays at 100% target white, as in SDR. Earlier versions raised sigmoid's or filmic's target white to 100% × 2^peak instead, but that stretches the tone mapper's whole curve above middle grey: on the D80 sample with tuned filmic, the HDR median was 0.92 against SDR's 0.44, so skin sat at SDR white. With the curve they match (0.437 against 0.438), with the brightest highlights at 3.9×. Opening or switching an older HDR edit puts its tone mapper back to 100% where it holds one of those values. For an HDR source, the app rolls the highlights off to the peak instead. SDR renders and SDR exports of such an edit are its SDR rendition: the helper switches the HDR white off for the render, and for an export applies the SDR profile and 100% white as history items it takes back afterwards, so the edit is unchanged. An sRGB export of the HDR edit matches the SDR view. And Auto exposure leaves an HDR source at 0 EV, as rendered: darktable's rule lifted the HEIC by 1.3 EV. The HDR view of an iPhone HDR HEIC then matches macOS's own decode within 3%.

### SDR version

With an HDR export profile, the SDR view shows the edit's SDR rendition: the tone mapper's target white back at 100%, which is what displays without HDR show and the base of a gain map JPEG. The SDR version card adjusts brightness, contrast and saturation for that rendition only, like Lightroom's SDR settings. They become overrides on exposure (or its automatic target level), the tone mapper's contrast and color balance rgb's saturation. The helper commits overrides straight to the pipeline's nodes for one render, pointing each module at the overridden params while committing, because darktable's cache key hashes the module's own params rather than the committed ones. The cache still serves everything before the first overridden module. darktable's sidecar has no place for these settings, so they're stored per photo in the app's preferences.

### Zoom

Click the photo to zoom to 100% at that point, and drag to move around; click again, or press ⌘0, to fit. The engine renders only the visible crop at the zoom scale, as darktable's darkroom does, so at 100% darktable runs its full demosaic rather than the fast preview one. Demosaic methods, capture sharpening and noise reduction can only be judged at 100%. While zoomed, the histograms still describe the whole photo. Panning moves the frame with the pointer straight away. Under it sits the last whole-photo frame (the fitted view, or the small frame rendered for the histograms after an edit while zoomed), scaled to the zoom, so the area a pan uncovers shows a soft version at once. darktable's sharp render then replaces it.

### Export

File › Export (⌘E) is the macOS save panel with the options underneath, as in Pixelmator: format, colour profile, size, quality, bit depth.

- **Formats:** JPEG, TIFF and PNG go through darktable's own export path (the "disk" storage and format modules, as darktable-cli uses), so the output matches darktable's. HEIF is darktable's 16-bit TIFF written to HEIC by Core Image (see A slimmer engine). JPEG XL, WebP and OpenEXR export are left out.
- **Colour profile:** comes from the edit's output colour profile unless overridden, so HLG and PQ exports carry their HDR tagging. A 10-bit HLG HEIF is tagged Display P3 with ARIB (HLG), and a 10-bit PQ HEIF with SMPTE (PQ).
- **JPEG with HDR gain map:** an ISO 21496-1 gain map, the standard behind Ultra HDR, written by Core Image. darktable 5.6.2 can't write it; darktable does it through its `ultrahdr` Lua script, and an unmerged PR (#21458) would add it with libultrahdr. The HDR image is the HDR preview's output. Following Greg Benz's advice that the SDR base matters most, the SDR base is by default darktable's own SDR rendering of the edit, with the tone mapper's target white back at 100% and the SDR version's adjustments, rendered without touching the edit. Apple's automatic tone mapping is the alternative. Checked by decoding: the SDR base peaks at 0.93, and expanded to HDR it peaks at 4.5× white with 41% above white, matching the HDR preview.

### Library and filmstrip

The library sidebar (the standard sidebar button or View › Show Sidebar; it stays as you leave it) has two collections gathered across folders, **Edited** and **Exported**, then the folders added to the library, each expanding to its subfolders. Add folders with + or by dragging them from Finder; right-click to remove one. A folder that's open but not added shows under Current Folder. "Include Subfolders", above the grid, shows everything beneath a folder (up to 5,000 photos), with each photo's folder under its name.

The catalog (`~/Library/Application Support/Darkslide/catalog.json`) records the added folders, when each photo was last saved, and every export (file, format, date). Photos found with a sidecar join Edited when their folder is first shown, so edits from darktable count too. Exported photos carry a badge, orange when edited since the last export, and their exports are listed in the right-click menu to show in Finder.

**Places.** The sidebar's Places shows every photo in the library's folders and their subfolders (plus the folder open now, up to 5,000 photos). Grid | Map above the library, or View › as Grid (⌥⌘1) and as Map (⌥⌘2), switch the folder or collection being shown. Either way the photos are on Apple Maps, each photo pinned by its thumbnail where it was taken (photos close together on screen share one pin with a count; click it to zoom in); click to select, double-click to edit. Positions come from the sidecar first (darktable's map view geotags there, in degrees and decimal minutes) and then the file's EXIF GPS via ImageIO, which reads raws too; zero positions, which cameras without a fix write, are ignored. A strip of the photos runs under the map, each marked with a pin or a crossed-out pin; click a placed one to go to it, or a pin to find its photo in the strip. Drag a photo from the strip onto the map to give it a location, or a pin to a new spot; right-click to remove one. Locations are written as darktable's map view writes them: the helper imports the photo into darktable's library, sets it with `dt_image_set_location` and writes the XMP sidecar (`Xmp.exif.GPSLatitude`), so any edit in the sidecar is kept and raws are never touched. While a photo is dragged over the map, a pin follows the pointer with its tip where the photo will land (a DropDelegate tracks the drag, which `dropDestination` can't).

**Match Locations** gives photos without GPS a position from a track: GPX files from a GPS logger, watch or tracking app (Arc, Strava, Garmin; several files make one track, and points without a time are left out), located photos in the Photos library (an iPhone's, via PhotoKit, asking for access the first time), or the located photos in view. Each photo's capture time (EXIF DateTimeOriginal, in its recorded zone or the camera zone chosen, plus a clock correction for a fast or slow camera) is placed between the track points either side, partway in proportion to the time, or at the nearest point if only one is within the chosen gap. Proposals show as outlined pins with the track drawn; Apply writes them as dragging does. `LocationMatcher.swift` does the matching.

The toolbar changes with the view: the editor's tools (crop, zoom, compare, SDR/HDR, export, save, inspector) in the editor, Grid | Map in the library. It's one customisable toolbar whose items are hidden by view (`.hidden(_:)`): swapping two toolbars in a window, or a toolbar item with no view, makes AppKit throw, and the `.toolbar` modifier has to come after `.inspector` or its items are registered more than once.

The filmstrip (in the editor and under the map) resizes by dragging its top edge, and View › Hide Filmstrip (⌥⌘F) hides it.

The search field finds places with Apple Maps (MKLocalSearch) near the area shown, and marks the one chosen.

The library watches the folders it's showing (FSEvents, `FolderWatcher.swift`), so photos added or removed elsewhere, in Finder or by another app, appear and go within a second or so.

**Raws darktable can't decode.** If darktable's decoders (rawspeed, then LibRaw) can't read a raw but macOS can, `AppleRawFallback.swift` decodes it with Core Image's raw engine, as Photos shows it in HDR (Apple's tone curve, local tone mapping and noise reduction, highlights above SDR white), to a half-float linear Rec.2020 TIFF in `~/Library/Caches/Darkslide/decoded`, and darktable edits that as an HDR source (below). iPhone ProRAW is the common case: rawspeed can't read its lossless JPEG (predictor 7), and a ProRAW's +3 EV baseline exposure relies on Apple's tone curve, so a scene-referred decode without a tone mapper looked flat and far too bright. ProRAW files with a gain map show the HDR badge. The library, Info, exports and the catalog still refer to the original; the edit's sidecar is kept beside it and copied to and from the TIFF's. The decode is checked for content first: macOS reports the size of some raws it can't decode, such as Hasselblad's multi-shot FFF (six samples per pixel, lossless JPEG), and returns black. Those need exporting to DNG or TIFF from the maker's software.

**Raw decoder (for interest).** Image › Raw Decoder picks, per photo, darktable's decoder or Apple's raw engine at any version macOS offers for that file (RAW 9, 8, 7; `CIRAWFilter.supportedDecoderVersions`). "Apple, newest" picks the highest itself, as Core Image's default isn't always the newest (a Nikon Z6 II file offers 7, 8 and 9 but defaults to 8). The decoder in use shows in the window subtitle and the Info window. Switching saves the edit and reopens the photo. With Apple's engine the image reaches darktable already demosaiced, so its raw-only modules have nothing to work on; the engine reports them as not applicable (darktable's own sign: off by default with no on/off control, as demosaic, raw prepare, raw denoise, hot pixels and raw chromatic aberration are on a non-raw) and the inspector hides them, with a note saying why. A DNG (Adobe DNG Converter, which also reads Nikon HE) keeps the sensor data, so darktable's raw tools work on it.

**Apple RAW controls.** When Apple's engine decodes the photo, an Apple RAW section leads the inspector with the decoder's own settings for that camera, as Core Image's `CIRAWFilter` offers them: exposure, boost, shadow boost, local tone mapping (where supported) and the HDR amount, then noise reduction, sharpness, contrast, detail, moiré reduction and lens correction under a disclosure. Defaults are the camera's; the HDR amount defaults to 1, Darkslide's usual Apple decode. Changes are kept per photo (`AppleRawSettings`) and, half a second after a slider rests, the raw is decoded again with them and reopened, darktable's edits carrying over through the sidecar. Each set of settings has its own cached TIFF.

**Edits on an Apple decode** are kept in their own sidecar, `photo.NEF.apple.xmp`, apart from darktable's `photo.NEF.xmp`: the two decodes don't share raw-stage steps, and darktable's raw white balance applied again to Apple's already balanced image turned it purple. The engine also rereads (or, with no sidecar, clears) an image's history on every open, as darktable only reads a sidecar on first import.

**HDR images.** A gain-map JPEG or HEIC (iPhone, Pixel, Ultra HDR, Darkslide's own exports) or an HLG or PQ HEIF or AVIF (Nikon's HLG HEIF) is opened through macOS's HDR decode (`CIImage` with `expandToHDR`): darktable would read only a gain map image's SDR base. It arrives as a linear half-float TIFF in Rec.2020 (written through ImageIO, in strips: Core Image writes tiled TIFFs, which darktable's TIFF reader refuses) with SDR white at 1.0 and the highlights above it, so the HDR view and exports keep them. These photos get an HDR badge in the library and the Info window. Nikon's High Efficiency raws (HE and HE*, TicoRAW) aren't readable by rawspeed or LibRaw; they open through the raw fallback above, as macOS reads them (checked with raw.pixls.us Z8 samples).

Folders and photos can be dropped on the window or the Dock icon, or opened from Finder: a folder shows in the library, a photo (raw or not) opens. The app declares raws, common image formats and folders as documents for that.

Opening a photo makes its folder the library, unless it's in the folder or collection already showing; File › Open Folder (⇧⌘O) opens one directly. The filmstrip under the photo shows the folder's raws and images by name; click one, or press ← and →, to move through them (⌘← and ⌘→ in the Go menu). G, or the toolbar's grid button, shows the folder as a grid; double-click or Return opens a photo. Single keys are ignored while typing in a text field.

- **Thumbnails** start as the camera's embedded preview (ImageIO, so they're quick). Once a photo is edited, its thumbnail is the render, cached in `~/Library/Caches/Darkslide/thumbnails` and keyed to the sidecar's modification date, so an edit made elsewhere invalidates it.
- **Moving to another photo saves your edits** to the XMP sidecar, as darktable and Lightroom do. Only your own edits count: a photo you only looked at keeps no sidecar, even though opening it applies the new-photo defaults (those aren't recorded as undo steps, which is how they're told apart).

### Info

Window › Show Info (⌘I) is laid out as Photos' Info window and behaves like it, and like Finder's inspector: a floating panel (`InfoPanel.swift`, a non-activating HUD `NSPanel`) that stays above the main window without taking focus from it, so arrows, shortcuts and clicks keep going to the photos. ⌘I shows and hides it; it becomes the key window only while you type in one of its fields, and hides while Darkslide is in the background. It follows the photo being looked at: the open one in the editor, or the one selected in the grid, map or strip. With several selected it sums them up (`MultiInfo.swift`): how many, when they were taken, the cameras and lenses, their size, the keywords they share, and a rating or keyword set there goes to all of them. The title, caption, keywords and star rating are editable (click a star again to clear it); they go to the sidecar through darktable (`dt_metadata_set` with Xmp.dc.title and Xmp.dc.description, darktable tags, `dt_ratings_apply_on_image`), so darktable shows them too. With sidecar writing off, darktable reads a sidecar's title and description only if each field's import flag is set, and a new config leaves them unset; the helper sets them at start-up, or the next write would drop them. Lens names get the ƒ glyph ("f/1.2", "F2.8"). Where the EXIF lacks the 35 mm equivalent focal length (Fujifilm), it's worked out from the sensor's size, or the camera's crop factor. Cameras are named as sold (`CameraNames.swift`: NIKON CORPORATION / NIKON Z 6_2 is a Nikon Z6 II, SONY / ILCE-7M3 a Sony α7 III). The exposure line gives the full-frame equivalent focal length; hold Option for the true one. It has the file name and capture time, a card with the camera, lens, size and format, white balance, metering and flash as icons and the exposure along the bottom, the darktable edit (the modules used, leaving out the ones darktable always runs, and the history length), the user's tags (without darktable's automatic `darktable|…` ones), and the place, named by reverse geocoding, over a map. All Metadata opens every tag, by dictionary, with a filter. The file's metadata comes from ImageIO, which reads raws; for raws, bit depth and colour profile are left out, as ImageIO reports the embedded preview's. `PhotoMetadata.swift` does the reading.

### Undo

Edit › Undo and Redo (⌘Z, ⇧⌘Z) step darktable's history position back and forward, as darktable's own history stack does, so each step is mostly a pipe cache hit. The app keeps the stack: each step records the history position plus what isn't in darktable's history (the SDR version, applied styles). A slider drag is one step however long it takes, and a second drag is a new step. Other changes to one module less than a second apart are one step, so a tone equalizer macro or a white balance pick undoes in one go. Steps for slider edits are resolved as their queued settings reach the engine, so a step always lands exactly between two edits. Auto is one step. Opening a photo and Reset All clear the stack.

### Sliders

Drag anywhere on the track; the thumb stays under the pointer. For small changes, scroll sideways over a slider (a two-finger swipe moves it about 0.15% of its range per point, a mouse's sideways wheel 1% a click; vertical scrolling still scrolls the inspector), or use the arrow keys on a slider you've just used (1% a press, 10% with Shift; its thumb is ringed while it takes them). There's no fine-control modifier: moving the value slower than the pointer separates the thumb from it. On tone sliders (exposure, the tone mappers, tone equalizer, levels, local contrast, colour balance, the SDR version and the HDR peak; `Presentation.clippingOps`), Option shows what clips while you drag, as Lightroom's Option-drag does, for both ends at once: on a grey ground, highlights clipped in a channel show in its colour (white where all three clip) and shadows in its complement (black where all three clip). `Clipping.swift` makes it from the frame on screen, once per frame. A caption over the photo says what the colours mean. In HDR it shows the headroom overlay instead. Double-click the track or label to reset; click the value to type one. While dragging, the thumb and number show the drag's own value, so they stay under the pointer, and the value goes to the editor at most every 33 ms.

**Keeping the window responsive.** A slider sends many values a second, and anything that reads a changed value redraws. Two reads used to rebuild the whole window on every change: the menu commands, declared in the app struct (they read what's enabled, so every change rebuilt the scene), and the window subtitle's render time. Both now live in their own types (`AppCommands`, `WindowSubtitle`). `-TestDrag exposure` drags a slider at 30 values a second and logs how late the main thread was and how many frames were shown: 2 ms median and about 20 frames a second on the sample, against 60 to 90 ms and 6 before.

### Inspector

One surface, as in Photos and Pixelmator Pro: sections divided by hairlines, each with a leading disclosure chevron. A module's row shows only its name, its Auto pill if it has one, and its switch; presets (⋯) and reset appear on hover and in the right-click menu. Disclosures inside a section (Advanced and the like) are quieter, with a small grey chevron. In Essentials, drag a module by its name to reorder, as on the iPhone's Home Screen: every module folds shut, a floating copy of the held one follows the pointer, and the others slide around its empty slot (`EssentialsDrag`). Restore Default Order (in a module's right-click menu and under the list) puts the standard modules back in order, keeping any added after them; Restore Default Essentials also resets which modules are there. Along the top, Essentials, Active and All are a standard segmented control with the workspace menu beside it, then the module search and Auto. Reset All sits quietly at the bottom (and in the Image menu); Compare is in the toolbar, grouped with crop and zoom.

### Workspaces

A workspace is a named inspector set: the modules in Essentials and their order, the cards that are open, and which fixed panels show (histogram, SDR version, HDR details, Look, local adjustments). The current one keeps changes as you make them. Window › Workspace, or the button beside the module search, switches between them (⌃⌘1 to ⌃⌘9), shows or hides panels, and saves a copy under a new name, renames or deletes. The fixed panels are descriptors in `InspectorPanel.all` (`InspectorPanels.swift`): an id, title, icon, placement (pinned above the cards, or among them), when it applies, and its view. A workspace stores only ids, so a new panel is one entry there. Runs with `-Test…` or `-Start…` launch arguments never save workspaces.

### Crop and straighten

Image › Crop and Straighten (⌘K, or C on its own), or the toolbar's crop button. The canvas shows the whole straightened photo with a crop box; drag its corners, edges or inside, with a ratio held if one is chosen. Return finishes, Escape cancels.

- **Guides** (`CropGuides.swift`): rule of thirds, golden ratio (lines at 0.382 and 0.618), the golden spiral (a golden rectangle cut into squares with a quarter circle in each, stretched to the box; the flip button or O moves its eye to another corner), diagonals with their reciprocals (dynamic symmetry), rebatement (each short side's square swung in, with its diagonals) and an even grid. Each is drawn for a landscape box and turned for a portrait one. Shown always, or only while dragging; the choice is kept between photos.
- **Straighten** is darktable's rotate and perspective module (ashift): its rotation, plus crop margins that keep the photo's shape and cut off the corners the rotation brings in, as its "original format" automatic cropping would. darktable fits those margins in its interface code, so for a pure rotation the app works them out: the largest centred rectangle of the photo's proportions inside the rotated bounding box. ashift runs before the orientation flip, so this uses the size reaching it (the render reply reports it).
- **Instant preview.** Rotation runs early in the pipe, so each straighten change reprocesses most of it (about 400 ms on a 24 MP raw). While that runs, the canvas turns the frame it has by the difference and enlarges it to fill, which is what the margins will do; darktable's render then replaces it.
- **Auto straighten** works like Lightroom's and Photomator's levelling (`LevelDetector.swift`). It takes Sobel gradients on a 900 px grey copy of the photo as shown and keeps only pixels where a structure tensor over 5 × 5 pixels is coherent, which means straight edges and not grass or leaves. Each one's tilt from the nearest axis goes into a 0.1° histogram, weighted towards lines near the centre, because converging verticals lean more towards the edges. Verticals count double, as horizons are often hills. The peak is the tilt. Vision's horizon detection is the fallback. It always measures the same picture: a 1200 px render with the rotation and crop overridden to none. So the tilt found is the rotation that levels the photo, in one pass, rounded to 0.1°. The answer depends only on the photo, and pressing it again changes nothing. On the Z50 sample it gives 0.1° from starting angles of 0°, 4°, −3° and 7°.
- **Perspective.** Vertical and Horizontal sliders are darktable's lens shifts (`lensshift_v`, `lensshift_h`), shown as −100 to 100 the way Lightroom shows them. `Perspective.swift` ports ashift's homography (generic lens model, as the module defaults to) and fits the "original format" automatic crop: the largest rectangle of the photo's shape inside the corrected quadrilateral. darktable fits the crop's centre with a simplex in its GUI code; here a pattern search does the same job. The port's output shapes match the engine's to three decimal places. Straighten uses the same path, so rotation and perspective crop together.
- **Upright** only acts on photos with clear verticals: after the fit, at least a fifth of the edge strength must lie within 1° of vertical (the Z50 sample, buildings among trees, scores 0.27; a landscape scored 0.14 and had been tilted 7° by the fit). Otherwise it says so and leaves the photo alone.
- **Upright** is like Lightroom's Upright Vertical: it finds the rotation and vertical shift that make the photo's near-vertical lines vertical. It measures the photo as ashift receives it: a render with rotation, perspective and crop overridden to none, and the orientation flip overridden off, because the flip comes after ashift. Edge samples come from the level detector's structure tensor, near-vertical only. Each sample's direction is pushed through the homography, and a robust cost (each line's lean, capped at 3°) is minimised by a grid search and then a pattern search. On the Z50 with a +0.40 vertical shift applied it finds −0.41; on the photo itself it finds 0.16° and −0.05, the same on every press. Level now measures the same unflipped render, so both work in ashift's own terms whatever the camera's orientation. Overrides can now set whole-number, choice and on/off settings, not just decimal ones, which the flip override needed.
- **Crop** is darktable's crop module, which comes after rotation, so the box is relative to the straightened photo. While cropping, renders override the crop to the full frame (the helper recomputes the output size after overrides for this).

Both are ordinary edits, so they undo, save to the XMP and open in darktable.

### Film looks

The Look card's "Film look" applies a LUT from a folder you choose: Hald CLUT images (.png, .tif) or .cube and .3dl files, such as the RawTherapee film simulation collection (CC BY-SA 4.0, not included). Menus follow the folder's own folders. Files of one film pushed and pulled, numbered as that pack numbers them ("… 1 -", "… 2", "… 3 +", "… 4 ++"), sit together under the film as −, Normal, + and ++. A strength slider blends the look in.

Under it, Grain switches on darktable's grain module with its strength and film speed, so a black and white film and its grain sit together; the channel and mid-tones bias stay in the module. darktable's coarseness is a film speed (its GUI shows 20 to 6400, and it stores that divided by 213.2), so Darkslide shows it as one: ISO 1600, on a slider in stops that snaps to the thirds printed on film boxes (`FilmSpeed.swift`, `FilmSpeedSlider`). Choosing a film with grain on, or turning grain on with a film chosen, sets the speed to the film's, a stop faster or slower for each + or − variant; a link puts it back after changing it. The speed comes from the number in the film's name (Tri-X 400, Fuji 400H, Retro 80s), or a short list for names without one (HP5, XP2, Polaroid's pack numbers: 667 is ISO 3000). Creative looks have none and leave the grain alone.

Browse… opens a grid of the photo in each film, by folder, with a search across film and folder names and a star for favourites, which gather at the top. A film's push and pull variants show on the Look card once it's chosen. The previews are worked out in the app: each LUT (a Hald CLUT image, or a .cube file) is shrunk to a 32-point cube for Core Image's colour cube and applied to a 280 px render of the photo with its look switched off. Overrides can now switch a module off for one render ("disable") for this. The previews are close to darktable's result rather than identical (darktable interpolates the full cube tetrahedrally); an identity LUT returns the photo unchanged. Favourites are kept per film in the app's preferences.

darktable's LUT 3D module applies it. The engine's `look` command sets the module's LUT folder setting and its file path (relative to that folder, as darktable stores it), with sRGB as the LUT's colour space. darktable places LUT 3D before the tone mapper, for scene-referred LUTs, but film LUTs are made for display-referred sRGB, so the engine moves it after the tone mapper in use; the order is saved with the edit. Strength is the module's blend opacity.

Film LUTs only cover 0 to 1. Engine patch 0004 makes LUT 3D scale any pixel brighter than white into range by its largest channel, look it up, and scale it back, so in HDR the highlights keep their brightness and take the film's colour. Pixels in range are unchanged, so SDR results are as before. On the Z50 with sigmoid's target white at 400%, the HDR peak is 2.17× white without a look, 2.14× with Velvia and 2.17× with HP5, where unpatched darktable clips at 1. The module now runs on the CPU, because the step is only in its CPU code.

### Apple Photos

A switch at the top of the sidebar picks the library: Folders (the folders on this Mac, with Edited, Exported and Places gathered from them) or Apple Photos (All Photos, Places, Favourites and the albums). They never mix. Photos asks for access the first time.

**A whole library.** All Photos shows every photo: 63,000 in a few seconds, without stalling the Mac. That took several fixes. Thumbnails reuse the assets from the grid's fetch, rather than a fetch each, and use only what Photos keeps on the Mac, as allowing iCloud downloads fetched thousands of originals. Album counts are Photos' estimates, loaded off the main thread. Photos reports changes constantly while it analyses the library: only changes to a photo's picture count, applied in one go rather than a grid redraw per photo. The map gathers photos near each other on screen into one pin with a count (click to zoom in), about a hundred in view instead of a pin and thumbnail for every photo. And strips and the grid scroll to the selected photo by working out its offset, since `scrollTo(id:)` laid out every photo before it.

Photos assets aren't files, so library items address them as `photos://asset?id=<local identifier>`, and their thumbnails come from Photos (`PHImageManager`). Opening one writes its original to `~/Library/Caches/Darkslide/photos` and edits that file: the raw of a raw or raw-and-JPEG photo, otherwise the photo as taken, before any edit. The library stays on Photos, and the filmstrip and arrows follow the asset (`libraryURL`). The original's title is its file name; renaming and the title's file icon are off, as the file is a cache copy.

**Map and changes.** Places, and the map view of any Photos album, place photos from Photos' own locations, not from their files (49,589 of 63,477 here). Dragging one onto the map sets its location in Photos, as Photos' Info does. A PhotoKit change observer keeps the grid current: photos added, removed or moved (here, in Photos or on another device) reload it, and photos edited elsewhere get new thumbnails and places.

**File › Save to Photos (⌥⌘S)** saves the edit to Photos as its own edit of the original, so Photos keeps the original and Revert to Original works. It saves a rendering (a JPEG with an HDR gain map for an HDR edit, otherwise the type Photos asks for, through darktable's export) and the darktable edit (the XMP sidecar) as the edit's adjustment data, identified as `me.frsr.darkslide` (edits saved as `me.frsr.develop`, the app's earlier name, still open). Opening the photo again reads that back as its sidecar, so every setting returns. A photo edited in Photos itself opens from its original here, and saving replaces Photos' edit.

### Frames and watermarks

The export panel can add a frame and a text watermark to the exported file, leaving the edit as it is. Both work for every format, gain map JPEG included, and the framed picture comes out at the size chosen (the photo is exported smaller by the frame's share).
- **Frame:** an even border, square or 4:5 portrait, in white or black, sized as a share of the longer side.
- **Watermark:** your text in one of nine positions, white or black, with a size and opacity. With a frame on, it sits in the bottom border instead, sized to the border, in the frame's other colour, lined up with the photo's edge (or centred).

The app draws them with Core Image (`ExportExtras.composite`), not darktable's framing and watermark modules, which needed Cairo:
- **The path:** darktable exports a 16-bit (or float) TIFF already encoded in the export's profile. The frame and watermark are drawn on it, and Core Image writes the chosen format, tagged with the matching colour space. Colour management is off for that step, so nothing is converted twice, and the TIFF's metadata goes into the file. Exports without a frame or watermark still come straight from darktable, except HEIF, which always takes this path.
- **Gain map JPEGs:** these get them on both the HDR and SDR images before the gain map is computed.
- **White:** the frame and white text sit at reference white in the file's encoding: 1 for SDR, 75% signal for HLG, and the PQ signal for 203 nits. In an HLG HEIF and a gain map JPEG the frame decodes to exactly 1.00, with the photo's highlights above it.
- **Layout:** `frameLayout` ports `borders.c`'s `modify_roi_out`, the border's size being its share of the framed side, so frames match darktable's. With a frame on, the signature sits in the bottom border, sized to it, in the frame's other colour, lined up with the photo's edge.
- **Text:** the text is drawn with Core Text.

### Copy and paste adjustments

As in Photos:
- **Edit › Copy Adjustments (⇧⌘C)** copies the open photo's edit, or the selected one's in the library.
- **Copy Some Adjustments… (⌥⇧⌘C)** gives a checklist of the edit's modules, with white balance, lens correction and orientation unticked because they belong to the photo.
- **Paste Adjustments (⇧⌘V)** pastes onto the open photo, or every photo selected in the library. In the grid, click selects one photo, ⌘-click adds or removes one, ⇧-click selects a range and ⌘A selects all; the right-click menu on a selected photo pastes to the whole selection. The single current photo (arrows, Return, Info, the map) is the last one clicked.
- **Right-click menu:** library photos also have Copy Adjustments and Paste Adjustments.
- **Camera style shortcut:** Apply Camera Style moves to ⌥⌘C.

The engine's `paste` uses darktable's own history copy (`dt_history_copy_and_paste_on_image`), which carries module instances, masks and module order. It merges: the modules copied replace the same ones on the target, and the rest stay. A copy of everything is darktable's Copy: every module the photo has changed, except those its modules mark unsafe to copy. A chosen set is passed as indices of each module's last history item, as darktable's selective copy does. The open photo's edit goes to darktable's library before copying. Other targets get their sidecars written. A paste onto the open photo reloads it, and it's one undo step: the step records its history position before the paste. darktable reports a paste as `TRUE`, not as a failure.

### Presets and instances

Each card's ⋯ menu lists darktable's presets for the module, with names written "group | name" gathered into submenus. It can also save the current settings as a preset (any camera, lens and exposure, not applied automatically, as darktable's "store new preset" defaults), delete your own presets, add a new instance of the module, and delete an extra instance.

The engine reads and writes `data.presets` in Darkslide's darktable database. It lists the presets matching each module's version, leaving out the automatically applied workflow defaults. darktable stores its own presets as "_builtin_name" and shows them without the prefix, as Darkslide does. Applying copies the stored settings, and the blending where its version matches. New instances are numbered as darktable shows them ("Exposure 1"); a name not marked as given is replaced from presets, so the engine marks it. Deleting an instance switches it off and renames it out of sight, as for local adjustments, since darktable's removal is interface code.

### Local adjustments

The Local adjustments card adds the subject, and linear and radial gradients, to brighten or darken part of the photo. Each is its own exposure instance, named "Local n", masked by one darktable drawn shape (a gradient or an ellipse), so the sidecar carries it as darktable would. Select one to show its shape on the photo:
- **Linear:** drag the centre to move it, the arrow to turn it (the side it points to gets the adjustment), and the dashed line to soften it.
- **Radial:** drag the centre, the two radius handles, and the outer handle for the softness.
- **Subject:** Apple's Vision finds the subject (`VNGenerateForegroundInstanceMaskRequest`, the subject lifting in Photos and Preview: people, animals and objects that stand out) in a render of the photo as it looks, in about half a second. The engine traces the mask into darktable path shapes with darktable's own `ras2forms` (potrace), as darktable's AI masks do, holes included, so the edit is darktable's and exports anywhere. Its outline shows on the photo. The [mask lab](Tools/masklab) compared Vision with SAM and darktable's AI models.

The engine does what darktable's mask tools do, without the interface:
- `add_local` duplicates the module, creates the shape, saves it with `dt_masks_gui_form_save_creation` (which makes the module's mask group and links it), turns on the drawn mask, and rebuilds the pipe.
- `set_shape` and `shape` take and give points in the photo as processed. They move them through the pipe's distortions (lens, perspective, crop, flip) with `dt_dev_distort_backtransform_plus` and `dt_dev_distort_transform_plus`, because shapes are stored in input coordinates.
- Two traps. The pipe cache's key doesn't cover a shape, so a moved shape invalidates the cache from its module on. And each node's input size is only set when the pipe's dimensions are worked out, which happens at load, so a module switched on since (lens correction) transformed points with a zero size until the engine started working them out again first.
- darktable's instance removal is interface code, so Delete switches the instance off and renames it out of sight, and undo brings it back.
- For now each adjustment is exposure only; other adjustments would be other modules masked the same way.

### Hue curves

The Hue curves card is darktable's colour equaliser shown as Photomator-style curves. It has Hue, Saturation and Luminance tabs, each plotted against hue, with a handle on each of darktable's eight colours (red, orange, yellow, green, cyan, blue, lavender and magenta). Drag a handle up or down, or double-click it to reset. Hue runs ±90° on screen (darktable allows ±180°) and the others 0 to 200%. The line is darktable's periodic radial-basis interpolation (`_periodic_RBF_interpolate`), ported, so it's the curve applied, including the module's hue smoothing and node placement. The handles use the eight named colours rather than HSV hues, because darktable's hue circle (its UCS) isn't HSV's. The module's other settings (saturation threshold, contrast, white level, the guided filter's radii) are under Advanced. Every value is a plain field, so no engine support was needed.

### RGB curve and lens correction

The RGB curve card (darktable's rgb curve, linked channels, preserve colours on) is a Photomator-style editor: guides at blacks, shadows, mid-tones, highlights and whites, the curve's input histogram behind, and a handle on each guide. A handle you haven't moved rides on the curve as other handles change it; a moved one is a point of the curve and shows a dot. Each point belongs to its nearest guide, so dragging a handle sideways doesn't leave another behind. The end handles move inwards too, to compress the range: beyond them the curve is flat, as darktable's is, which also caps HDR highlights. Click the curve between guides to add a point; double-click a handle to reset it. While dragging, the editor draws the curve from the drag itself and only the latest position goes to the engine, so the line keeps up with the pointer and the photo follows as fast as it renders. Its axis is rgb curve's middle-grey-compensated scale (Lab lightness), so the guides are labelled in stops from middle grey: about −2, grey, +1.4 and +2.4 EV, the top of the curve, above which darktable carries the curve on along its last slope, so HDR highlights aren't clipped. The engine writes the points (`set_curve`) and returns them with the histogram (`curve`); rgb curve switches its histogram off outside darktable's preview pipe at every commit, so the engine turns it back on before each render, and while the editor shows an rgb curve that's off, the preview runs it flat (an override that isn't an edit) to collect the histogram. The curve is drawn with darktable's monotone Hermite maths, ported. RGB, Red, Green and Blue tabs switch between the linked curve and the colour curves. darktable's rgb curve holds either one linked curve or three independent ones, so the colour curves live in a second rgb curve instance named "channels", in independent mode, placed right after the first. The engine's `add_instance` command creates it on the first colour edit, as darktable's duplicate button does: it's recorded in the history and the sidecar by name, and the pipe's nodes are rebuilt. The app keeps it out of the module list, and the card's switch and reset act on both. Each colour tab shows its own channel's input histogram.

Lens correction shows the lens darktable matched (the engine now sends modules' text settings), where the correction data comes from (the camera's own, Lensfun, or a manual vignette) and switches for distortion, vignetting and chromatic aberration, with strength sliders for the camera's own data. darktable's other lens settings stay at their defaults.


**Lens settings take effect.** darktable's lens module ignores its own settings until `has_been_set`, which its interface sets on the first change, and uses its automatic defaults instead; the engine now sets it on every change, so a chosen lens, the corrections and the strengths apply. The pipe cache also keys the module on committed data holding a pointer to the Lensfun lens, so a text change (camera, lens) invalidates the cache from the module on.

**Lens picker.** With Lensfun chosen, the lens name is a pop-up button that opens a picker for when the metadata names the lens wrongly or not at all. It lists every Lensfun lens that fits the camera, filtered by any words of its name. A Camera tab searches Lensfun's cameras, for a camera it didn't recognise. The engine reads the Lensfun database darktable has already loaded, through the lens module's global data. That struct isn't in a header, so the helper mirrors the start of it. The engine's commands are `lens_lenses`, `lens_cameras` and `set_text`; `set_text` sets any char-array setting, such as the lens module's camera and lens. Lensfun's own loose search ranks poorly ("16-50" doesn't find the Z DX 16-50 first), so the app filters the full list itself.
### Looks

- **Default tone mapper.** darktable's workflow setting (sigmoid, filmic or AgX), chosen in Settings (⌘,). Darkslide defaults to filmic. darktable registers the matching presets at startup, so changing this restarts the engine. If edits are unsaved, the restart waits until the next photo is opened.
- **Camera styles.** darktable ships 510 styles that approximate each camera maker's JPEG look. `CameraStyles.swift` matches the photo's camera to one, following darktable's `apply_camera_style.lua`: exact model first, then series patterns like `EOS R? series` and sets like `EOS [200D Mark II,250D]`. Only a style for that camera or its series is offered, not the maker's or darktable's generic ones, and only for raws (a JPEG or HEIC already has the camera's look). For raws without an existing edit, a banner offers the match. Settings can make it automatic or turn it off. Styles are appended to the edit, as in darktable's default mode.
- **Match Camera.** One button for the camera style plus automatic exposure, roughly the camera's own JPEG look. It's named for what it does rather than "Auto Enhance", because nothing analyses the photo's content.
- **New-photo defaults.** For photos without an existing edit, lens correction is on by default (darktable leaves it off). darktable uses the correction data stored in the raw where the camera writes it (Sony, Fujifilm, Olympus and others), otherwise the Lensfun database. Automatic exposure is optional. It's darktable's metering rule (a chosen percentile to a target level), shown as an "Auto" pill rather than a wand for the same reason. Auto sets the Exposure slider to a measured value, as Lightroom's does. It doesn't switch on darktable's automatic mode, which only runs on 16-bit mosaic raws. On monochrome raws such as the Leica M11 Monochrom, linear DNGs, JPEGs and decoded TIFFs, that mode silently does nothing, while hiding the slider behind a percentile and a target level. The engine's `auto_exposure` command applies darktable's rule (the 50th percentile of the input, in EV below white, to −4 EV) to any input. It reads a sample of the full-size input buffer, uses the raw black and white levels for raws, and undoes the sRGB curve for display-referred files, which aim a little lower (−3 EV), since the camera has already exposed them. The result allows for the module's exposure-bias and highlight-preservation compensation. On the Z50 sample it gives the same frame as darktable's own mode. darktable's rule meters the raw, so a bright sky or backlight leaves the subject dark (a dusk portrait came out about a stop and a half under). So the Auto button then checks the photo as it renders (`liftDarkExposure`): if the median of a 400 px SDR render is more than a third of a stop under 13% display-linear (about 40% in sRGB, a typical photo's middle tone), it lifts the exposure, scaled down for the tone mapper's mid-tone gain (about 1.4), in up to three passes and at most 2 EV. It only lifts. On the D80 sample it changes nothing; the Sony sample gets +0.4 EV; either started two stops dark comes back to the same value. A photo saved in darktable's automatic mode is switched to the equivalent manual value when opened, using its own percentile and target. The Auto pill shows as on while the slider sits at the measured value. Three more, each in Settings: filmic's auto-tune runs last, once exposure and any camera style are in (its white and black from the photo, rather than darktable's average-scene defaults); darktable's colour balance rgb "basic colorfulness" preset (natural skin by default, or standard, vibrant or none; skipped when a camera style brings its own colour), because darktable adds no colour and looks flat next to a camera JPEG; and darktable's profiled denoise for raws from ISO 800 (or 400, 1600, 3200 or off), as Lightroom always reduces noise and older sensors such as the D80's CCD band visibly when pushed. Turning modules on for a new photo is awaited, not left to a background task, as the auto-tune then takes the engine's module list.
- **Before and after.** The helper keeps a second, untouched copy of the photo as it was opened, with its own pipe and cache, so edits only re-render the edited side. Compare (⇧⌘B) shows it left of a draggable divider.
- **Customisable Essentials.** The default tab. Add or remove modules from a module's context menu and drag a module by its name into your own order.
- **White balance.** darktable sets the light's colour in color calibration (a CAT16 chromatic adaptation, more accurate than scaling the raw channels), leaving its own white balance module, shown here as Raw white balance, on camera reference. The White balance card shows color calibration's illuminant as temperature and tint; search still finds it as scene white or color calibration. `Illuminant.swift` converts to and from xy with Krystek's Planckian locus and standard Duv; D65 round-trips to 6506 K, +3.3.
- **Shadows and highlights.** The tone equalizer, with two main sliders that move weighted groups of its exposure zones. Known gap: darktable fits the tone equalizer's mask to each photo with an auto-adjust ("magic wand") in its interface code. Without it, which zones a photo occupies varies, so on very bright or dark photos the sliders reach into the midtones. Next: run that fit in the engine.
- **Card layouts.** `Presentation.layouts` groups a module's fields into an open main section, disclosures and Advanced (used for color balance rgb and the tone equalizer). `fieldLabels`, `displayNames` and `searchAliases` give familiar names, so "clarity" finds local contrast and "dehaze" finds haze removal. `fieldHelp` adds tooltips where a name doesn't say which way to move a slider. A disclosure whose fields all belong to another mode isn't shown. Profiled denoise leads with its method, each explained, then strength and the shadow controls; patch settings appear only for non-local means, and the automatic methods show Auto strength in place of the settings they work out for themselves, as darktable's own panel does. `softRanges` narrows sliders as darktable's GTK sliders do (raw denoise's threshold runs to 0.1, not 1). Sliders reset to, and mark, the module's defaults for this photo rather than the generic ones its params declare, as some modules set theirs from the camera (denoise from the noise profile).
- **Other styles.** Every other darktable style is under Look › Apply a style.

## Building

Needs Xcode 16 or later, Homebrew, and these formulae:

```fish
brew install gtk+3 json-glib librsvg exiv2 lensfun pugixml potrace libomp pkgconf intltool cmake ninja
```

Then:

```fish
Engine/fetch-engine.sh     # darktable source + patches -> vendor/dt-install (~5 min)
Scripts/fetch-models.sh    # optional: darktable's raw denoise model -> Models/, as Core ML (needs uv)
Scripts/build-app.sh       # helper + app -> build/Darkslide.app, signed
open build/Darkslide.app
```

Without the model, Image › Denoise to New DNG is greyed out. The model is darktable 5.6's RawNIND raw denoiser (GPL-3.0), downloaded from darktable-ai's release and converted, so it isn't kept in git.

For faster iteration on the Swift side, `swift run` works if `DARKSLIDE_ENGINE` points at `vendor/dt-install/bin/darkroom-helper`.

## Layout

| Path | What |
| --- | --- |
| `Engine/helper.c` | The headless engine and its protocol |
| `Engine/patches/` | Changes to darktable itself, listed in its README |
| `App/Sources/Engine/` | Process management, wire types, HDR analysis |
| `App/Sources/Editor/` | Editor state, edit coalescing, camera style matching, settings, presentation overrides |
| `App/Sources/Views/` | SwiftUI views |
| `Design/` | The app icon: `make-icon.py` draws darktable's aperture as a real iris (each blade lying on the next, shading painted in, since glass stacking can't loop) into Icon Composer layers, `AppIcon.icon`, which `build-app.sh` compiles with `actool` |

## Known limits

- **Not notarised:** The app is signed with a development identity only, so on another Mac Gatekeeper blocks it until it's allowed in System Settings › Privacy & Security.
- **HDR preview untested against real files:** The HDR view hasn't yet been compared side by side with an actual PQ/HLG file exported from darktable on the same display.
- **Slider ranges:** These come from darktable's hard limits unless overridden in `Presentation.swift`. darktable's GTK interface narrows them per module in code we can't see, so the useful modules need hand-tuning.
- **White balance:** The temperature module stores RGB multipliers. Kelvin and tint are worked out in darktable's GUI code, so they need a custom editor.
- **Not supported yet:** masks other than linear and radial gradients (paths, brushes, parametric masks), and local adjustments other than exposure.

## Licence

Darkslide is free software under the GNU General Public License, version 3 or later (`LICENSE`). It has to be: the engine links against darktable (GPL-3.0-or-later), `Engine/patches` modifies it, and the Metal kernels are translated from darktable's OpenCL code. Anyone may use, change and share it, and anything built from it and shared must be GPL too, with its source.

The built app also contains code under other licences, all compatible with the GPL. `Scripts/notices.py` lists every part in the app's acknowledgements (Help › Acknowledgements) with its licence text in full, and the build fails if the engine picks up a library that isn't listed.

| Part | Licence |
| --- | --- |
| darktable 5.6.2, with rawspeed, LibRaw and whereami inside it | GPL-3.0-or-later; LGPL-2.1-or-later; LGPL-2.1 or CDDL-1.0; MIT |
| GLib, JSON-GLib, libintl | LGPL-2.1-or-later |
| Lensfun, and its lens database | LGPL-3.0; CC BY-SA 3.0 |
| Exiv2, Potrace | GPL-2.0-or-later |
| Little CMS, pugixml, Brotli, libjpeg-turbo, LibTIFF, libpng, Imath, inih, PCRE2, Zstandard, liblzma | MIT, BSD and similar permissive licences |
| LLVM's OpenMP runtime | Apache-2.0 with the LLVM exception |
| Raw denoise model (RawNIND, from darktable-ai) | GPL-3.0 |
| Rescue Focus models (Restormer) | MIT |

The LGPL libraries are separate dynamic libraries in `Contents/Resources/engine/lib/darktable`, so they can be replaced. `Licences/` holds the texts the build can't find in the libraries' own files.

A binary release must come with its source: each release is built from a tag (`Scripts/release.sh`), and that tag, with darktable 5.6.2 and the patches here, is its source.

## A slimmer engine

darktable is built with only what Darkslide uses. Besides the extras that were already off (maps, Lua, colord, G'MIC, ImageMagick, tethering, AI masks and others), XCF and ICU are off, and so are its HEIF, OpenEXR, JPEG XL and WebP modules. macOS does that work instead:
- **Opening:** HEIC, HEIF, AVIF, JPEG XL, WebP and OpenEXR files go through macOS's decode. SDR images become a 16-bit TIFF in their own colour space; HDR images and EXR become a linear Rec.2020 float TIFF, as before. darktable edits the TIFF, and the sidecar stays with the original.
- **HEIF export:** darktable exports a 16-bit TIFF already encoded in the export's profile (with any frame and watermark), and Core Image writes those values unchanged into a HEIC tagged with the matching colour space (sRGB, Display P3, Adobe RGB, linear Rec.2020, or PQ or HLG in Rec.2020 or P3), 8-bit or 10-bit. Colour management is off for that step, so nothing is converted twice.
- **JPEG XL and WebP export** are gone: macOS reads both but writes neither.

**No interface libraries.** darktable's build requires GTK and the libraries under it, and its code refers to them throughout (every module has interface code), but Darkslide never runs darktable's interface. So the app build (`Scripts/stub-gui-libs.py`) gives the bundle's engine stand-ins instead. For each of GTK, GDK, gdk-pixbuf, Pango, Pango-Cairo, librsvg, ATK, HarfBuzz and cairo-gobject, it builds a small library exporting every function the engine refers to from it (646 for GTK, about 780 in all), each doing nothing and returning zero. It then points the engine's 148 binaries at those with `install_name_tool`. darktable itself is built unchanged against GTK's headers. A stand-in that is ever called logs `[gui stub] <name> called`. None has been, across opening, rendering in SDR and HDR, curves, hue curves, local adjustments, lens changes, film looks, perspective, presets and instances, copy and paste, and JPEG, HEIF and framed, watermarked exports.

Cairo gets a stand-in too. Homebrew's Cairo brought in X11 (libX11, libxcb, libXext, libXrender), fontconfig, freetype and pixman, about 24 MB. Darkslide only used it for darktable's watermark module, and now draws frames and watermarks itself. potrace (tiny) is bundled for real: it traces subject masks into paths. The bundle also leaves out darktable's lighttable and view modules and its interface art (pixmaps, themes, the slideshow viewer), as well as its LaTeX and tools folders. The engine is 29 MB, down from 35 MB.

The engine now links 16 Homebrew libraries rather than 39: the GLib family (GLib, GObject, GIO, GModule, GThread), json-glib, Little CMS, Exiv2, Lensfun, pugixml, libjpeg, libpng, libtiff, libomp, libintl and Imath.

**Self-contained.** The app build bundles them (`Scripts/bundle-libs.py`), so Darkslide runs on a Mac without Homebrew; building it still needs Homebrew.
- **What's copied:** the 16 above, plus the 7 they use themselves (PCRE2, Brotli, inih, zstd, xz), 23 in all, about 12 MB. They go into the engine's `lib/darktable` under the names they're referred to by, each with an `@rpath` install name and every reference pointed at it. The helper no longer searches `/opt/homebrew/lib`. Lensfun's lens database goes into `share/lensfun`, where darktable looks for it beside its own data.
- **Signing:** changing a library breaks its signature. install_name_tool only re-signs what the linker signed, and macOS kills a process that loads a library with a broken signature (exit 137), so the script signs every binary it changes again.
- **Tested without Homebrew:** the engine run under `sandbox-exec` with all reads of `/opt/homebrew` denied opens raws, finds lenses in the bundled database, renders and exports.
- **Any Apple silicon Mac:** darktable is built with `BINARY_PACKAGE_BUILD`, so it targets generic arm64 rather than `-march=native`, which would tie it to the build Mac's chip generation.
- **No build paths:** darktable builds with debug info, and OpenMP and `__FILE__` put source paths into the binaries. The engine build maps the checkout's path away (`-ffile-prefix-map`), the bundle step strips the debug map, and it fails if any binary still contains the home folder.
- **Size:** the app is 57 MB.

The engine's old frame and watermark support (darktable's modules through an export style) is gone, as it needed Cairo; the app draws them.

