// Pure-JS clipboard helpers: type detection, icons, formatting, search.
// No Qt imports - unit-drivable, fast, allocation-aware. Every derived
// display string lives here so the service stays a thin state machine
// and the unit suite can pin the exact user-facing copy.
.pragma library

.import "../launcher/CalcLib.js" as Calc
.import "../../common/math/FuncLib.js" as Func
.import "../../common/text/SearchLib.js" as SL
.import "../../common/text/Format.js" as Format
.import "../../common/text/Clock.js" as ClockFmt
.import "../../common/text/Duration.js" as DurationFmt
.import "../../common/text/StringUtils.js" as SU
.import "../../common/theme/FileIcons.js" as FileIcons

// Icon basenames under shell/assets/icons, canonicalized in
// common/theme/FileIcons.js so clipboard rows and file views share one
// table. Kept under this name so the builders below read unchanged.
const ICONS = {
  text: "text",
  math: "math",
  calculator: "calculator",
  url: "link",
  archive: "file-archive",
  folder: "file-folder",
  foldergit: "file-folder-git",
  folders: "file-folders",
  file: "file",
  files: "files",
  image: "file-image",
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

const ARCHIVE_EXTS = {
  zip: true, tar: true, gz: true, tgz: true, bz2: true,
  xz: true, "7z": true, rar: true, zst: true, lz: true, lzma: true
}

const IMAGE_EXTS = {
  png: true, jpg: true, jpeg: true, webp: true, gif: true,
  bmp: true, tiff: true, tif: true, svg: true, avif: true,
  heic: true, heif: true
}

// Extension -> MIME value for image previews and snapshots. Anything unknown
// falls back to image/png.
const IMAGE_MIMES = Object.assign(Object.create(null), {
  png: "image/png", jpg: "image/jpeg", jpeg: "image/jpeg",
  webp: "image/webp", gif: "image/gif", bmp: "image/bmp",
  tiff: "image/tiff", tif: "image/tiff", svg: "image/svg+xml",
  avif: "image/avif", heic: "image/heic", heif: "image/heif"
})

// Extension sets that steer preview rendering and row icons.
const VIDEO_EXTS = {
  mp4: true, mkv: true, webm: true, mov: true, avi: true, m4v: true
}

const PDF_EXTS = { pdf: true }
const SHEET_EXTS = { xls: true, xlsx: true, ods: true, csv: true, tsv: true }
const DB_EXTS = {
  db: true, sqlite: true, sqlite3: true, sql: true, mdb: true, accdb: true
}

const FONT_EXTS = {
  ttf: true, otf: true, woff: true, woff2: true, eot: true, fon: true, pfb: true
}
const MUSIC_EXTS = {
  mp3: true, flac: true, ogg: true, oga: true, opus: true, wav: true,
  m4a: true, aac: true, wma: true, mid: true, midi: true, it: true, xm: true
}
const CODE_EXTS = {
  rs: true, ts: true, tsx: true, js: true, jsx: true, mjs: true, cjs: true,
  py: true, c: true, h: true, cc: true, cpp: true, hh: true, hpp: true,
  go: true, rb: true, java: true, kt: true, kts: true, swift: true,
  lua: true, sh: true, bash: true, zsh: true, fish: true, nu: true,
  vim: true, el: true, nix: true, pl: true, pm: true, php: true, cs: true,
  dart: true, zig: true, hs: true, ml: true,
  clj: true, ex: true, exs: true, erl: true, gleam: true, rkt: true,
  vue: true, svelte: true, astro: true,
  html: true, htm: true, css: true, scss: true, sass: true, less: true,
  styl: true, xml: true, json: true, jsonc: true, json5: true, toml: true,
  yaml: true, yml: true, ini: true, cfg: true, conf: true,
  service: true, timer: true, socket: true, desktop: true,
  properties: true, env: true, gradle: true, cmake: true, mk: true,
  makefile: true, dockerfile: true, justfile: true,
  editorconfig: true, proto: true, graphql: true, gql: true,
  prisma: true, tf: true, tfvars: true, hcl: true, md: true, markdown: true,
  rst: true, adoc: true, org: true, tex: true, bib: true
}

// Regexes hoisted to module scope. QML's JS engine allocates a fresh
// RegExp object for every literal evaluated at runtime - a literal sitting
// inside a function body gets re-allocated on every single call. None of
// these are used with exec/test under the g flag across repeated calls
// (the one case where sharing an instance is unsafe due to lastIndex
// state), so one instance per pattern is behavior-identical.
const RE_ANY_WS = /\s/
const RE_WS_SPLIT = /\s+/
const RE_WS_COLLAPSE = /\s+/g
const RE_HTTP_WWW = /^(https?:\/\/|www\.)/i
const RE_SCHEME_STRIP = /^[a-z0-9+.-]+:\/\//i
// Scheme (+ optional host) matcher shared by isNetworkUri (scheme only)
// and buildSubLeft (scheme+host, for "PROTO - host" subtext). Host group
// is "*" not "+": a bare "proto://" with nothing after it still counts as
// network in isNetworkUri, and buildSubLeft now falls back to
// "PROTO location" instead of "Network storage" for that same edge case.
const RE_URI_SCHEME_HOST = /^([a-z0-9+.-]+):\/\/([^\/?#]*)/i
// Bare number: optional sign, digits with optional fraction, optional
// exponent ("42", "-3.14", "+.5", "1e6"). The launcher's calculator
// deliberately rejects lone numbers so they never hide apps - here they
// are exactly what gets the math icon, so they need their own check.
const RE_NUMBER_TEXT = /^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$/

// Icon basename for a concrete filesystem path, canonicalized in
// common/theme/FileIcons.js. Falls back to "" so callers decide their
// own generic.
function extIconName(path) {
  return FileIcons.extIconName(path)
}

function isVideo(path) {
  return extIn(path, VIDEO_EXTS)
}

const NETWORK_SCHEMES = {
  ftp: true, ftps: true, sftp: true, smb: true, cifs: true,
  nfs: true, ssh: true, scp: true, rsync: true, webdav: true,
  dav: true, davs: true, afp: true, s3: true, nmb: true
}

// Scheme -> display label for the subtext ("SMB • server"). Unknown
// schemes fall back to the uppercased scheme itself.
const NETWORK_PROTO_LABELS = {
  ftp: "FTP", ftps: "FTPS", sftp: "SFTP", smb: "SMB", cifs: "CIFS",
  nfs: "NFS", ssh: "SSH", scp: "SCP", rsync: "RSYNC", webdav: "WebDAV",
  dav: "WebDAV", davs: "WebDAVS", afp: "AFP", s3: "S3", nmb: "NMB"
}

function isNetworkUri(s) {
  const t = String(s).trim()
  const m = t.match(RE_URI_SCHEME_HOST)
  if (!m) return false
  return NETWORK_SCHEMES[m[1].toLowerCase()] === true
}

// "number" for a bare number ("42", "-3.14"), "expr" for a valid
// arithmetic expression under the launcher calculator's own definition
// ("2+2", "(1+2)*3"), "func" for a single correct function-of-x
// ("x^2", "y = sin(x)" - the static preview graph's gate), "" otherwise.
// Single-line only: multi-line pastes stay text, and over-long input is
// rejected before the evaluators ever see it. A lone variable ("x") is
// valid math but not a curve worth a viewport - it stays text.
function mathTextKind(s) {
  const t = String(s || "").trim()
  if (t === "" || t.length > 256) return ""
  if (t.indexOf("\n") >= 0 || t.indexOf("\r") >= 0) return ""
  if (RE_NUMBER_TEXT.test(t)) return "number"
  try {
    if (Calc.tryEvaluate(t) !== null) return "expr"
  } catch (e) {}
  try {
    const fr = Func.tryParseFunction(t)
    return (fr !== null && !Func.isBareVariable(fr.body)) ? "func" : ""
  } catch (e) {
    return ""
  }
}

// Plottable body for a text snippet, or "" when it is not a single
// correct function. The preview pane binds its static graph to this -
// same curve the launcher draws live.
function funcBodyFor(s) {
  try {
    const r = Func.tryParseFunction(String(s || ""))
    if (!r || Func.isBareVariable(r.body)) return ""
    return String(r.body)
  } catch (e) {
    return ""
  }
}

// A plain-text snippet that is really an absolute (or ~) path pointing
// at an image file. Promoted to a live image entry by the service.
// Rejects whitespace/newlines and everything without an image extension;
// `home` is injected so "~" forms resolve without touching the fs.
function textImagePath(text, home) {
  const t = String(text || "").trim()
  if (t.length < 6 || t.length > 4096) return ""
  if (RE_ANY_WS.test(t)) return ""
  if (!isImageExt(t)) return ""
  let p = t
  if (p.indexOf("file://") === 0) {
    const parsed = parseUriList(p)
    if (parsed.length !== 1) return ""
    p = parsed[0]
  }
  if (!isImageExt(p)) return ""
  if (p.indexOf("~/") === 0) {
    if (!home || home === "") return ""
    p = home + p.substring(1)
  }
  if (p.charAt(0) !== "/") return ""
  return p
}


// $HOME is injected by the service at boot so titles read ~/x/y instead
// of /home/u/x/y. Pure-lib (and therefore unit-test friendly).
let HOME = ""
function setHome(h) { HOME = String(h || "") }

function isUrl(s) {
  const t = String(s).trim()
  if (t.length < 4) return false
  // ftp is in NETWORK_SCHEMES, so isNetworkUri already ate every ftp://
  // string above - no ftp:// branch needed in the regex below.
  if (isNetworkUri(t)) return false
  return RE_HTTP_WWW.test(t) && t.indexOf(" ") < 0
}

function extOf(path) {
  const base = String(path).split("/").pop() || ""
  const dot = base.lastIndexOf(".")
  if (dot <= 0) return ""
  return base.substring(dot + 1).toLowerCase()
}

// Shared membership check - every isX(path) below is extOf(path) tested
// against one of the *_EXTS tables. One helper instead of N copies.
function extIn(path, extSet) {
  return extSet[extOf(path)] === true
}

function isArchive(path) {
  return extIn(path, ARCHIVE_EXTS)
}

function isImageExt(path) {
  return extIn(path, IMAGE_EXTS)
}

function isImageMime(mime) {
  return String(mime).toLowerCase().indexOf("image/") === 0
}

function mimeForExt(path) {
  const m = IMAGE_MIMES[extOf(path)]
  return m !== undefined ? m : "image/png"
}

// Copy time, canonicalized in common/text/Clock.js. Follows the shell's
// TimeFormat config (12/24-hour) instead of the OS locale. Same calendar
// day -> clock time, otherwise the day rides along. `use12h` is optional
// (defaults to 24-hour) so callers without a config still render.
// `now` is injectable so tests stay deterministic.
function formatTime(ts, now, use12h) {
  return ClockFmt.formatTime(ts, now, use12h === true)
}

// Two-digit zero padding, canonicalized in common/text/Format.js.
function pad2(n) {
  return Format.pad2(n)
}

function formatSize(bytes) {
  const b = Number(bytes)
  if (isNaN(b) || b <= 0) return ""
  if (b < 1024) return b + " B"
  if (b < 1024 * 1024) return Format.trim1(b / 1024) + " KB"
  if (b < 1024 * 1024 * 1024) return Format.trim1(b / (1024 * 1024)) + " MB"
  return Format.trim1(b / (1024 * 1024 * 1024)) + " GB"
}

// One decimal unless it rounds away, canonicalized in
// common/text/Format.js.
function trim1(n) {
  return Format.trim1(n)
}

// Text titles collapse whitespace and cap length, canonicalized in
// common/text/StringUtils.js.
function truncateText(s, max) {
  return SU.truncateText(s, max)
}

// Path titles cut from the FRONT, canonicalized in
// common/text/StringUtils.js.
function truncatePath(path, max) {
  return SU.truncatePath(path, max)
}

// Display form: $HOME shrinks to "~" so more real path fits a title.
function homeTilde(path) {
  const p = String(path)
  if (HOME === "" || HOME === "/") return p
  if (p === HOME) return "~"
  if (p.indexOf(HOME + "/") === 0) return "~" + p.substring(HOME.length)
  return p
}

// Strip a leading "file://" so titles read as plain paths. Uri-list
// parsing already removes it; this covers raw/plain-text copies that
// still carry the scheme.
function stripFileScheme(s) {
  const t = String(s)
  return t.toLowerCase().indexOf("file://") === 0 ? t.substring(7) : t
}

function countWords(s) {
  const t = String(s).trim()
  if (t === "") return 0
  return t.split(RE_WS_SPLIT).length
}

function countSymbols(s) {
  return String(s).length
}

// Search haystack: title + subtext + peeked preview + mime/type hints.
// Secrets contribute ONLY the generic hint - their payload never enters
// any searchable surface.
function hayFor(entry) {
  const parts = []
  if (entry.title) parts.push(String(entry.title))
  if (entry.subLeft) parts.push(String(entry.subLeft))
  if (entry.preview) parts.push(String(entry.preview).substring(0, 200))
  if (entry.mime) parts.push(String(entry.mime))
  parts.push(String(entry.type || ""))
  if (entry.type === "secret") parts.push("secret credentials password")
  if (entry.type === "network") parts.push("network storage ftp sftp smb nfs ssh s3")
  // Lowercase once, dedupe via SearchLib (prototype-less, for the reason
  // stated there - a plain {} drops "constructor" / "__proto__" words).
  const raw = parts.join(" ").toLowerCase()
  return SL.dedupeWords(raw.split(RE_WS_SPLIT)).join(" ")
}

function wordsFor(hay) {
  return String(hay).split(" ")
}

// Tokenized AND search with substring-beats-prefix scoring - light twin
// of LauncherLib.searchRecords, allocation-capped through `cap`.
function searchEntries(entries, query, cap) {
  const q = SL.normalizeQuery(query)
  if (q === "") return entries.slice(0, cap !== undefined ? cap : entries.length)
  const tokens = SL.splitTokens(q)
  const scored = []
  for (let i = 0; i < entries.length; i++) {
    const e = entries[i]
    const hay = e.hay || ""
    const words = e.words || hay.split(" ")
    // Whole-title exact match wins outright - typing a pinned app name
    // or a file basename lands on it before longer texts that merely
    // contain the same word.
    let baseScore = 0
    if (e.title !== undefined && String(e.title).toLowerCase() === q) baseScore = 600
    let ok = true
    let total = baseScore
    for (let t = 0; t < tokens.length; t++) {
      const tok = tokens[t]
      if (SL.lengthReject(tok, hay)) { ok = false; break }
      let s = -1
      const idx = hay.indexOf(tok)
      if (idx >= 0) {
        const wordStart = idx === 0 || hay[idx - 1] === " "
        // Exact whole-word token beats a same-offset substring hit.
        const exact = words.indexOf(tok) >= 0 ? 250 : 0
        s = 2000 - idx * 10 - (wordStart ? 0 : 500) + exact
      } else {
        // word-prefix chain fallback
        let qi = 0
        for (let w = 0; w < words.length && qi < tok.length; w++) {
          const word = words[w]
          if (word.charCodeAt(0) === tok.charCodeAt(qi)) {
            let take = 1
            while (take < word.length && qi + take < tok.length
              && word.charCodeAt(take) === tok.charCodeAt(qi + take)) take++
            qi += take
          }
        }
        if (qi === tok.length) s = 10
      }
      if (s < 0) { ok = false; break }
      total += s
    }
    if (ok) scored.push({ e: e, s: total })
  }
  scored.sort((a, b) => b.s - a.s)
  const n = Math.min(scored.length, cap !== undefined ? cap : scored.length)
  const out = new Array(n)
  for (let i = 0; i < n; i++) out[i] = scored[i].e
  return out
}

// Credential hint mimes, as one predicate. The read path decides from this
// whether a paste is a credential at all, and detectType() below decides the
// same thing to type a row; two copies of the hint list would let them
// disagree about the same mime.
function isCredentialMimeTypes(types) {
  const seen = types || []
  for (let i = 0; i < seen.length; i++) {
    const m = String(seen[i]).toLowerCase()
    if (m.indexOf("password") >= 0 || m.indexOf("sensitive") >= 0
      || m.indexOf("x-kde-pass") >= 0 || m.indexOf("keepassxc") >= 0
      || m.indexOf("secret") >= 0 || m.indexOf("credential") >= 0
      || m.indexOf("keepass") >= 0 || m.indexOf("1password") >= 0
      || m.indexOf("bitwarden") >= 0 || m.indexOf("lastpass") >= 0)
      return true
  }
  return false
}

// Type decision order: credential hint mimes first (KeePassXC & friends),
// then embedded images, then URI lists, then plain-text classification.
function detectType(mimeTypes, content, filePaths) {
  const mimes = (mimeTypes || []).map(m => String(m).toLowerCase())
  const has = name => {
    for (let i = 0; i < mimes.length; i++)
      if (mimes[i].indexOf(name) >= 0) return true
    return false
  }
  if (isCredentialMimeTypes(mimes)) return "secret"
  for (let i = 0; i < mimes.length; i++)
    if (isImageMime(mimes[i])) return "image"
  if (has("text/uri-list") && filePaths && filePaths.length > 0) {
    if (filePaths.length === 1) {
      const p = filePaths[0]
      if (isImageExt(p)) return "image"
      if (isArchive(p)) return "archive"
      return "file" // folder-vs-file correction arrives with the stat probe
    }
    return "files"
  }
  const t = String(content || "").trim()
  if (t === "") return "text"
  // Single network URI (ftp, sftp, smb, etc.) - treat as network storage, not generic url
  if (isNetworkUri(t)) return "network"
  // List of network URIs (one per line)
  const nlIdx = t.indexOf("\n")
  if (nlIdx >= 0) {
    const lines = t.split("\n").map(s => s.trim()).filter(s => s !== "" && s.charAt(0) !== "#")
    let net = 0
    for (let i = 0; i < lines.length; i++) if (isNetworkUri(lines[i])) net++
    if (net > 0 && net === lines.length) return "network"
  }
  // text/uri-list that was actually network URIs dropped by parseUriList.
  // Grab line 0 via substring instead of a second split("\n") over the
  // whole string - the first split above already paid that cost once.
  if (has("text/uri-list")) {
    const firstLine = nlIdx >= 0 ? t.substring(0, nlIdx) : t
    if (isNetworkUri(firstLine.trim())) return "network"
  }
  if (isUrl(t)) return "url"
  return "text"
}

function iconForType(type) {
  const t = ICONS[String(type)]
  return t !== undefined ? t : ICONS.text
}

// Title + icon. Mutates entry. Path-bearing rows keep the full tilde-folded
// path as the title and flag pathLike:true - the row Text then elides from
// the LEFT so a long location always ends in the visible file name. Only an
// extreme cap remains here as haystack/storage hygiene.
function buildTitleSub(entry) {
  const type = entry.type
  if (type === "secret") {
    entry.title = "Sensitive content"
    entry.icon = ICONS.secret
    entry.pathLike = false
    return
  }
  if (type === "url") {
    entry.title = truncateText(entry.raw, 64)
    entry.icon = ICONS.url
    entry.pathLike = false
    return
  }
  if (type === "text") {
    entry.title = truncateText(stripFileScheme(entry.raw), 72)
    if (entry.title.trim() === "") entry.title = "Empty text"
    const mk = mathTextKind(entry.raw)
    entry.icon = mk === "number" ? ICONS.calculator : (mk === "expr" || mk === "func") ? ICONS.math : ICONS.text
    entry.pathLike = false
    return
  }
  if (type === "image") {
    if (entry.filePaths && entry.filePaths.length === 1) {
      // Copied file: full path title (left-elided), image-icon flavor.
      const p = safePath(stripFileScheme(entry.filePaths[0]))
      entry.title = homeTilde(p)
      entry.icon = extIconName(p) || ICONS.image
      entry.pathLike = true
      return
    }
    // Snapshot off the clipboard: no path exists.
    entry.title = prettyImageName(entry) + " image"
    entry.icon = String(entry.mime).indexOf("svg") >= 0 ? ICONS.svg : ICONS.image
    entry.pathLike = false
    return
  }
  if (type === "file" || type === "folder" || type === "archive") {
    const p = safePath(stripFileScheme(entry.filePaths && entry.filePaths.length === 1
      ? entry.filePaths[0] : String(entry.raw)))
    entry.title = homeTilde(p)
    if (type === "folder") {
      // A git work tree keeps the folder shape but rides the git glyph:
      // presence is the verdict, validity is branch-or-detached (same gate
      // as gitInfoRows), so a hand-shaped or empty payload never flips it.
      const g = entry.git
      const isGit = g && typeof g === "object"
        && (String(g.branch || "") !== "" || g.detached === true)
      entry.icon = isGit ? (ICONS.foldergit || "file-folder-git") : ICONS.folder
    }
    else if (type === "archive") entry.icon = ICONS.archive
    else entry.icon = extIconName(p) || ICONS.file
    entry.pathLike = true
    return
  }
  if (type === "network") {
    // Prefer the first real URI - uri-lists may lead with "#" comment
    // lines that raw would surface. Strip "proto://" so the title is
    // the share's own path, elided from the left like file rows so a
    // long location always ends in the visible file name.
    let uri = ""
    if (entry.filePaths && entry.filePaths.length > 0) {
      uri = String(entry.filePaths[0])
    } else {
      const lines = String(entry.raw || "").trim().split("\n")
      for (let i = 0; i < lines.length; i++) {
        const l = lines[i].trim()
        if (l !== "" && l.charAt(0) !== "#") { uri = l; break }
      }
    }
    const stripped = uri.replace(RE_SCHEME_STRIP, "")
    entry.title = safePath(stripped !== "" ? stripped : uri)
    // Fallback to network-storage generic if still empty
    if (entry.title.trim() === "" || entry.title === "...") entry.title = "Network storage"
    entry.icon = ICONS.network
    entry.pathLike = true
    return
  }
  if (type === "files" || type === "folders") {
    const n = entry.filePaths ? entry.filePaths.length : 0
    if (entry.allFolders) entry.title = n > 0 ? n + " folders" : "Folders"
    else entry.title = n > 0 ? n + " files" : "Files"
    entry.icon = entry.allFolders ? ICONS.folders : ICONS.files
    entry.pathLike = false
    return
  }
  entry.title = truncateText(entry.raw, 64)
  entry.icon = iconForType(type)
  entry.pathLike = false
}

// Hard sanity cap so a corrupted uri-list cannot balloon entry objects;
// normal paths never come close.
function safePath(p) {
  const s = String(p || "")
  return s.length > 240 ? truncatePath(s, 240) : s
}

function prettyImageName(entry) {
  const ext = entry.filePaths && entry.filePaths.length === 1
    ? extOf(entry.filePaths[0]).toUpperCase() : ""
  if (ext !== "") return ext
  const m = String(entry.mime || "")
  if (m.indexOf("png") >= 0) return "PNG"
  if (m.indexOf("jpeg") >= 0 || m.indexOf("jpg") >= 0) return "JPEG"
  if (m.indexOf("gif") >= 0) return "GIF"
  if (m.indexOf("webp") >= 0) return "WEBP"
  return "Image"
}

// Subtext: what the thing IS, quantified. Parts join with " • ".
// Optional detail (sizes, recursive folder walks) only appears once the
// async probe delivered it - absent means pending, never fake.
// A row flagged missing (its open-on-Enter existence probe found the
// path gone) shows the flag instead: the size/resolution metadata is
// stale the moment the file is gone.
function buildSubLeft(entry) {
  if (entry && entry.missing === true)
    return String(entry.missingText || "File not found")
  switch (entry.type) {
    case "secret":
      return "Credentials • Hidden"
    case "url":
      return "Web URL"
    case "text": {
      const w = countWords(entry.raw)
      const c = countSymbols(entry.raw)
      return w + (w === 1 ? " word" : " words") + " • " + c + " chars"
    }
    case "image": {
      const parts = []
      if (entry.imageW > 0 && entry.imageH > 0)
        parts.push(entry.imageW + "x" + entry.imageH)
      if (entry.fileSize !== undefined && entry.fileSize > 0)
        parts.push(formatSize(entry.fileSize))
      return parts.length > 0 ? parts.join(" • ") : "Image"
    }
    case "archive":
      return entry.fileSize !== undefined && entry.fileSize > 0
        ? "Archive • " + formatSize(entry.fileSize) : "Archive"
    case "file":
      return entry.fileSize !== undefined && entry.fileSize > 0
        ? formatSize(entry.fileSize) : "File"
    case "network": {
      // Same URI source as the title: filePaths when present, else the
      // first non-comment raw line (uri-lists may carry "#" headers).
      let nets = []
      if (entry.filePaths && entry.filePaths.length > 0) {
        nets = entry.filePaths.filter(isNetworkUri)
      } else {
        const raw = String(entry.raw || "").trim()
        const lines = raw.split("\n").map(s => s.trim()).filter(s => s !== "" && s.charAt(0) !== "#")
        nets = lines.filter(isNetworkUri)
      }
      if (nets.length > 1) return nets.length + " network locations"
      const single = nets[0] || ""
      // Extract protocol and host without URL global (not available in QML JS)
      const m = String(single).match(RE_URI_SCHEME_HOST)
      if (m) {
        const proto = NETWORK_PROTO_LABELS[m[1].toLowerCase()] || m[1].toUpperCase()
        const host = m[2].split("@").pop().split(":")[0]
        if (host && proto) return proto + " • " + host
        if (host) return host
        if (proto) return proto + " location"
      }
      return "Network storage"
    }
    case "folder": {
      const parts = []
      if (entry.folderCount !== undefined && entry.folderCount !== null)
        parts.push(entry.folderCount + " files")
      if (entry.fileSize !== undefined && entry.fileSize > 0)
        parts.push(formatSize(entry.fileSize))
      return parts.length > 0 ? parts.join(" • ") : "Folder"
    }
    case "files":
    case "folders": {
      const n = entry.filePaths ? entry.filePaths.length : (entry.fileCount || 0)
      const folders = entry.foldersCount || 0
      const allFolders = entry.allFolders === true
      let first
      if (allFolders) first = n + (n === 1 ? " folder" : " folders")
      else if (folders > 0) first = n + (n === 1 ? " item" : " items")
      else first = n + (n === 1 ? " file" : " files")
      const parts = [first]
      if (!allFolders && folders > 0 && folders < n)
        parts.push(folders + (folders === 1 ? " folder" : " folders"))
      if (entry.folderCount !== undefined && entry.folderCount > 0)
        parts.push(entry.folderCount + " files")
      if (entry.totalSize !== undefined && entry.totalSize > 0)
        parts.push(formatSize(entry.totalSize))
      return parts.join(" • ")
    }
    default:
      return ""
  }
}

// text/uri-list -> local paths ([] when remote URLs ride along).
function parseUriList(text) {
  const lines = String(text).split("\n")
  const out = []
  for (let i = 0; i < lines.length; i++) {
    let line = lines[i].trim()
    if (line === "" || line.charAt(0) === "#") continue
    if (line.toLowerCase().indexOf("file://") === 0) {
      line = line.substring(7)
      if (line.indexOf("localhost/") === 0) line = line.substring("localhost".length)
      try {
        line = decodeURIComponent(line)
      } catch (e) {
      }
    }
    if (line.indexOf("://") > 0) continue // ftp://... etc are not files (handled as network)
    if (line.charAt(0) !== "/") continue
    out.push(line)
  }
  return out
}

function extractNetworkUris(text) {
  const lines = String(text).split("\n")
  const out = []
  for (let i = 0; i < lines.length; i++) {
    let line = lines[i].trim()
    if (line === "" || line.charAt(0) === "#") continue
    if (isNetworkUri(line)) out.push(line)
  }
  return out
}

// --- secret codec ---
// Round-trip codec for the per-install XOR cipher: each code point is XORed
// with a repeating key and encoded as four hex digits, which keeps it lossless
// for arbitrary unicode (it works on char codes, not re-encoded UTF-8 bytes).
// Decoding it is an import read. The key travels inside the same file as
// the ciphertext, so what comes out is held in memory for the session and
// never written back under any key.
function hex4(n) {
  return ("000" + n.toString(16)).slice(-4)
}

function decryptSecret(hex, key) {
  key = String(key || "")
  if (key === "") return String(hex)
  const kl = key.length
  let out = ""
  const pairs = String(hex).length / 4
  for (let i = 0; i < pairs; i++) {
    const v = parseInt(hex.substring(i * 4, i * 4 + 4), 16)
    out += String.fromCharCode(v ^ key.charCodeAt(i % kl))
  }
  // Integrity gate: a wrong key yields garbage that must not be stashed as
  // a credential. Correct decryptions of real credentials are text, so an
  // output carrying lone surrogates, non-characters or C1 controls is not
  // a credential at all - the caller marks the row unavailable instead.
  // The codec supports NUL and C0 controls (round-tripped above), so those
  // stay allowed here; only values no valid string from this codec produces
  // on a correct key are rejected.
  for (let i = 0; i < out.length; i++) {
    const c = out.charCodeAt(i)
    if (c >= 0xD800 && c <= 0xDBFF) {
      const n = out.charCodeAt(i + 1)
      if (n >= 0xDC00 && n <= 0xDFFF) { i++; continue }
      return ""
    }
    if (c >= 0xDC00 && c <= 0xDFFF) return ""
    if (c === 0xFFFE || c === 0xFFFF) return ""
    if (c >= 0xFDD0 && c <= 0xFDEF) return ""
    if (c === 0x7F || (c >= 0x80 && c <= 0x9F)) return ""
  }
  return out
}

// file path -> encoded file:// URI, one encodeURIComponent per segment so
// spaces, "#" and unicode survive the trip through any consumer.
// Root must serialize as the canonical triple-slash form.
function toFileUri(path) {
  const p = String(path)
  const parts = p.split("/")
  let u = ""
  for (let i = 0; i < parts.length; i++) {
    if (parts[i] === "") continue
    u += "/" + encodeURIComponent(parts[i])
  }
  return "file://" + (u === "" ? "/" : u)
}

// --- shell quoting and native helpers (always in memory) ---
// Single-quote escaping, canonicalized in StringUtils.shellQuote.
function sq(s) {
  return SU.shellQuote(s)
}

// wl-copy helpers - keep construction in JS, QML just calls CL.build*
//
// The payload-carrying commands are stdin jobs: the argv holds flags and the
// mime type only, and the bytes go to the child over its write channel, where
// they never reach /proc/<pid>/cmdline or a shell source string. Taking the
// value as a parameter is what put it in argv, so no builder here accepts one
// - a caller cannot hand a credential to these functions even by mistake.
function buildCopyTextCmd() {
  return ["wl-copy", "-n"]
}
function buildCopySecretCmd() {
  return ["wl-copy", "-n", "--sensitive", "--type", "text/plain"]
}
function buildCopyUriListCmd() {
  return ["wl-copy", "-n", "--type", "text/uri-list"]
}
function buildCopyImageDataCmd(mime, path) {
  return ["sh", "-c", "wl-copy -n --type " + sq(mime) + " < " + sq(path)]
}
// Retained shell fragment: the URI list reaches wl-copy as one quoted word
// instead of a stdin write, because callers route an image re-copy through a
// single process. The data is a file:// URI, not credential material, and sq()
// keeps a path with spaces or quotes from splitting the command.
function buildCopyUrisCmd(uris) {
  return ["sh", "-c", "printf %s " + sq(uris) + " | wl-copy -n --type text/uri-list"]
}
function buildCopyImageFileCmd(path) {
  return buildCopyUrisCmd(toFileUri(path))
}
// Empty the system clipboard (wl-copy keeps serving the last offer even
// after the history entry is deleted - a fresh boot would re-offer the
// old content and the manager would re-capture it).
function buildClearCmd() {
  return ["wl-copy", "--clear"]
}
function buildMkdirCmd(imgDir, cacheDir) {
  return ["mkdir", "-p", "--", String(imgDir), String(cacheDir)]
}
function buildWatchCmd() {
  // Direct exec (no sh wrapper): the Process child IS wl-paste, so
  // shell teardown kills the watcher instead of orphaning it behind
  // a dead sh. Protocol unchanged: one __vc__ line per clipboard write.
  return ["wl-paste", "--watch", "sh", "-c", "printf \"__vc__\\n\""]
}

// Controller-side argv: every other child the service spawns. The Process
// objects stay in Clipboard.qml (a .pragma library carries no Qt types), so
// what moves here is the command line alone - the reviewable statement of
// which binaries this feature can run. None of these carries a payload: they
// name directories this feature created, snapshot files it wrote, or the mime
// list a read returns.
//
// The one argv deliberately NOT here is the `install -m 0600 -- /dev/null
// <history>` that creates the history node at its final mode. Its literal has
// to stay spelled in the controller, where the create-before-write gate
// lives: the history node is created at 0600 and every write is held back
// until the mode has been confirmed. No case under tests/shell/suites/
// asserts that gate, so it is verified by reading Clipboard.qml.
function buildEnsurePrivateDirsCmd(cacheDir, imgDir) {
  return ["install", "-d", "-m", "0700", "--", String(cacheDir), String(imgDir)]
}
// Clamp the history file to owner-only access.
function buildHistoryModeCmd(historyPath) {
  return ["chmod", "0600", "--", String(historyPath)]
}
function buildRmPathCmd(path) {
  return ["rm", "-f", "--", String(path)]
}
function buildRmPathsCmd(paths) {
  const out = ["rm", "-f", "--"]
  for (let i = 0; i < (paths || []).length; i++) out.push(String(paths[i]))
  return out
}
// One-shot: kill watchers orphaned by pre-fix generations (bare kill/pkill
// leaves wl-paste reparented). Matches only our own __vc__ protocol string,
// never a generic wl-paste.
function buildOrphanReapCmd() {
  return ["sh", "-c", "pkill -f 'wl-paste --watch.*__vc__' 2>/dev/null || true; exit 0"]
}
function buildListTypesCmd() {
  return ["wl-paste", "--list-types"]
}
function buildPasteUriListCmd() {
  return ["wl-paste", "--no-newline", "--type", "text/uri-list"]
}
function buildPasteTextCmd() {
  return ["wl-paste", "--no-newline"]
}

// Mime subtype -> snapshot file extension. The subtype of image/svg+xml is
// "svg+xml", which no *_EXTS table holds, so it maps back to "svg" here;
// "jpg" normalizes to "jpeg" so snapshots and mimeForExt agree. Anything
// unknown falls through to the stripped subtype, then to png.
const MIME_EXT = {
  "svg+xml": "svg", svg: "svg", jpeg: "jpeg", jpg: "jpeg"
}

// Unique destination per capture: history previews never mutate under an
// existing entry, and the sequence keeps two snapshots inside the same
// millisecond apart.
function snapshotPath(imgDir, ts, seq, mime) {
  const raw = (String(mime).split("/")[1] || "png").split(";")[0].trim().toLowerCase()
  const ext = MIME_EXT[raw] || raw.split("+")[0] || "png"
  return String(imgDir) + "/t" + ts + "-" + seq + "." + ext
}

// Image snapshot - wl-paste needs shell redirection; emit size + sha without wc/cut pipes
function buildImageSnapshotCmd(mime, path) {
  return ["sh", "-c",
    "p=" + sq(path) + "; "
    + "if wl-paste --type " + sq(mime) + " > \"$p\" 2>/dev/null; then "
    + "chmod 0600 -- \"$p\" 2>/dev/null; "
    + "stat -c %s \"$p\" 2>/dev/null; "
    + "sha1sum \"$p\" 2>/dev/null; "
    + "else rm -f -- \"$p\"; echo EMPTY; fi"]
}
function buildDimCmd(path) {
  // Use [0] for first frame (GIFs) and no head pipe - format already single line
  return ["sh", "-c", "identify -format '%w %h\\n' " + sq(path + "[0]") + " 2>/dev/null || true"]
}

// File info - shell emits raw sizes only, JS aggregates.
// For a single path:
//   dir  -> timeout-bounded find, awk-summed to "<count> <bytes>"
//   file -> stat -c %s
// For multiple: loop, prefix each chunk with marker so JS can group.
// The find stays on one filesystem (-xdev) and dies after 10s; walks past
// 20000 files print TOOBIG instead of a sum so a home-directory copy can
// never wedge the probe.
function buildFileInfoCmd(paths) {
  if (!paths || paths.length === 0)
    return ["sh", "-c", "true"]
  const awkSum = "awk 'BEGIN{c=0;s=0;big=0} {c++; s+=$1; if(c>20000){print \"TOOBIG\"; big=1; exit}} END{if(!big) print c\" \"s}'"
  if (paths.length === 1) {
    const q = sq(paths[0])
    return ["sh", "-c",
      "if [ -d " + q + " ]; then "
      + "echo DIR; timeout 10 find " + q + " -xdev -type f -printf '%s\n' 2>/dev/null | " + awkSum + "; "
      + "elif [ -f " + q + " ]; then "
      + "echo FILE; stat -c %s " + q + " 2>/dev/null || echo 0; "
      + "else echo MISSING; fi"]
  }
  let list = ""
  for (let i = 0; i < paths.length; i++)
    list += (i ? " " : "") + sq(paths[i])
  return ["sh", "-c",
    "for p in " + list + "; do "
    + "if [ -d \"$p\" ]; then "
    + "echo \"DIR $p\"; timeout 10 find \"$p\" -xdev -type f -printf '%s\n' 2>/dev/null | " + awkSum + "; echo \"ENDDIR\"; "
    + "elif [ -f \"$p\" ]; then "
    + "echo \"FILE $p\"; stat -c %s \"$p\" 2>/dev/null || echo 0; echo \"ENDFILE\"; "
    + "else echo \"MISSING $p\"; echo \"ENDMISSING\"; fi; "
    + "done"]
}

// Text probe - shell emits mime and head, JS decides binary vs text.
function buildTextProbeCmd(path) {
  return ["sh", "-c",
    "if [ -r " + sq(path) + " ]; then "
    + "file -b --mime " + sq(path) + " 2>/dev/null; "
    + "printf \"__HEAD__\\n\"; "
    + "head -c 24576 -- " + sq(path) + " 2>/dev/null || true; "
    + "else "
    + "echo \"binary\"; printf \"__HEAD__\\n\"; "
    + "fi"]
}

// Media probe - shell gates, JS parses the default dump and decides.
// The path is lowercased before the case so .MP3 matches the same way
// extOf() (which lowercases) matches inside isMediaPath().
function buildMediaInfoCmd(path) {
  return ["sh", "-c",
    "command -v mediainfo >/dev/null 2>&1 || exit 1; "
    + "p=" + sq(path) + "; "
    + "p=$(printf '%s' \"$p\" | tr '[:upper:]' '[:lower:]'); "
    + "case $p in "
    + "*.mp3|*.flac|*.ogg|*.oga|*.opus|*.wav|*.m4a|*.aac|*.wma|*.mid|*.midi|*.it|*.xm|*.mp4|*.mkv|*.webm|*.mov|*.avi|*.m4v) ;; "
    + "*) exit 1;; esac; "
    + "exec mediainfo -- " + sq(path) + " 2>/dev/null"]
}

// Git probe for a singular folder: read-only, one cheap script. A missing
// git binary or a failed status (not a work tree at all) answers GIT MISS
// and the folder card renders as today.
//
// Fork budget, deliberately three: the `status -b` call folds the branch
// header, the upstream, the ahead/behind counts AND the file list into one
// repo discovery, the log block carries hash/author/time/subject in one
// read, and the remote URL has no cheaper source than its own read. Every
// git runs guarded so one failure cannot kill the rest. The locale is
// pinned so a non-English environment can never reshape a parsed line:
// porcelain is stable by contract and %ct is numeric, but the guarantee
// should not have to be re-derived per line. The status uses
// --untracked-files=no so even a huge checkout answers from the index
// alone, and --no-optional-locks so a stale lock can never hang the probe.
// The parser below owns the line protocol, so the shell never interprets
// a branch name, an author or a commit subject.
function buildGitInfoCmd(path) {
  const q = sq(String(path))
  return ["sh", "-c",
    "export LC_ALL=C; "
    + "command -v git >/dev/null 2>&1 || { echo \"GIT MISS\"; exit 0; }; "
    + "p=" + q + "; "
    + "st=$(git --no-optional-locks -C \"$p\" status --porcelain=v1 -b --untracked-files=no 2>/dev/null) || { echo \"GIT MISS\"; exit 0; }; "
    + "echo \"GIT OK\"; "
    + "echo \"head $(printf '%s\\n' \"$st\" | head -n 1)\"; "
    + "echo \"---STATUS---\"; "
    + "printf '%s\\n' \"$st\" | tail -n +2; "
    + "echo \"---END---\"; "
    + "echo \"---COMMIT---\"; "
    + "git -C \"$p\" log -1 --format='chash %h%nauthor %an%nemail %ae%nctime %ct%nsubject %s' 2>/dev/null; "
    + "echo \"---ENDCOMMIT---\"; "
    + "echo \"remote $(git -C \"$p\" config --get remote.origin.url 2>/dev/null)\""]
}

// Verdict for buildGitInfoCmd's stdout, or null when the directory is no
// repo (or git is absent): { branch, upstream, ahead, behind, gone,
// detached, staged, unstaged, chash, csubject, cauthor, cemail, ctime, remote }.
// Presence is the verdict - a non-repo answers null, never an object.
// Absent data omits rather than fakes - a detached HEAD names no branch, a
// missing upstream leaves no counts, and an empty commit block means no
// commit yet.
function parseGitInfoOutput(text) {
  // The raw `## ...` header of `git status -b`: branch, upstream and
  // ahead/behind in one line. Refnames cannot hold three dots in a row
  // (no component may start or end with one), so the first "..." is
  // always the branch/upstream separator, never part of a name.
  function parseHead(line) {
    const out = { branch: "", upstream: "", ahead: 0, behind: 0, gone: false, detached: false }
    let rest = String(line || "")
    if (rest.indexOf("## ") === 0) rest = rest.substring(3)
    else return out
    if (rest === "HEAD (no branch)") { out.detached = true; return out }
    const NONAME = "No commits yet on "
    if (rest.indexOf(NONAME) === 0) rest = rest.substring(NONAME.length)
    const cut = rest.indexOf("...")
    let tail = ""
    if (cut < 0) {
      out.branch = rest.trim()
      return out
    }
    out.branch = rest.substring(0, cut).trim()
    tail = rest.substring(cut + 3)
    let bracket = ""
    const bo = tail.lastIndexOf(" [")
    if (bo >= 0 && tail.charAt(tail.length - 1) === "]") {
      bracket = tail.substring(bo + 2, tail.length - 1)
      tail = tail.substring(0, bo)
    }
    out.upstream = tail.trim()
    const a = bracket.match(/ahead (\d+)/)
    const b = bracket.match(/behind (\d+)/)
    if (a) out.ahead = parseInt(a[1], 10)
    if (b) out.behind = parseInt(b[1], 10)
    if (/(^| )gone($| )/.test(bracket)) out.gone = true
    return out
  }
  const lines = String(text || "").split("\n")
  if (lines.length === 0 || lines[0].trim() !== "GIT OK") return null
  const g = { branch: "", upstream: "", ahead: 0, behind: 0, gone: false, detached: false, staged: 0, unstaged: 0, chash: "", csubject: "", cauthor: "", cemail: "", ctime: "", remote: "" }
  let inStatus = false
  let inCommit = false
  for (let i = 1; i < lines.length; i++) {
    const line = lines[i]
    if (line === "---STATUS---") { inStatus = true; inCommit = false; continue }
    if (line === "---END---") { inStatus = false; continue }
    if (line === "---COMMIT---") { inCommit = true; inStatus = false; continue }
    if (line === "---ENDCOMMIT---") { inCommit = false; continue }
    if (inCommit) {
      // One labeled line each; anything else (a smuggled newline inside a
      // name, a truncated tail) matches no key and is dropped.
      if (line.indexOf("chash ") === 0) g.chash = line.substring(6).trim()
      else if (line.indexOf("author ") === 0) g.cauthor = line.substring(7).trim()
      else if (line.indexOf("email ") === 0) g.cemail = line.substring(6).trim()
      else if (line.indexOf("ctime ") === 0) g.ctime = line.substring(6).trim()
      else if (line.indexOf("subject ") === 0) g.csubject = line.substring(8).trim()
      continue
    }
    if (inStatus) {
      // Porcelain v1 XY columns: staged is X, unstaged is Y. Renames (R),
      // unmerged (UU/AA) and typechanges (T) all count on the side they
      // appear, which is exactly what "how much is uncommitted" asks.
      if (line.length >= 2) {
        const x = line.charAt(0), y = line.charAt(1)
        if (x !== " " && x !== "?") g.staged++
        if (y !== " " && y !== "?") g.unstaged++
      }
      continue
    }
    const sp = line.indexOf(" ")
    const key = sp < 0 ? line : line.substring(0, sp)
    const val = sp < 0 ? "" : line.substring(sp + 1).trim()
    if (key === "head") {
      const h = parseHead(val)
      g.branch = h.branch
      g.upstream = h.upstream
      g.ahead = h.ahead
      g.behind = h.behind
      g.gone = h.gone
      g.detached = h.detached
    }
    else if (key === "remote") g.remote = cleanGitRemote(val)
  }
  return g
}

// A remote URL reduced to host/path for the row: scp syntax
// ([user@]host:path), scheme URLs (with optional user@), and anything
// else (local paths, odd transports) passed through trimmed. Trailing
// .git and slashes go; the value stays recognizable.
function cleanGitRemote(url) {
  const u = String(url || "").trim().replace(/\.git$/, "")
  if (u === "") return ""
  if (u.indexOf("://") < 0) {
    const m = u.match(/^(?:[^@/]+@)?([^:/@]+):(.+)$/)
    if (m) return (m[1] + "/" + m[2]).replace(/\/+$/, "")
    return u
  }
  const m = u.match(/^[a-z][a-z0-9+.-]*:\/\/(?:[^@/]+@)?([^/]+)\/(.+)$/i)
  if (m) return (m[1] + "/" + m[2]).replace(/\/+$/, "")
  return u
}

// A commit timestamp (unix seconds, %ct) as local YYYY-MM-DD HH:MM.
// Numeric fields only, so the output is identical under every locale -
// the whole reason the probe reads %ct instead of a preformatted date.
// Anything outside the valid range answers "" and the row is omitted.
function formatGitTime(ts) {
  const n = parseInt(String(ts === undefined || ts === null ? "" : ts).trim(), 10)
  if (isNaN(n) || n <= 0) return ""
  const d = new Date(n * 1000)
  if (isNaN(d.getTime())) return ""
  const p2 = v => (v < 10 ? "0" : "") + v
  return d.getFullYear() + "-" + p2(d.getMonth() + 1) + "-" + p2(d.getDate())
    + " " + p2(d.getHours()) + ":" + p2(d.getMinutes())
}

// Folder-card git rows from a parseGitInfoOutput payload, in the same
// {icon, label, value} vocabulary as folderInfoRows/mediaInfoRows. A
// non-repo (or anything the probe could not answer) renders nothing, so
// the card reads exactly as it does today.
function gitInfoRows(g) {
  const rows = []
  // Presence is the verdict, so validity is grounded in content: a real
  // probe always names a branch or reports detached. Anything else (a
  // hand-shaped object, a future field set) renders nothing.
  if (!g || (String(g.branch || "") === "" && g.detached !== true)) return rows
  if (g.detached === true) {
    rows.push({ icon: "git", label: "Branch", value: "(detached)" })
  } else if (String(g.branch || "") !== "") {
    rows.push({
      icon: "git", label: "Branch",
      value: String(g.branch) + (g.upstream ? " \u2192 " + g.upstream : "")
    })
  }
  const dirty = []
  if (g.staged > 0) dirty.push(g.staged + " staged")
  if (g.unstaged > 0) dirty.push(g.unstaged + " unstaged")
  rows.push({ icon: "git", label: "Status", value: dirty.length > 0 ? dirty.join(", ") : "clean" })
  if (g.gone === true) {
    rows.push({ icon: "git", label: "Sync", value: "upstream gone" })
  } else if (g.upstream) {
    if (g.ahead > 0 || g.behind > 0) {
      const sync = []
      if (g.ahead > 0) sync.push("ahead " + g.ahead)
      if (g.behind > 0) sync.push("behind " + g.behind)
      rows.push({ icon: "git", label: "Sync", value: sync.join(", ") })
    } else {
      rows.push({ icon: "git", label: "Sync", value: "up to date" })
    }
  }
  if (g.chash) {
    // Subjects are free text of unbounded length; the row elides, but a
    // pathological one-liner still costs layout. Cap with an ellipsis.
    let subj = String(g.csubject || "")
    if (subj.length > 200) subj = subj.substring(0, 200) + "\u2026"
    rows.push({ icon: "git", label: "Commit", value: subj !== "" ? String(g.chash) + " - " + subj : String(g.chash) })
  }
  const when = formatGitTime(g.ctime)
  if (when !== "") rows.push({ icon: "git", label: "Date", value: when })
  // Author email rides along in parentheses when the probe answered one;
  // absent means the row reads exactly as before, never with empty parens.
  {
    const a = String(g.cauthor || "")
    const e = String(g.cemail || "").trim()
    if (a !== "" && e !== "") rows.push({ icon: "git", label: "Author", value: a + " (" + e + ")" })
    else if (a !== "") rows.push({ icon: "git", label: "Author", value: a })
    else if (e !== "") rows.push({ icon: "git", label: "Author", value: e })
  }
  if (g.remote) rows.push({ icon: "git", label: "Remote", value: String(g.remote) })
  return rows
}

// Existence probe for the open-on-Enter path: one line per path,
// "<index> ok" or "<index> missing". Indices (not paths) ride the
// protocol so a newline or quote inside a filename cannot forge a line.
// `[ -e ]` follows the launcher's stat probe (dir or file counts as
// present); the open below only runs for indices that answered "ok".
function buildExistenceProbeCmd(paths) {
  if (!paths || paths.length === 0)
    return ["sh", "-c", "true"]
  const parts = []
  for (let i = 0; i < paths.length; i++) {
    const q = sq(String(paths[i]))
    parts.push("if [ -e " + q + " ]; then echo \"" + i + " ok\"; else echo \"" + i + " missing\"; fi")
  }
  return ["sh", "-c", parts.join("; ") + "; true"]
}

// Verdicts for buildExistenceProbeCmd's stdout. Returns
// { existing: [...indices], missing: [...indices] }: every index in
// [0, count) appears exactly once, so a truncated or hostile output can
// never silently drop a path into the open set - an index with no "ok"
// line lands in missing and is never executed.
// Open a verified local path in its default app. Same launch discipline
// as the launcher (AppLauncherController._openPath): xdg-open inside
// app2unit's transient systemd scope so the process stays session-tracked;
// execDetached guarantees survival past panel close.
// Local paths Enter should open instead of re-copying. Single-path rows
// (file/folder/archive/image) yield at most one absolute path; multi-rows
// (files/folders) yield every absolute path. Everything else (text, url,
// network, secret) yields [] and keeps the copy behaviour. Image rows
// prefer the concrete file, then the session snapshot, then the lone
// filePaths entry - all three are absolute local paths when present.
// Notice copy for a failed open-on-Enter existence probe. A single-path
// row names no count; a multi-row names how many of its paths are gone.
// Empty when nothing is missing, so only a real verdict ever renders.
// Parse the plain `mediainfo` dump into a card payload. Format facts
// (verified on MediaInfoLib v26.05): section headers sit at column 0,
// kv lines are "Key<pad> : value" with the key ALSO at column 0, blank
// lines separate sections, and long values wrap onto space-indented
// continuation lines with no separator. Returns null when the dump
// carries no real media info (unparseable file: General section with
// only Complete name/File size, no Duration, no Audio/Video). Absent
// metadata simply produces absent fields - never fake copy.
function parseMediaInfo(text) {
  const lines = String(text).split("\n")
  const sections = []
  let cur = null
  let lastKey = ""
  for (let i = 0; i < lines.length; i++) {
    const l = lines[i].replace(/\s+$/, "")
    if (l === "") { cur = null; continue }
    const sep = l.indexOf(" : ")
    if (sep > 0) {
      if (cur === null) continue
      lastKey = l.substring(0, sep).trim()
      cur.kv[lastKey] = l.substring(sep + 3).trim()
      continue
    }
    if (l.charAt(0) === " ") {
      // Wrapped value continuation - rejoin onto the previous key.
      if (cur !== null && lastKey !== "" && cur.kv[lastKey] !== undefined)
        cur.kv[lastKey] += " " + l.trim()
      continue
    }
    cur = { name: l.trim(), kv: {} }
    lastKey = ""
    sections.push(cur)
  }
  let g = null, a = null, v = null
  for (let s = 0; s < sections.length; s++) {
    if (g === null && sections[s].name === "General") g = sections[s]
    else if (a === null && sections[s].name === "Audio") a = sections[s]
    else if (v === null && sections[s].name === "Video") v = sections[s]
  }
  // The one hard validity gate: a parsed media file always reports Duration.
  if (g === null || g.kv.Duration === undefined) return null
  const t = k => {
    const s = g.kv[k]
    return s === undefined ? "" : String(s).replace(/\s+/g, " ").trim()
  }
  const mi = {}
  const first = keys => {
    for (let i = 0; i < keys.length; i++) {
      const s = t(keys[i])
      if (s !== "") return s
    }
    return ""
  }
  const track = first(["Track name", "Title", "Movie", "Movie name"])
  if (track !== "") mi.track = track
  const artist = first(["Performer", "Artist"])
  if (artist !== "") mi.artist = artist
  const album = first(["Album"])
  if (album !== "") mi.album = album
  if (g.kv.Format !== undefined) mi.format = g.kv.Format
  if (g.kv.Duration !== undefined) mi.duration = g.kv.Duration
  if (a !== null) mi.audio = a.kv
  if (v !== null) mi.video = v.kv
  return mi
}

// "2 s 38 ms" -> "0:02.038", canonicalized in
// common/text/Duration.js. Sub-second precision only survives below 10 s;
// longer media round down.
function formatMediaDuration(s) {
  return DurationFmt.formatMediaDuration(s)
}

// No-mediainfo fallback: basename + extension class, same copy rules as
// every lib builder - descriptive, never tool- or error-flavored.
function buildMediaSummary(path) {
  const name = String(path).replace(/^.*\//, "")
  const e = extOf(name)
  if (isVideo(path)) return { title: name, icon: ICONS.file, video: true, ext: e }
  return { title: name, icon: ICONS.music, video: false, ext: e }
}

// Extension gate mirrored from MUSIC_EXTS/VIDEO_EXTS so the service can
// skip the mediainfo probe for non-media files without spawning a shell.
function isMediaPath(path) {
  return extIn(path, MUSIC_EXTS) || extIn(path, VIDEO_EXTS)
}

// Card header shows the basename; the list row already carries the full
// path. Lib owns every display string.
function mediaBaseName(path) {
  return String(path).replace(/^.*\//, "")
}

// Preview-card rows from a parseMediaInfo() payload. Everything
// user-readable comes from here; the QML side only maps icon -> glyph.
// Rows: Track / Artist / Album / Duration, then exactly one codec line -
// video (WxH + FPS) when a Video track exists, else audio (channels +
// rate). Absent metadata omits the row, never fakes it.
function mediaInfoRows(mi) {
  const rows = []
  const a = mi.audio || {}
  const v = mi.video || {}
  if (mi.track) rows.push({ icon: "music-track", label: "Track", value: mi.track })
  if (mi.artist) rows.push({ icon: "music-artist", label: "Artist", value: mi.artist })
  if (mi.album) rows.push({ icon: "music-album", label: "Album", value: mi.album })
  const dur = formatMediaDuration(mi.duration || "")
  if (dur !== "") rows.push({ icon: "hourglass", label: "Duration", value: dur })
  if (v["Width"] !== undefined) {
    const w = String(v["Width"]).replace(/\s*pixels$/, "").trim()
    const h = String(v["Height"]).replace(/\s*pixels$/, "").trim()
    const fps = String(v["Frame rate"] || "").replace(/\s*FPS$/, "").trim().replace(/(\.\d*?)0+$/, "$1").replace(/\.$/, "")
    const parts = [String(v["Format"] || "").trim()]
    if (w !== "" && h !== "") parts.push(w + "x" + h)
    if (fps !== "") parts.push(fps + " FPS")
    rows.push({ icon: "recording", label: "Video", value: parts.filter(s => s !== "").join(" - ") })
  } else if (a["Format"] !== undefined) {
    const parts = [String(a["Format"]).trim()]
    if (a["Channel(s)"]) parts.push(String(a["Channel(s)"]).trim())
    if (a["Sampling rate"]) parts.push(String(a["Sampling rate"]).trim())
    rows.push({ icon: "speaker", label: "Audio", value: parts.filter(s => s !== "").join(" - ") })
  }
  return rows
}

// Folder card rows from the entry's own probe fields - no spawn, no
// walk: the capture-time file-info report already counted the files
// inside and their bytes, so the card is free. A field the probe has
// not delivered yet omits its row instead of faking one.
function folderInfoRows(entry) {
  const rows = []
  // Multiple folders (allFolders): reuse the card shape with an aggregate
  // count, file count and total size. The entry keeps its "files" type,
  // flagged allFolders so the shape is not confused with mixed selections.
  if (entry && entry.allFolders === true) {
    const paths = Array.isArray(entry.filePaths) ? entry.filePaths : []
    if (paths.length > 0)
      rows.push({ icon: "file-folders", label: "Folders",
        value: paths.length + (paths.length === 1 ? " folder" : " folders") })
    const fc = entry.folderCount
    if (typeof fc === "number" && fc >= 0)
      rows.push({ icon: "files", label: "Files", value: fc + (fc === 1 ? " file" : " files") })
    const b = entry.totalSize
    if (typeof b === "number" && b > 0)
      rows.push({ icon: "save", label: "Size", value: formatSize(b) })
    return rows
  }
  const p = entry && entry.filePaths && entry.filePaths.length === 1
    ? String(entry.filePaths[0]) : ""
  if (p !== "") {
    const base = mediaBaseName(p)
    rows.push({ icon: "file-folder", label: "Folder", value: base !== "" ? base : p })
  }
  const n = entry ? entry.folderCount : undefined
  if (typeof n === "number" && n >= 0)
    rows.push({ icon: "files", label: "Files", value: n + (n === 1 ? " file" : " files") })
  const b = entry ? entry.fileSize : undefined
  if (typeof b === "number" && b > 0)
    rows.push({ icon: "save", label: "Size", value: formatSize(b) })
  return rows
}

function isTextMime(mime) {
  const m = String(mime).toLowerCase()
  if (m.indexOf("charset=binary") >= 0) return false
  if (m.indexOf("application/x-executable") >= 0) return false
  if (m.indexOf("application/x-sharedlib") >= 0) return false
  if (m.indexOf("application/zip") >= 0) return false
  if (m.indexOf("application/gzip") >= 0) return false
  if (m.indexOf("application/x-7z") >= 0) return false
  if (m.indexOf("application/x-rar") >= 0) return false
  if (m.indexOf("application/zstd") >= 0) return false
  if (m.indexOf("application/pdf") >= 0) return false
  if (m.indexOf("application/vnd.") >= 0) return false
  return true
}

// JS-side parsers - keep shell minimal, do aggregation here.
// --- controller-side result parsing ---
//
// Each of these turns one child's stdout into a value the controller can
// branch on, or null when the output says the read produced nothing. They
// hold no Process and read no controller state, so the whole decision half of
// the read pipeline is unit-drivable from a recorded stdout - no compositor,
// no wl-paste, and no clipboard.

// `wl-paste --list-types`: which of the three read routes a paste takes.
// hasUri wins over an embedded image, exactly as the read path orders them.
function parseTypeList(text) {
  const raw = String(text || "").trim()
  const types = raw === "" ? [] : raw.split("\n").map(s => s.trim()).filter(s => s !== "")
  let hasUri = false
  let imageType = ""
  for (let i = 0; i < types.length; i++) {
    const t = types[i].toLowerCase()
    if (t.indexOf("text/uri-list") >= 0) hasUri = true
    if (imageType === "" && t.indexOf("image/") === 0) imageType = types[i]
  }
  return { types, hasUri, hasImage: imageType !== "", imageType }
}

// Image snapshot stdout: "<size>\n<sha>  <path>". The EMPTY marker and the
// child's own failure are the controller's to notice; a non-positive size or
// a missing digest means there is no snapshot to offer. A size that is not a
// number at all is not a non-positive one, so it passes here exactly as it
// did when the arithmetic was inline - the entry simply never matches an
// existing sha+size pair.
function parseSnapshotOutput(text) {
  const lines = String(text).trim().split("\n").map(s => s.trim()).filter(s => s !== "")
  const size = parseInt(lines[0] || "0", 10)
  const sha = (lines[1] || "").split(/\s+/)[0] || ""
  if (size <= 0 || sha === "") return null
  return { size, sha }
}

// `identify` stdout: "WxH". Anything else leaves the entry's dimensions alone
// rather than writing a zero.
function parseDimOutput(text) {
  const m = String(text).trim().split(/\s+/)
  const w = parseInt(m[0] || "0", 10)
  const h = parseInt(m[1] || "0", 10)
  if (w > 0 && h > 0) return { w, h }
  return null
}

// Text probe stdout: "<mime>\n__HEAD__\n<head>". A child that never reached
// the file emits the binary marker and an empty head, so a missing separator
// yields the whole output as the mime and an empty body.
function parseTextProbeOutput(text) {
  const raw = String(text)
  const sep = "__HEAD__\n"
  const idx = raw.indexOf(sep)
  if (idx >= 0)
    return { mime: raw.substring(0, idx).trim(), body: raw.substring(idx + sep.length) }
  return { mime: raw.trim(), body: "" }
}

// File info stdout, aggregated in JS so the shell only walks sizes.
// The DIR/FILE/MISSING chunks are the only protocol. `entryKnown` is the
// one piece of controller state the fallback branch reaches for: an
// unlabelled single-path dump is read as a directory only when the row it
// would patch is still in history. null means the report named nothing, so
// the entry keeps its pending shape.
function parseFileInfoReport(text, entryKnown) {
  const body = String(text).trim()
  if (body === "") return null
  const lines = body.split("\n").map(s => s.trim())
  let folders = 0, files = 0, innerFiles = 0, bytes = 0
  let mode = ""
  let curCount = 0, curSum = 0
  const flush = () => {
    if (mode === "DIR") { folders++; innerFiles += curCount; bytes += curSum }
    else if (mode === "FILE") { files++; bytes += curSum }
    curCount = 0; curSum = 0; mode = ""
  }
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i]
    if (line === "") continue
    if (line === "DIR" || line.startsWith("DIR ")) { flush(); mode = "DIR"; continue }
    if (line === "FILE" || line.startsWith("FILE ")) { flush(); mode = "FILE"; continue }
    if (line.startsWith("MISSING") || line === "ENDDIR" || line === "ENDFILE" || line === "ENDMISSING") {
      if (line.startsWith("END")) flush()
      continue
    }
    // Bounded-walk aggregate: "<count> <bytes>" from the awk sum. A capped
    // walk prints TOOBIG instead, which falls through as non-numeric and
    // leaves the chunk empty (a bounded undercount, never a wedge).
    const agg = line.match(/^(\d+)\s+(\d+)$/)
    if (agg !== null && mode === "DIR") {
      curCount += parseInt(agg[1], 10)
      curSum += parseInt(agg[2], 10)
      continue
    }
    const n = parseInt(line, 10)
    if (!isNaN(n)) { curCount++; curSum += n }
  }
  flush()
  // Unlabelled sizes: one path, no headers. A run of more than one size
  // came from find, so it is a directory - but only for a row that is still
  // in history to receive that verdict.
  if (folders === 0 && files === 0 && lines.length > 0
    && !body.includes("DIR") && !body.includes("FILE")) {
    let c = 0, s = 0
    for (let i = 0; i < lines.length; i++) {
      const n = parseInt(lines[i], 10)
      if (!isNaN(n)) { c++; s += n }
    }
    if (c > 0) {
      if (entryKnown === true && c > 1) { folders = 1; innerFiles = c; bytes = s }
      else { files = 1; bytes = s }
    }
  }
  if (folders === 0 && files === 0) return null
  return { folders, files, innerFiles, bytes }
}

// The persisted history document. Accepted shapes: a bare array, an
// object keyed entries/history/data, and an object carrying its own `key`.
function parseHistoryDocument(text) {
  const body = String(text)
  let obj = null
  try { obj = JSON.parse(body) } catch (e) { obj = null }
  let entries = []
  let key = ""
  if (Array.isArray(obj)) {
    entries = obj
  } else if (obj && typeof obj === "object") {
    if (typeof obj.key === "string" && obj.key !== "") key = String(obj.key)
    if (Array.isArray(obj.entries)) entries = obj.entries
    else if (Array.isArray(obj.history)) entries = obj.history
    else if (Array.isArray(obj.data)) entries = obj.data
    else entries = []
  }
  return { entries, key }
}

// --- model projections ---
//
// The derivations that turn a payload plus its metadata into the row the list
// renders, searches, and persists. `id` and `ts` are parameters rather than
// reads of a clock or a counter so a suite can pin a row's shape exactly.

// Every field a row may carry, so every creator shares identical hygiene and
// patch sites re-derive rather than hand-maintain.
function newEntry(id, ts, raw, mime, type, filePaths, preview) {
  return {
    id: id,
    ts: ts,
    raw: String(raw === undefined ? "" : raw),
    mime: String(mime || "text/plain"),
    type: type,
    icon: "",
    title: "",
    subLeft: "",
    hay: "",
    words: [],
    pinned: false,
    preview: preview === undefined ? "" : String(preview),
    filePaths: filePaths || [],
    fileSize: undefined,
    totalSize: undefined,
    folderCount: undefined,
    foldersCount: 0,
    allFolders: false,
    imageW: 0,
    imageH: 0,
    imageFile: "",
    imageDataFile: "",
    imageSha: "",
    // Lazily gathered folder payload (git verdict), persisted per entry and
    // revalidated in the background - never recomputed from the row itself.
    git: null,
    pathLike: false,
    secretHandle: "",
    unavailable: false,
    missing: false,
    missingText: ""
  }
}

// Recompute the display fields after any mutation. Never logs an entry
// payload: titles count words, they do not carry content.
function deriveEntry(e, use12h) {
  buildTitleSub(e)
  e.subLeft = buildSubLeft(e)
  e.timeStr = formatTime(e.ts, undefined, use12h === true)
  e.hay = hayFor(e)
  e.words = wordsFor(e.hay)
  return e
}

// Every path this entry references, in the order the snapshot GC and the
// pending-copy matcher need them. A uri-list in any single slot is expanded
// to its local paths; a bare absolute path is taken as is.
function entryPaths(entry) {
  const paths = []
  const add = value => {
    const raw = String(value == null ? "" : value)
    if (raw === "") return
    if (raw.toLowerCase().indexOf("file://") === 0) {
      const parsed = parseUriList(raw)
      for (let i = 0; i < parsed.length; i++) paths.push(parsed[i])
    } else if (raw.charAt(0) === "/") {
      paths.push(raw)
    }
  }
  if (entry === null || entry === undefined) return paths
  add(entry.imageDataFile)
  add(entry.imageFile)
  if (Array.isArray(entry.filePaths)) {
    for (let i = 0; i < entry.filePaths.length; i++) add(entry.filePaths[i])
  }
  return paths
}

// The mode filter and the search in one step, so the list a panel binds and
// the count it reports cannot come from two different passes.
function selectEntries(history, mode, query) {
  const src = String(mode) === "pinned"
    ? (history || []).filter(e => e.pinned)
    : (history || []).filter(e => !e.pinned)
  const q = String(query).trim()
  if (q === "") return src
  return searchEntries(src, q, 200)
}

// One persisted row. A credential is written only as a tombstone: a live one
// has a payload in memory that no key can protect on disk, and an
// unavailable one is kept so the row stays visible in the list.
function exportEntry(e) {
  if (e.type === "secret" && e.unavailable !== true) return null
  const o = {
    id: e.id, ts: e.ts, type: e.type, mime: e.mime, pinned: e.pinned,
    filePaths: e.filePaths || [], imageFile: e.imageFile || "",
    imageDataFile: e.imageDataFile || "", imageSha: e.imageSha || "",
    git: (e.git && typeof e.git === "object") ? e.git : null,
    fileSize: e.fileSize,
    totalSize: e.totalSize, folderCount: e.folderCount,
    foldersCount: e.foldersCount || 0, allFolders: e.allFolders === true,
    imageW: e.imageW || 0, imageH: e.imageH || 0, folderItems: e.folderItems,
    missing: e.missing === true,
    missingText: typeof e.missingText === "string" ? e.missingText : "",
    preview: e.type === "secret" ? "" : (typeof e.preview === "string" ? e.preview : ""),
    raw: e.type === "secret" ? "" : (typeof e.raw === "object" ? "" : (e.raw || ""))
  }
  if (e.unavailable === true) o.unavailable = true
  return o
}

function exportEntries(history) {
  const out = []
  for (let i = 0; i < (history || []).length; i++) {
    const o = exportEntry(history[i])
    if (o !== null) out.push(o)
  }
  return out
}

// The anatomy a file info report lands on. A single folder is the real
// verdict, so the plain-file guess the uri-list read made is corrected; a
// multi-selection keeps its shape and gains the counts.
function projectFileInfo(entry, report) {
  const n = entry.filePaths.length
  if (n === 1) {
    if (report.folders === 1) {
      entry.type = "folder"
      entry.folderCount = report.innerFiles
      entry.fileSize = report.bytes > 0 ? report.bytes : undefined
      entry.folderItems = entry.folderItems || []
    } else {
      entry.fileSize = report.bytes
    }
    return entry
  }
  entry.foldersCount = report.folders
  entry.folderCount = report.innerFiles
  entry.totalSize = report.bytes
  entry.allFolders = report.folders === n
  if (entry.type !== "image" && entry.type !== "archive") entry.type = "files"
  return entry
}

