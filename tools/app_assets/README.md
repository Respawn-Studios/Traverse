# App icon source

`generate.swift` is the editable source for the bundled app icon. It draws the
folder, compass, gradients and shadows with Core Graphics; it does not load a
third-party image, downloaded font or model asset. The original project license
applies to this artwork and generator.

`App/MacExplorer/Resources/AppIcon.icns` contains the selected A variant at the
standard small and Retina sizes. `manifest.json` binds that resource to its
generator hash, representation list and original render. Its provisional and
name-selection fields describe that historical render; they are not a current
product-name selector or permission to replace the icon.

For a read-only integrity check:

```sh
python3 -B tools/app_assets/check.py
```

Render experiments only into a fresh owned `assets` directory under `.build/`,
with compiler caches explicitly kept there. The generator refuses existing
output files. Review a visual change before adopting it; the historical
`--publish-case` route never replaces an existing resource and is not an ordinary
asset-update command. Do not modify its old render records to make a new icon
appear qualified.

The contributor source selection includes this generator, manifest and icon.
Compiled `.icns` bytes alone would omit the preferred editable artwork source.
