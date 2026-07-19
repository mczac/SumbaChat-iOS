# SumbaChat — next features

Backlog of planned work (not scheduled). Oldest / clearest first.

## Media

- **Save chat image to Photos with GPS/EXIF** — Chat send/receive/download already keep location (ImageIO). System Share → Save Image often strips EXIF via `UIImage`. Add an in-app Save that writes file bytes with `PHAssetCreationRequest` (we don’t own Apple’s Save Image path).
