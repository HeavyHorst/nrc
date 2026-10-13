# nrc mark

`logo.svg` is the editable vector master of the selected folded mark. It has an
explicit black fill, no background, and no fonts or external resources.
Use black on light surfaces and white on dark surfaces. Preserve its proportions
and the open diagonal gap; do not stretch, rotate, or add effects.

`logo.png` is the transparent black raster export. `logo_full.jpg` is the same
mark on white. Browser and installed-app icons use a white mark on a dark tile
with platform-safe padding. These assets contain no tagline or expanded name.

Regenerate all raster assets with **ImageMagick 7 with SVG support**:

```sh
bash logo/generate.sh
```

The script updates the PNG/ICO assets in this directory and `client/`. When
changing shipped icons, bump `CACHE_NAME` in `client/service-worker.js` and the
favicon/touch-icon URL versions in `client/index.html`. Keep
`originalFaviconHref` in `client/app.js` aligned with the HTML favicon URL.

This is a custom vector reconstruction of the selected Painter concept, not an
automatic trace. No trademark clearance is implied.
