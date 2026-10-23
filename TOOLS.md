# Tool catalog

Taken from the Swift reflection metadata (enum case names) in Tangerine 2.0.2's binary.
This is the feature list Lemon targets; the implementations are Lemon's own.

## Dial modes (hold a key while the dial is open)

| Key | Mode (Tangerine name) | Contents |
|---|---|---|
| Shift | Convert (`conversions`) | target formats for the dragged file's type |
| Command | Edit (`fileTools`) | file tools below |
| Control | Actions (`fileActions`) | AirDrop, Float, Copy, Move, Copy Path, Open in Terminal |

## Conversion formats (`ConversionFormat`)

- Image: JPG, PNG, WEBP, HEIC, TIFF, SVG, AVIF, BMP, PDF
- Audio: MP3, M4A, WAV, FLAC, OGG, OPUS, AIFF, WMA
- Video: MP4, MOV, MKV, WEBM, AVI, WMV, GIF
- Documents: DOCX, PAGES, PPT, PPTX, TXT, MD, RTF, RTFD, TEXTCLIPPING, HTML, EPUB, PDF
- Spreadsheets: XLSX, XLS, ODS, CSV, TSV
- Subtitles: SRT, VTT
- Archives: ZIP, TAR, GZIP, RAR

## File tools (`FileTool`)

compress, removeMetadata, editImage, annotateImage, frameImage ("Add BG"), cropImage,
normalizeAudio, muteVideo, trimVideo, splitPDF, organizePDF, extractArchive, createPDF,
mergePDF, cropVideo, changeVideoSpeed, joinVideos, videoSnapshots, splitVideo, audioToVideo,
trimAudio, audioChannels, createCollage, readQRCode, redactImage, redactVideo, redactAudio

## Actions (`ConversionFanAction`)

convert, fileTool, airDrop, float, copy, move, copyPath, openTerminal

## Tool options (field names from Tangerine's options model; meanings inferred)

| Tool | Options |
|---|---|
| Compress (image) | target mode: preset / file size / percentage; target size + unit; reduction % |
| Compress (video) | target encoding; levels balanced / strong; accurate / fast |
| Metadata | pick individual fields, or remove all |
| Edit (image adjust) | exposure, brightness, contrast, highlights, shadows, whites, blacks, temperature, tint, saturation, vibrance, hue, gamma, clarity, texture, sharpness, dehaze, fade, vignette, grain, noise reduction, blur |
| Annotate | layers; blend mode normal / multiply / overlay; colour |
| Add BG (frame) | background: gradients (citrus, mesh, meadow, whisper, orchid, oasis, lagoon, aqua, dream, sorbet, frost, emerald, sunset, sky, mint, violet, graphite), solid colours, custom image; padding, corner radius, shadow; canvas ratio automatic / square / landscape / portrait |
| Crop | x, y, width, height per image (multiple selections) |
| Redact (image/video) | rectangles with strength and size; style; video time ranges |
| Redact (audio) | bleep ranges |
| Normalize audio | target loudness, loudness range, true peak (EBU R128) |
| Trim video/audio | start, duration; audio: auto-trim silence below a dB threshold |
| Change speed | playback speed |
| Snapshots | chosen times |
| Split video | split times, removed clips, export as clips or merged |
| Audio to video | waveform or static image; canvas size |
| Audio channels | channel count, left/right volume |
| Organize PDF | page order, page rotations, equalize page widths |
| Collage | layout options |

## Float shelf

Floating file shelf that can attach to a screen edge (spring animation), compact / expanded,
icons / list view, multi-select with rubber band, drag files out, Quick Look, context menu,
share picker, type-to-select, and a "paper clip" retraction animation.
