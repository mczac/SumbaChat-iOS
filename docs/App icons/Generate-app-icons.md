# Generate SumbaChat app icons

Source icon: `sumbachat-icon-source.png` (square PNG).

**Important:** iOS app icons must be **full-bleed** — no white/transparent corners and no
pre-applied rounded-rect mask. iOS applies the mask itself. A masked source with white
corners makes Xcode report the icon as missing / “not registered”.

If the source has baked rounded corners, generate a full-bleed copy first:

```bash
python3 - <<'PY'
from PIL import Image
im = Image.open('sumbachat-icon-source.png').convert('RGB')
px = im.load()
brand = (0, 126, 251)
w, h = im.size
for y in range(h):
    for x in range(w):
        r, g, b = px[x, y]
        if r > 230 and g > 230 and b > 230:
            px[x, y] = brand
im.save('sumbachat-icon-fullbleed.png')
PY
```

## App Store / iOS asset catalog (active)

`ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` points at
`Images.xcassets/AppIcon.appiconset`. Modern Xcode only needs one 1024×1024 PNG:

```bash
sips -z 1024 1024 sumbachat-icon-fullbleed.png \
  --out ../SumbaChat/Images.xcassets/AppIcon.appiconset/talk-icon1024@1x.png
```

## Icon Composer (optional, not the active AppIcon)

Kept as `SumbaChat/SumbaChatIcon.icon` for future liquid-glass work. It is **not**
named `AppIcon` and is **not** in any target’s Copy Bundle Resources, so it cannot
conflict with `AppIcon.appiconset`.

```bash
cp sumbachat-icon-fullbleed.png ../SumbaChat/SumbaChatIcon.icon/Assets/SumbaChat-icon.png
```

## Splash / launch screen

Source: `sumbachat-splash-source.png` (portrait, ~853×1844).

```bash
sips -z 922 427 sumbachat-splash-source.png \
  --out ../SumbaChat/Images.xcassets/launchscreen.imageset/launchscreen.png
cp sumbachat-splash-source.png \
  ../SumbaChat/Images.xcassets/launchscreen.imageset/launchscreen@2x.png
sips -z 2766 1280 sumbachat-splash-source.png \
  --out ../SumbaChat/Images.xcassets/launchscreen.imageset/launchscreen@3x.png
```

After changing launch assets, delete the app from the device and do a clean build —
iOS caches launch screens aggressively.

## Optional legacy size exports

```bash
for size in 20 29 40 58 60 76 80 87 120 152 167 180 1024; do
  sips -z $size $size sumbachat-icon-fullbleed.png --out generated/sumbachat-icon-${size}.png
done
```
