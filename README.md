<!--
  - SPDX-FileCopyrightText: 2017 Nextcloud GmbH and Nextcloud contributors
  - SPDX-FileCopyrightText: 2026 Peter Zakharov
  - SPDX-License-Identifier: GPL-3.0-or-later
-->
<p align="center">
  <img src="docs/App%20icons/sumbachat-icon-readme.png" alt="SumbaChat" width="128" height="128">
</p>

# SumbaChat

**Chat, voice, and video for your own Nextcloud — iOS client**

SumbaChat is an iOS messaging app based on [Nextcloud Talk](https://github.com/nextcloud/talk-ios). It keeps Talk’s on‑premises calls and chat, with SumbaChat branding and extras such as in-chat media galleries, multi-photo albums, upload compression, SumbaFiles browsing, and account management.

This repository is **SumbaChat**, not the upstream Nextcloud Talk project. Upstream Talk lives at [nextcloud/talk-ios](https://github.com/nextcloud/talk-ios).

## Prerequisites

- [Nextcloud server](https://github.com/nextcloud/server) version 22 or higher (ATS-compatible HTTPS).
- [Nextcloud Talk](https://github.com/nextcloud/spreed) (spreed) version 12.0 or higher.
- For in-app account deletion: Talk Upload Policy retire enabled on the server (`spreed.config.sumbachat-client.accountRetire.enabled`).
- [CocoaPods](https://cocoapods.org/)
- Xcode with a valid Apple Developer team

## Development setup

1. Clone this repository and run `pod install`.
2. Open `SumbaChat.xcworkspace` in Xcode. App sources live under `SumbaChat/` (many upstream filenames like `NextcloudTalk-Bridging-Header.h` are kept for tracking).
3. Copy local deployment hosts (from the repo root):

   ```bash
   cp SumbaChat/Settings/NCAppBrandingLocal.example.h \
      SumbaChat/Settings/NCAppBrandingLocal.h
   ```

   Edit `NCAppBrandingLocal.h` with your cloud URL, push proxies, base domain, default subdomain, support email, and privacy `uid` XOR key. That file is **gitignored** — never commit real hostnames or keys. Without it, the app falls back to `example.com` placeholders.

4. Bundle id / App Group are already set for SumbaChat (`com.spl.SumbaChat` / `group.com.spl.SumbaChat`). Use a team that can sign those identifiers, or change them in the Xcode targets and in `NCAppBranding.m` together.

Pull requests should stay SwiftLint-clean.

## Features beyond upstream Talk

### Login & account

- Native username/password login for a branded domain (subdomain field + fixed parent domain; no Nextcloud web login flow)
- Switch server from the profile, with live `status.php` probes (online / maintenance / offline)
- Forgot password flow
- Contact us (mailto to the configured support address)
- Delete account from Account screen when `sumbachat-client.accountRetire.enabled` (password → countdown → `DELETE talk_upload_policy/api/v1/account` → local logout). Profile removed; shared project content stays archived under “Former Team Member” (see Privacy Policy)
- Privacy policy URL comes from gitignored `NCAppBrandingLocal.h` (`privacyURL`); opens with `?uid=` set to a hex XOR of the Nextcloud user id
- Source code link to the SumbaChat GitHub repository
- Online presence restore for branded clients (including first login when no user-status row exists yet)

### Media & gallery

- **Media albums in chat:** send a multi-photo/video selection as one message — mosaic preview in the bubble, optional caption, gallery icon on the room list
- **In-chat media gallery:** tap any photo, video, or album tile to open a full-screen viewer; swipe (or edge-tap) through every image and video in the room in chat order, including all members of an album
- Gallery chrome shows sender, time, and position (`3 of 12`); tap the centre to hide chrome; footer actions: Share, Show in chat, and Mute (videos)
- Album push notifications: only the last member notifies; body uses a single caption such as `Hey (N media files)`
- Photo/video upload compression (None / Automatic / Manual) with in-app and Share Extension UX
- Writer-based video encode (default): keeps audio, per-profile AAC, retains GPS/capture date when possible; Automatic ladder picks a profile
- App Group media cache (upload / download / convert) and Settings → Caching
- In-chat cache hit/miss indicator on file messages (local / warm cache / needs download)
- Video playback starts with sound; mute from the gallery footer
- Quick Look / SumbaFiles: middle-truncated long filenames

### SumbaFiles & chat UX

- SumbaFiles chooser: type filter (All / Video / Audio / Documents), search by name, size · relative date in each row
- Chat keyboard & scroll: keep the latest messages above the composer
- Calls: request mic/camera before join; refresh local media if permission is granted mid-call
- Connection toasts: “Network available” only after a real disconnect (not on cold launch)

### Branding & ops

- SumbaChat branding and UI chrome (icon, splash, chat bar, share sheet)
- Dedicated push proxies and system-announcement notification chrome (via `NCAppBrandingLocal.h`)
- Server-driven App Store update prompts via Talk capabilities (`config.sumbachat-client`: `minIosBuild` / `latestIosBuild` / `app`)
- Diagnostics and in-app logfile viewer (Settings)
- Rate-limit friendly copy on login / forgot-password / delete-account (HTTP 429)

See also [docs/notifications.md](docs/notifications.md) and [docs/local-modifications/media-upload-compression.md](docs/local-modifications/media-upload-compression.md).

## WebRTC

WebRTC builds come from [nextcloud-releases/talk-clients-webrtc](https://github.com/nextcloud-releases/talk-clients-webrtc) (same as upstream Talk).

## Running tests locally

Integration tests expect a Nextcloud + Talk instance. Upstream provides `start-instance-for-tests.sh` to bring up Docker for that purpose. Then:

```bash
xcodebuild test -workspace SumbaChat.xcworkspace \
    -scheme "SumbaChat" \
    -destination "platform=iOS Simulator,name=iPhone 16,OS=18.5" \
    -test-iterations 3 \
    -retry-tests-on-failure
```

## Push notifications

If pushes fail, see [docs/notifications.md](docs/notifications.md). Proxy URLs belong only in `NCAppBrandingLocal.h`.

## Credits

### Upstream

SumbaChat is derived from [Nextcloud Talk for iOS](https://github.com/nextcloud/talk-ios) by Nextcloud GmbH and contributors.

### Ringtones

- [Telefon-Freiton in Deutschland nach DTAG 1 TR 110-1, Kap. 8.3](https://commons.wikimedia.org/wiki/File:1TR110-1_Kap8.3_Freiton1.ogg)
  author: arvedkrynil

## License

[GPLv3](LICENSE) with [Apple App Store exception](COPYING.iOS), same as upstream Talk.

Copyright for SumbaChat modifications: © 2026 Peter Zakharov.  
Copyright for original Talk code: Nextcloud GmbH and Nextcloud contributors.
