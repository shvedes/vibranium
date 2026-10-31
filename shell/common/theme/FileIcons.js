// Shared file icon vocabulary (qs.common.theme).
//
// Single source for file-extension -> icon basenames: the ClipboardLib
// ICONS table plus every extension set, merged with the ImageExts static
// table. The animated flag marks formats Qt must not cache frame by
// frame (a small gif costs gigabytes of RAM). Pure JS, pragma library,
// no Qt imports.
.pragma library

// Icon basenames under shell/assets/icons (resolved by Icons.url via
// Menu.resolveIcon in the views). Canonical home of ClipboardLib ICONS.
var ICONS = {
  text: "text",
  math: "math",
  calculator: "calculator",
  url: "link",
  archive: "file-archive",
  folder: "file-folder",
  folderGit: "file-folder-git",
  folders: "file-folders",
  file: "file",
  files: "files",
  image: "file-image",
  code: "file-code",
  db: "file-db",
  diff: "file-diff",
  font: "file-font",
  music: "file-music",
  pdf: "file-pdf",
  svg: "file-svg",
  xls: "file-xls",
  secret: "lock",
  network: "file-network"
}

// Static extensions Qt decodes natively (qt6-imageformats plus
// built-ins), lowercased. Mirrors the ImageExts EXTS merge-point table
// entry for entry (animated formats excluded in both - see ImageExts):
// FileIcons carries the merged vocabulary for icon consumers, ImageExts
// keeps the literal table the still gate and the themes suite pin.
var IMAGE_EXTS = {
  png: 1, jpg: 1, jpeg: 1, jfif: 1, webp: 1, ppm: 1, pgm: 1, pbm: 1,
  pnm: 1, tiff: 1, tif: 1, bmp: 1, svg: 1, svgz: 1, jp2: 1, jpx: 1,
  j2k: 1, jpc: 1, tga: 1, ico: 1, icns: 1, wbmp: 1
}

// Extension sets that steer preview rendering and row icons.
// Canonical home of the ClipboardLib extension tables.
var ARCHIVE_EXTS = {
  zip: 1, tar: 1, gz: 1, tgz: 1, bz2: 1,
  xz: 1, "7z": 1, rar: 1, zst: 1, lz: 1, lzma: 1
}

var VIDEO_EXTS = {
  mp4: 1, mkv: 1, webm: 1, mov: 1, avi: 1, m4v: 1
}

var PDF_EXTS = { pdf: 1 }
var SHEET_EXTS = { xls: 1, xlsx: 1, ods: 1, csv: 1, tsv: 1 }
var DB_EXTS = {
  db: 1, sqlite: 1, sqlite3: 1, sql: 1, mdb: 1, accdb: 1
}
var DIFF_EXTS = { diff: 1, patch: 1, rej: 1 }
var FONT_EXTS = {
  ttf: 1, otf: 1, woff: 1, woff2: 1, eot: 1, fon: 1, pfb: 1
}
var MUSIC_EXTS = {
  mp3: 1, flac: 1, ogg: 1, oga: 1, opus: 1, wav: 1,
  m4a: 1, aac: 1, wma: 1, mid: 1, midi: 1, it: 1, xm: 1
}
var CODE_EXTS = {
  rs: 1, ts: 1, tsx: 1, js: 1, jsx: 1, mjs: 1, cjs: 1,
  py: 1, c: 1, h: 1, cc: 1, cpp: 1, hh: 1, hpp: 1,
  go: 1, rb: 1, java: 1, kt: 1, kts: 1, swift: 1,
  lua: 1, sh: 1, bash: 1, zsh: 1, fish: 1, nu: 1,
  vim: 1, el: 1, nix: 1, pl: 1, pm: 1, php: 1, cs: 1,
  dart: 1, zig: 1, hs: 1, ml: 1,
  clj: 1, ex: 1, exs: 1, erl: 1, gleam: 1, rkt: 1,
  vue: 1, svelte: 1, astro: 1,
  html: 1, htm: 1, css: 1, scss: 1, sass: 1, less: 1,
  styl: 1, xml: 1, json: 1, jsonc: 1, json5: 1, toml: 1,
  yaml: 1, yml: 1, ini: 1, cfg: 1, conf: 1,
  service: 1, timer: 1, socket: 1, desktop: 1,
  properties: 1, env: 1, gradle: 1, cmake: 1, mk: 1,
  makefile: 1, dockerfile: 1, justfile: 1,
  editorconfig: 1, proto: 1, graphql: 1, gql: 1,
  prisma: 1, tf: 1, tfvars: 1, hcl: 1, md: 1, markdown: 1,
  rst: 1, adoc: 1, org: 1, tex: 1, bib: 1
}

