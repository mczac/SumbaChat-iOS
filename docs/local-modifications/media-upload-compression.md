# Local modification: media upload compression

Branch: `feature/media-upload-compression`

## What changed

Photos and videos are compressed before upload staging in `ShareItemController`.

| File | Change |
|------|--------|
| `NextcloudTalk/Settings/MediaUploadPreprocessor.swift` | **New** — image resize/JPEG + video export helper |
| `ShareExtension/ShareItemController.m` | Compress images/videos when items are staged |
| `NextcloudTalk.xcodeproj/project.pbxproj` | Include preprocessor in ShareExtension target |

## Behavior

- **Photos** (except GIF): server-configurable maximum dimension and JPEG quality
- **Videos**: server-configurable export preset → `.mp4`
- **Defaults without server settings**: images 1280px / JPEG quality 45; videos `low`
- **GIF / pasted PNG**: unchanged
- **Video compression failure or larger output**: falls back to original file

## Server capability contract

The app reads an effective compression policy from the authenticated OCS
capabilities response:

`GET /ocs/v1.php/cloud/capabilities?format=json`

Add this object under
`ocs.data.capabilities.spreed.config.attachments`:

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

### Parameters

| Parameter | Type | Accepted values | App fallback |
|-----------|------|-----------------|--------------|
| `enabled` | boolean | `true`, `false` | `true` |
| `images.enabled` | boolean | `true`, `false` | `true` |
| `images.max-dimension` | integer pixels | `320...8192` | `1280` |
| `images.jpeg-quality` | integer percent | `10...100` | `45` |
| `videos.enabled` | boolean | `true`, `false` | `true` |
| `videos.preset` | string | `low`, `medium`, `high`, `480p`, `720p`, `1080p`, `2160p` | `low` |

Invalid or missing numeric and preset values use the app fallback. JSON values
must use their documented types; numeric strings are not accepted.

The response is already authenticated, so the server may return values merged
from a server-wide admin policy and a per-user override. The iOS app stores the
effective values per account and does not need to know where the server stored
them.

### Recommended server storage

Store server-wide values in Nextcloud app config (`oc_appconfig`) under a
custom app such as `talk_upload_policy`, and expose them through an
`OCP\Capabilities\ICapability` provider. Nextcloud deep-merges capability
providers, allowing the custom app to append this object to
`spreed.config.attachments` without replacing Talk's existing attachment keys.

Suggested app-config keys:

- `enabled`
- `image_enabled`
- `image_max_dimension`
- `image_jpeg_quality`
- `video_enabled`
- `video_preset`

If an admin changes the policy, clients need a fresh capabilities response.
Either include these settings in Talk's capabilities hash calculation or
trigger/refetch capabilities in another reliable way.

Changing the persisted capability model raised the shared Realm schema version
to 91. Run the main app once after installing the build before invoking the
share extension so the main app can migrate the shared Realm.

## Branded login

SumbaChat locks login to `https://cloud.example.com` via `forceDomain` in
`NCAppBranding.m`. The server-address screen is skipped and authentication
opens directly. Nextcloud's "Grant access" step remains required to create a
per-device app password and cannot be removed client-side.

## Preparing media HUD

While photos/videos are compressed before upload, `ShareConfirmationViewController`
shows an indeterminate "Preparing…" HUD and disables Send until preparation
finishes.

## Revert this feature only

```bash
cd /Users/peterzakharov/Developer/NextCloutTalk
git checkout main -- ShareExtension/ShareItemController.m
git rm NextcloudTalk/Settings/MediaUploadPreprocessor.swift
git checkout main -- NextcloudTalk.xcodeproj/project.pbxproj
```

Or discard the whole branch:

```bash
git checkout main
git branch -D feature/media-upload-compression
```

## Revert everything on this branch

```bash
git checkout main
git branch -D feature/media-upload-compression
```

(ADC signing changes from the initial setup are still uncommitted local edits on this branch.)
