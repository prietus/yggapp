# App icon

Source SVGs for `App/Assets.xcassets/AppIcon.appiconset`: a tree whose branches end in
connected nodes (Yggdrasil as both world tree and mesh), on a lavender gradient.

- `AppIcon.svg`: default (light)
- `AppIcon-dark.svg`: iOS dark appearance
- `AppIcon-tinted.svg`: iOS tinted appearance (white glyph on black; iOS tints by luminance)

Regenerate the PNGs (opaque, 1024×1024) after editing:

```sh
for f in AppIcon AppIcon-dark AppIcon-tinted; do
  rsvg-convert -w 1024 -h 1024 design/icon/$f.svg | magick - -background black -alpha remove -alpha off PNG24:App/Assets.xcassets/AppIcon.appiconset/$f.png
done
```
