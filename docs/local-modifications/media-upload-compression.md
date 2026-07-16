# Local modification: media upload compression

Branch: `feature/media-upload-compression`

## What changed

Photos and videos are compressed **on Send** (after preview), driven by the
user **Upload Media** setting — not by server capabilities.

| File | Role |
|------|------|
| `NextcloudTalk/Settings/MediaUploadPreprocessor.swift` | Presets (None / Moderate / High), size estimates, Automatic policy |
| `NextcloudTalk/Settings/NCUserDefaults.m` | Persists Upload Media mode in App Group |
| `NextcloudTalk/Settings/SettingsTableViewController.swift` | COMPRESSION section UI |
| `ShareExtension/ShareItemController.m` | Stages originals; compresses on Send |
| `ShareExtension/ShareConfirmationViewController.swift` | Choose-on-upload quality UI; Preparing → Upload |

## User settings

**Settings → Compression**

| Row | Options |
|-----|---------|
| Upload Media / Media Compression | None / Automatic / Manual (**default: Automatic**) |
| Video Call Quality | WebRTC call camera resolution (unchanged behavior) |

**Include calls in call history** lives in the untitled account section (after phone number integration).

### Media Compression modes

| Mode | Preview | On Send |
|------|---------|---------|
| None | Original | Upload as staged |
| Automatic | Original | Always compress ≥ Moderate; escalate to High if estimate > 16 MB (or > ~8 MB on cellular) |
| Manual | Original + quality control | Compress chosen None / Moderate / High |

### Compression presets

| Level | Images | Videos |
|-------|--------|--------|
| None | Passthrough | Passthrough |
| Moderate | max 1920px, JPEG 80% | `720p` |
| High | max 1280px, JPEG 45% | `low` |

Automatic never skips compression for files under 16 MB (avoids large RAW/HEIC near the cap). WhatsApp-style: standard quality always recompresses; 16 MB is an escalation cap, not a skip threshold.

## Server capability contract (stored, not applied on upload)

The app still parses and stores `spreed.config.attachments.upload-compression`
from capabilities (hash-change refresh unchanged) so the server option remains
available for other clients or future use. **iOS uploads ignore those values**
and use the user Upload Media preference only.

```json
{
  "upload-compression": {
    "enabled": true,
    "images": {
      "enabled": true,
      "max-dimension": 1280,
      "jpeg-quality": 45
    },
    "videos": {
      "enabled": true,
      "preset": "low"
    }
  }
}
```

## Preparing media HUD

On Send (when compression is needed), `ShareConfirmationViewController` shows one
locked **square** annular HUD for both phases:

1. **Preparing…** — determinate progress from video export / per-item compress
   (≈55% of the ring); placeholder details line keeps title Y aligned with phase 2
2. **Uploading** / **N media file(s)** — remaining ring for network upload

Bezel: solid `.systemBackground`, separator border + light shadow so it stays
visible on white previews.

## GIF / pasted PNG

Unchanged (GIF skipped; pasted PNG data path unchanged).

## iOS 18 hardening (build 6+)

- **Staging:** security-scoped access, copy (not move), sync copy before
  `NSItemProvider` completion returns, reject 0-byte staged files. Empty staging
  showed placeholder preview, Manual None=`–`, Moderate/High both `~12.3 KB`.
- **Send lock:** `isUploadingMedia` blocks re-Send while upload is in flight
  (log showed repeated `Media upload Send` during one upload).
- **Provider fallback chain:** `loadFileRepresentation` → `loadItem` URL copy →
  image decode (`UIImage` / `addImageFromItemProvider`). Prefer image
  representation for Photos file-url attachments (iCloud). Logs each step so
  a failed copy never becomes a silent empty preview.
- **Unavailable file UI:** staging failures surface a “Couldn't load file”
  alert (iCloud / offline), then dismiss if nothing remains.
- **Cancel during prepare/upload:** `mediaFlowCancelled` + export cancel token +
  `URLSessionTask.cancel()` — prepare completion must not start PUT after Cancel.
- **Large video hitch:** staging copy always runs on `preparationQueue`
  (`dispatch_sync` so `loadFileRepresentation` still finishes before return).