// Extension -> MIME value for image previews and snapshots. Anything
// unknown falls back to image/png. Canonical home of the ClipboardLib
// IMAGE_MIMES table.
var IMAGE_MIMES = {
  png: "image/png", jpg: "image/jpeg", jpeg: "image/jpeg",
  webp: "image/webp", gif: "image/gif", bmp: "image/bmp",
  tiff: "image/tiff", tif: "image/tiff", svg: "image/svg+xml",
  avif: "image/avif", heic: "image/heic", heif: "image/heif"
}

// Animated stills Qt must not frame-cache: gif and mng decode to every
// frame in RAM. webp is NOT listed: an animated webp shows its first
// frame through the static path.
function isAnimatedExt(ext) {
  var e = String(ext || "").toLowerCase()
  return e === "gif" || e === "mng"
}

// Lowercased extension of a path, or "" when there is none. Full-path
// form (the ImageExts contract, pinned by the text suite): a leading
// dot still names an extension (".png" -> "png").
function extOf(path) {
  var s = String(path || "")
  var dot = s.lastIndexOf(".")
  if (dot < 0) return ""
  return s.slice(dot + 1).toLowerCase()
}

// Icon basename for a concrete filesystem path. Falls back to "" so
// callers decide their own generic. Canonical home of ClipboardLib
// extIconName, whose stricter contract applies here (pinned by the
// clipboard suite): the basename only, and a leading dot is not an
// extension (".ts" -> ""), so a dot in a directory never leaks either.
function extIconName(path) {
  var base = String(path || "").split("/").pop() || ""
  var dot = base.lastIndexOf(".")
  if (dot <= 0) return ""
  var e = base.slice(dot + 1).toLowerCase()
  if (e === "") return ""
  if (e === "svg") return ICONS.svg
  if (IMAGE_EXTS[e] === 1 || e === "gif" || e === "avif" || e === "heic" || e === "heif") return ICONS.image
  if (ARCHIVE_EXTS[e] === 1) return ICONS.archive
  if (PDF_EXTS[e] === 1) return ICONS.pdf
  if (SHEET_EXTS[e] === 1) return ICONS.xls
  if (DB_EXTS[e] === 1) return ICONS.db
  if (DIFF_EXTS[e] === 1) return ICONS.diff
  if (FONT_EXTS[e] === 1) return ICONS.font
  if (MUSIC_EXTS[e] === 1) return ICONS.music
  if (VIDEO_EXTS[e] === 1) return ICONS.file
  if (CODE_EXTS[e] === 1) return ICONS.code
  return ""
}

// Static-image gate: a name Qt decodes natively through the still path.
function ok(name) {
  return !!IMAGE_EXTS[extOf(name)]
}

// MIME value for an image path, image/png for anything unknown.
function mimeForExt(path) {
  var m = IMAGE_MIMES[extOf(path)]
  return m !== undefined ? m : "image/png"
}

if (typeof module !== "undefined") {
  module.exports = {
    ICONS: ICONS,
    IMAGE_EXTS: IMAGE_EXTS,
    ARCHIVE_EXTS: ARCHIVE_EXTS,
    VIDEO_EXTS: VIDEO_EXTS,
    PDF_EXTS: PDF_EXTS,
    SHEET_EXTS: SHEET_EXTS,
    DB_EXTS: DB_EXTS,
    DIFF_EXTS: DIFF_EXTS,
    FONT_EXTS: FONT_EXTS,
    MUSIC_EXTS: MUSIC_EXTS,
    CODE_EXTS: CODE_EXTS,
    IMAGE_MIMES: IMAGE_MIMES,
    isAnimatedExt: isAnimatedExt,
    extOf: extOf,
    extIconName: extIconName,
    ok: ok,
    mimeForExt: mimeForExt
  }
}
