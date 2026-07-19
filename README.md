<!--
  - SPDX-FileCopyrightText: 2017 Nextcloud GmbH and Nextcloud contributors
  - SPDX-FileCopyrightText: 2026 Ivan Cursoroff and Peter Zakharov
  - SPDX-License-Identifier: GPL-3.0-or-later
-->
<p align="center">
  <img src="docs/App%20icons/sumbachat-icon-readme.png" alt="SumbaChat" width="128" height="128">
</p>

# SumbaChat

**Chat, voice, and video for your own Nextcloud — iOS client**

SumbaChat is an iOS messaging app based on [Nextcloud Talk](https://github.com/nextcloud/talk-ios). It keeps Talk’s on‑premises calls and chat, with SumbaChat branding and extras such as media upload compression and caching controls.

This repository is **SumbaChat**, not the upstream Nextcloud Talk project. Upstream Talk lives at [nextcloud/talk-ios](https://github.com/nextcloud/talk-ios).

## Prerequisites

- [Nextcloud server](https://github.com/nextcloud/server) version 22 or higher (ATS-compatible HTTPS).
- [Nextcloud Talk](https://github.com/nextcloud/spreed) (spreed) version 12.0 or higher.
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

   Edit `NCAppBrandingLocal.h` with your cloud and push-proxy URLs. That file is **gitignored** — never commit real hostnames.

4. Bundle id / App Group are already set for SumbaChat (`com.spl.SumbaChat` / `group.com.spl.SumbaChat`). Use a team that can sign those identifiers, or change them in the Xcode targets and in `NCAppBranding.m` together.

Pull requests should stay SwiftLint-clean.

## Features beyond upstream Talk

- SumbaChat branding and UI chrome (icon, splash, chat bar, share sheet)
- Native username/password login for a locked domain (no Nextcloud web login flow)
- Photo/video upload compression (None / Automatic / Manual) with in-app and Share Extension UX
- App Group media cache (upload / download / convert) and Settings → Caching
- Server-driven App Store update prompts via Talk capabilities (`config.sumbachat-client`: `minIosBuild` / `latestIosBuild` / `app`)
- Chat keyboard & scroll: keep the latest messages above the composer
- Calls: request mic/camera before join; refresh local media if permission is granted mid-call
- Dedicated push proxies (via `NCAppBrandingLocal.h`) and system-announcement notification chrome
- Media viewer: start muted with an on-screen mute control
- SumbaFiles chooser: type filter (All / Video / Audio / Documents), search by name, middle-truncated filenames, and size · relative date in each row

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

Copyright for SumbaChat modifications: © 2026 Ivan Cursoroff and Peter Zakharov.  
Copyright for original Talk code: Nextcloud GmbH and Nextcloud contributors.
