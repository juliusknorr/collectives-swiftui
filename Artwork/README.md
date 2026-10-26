# App icon

The editable artwork is `render-icon.swift`. It draws a stack of pages on a blue gradient using Core Graphics, without external assets or fonts. iOS uses an opaque square; Mac uses an inset rounded tile with transparent margins.

Regenerate from the repository root:

```sh
mkdir -p .build
swift Artwork/render-icon.swift "$PWD"
python3 Artwork/package-icon.py
```

Commit the generated asset catalog and `Resources/AppIcon.icns` alongside artwork changes. Xcode compiles the catalog for iOS and Mac; `make build` copies the ICNS into the local Mac bundle. Icon changes are included in the bundle's incremental build fingerprint.
