# App Store screenshot build (`demo-screenshot` branch)

This branch compiles SumbaChat with `DEMO_SCREENSHOTS`:

- **3 s splash hold** — launch image stays visible after startup for screenshot capture
- **Demo chat list** — replaces the active account’s conversation list with neutral Sumba Project rooms (real estate / hospitality / field contractors)
- **Full hero chat** — `Solar & Water Infrastructure` includes solar footing + water well progress, with two staging photos from `test.sumba.travel`
- **Offline demo rooms** — no server join; chat history loads from local Realm seed data

## Usage

1. Build/run SumbaChat from the `demo-screenshot` branch on **iPhone 17 (iOS 26)** simulator (or any device).
2. Log in with any account (demo data is injected for whichever user is active).
3. Capture the splash within the first 3 seconds after launch.
4. Room list shows seven project channels; open **Solar & Water Infrastructure** for the full conversation screenshot.

## Staging images

Room avatars and chat photo previews are downloaded once from `https://test.sumba.travel/` using the staging basic-auth credentials embedded in `DemoScreenshotImageStore.swift`. Images are cached under Application Support.

**Do not merge this branch to `main` or ship it to the App Store** — it replaces real conversations and skips room sync.
