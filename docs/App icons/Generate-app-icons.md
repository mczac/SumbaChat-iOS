# Generate SumbaChat app icons

Source icon: `sumbachat-icon-source.png` (or any square PNG, ideally 1024×1024 or larger).

## App Store / iOS asset catalog

Modern Xcode only needs one 1024×1024 PNG in the asset catalog:

```bash
sips -z 1024 1024 sumbachat-icon-source.png \
  --out ../NextcloudTalk/Images.xcassets/AppIcon.appiconset/talk-icon1024@1x.png
```

`AppIcon.appiconset/Contents.json` already references `talk-icon1024@1x.png`.

## iOS 26 Icon Composer (liquid glass)

Copy the same source into the icon composer bundle:

```bash
cp sumbachat-icon-source.png ../NextcloudTalk/AppIcon.icon/Assets/SumbaChat-icon.png
```

`AppIcon.icon/icon.json` references `SumbaChat-icon.png`.

## Optional legacy size exports

```bash
for size in 20 29 40 58 60 76 80 87 120 152 167 180 1024; do
  sips -z $size $size sumbachat-icon-source.png --out generated/sumbachat-icon-${size}.png
done
```

These are kept under `generated/` for reference; the Xcode project does not require them when using a single 1024×1024 app icon set entry.
