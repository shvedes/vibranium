// Shared image-extension table for wallpaper flows.
//
// Static extensions Qt decodes natively (qt6-imageformats plus built-ins).
// Animated formats (gif, mng) are excluded on purpose: Qt caches every
// decoded frame as RGBA, so a small gif costs gigabytes of RAM. webp
// stays whitelisted; an animated webp simply shows its first frame.
// One copy: Wallpaper plus WallpaperPicker share it instead of carrying
// identical 22-entry literals.
//
// Merge point for IMAGE_EXTS: the literal table lives here (the themes
// suite pins its entries from this source), and common/theme/FileIcons.js
// carries the merged file-icon vocabulary (clipboard icons plus this
// table plus the animated flag) for consumers that need more than the
// still gate. The two tables hold the same static set by construction;
// the animated exclusion above is the contract both keep.
.pragma library

var EXTS = ({
  png: 1, jpg: 1, jpeg: 1, jfif: 1, webp: 1, ppm: 1, pgm: 1, pbm: 1,
  pnm: 1, tiff: 1, tif: 1, bmp: 1, svg: 1, svgz: 1, jp2: 1, jpx: 1,
  j2k: 1, jpc: 1, tga: 1, ico: 1, icns: 1, wbmp: 1
})

function ok(name) {
  const s = String(name || "")
  const dot = s.lastIndexOf(".")
  if (dot < 0) return false
  return !!EXTS[s.slice(dot + 1).toLowerCase()]
}
