.pragma library

// Pure parsers for the downloader module: yt-dlp's --info table and the TSV
// history the CLI appends after a successful download. Kept free of QML so the
// JS suite can exercise both shapes headlessly.

// yt-dlp's --list-formats table is four '|'-separated sections:
//
//   ID EXT RESOLUTION FPS CH | FILESIZE TBR PROTO | VCODEC VBR ACODEC ABR ASR | MORE INFO
//
// Header rows, separators and [youtube]/[info] progress lines are not formats.
// A byte unit is what names the size: an HLS row leaves FILESIZE blank, so the
// first token of that section is the PROTO ("m3u8") and reading positionally
// puts the protocol in the size column. The section's only token carrying a
// unit is the file size; TBR ("49k") and PROTO ("https") never do.
var SIZE_TOKEN = /^\d+(?:\.\d+)?(?:B|KiB|MiB|GiB|TiB)$/

function parseInfo(text) {
  const out = []
  const lines = String(text || "").split("\n")
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i]
    if (line.indexOf("---") >= 0) continue
    if (line.indexOf(" ID ") === 0 || line.indexOf("ID ") === 0) continue
    if (line.charAt(0) === "[") continue
    const trimmed = line.replace(/^\s+/, "")
    if (trimmed === "") continue
    const fields = trimmed.split(/\s+/)
    const id = fields[0]
    if (!id || id === "ID") continue
    const ext = fields[1] || ""
    const resolution = fields[2] || ""
    // FPS follows the resolution, and only when it is a number: an audio row
    // spends that slot on the second word of "audio only".
    const fps = /^\d+$/.test(fields[3] || "") ? Number(fields[3]) : 0
    const parts = line.split("|")
    let size = ""
    if (parts.length > 1) {
      const tokens = parts[1].trim().split(/\s+/)
      for (let k = 0; k < tokens.length; k++) {
        if (SIZE_TOKEN.test(tokens[k])) {
          size = tokens[k]
          break
        }
      }
    }
    // "audio only" / "video only" mark a DASH stream that carries one half;
    // a progressive row names both codecs and carries neither marker.
    let kind = "both"
    if (/audio only/.test(line)) kind = "audio"
    else if (/video only/.test(line)) kind = "video"
    const note = parts.length > 1 ? parts[parts.length - 1].trim() : ""
    out.push({
      id: id,
      ext: ext,
      resolution: resolution,
      fps: fps,
      kind: kind,
      size: size,
      note: note
    })
  }
  return out
}

// Only formats that can actually be picked: skip storyboard rows and require
// a plausible id. videoOnly rows keep resolution; audio rows say "audio".
//
// The order is yt-dlp's. What the table shows is a sort projection over this
// set (see sortFormats), so the fetch stays the fetch.
function pickableFormats(text) {
  const all = parseInfo(text)
  const out = []
  for (let i = 0; i < all.length; i++) {
    const f = all[i]
    if (f.ext === "mhtml") continue
    if (f.id.indexOf("sb") === 0) continue
    out.push(f)
  }
  return out
}

// --- sorting -----------------------------------------------------------
//
// The table headers sort these rows, so the comparators live here and the
// island stays a view. Keys are the column names: resolution, fps, format,
// kind, size.
//
// A row that cannot answer a key (an audio row has no resolution) sorts after
// the rows that can, in EITHER direction: absent is not "the smallest", it is
// unknown, and flipping the sort must not promote it to the top.

var KIND_RANK = { audio: 0, video: 1, both: 2 }
var SIZE_UNITS = { B: 1, KiB: 1024, MiB: 1048576, GiB: 1073741824,
  TiB: 1099511627776 }

function resolutionPixels(row) {
  const m = String(row && row.resolution || "").match(/^(\d+)x(\d+)$/)
  if (m === null) return 0
  return Number(m[1]) * Number(m[2])
}

function sizeBytes(raw) {
  const m = String(raw || "").match(/^(\d+(?:\.\d+)?)(B|KiB|MiB|GiB|TiB)$/)
  if (m === null) return -1
  return Number(m[1]) * SIZE_UNITS[m[2]]
}

// -1 is the "this row cannot answer" value every key shares.
function sortValue(row, key) {
  if (key === "resolution") return resolutionPixels(row) > 0 ? resolutionPixels(row) : -1
  if (key === "fps") {
    const n = Number(row && row.fps)
    return isFinite(n) && n > 0 ? n : -1
  }
  if (key === "format") {
    const ext = String(row && row.ext || "").toLowerCase()
    return ext === "" ? "" : ext
  }
  if (key === "kind") {
    const k = String(row && row.kind || "")
    return KIND_RANK[k] === undefined ? -1 : KIND_RANK[k]
  }
  if (key === "size") return sizeBytes(row && row.size)
  return -1
}

function sortFormats(rows, key, direction) {
  const list = Array.isArray(rows) ? rows.slice() : []
  const k = String(key || "")
  const desc = String(direction || "") === "desc"
  const known = []
  const unknown = []
  for (let i = 0; i < list.length; i++) {
    const v = sortValue(list[i], k)
    if (v === -1 || v === "") unknown.push(list[i])
    else known.push({ row: list[i], v: v, at: i })
  }
  known.sort((a, b) => {
    let d = 0
    if (typeof a.v === "number" && typeof b.v === "number") d = a.v - b.v
    else d = a.v < b.v ? -1 : (a.v > b.v ? 1 : 0)
    // Equal values keep the order they arrived in, whichever way the column
    // is sorted: flipping a tie would shuffle rows for no reason.
    if (d === 0) return a.at - b.at
    return desc ? -d : d
  })
  const out = known.map(entry => entry.row)
  for (let i = 0; i < unknown.length; i++) out.push(unknown[i])
  return out
}

// --- format table projection -------------------------------------------
//
// The table's model is at least `windowSize` rows long: live formats plus
// fillers holding the footprint of the rows that are not there. A filler is
// not a format, so the delegate paints a skeleton bar for it and the keyboard
// cursor never stops on one.
var FILLER = { filler: true }

function rowWindow(rows, windowSize) {
  const list = Array.isArray(rows) ? rows : []
  if (list.length >= windowSize) return list
  const out = list.slice()
  for (let i = list.length; i < windowSize; i++) out.push(FILLER)
  return out
}

function isFiller(row) {
  return !row || typeof row !== "object" || row.filler === true
}

// A cell with nothing to say says so: a blank in a table reads as a bug, a
// dash reads as a value that is not there.
function cellLabel(text) {
  const s = text === undefined || text === null ? "" : String(text).trim()
  return s === "" ? "-" : s
}

// The primary cell of a format row: what a person picks by. yt-dlp reports the
// word "audio" as the resolution of an audio-only row, which the kind column
// already says, so that cell reads as absent rather than repeating it.
function formatLabel(row) {
  if (isFiller(row)) return ""
  const res = String(row.resolution || "").trim()
  if (res === "" || String(row && row.kind || "").trim() === "audio") return "-"
  return res
}

// The frame-rate cell: a bare number, so a column of them compares at a glance.
function fpsLabel(row) {
  if (isFiller(row)) return ""
  const n = Number(row && row.fps)
  return cellLabel(isFinite(n) && n > 0 ? String(n) : "")
}

// The container cell: the extension the stream lands in before the wrapper
// remuxes it, which is what tells two same-resolution rows apart.
function extLabel(row) {
  if (isFiller(row)) return ""
  return cellLabel(row && row.ext)
}

// Container to theme color. The palette is the theme's own accent set, so the
// coding travels with the theme instead of hard-coding hexes here. Anything
// unknown reads as ordinary foreground rather than as a made-up color.
var FILETYPE_KEYS = {
  mp4: "blue", m4v: "blue",
  webm: "green", mkv: "cyan", mov: "cyan", avi: "cyan", flv: "cyan",
  m4a: "orange", mp3: "purple", opus: "purple", ogg: "purple",
  oga: "purple", flac: "purple", wav: "purple"
}

function filetypeKey(ext) {
  const k = String(ext || "").trim().toLowerCase()
  if (k === "") return "foreground_1"
  if (!Object.prototype.hasOwnProperty.call(FILETYPE_KEYS, k)) return "foreground_1"
  return FILETYPE_KEYS[k]
}

// The audio/video cell: what the download lands with, in the column's own
// short hand. A video-only row is muxed with the best audio by
// downloadSelector below, so it lands with sound and says so - "v+a", video
// plus the audio added for it. A row whose stream already carries both reads
// "a+v": the order is what tells the two combined states apart, alongside the
// color, so no video row ever reads as silent.
function kindLabel(row) {
  if (isFiller(row)) return ""
  const kind = String(row.kind || "").trim()
  if (kind === "audio") return "a"
  if (kind === "video") return "v+a"
  if (kind === "both") return "a+v"
  return ""
}

// The same three states as palette leaves: the sound on its own is the warm
// one, a video-only stream the cool one, and a stream that already carries
// both the "go" green - so a row says what it holds before the cell is read.
var KIND_KEYS = { audio: "orange", video: "blue", both: "green" }

function kindKey(row) {
  if (isFiller(row)) return "foreground_1"
  const k = String(row && row.kind || "").trim()
  if (!Object.prototype.hasOwnProperty.call(KIND_KEYS, k)) return "foreground_1"
  return KIND_KEYS[k]
}

// The selector the wrapper hands to yt-dlp for a picked row. A video-only row
// carries no sound, so asking for that id alone would write a silent file: the
// pick brings the best audio with it, and the row itself stays the fallback for
// the videos that have no separate audio track to merge.
function downloadSelector(row) {
  if (!row || isFiller(row)) return ""
  const id = String(row.id || "").trim()
  if (id === "") return ""
  if (String(row.kind || "").trim() === "video") return id + "+bestaudio/" + id
  return id
}

// Column widths from the widest measured cell. Both value columns are capped
// so long strings cannot eat the primary one; whatever is left belongs to the
// resolution column. The narrow FPS and FORMAT columns are measured directly
// and need no arithmetic of their own.
function formatColumns(kindWidth, sizeWidth, viewport, rowChrome, caps) {
  // Two pixels of slack on the size: it is the column that ends a row, and a
  // measurement that lands exactly on the text width elides on rounding.
  let size = Math.ceil(sizeWidth) + 2
  size = Math.max(caps.minSize, Math.min(caps.sizeCap, size))
  let kind = Math.ceil(kindWidth) + 2
  kind = Math.max(caps.minKind,
    Math.min(Math.max(caps.minKind, viewport - rowChrome - size), kind))
  return { kind: kind, size: size }
}

// A title or a path can carry a tab or a newline (both are legal in a
// filename), and the CLI writes them escaped so one download is always one
// row. Unknown escapes stay literal, so an old line is read as written.
function unescapeField(text) {
  const s = String(text || "")
  let out = ""
  for (let i = 0; i < s.length; i++) {
    const c = s.charAt(i)
    if (c !== "\\") {
      out += c
      continue
    }
    const n = s.charAt(i + 1)
    if (n === "t") { out += "\t"; i++ }
    else if (n === "n") { out += "\n"; i++ }
    else if (n === "r") { out += "\r"; i++ }
    else if (n === "\\") { out += "\\"; i++ }
    else out += c
  }
  return out
}

// History rows are: timestamp \t title \t size \t path \t url \t format.
// The format column is newer than the rest, so an older line simply has none -
// which is not a match for anything, rather than a match for everything.
function parseHistory(text) {
  const out = []
  const lines = String(text || "").split("\n")
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].replace(/\r$/, "")
    if (line.trim() === "") continue
    const f = line.split("\t")
    if (f.length < 4) continue
    out.push({
      timestamp: unescapeField(f[0] || ""),
      title: unescapeField(f[1] || ""),
      size: unescapeField(f[2] || ""),
      path: unescapeField(f[3] || ""),
      url: unescapeField(f[4] || ""),
      format: unescapeField(f[5] || "")
    })
  }
  return out
}

// A playlist batch writes one row for its folder. The selector field carries
// `playlist` or `playlist:<tag>` so the row can be recognised without guessing
// from the path; a file row uses an engine and a media row uses a format id.
function isPlaylistHistory(row) {
  const format = String(row && row.format || "")
  return format === "playlist" || format.indexOf("playlist:") === 0
}

// The sidecar behind playlist history: folder \t entry URL \t entry file. One
// line per finished entry keeps the held ticks working while history stays one
// row for the whole batch.
function parsePlaylistLedger(text) {
  const out = []
  const lines = String(text || "").split("\n")
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].replace(/\r$/, "")
    if (line.trim() === "") continue
    const f = line.split("\t")
    if (f.length < 3) continue
    const folder = unescapeField(f[0] || "")
    const url = unescapeField(f[1] || "")
    const path = unescapeField(f[2] || "")
    if (folder === "" || url === "" || path === "") continue
    out.push({ folder: folder, url: url, path: path })
  }
  return out
}

function attachPlaylistEntries(history, ledger) {
  const rows = Array.isArray(history) ? history.slice() : []
  const entries = Array.isArray(ledger) ? ledger : []
  const byFolder = {}
  for (let i = 0; i < rows.length; i++) {
    if (!isPlaylistHistory(rows[i])) continue
    rows[i].entries = []
    const folder = String(rows[i].path || "")
    if (folder === "") continue
    if (!byFolder[folder]) byFolder[folder] = []
    byFolder[folder].push(rows[i])
  }
  for (let i = 0; i < entries.length; i++) {
    const targets = byFolder[entries[i].folder]
    if (!targets) continue
    for (let k = 0; k < targets.length; k++) targets[k].entries.push(entries[i])
  }
  return rows
}

// Preview output from the CLI: first line title, second line thumbnail URL.
function parsePreview(text) {
  const lines = String(text || "").split("\n")
  return {
    title: lines[0] || "",
    thumbnail: lines[1] || ""
  }
}

// --- clipboard --------------------------------------------------------
//
// yt-dlp supports thousands of sites, so an island that auto-filled whatever
// happened to be on the clipboard would be guessing. It only does that for the
// handful a copy is overwhelmingly likely to be: a plain link naming one of
// these hosts. A miss is not an error - it leaves the field empty for the next
// paste, and Ctrl+V in the field still takes anything the user copied.
var MAINSTREAM_HOSTS = [
  "youtube.com", "youtu.be", "youtube-nocookie.com",
  "x.com", "twitter.com",
  "reddit.com", "redd.it",
  "bsky.app",
  "instagram.com",
  "tiktok.com",
  "vimeo.com",
  "twitch.tv",
  "facebook.com", "fb.watch",
  "soundcloud.com",
  "dailymotion.com", "dai.ly",
  "streamable.com"
]

// A copied link routinely arrives wrapped or punctuated: "(https://...)",
// "https://...," or a quoted share sheet. The wrappers are not part of the
// URL, and filling them in would hand a tool a link with a comma on the end.
// A token containing whitespace is a sentence, not a URL; the caller scans the
// words of such a line instead of treating the whole line as one link.
function linkToken(token) {
  const raw = String(token || "").trim()
    .replace(/^[([{"'<]+/, "")
    .replace(/[)\]}"'>.,;:!?]+$/, "")
  if (raw === "" || /\s/.test(raw)) return ""
  const match = raw.match(/^(?:[a-z]+:\/\/)?((?:[a-z0-9-]+\.)+[a-z]{2,})(?:[/?#]|$)/i)
  if (match === null) return ""
  return raw
}

// A single token as a URL worth auto-filling: a host - with any subdomain -
// has to be in the list above. Anything that is not itself a URL token
// answers "". This is the conservative auto-fill filter; the preview pane
// uses `clipboardLink` because a direct file is a legitimate paste too.
function urlToken(token) {
  const raw = linkToken(token)
  if (raw === "") return ""
  const match = raw.match(/^(?:[a-z]+:\/\/)?((?:[a-z0-9-]+\.)+[a-z]{2,})(?:[/?#]|$)/i)
  const host = match[1].toLowerCase()
  for (let i = 0; i < MAINSTREAM_HOSTS.length; i++) {
    const h = MAINSTREAM_HOSTS[i]
    if (host === h || host.slice(-h.length - 1) === "." + h) return raw
  }
  return ""
}

// The first URL token in the clipboard, mainstream or direct file. The preview
// pane is a paste affordance for any link the downloader can classify, not
// only the media hosts auto-filled on open.
function clipboardLink(text) {
  const raw = String(text || "").trim()
  if (raw === "") return ""
  const whole = linkToken(raw)
  if (whole !== "") return whole
  const words = raw.split(/\s+/)
  for (let i = 0; i < words.length; i++) {
    const hit = linkToken(words[i])
    if (hit !== "") return hit
  }
  return ""
}

// The PRIMARY selection behind a middle-click is a direct download request,
// not a paste affordance. It is a link only when the whole selection is one
// token: prose that happens to contain a URL is still prose, and a sentence
// around a remembered link must not start a background download. The preview
// pane keeps the broader `clipboardLink` scan for an explicit paste.
function primaryLink(text) {
  const raw = String(text || "").trim()
  if (raw === "" || /\s/.test(raw)) return ""
  return linkToken(raw)
}

// Middle-click has no card in which to ask which engine to use. A verdict that
// names a type keeps its engine; an unknown verdict takes the File path with
// wget instead of aborting. This mirrors the island's File chip, while a
// classifier that names aria2c or yt-dlp keeps that choice.
function primaryTool(verdict) {
  const kind = String(verdict && verdict.kind || "unknown")
  const engine = String(verdict && verdict.engine || "")
  return kind === "unknown" || engine === "" ? "wget" : engine
}

// The clipboard text as a URL worth auto-filling, or "" when it is not one.
// The common case is the link alone; the next is a copied line carrying a
// title around it (a share sheet, a chat message), so when the whole text is
// not one token the words are scanned for the first mainstream link. A miss is
// not an error - the field stays empty.
function clipboardUrl(text) {
  const link = clipboardLink(text)
  if (link === "") return ""
  return urlToken(link) === link ? link : ""
}

// Did yt-dlp refuse the URL itself rather than fail a transfer? Only these
// answers justify the "not a video" hint: a network error, an age gate or a
// missing format must not be presented as the link being the wrong kind.
function videoUnsupported(text) {
  const s = String(text || "")
  if (s === "") return false
  return /unsupported url/i.test(s)
    || /is not a valid url/i.test(s)
    || /no video formats found/i.test(s)
    || /not a video/i.test(s)
}

// --- url classification -------------------------------------------------
//
// What the link is, before any tool runs. This is the offline half of the
// dispatcher's decision: a known media host or a streaming manifest is media,
// a path that names a file is a direct file, and anything else stays unknown
// until a content-type probe answers. The answer is a value, not a side
// effect, so the island can show the engine it chose and the user can
// override it.
//
// The host list is deliberately separate from MAINSTREAM_HOSTS above: that
// one decides what the clipboard may auto-fill, this one decides what yt-dlp
// owns. Widening one must not silently widen the other.
var MEDIA_HOSTS = [
  "youtube.com", "youtu.be", "youtube-nocookie.com",
  "vimeo.com",
  "dailymotion.com", "dai.ly",
  "twitch.tv",
  "soundcloud.com",
  "x.com", "twitter.com",
  "instagram.com",
  "tiktok.com",
  "facebook.com", "fb.watch",
  "reddit.com", "redd.it",
  "bilibili.com", "b23.tv",
  "rumble.com",
  "streamable.com",
  "bsky.app",
  "kick.com",
  "nicovideo.jp",
  "bandcamp.com",
  "mixcloud.com",
  "odysee.com"
]

// A manifest is media even on a host nobody listed: yt-dlp is what turns an
// HLS or DASH playlist into a file.
var STREAM_EXTENSIONS = { m3u8: 1, mpd: 1 }

// Extensions that name a file rather than a page. HTML is deliberately absent:
// a .html path is a page to read, not a file to fetch, and guessing otherwise
// is how a downloader saves an error page.
var FILE_EXTENSIONS = {
  "7z": 1, apk: 1, appimage: 1, avi: 1, bz2: 1, cab: 1, csv: 1, deb: 1,
  dmg: 1, doc: 1, docx: 1, epub: 1, exe: 1, flac: 1, gif: 1, gz: 1,
  img: 1, iso: 1, jpeg: 1, jpg: 1, json: 1, lz: 1, lz4: 1, m4a: 1,
  mkv: 1, mobi: 1, mov: 1, mp3: 1, mp4: 1, msi: 1, odt: 1, ogg: 1,
  opus: 1, pdf: 1, pkg: 1, png: 1, ppt: 1, pptx: 1, rar: 1, rpm: 1,
  tar: 1, tgz: 1, torrent: 1, ttf: 1, txt: 1, wav: 1, webm: 1, webp: 1,
  xls: 1, xlsx: 1, xz: 1, zip: 1, zst: 1
}

function classification(kind, engine, reason) {
  return { kind: kind, engine: engine, reason: reason }
}

function hostMatches(host, domain) {
  return host === domain || host.slice(-domain.length - 1) === "." + domain
}

function isMediaHost(host) {
  for (let i = 0; i < MEDIA_HOSTS.length; i++) {
    if (hostMatches(host, MEDIA_HOSTS[i])) return true
  }
  return false
}

// The path's extension, or "" when there is none. A trailing slash is a
// directory, a leading dot is a hidden name, and a ;parameter is not part of
// the name - none of those is a file extension.
function pathExtension(path) {
  let name = String(path || "")
  if (name === "" || name.charAt(name.length - 1) === "/") return ""
  const slash = name.lastIndexOf("/")
  name = slash < 0 ? name : name.slice(slash + 1)
  const semi = name.indexOf(";")
  if (semi >= 0) name = name.slice(0, semi)
  const dot = name.lastIndexOf(".")
  if (dot <= 0 || dot === name.length - 1) return ""
  return name.slice(dot + 1).toLowerCase()
}

// Host and path from a link that has already had its scheme removed. The
// query and fragment are dropped: a filename in a query ("?file=a.pdf") is
// not the path's filename. Userinfo and a port are not part of the host.
function splitLink(text) {
  let rest = text
  const hash = rest.indexOf("#")
  if (hash >= 0) rest = rest.slice(0, hash)
  const query = rest.indexOf("?")
  if (query >= 0) rest = rest.slice(0, query)
  const slash = rest.indexOf("/")
  let host = slash < 0 ? rest : rest.slice(0, slash)
  const path = slash < 0 ? "" : rest.slice(slash)
  const at = host.lastIndexOf("@")
  if (at >= 0) host = host.slice(at + 1)
  if (host.charAt(0) === "[") {
    const close = host.indexOf("]")
    if (close >= 0) host = host.slice(1, close)
  } else {
    const colon = host.indexOf(":")
    if (colon >= 0) host = host.slice(0, colon)
  }
  host = host.toLowerCase()
  if (host.slice(-1) === ".") host = host.slice(0, -1)
  return { host: host, path: path }
}

// What the link is: media, a direct file, or unknown. The reason is part of
// the answer, not a log line: the island shows it beside the engine, and the
// dispatcher uses it to decide whether a probe is still needed.
function classifyUrl(raw) {
  let text = String(raw === undefined || raw === null ? "" : raw).trim()
  if (text === "") return classification("unknown", "", "empty input")
  if (/^magnet:/i.test(text)) return classification("file", "aria2c", "magnet link")

  const schemeMatch = text.match(/^([a-z][a-z0-9+.-]*):\/\//i)
  if (schemeMatch !== null) {
    const scheme = schemeMatch[1].toLowerCase()
    if (scheme === "ftp") return classification("file", "wget", "ftp url")
    if (scheme === "ftps") return classification("file", "aria2c", "ftps url")
    if (scheme === "sftp") return classification("file", "aria2c", "sftp url")
    if (scheme !== "http" && scheme !== "https") {
      return classification("unknown", "", "unsupported scheme")
    }
    text = text.slice(schemeMatch[0].length)
  } else if (/^[a-z][a-z0-9+.-]*:/.test(text)) {
    // A host:port is not a scheme. Anything else before the colon names a
    // protocol this downloader does not fetch.
    const after = text.slice(text.indexOf(":") + 1)
    if (!/^\d+(?:\/|$)/.test(after)) {
      return classification("unknown", "", "unsupported scheme")
    }
  }
  if (schemeMatch === null) {
    if (!/^[^\s/]+\.[^\s/]+/.test(text)
      && !/^localhost(?::\d+)?(?:\/|$)/i.test(text)) {
      return classification("unknown", "", "not a url")
    }
  }

  const link = splitLink(text)
  if (link.host === "") return classification("unknown", "", "missing host")
  if (isMediaHost(link.host)) return classification("media", "yt-dlp", "media host")
  const ext = pathExtension(link.path)
  if (STREAM_EXTENSIONS[ext] === 1) {
    return classification("media", "yt-dlp", "streaming manifest")
  }
  if (FILE_EXTENSIONS[ext] === 1) {
    return classification("file", "wget", "direct file extension")
  }
  return classification("unknown", "", "needs content-type probe")
}

// The filename a direct file link will land as. It mirrors the dispatcher's
// Bash resolver: the path after the host, percent-decoded, slashes flattened,
// control characters gone, dots-only rejected, and the same 200-character
// bound. The dispatcher still chooses the collision suffix.
function decodePercent(text) {
  const s = String(text || "")
  try {
    return decodeURIComponent(s)
  } catch (e) {
    // A malformed escape is not a reason to drop the whole name: decode the
    // well-formed ones and leave the rest as written.
    return s.replace(/%([0-9A-Fa-f]{2})/g, (_m, hex) =>
      String.fromCharCode(parseInt(hex, 16)))
  }
}

function fileName(raw) {
  let rest = String(raw || "").trim()
    .replace(/^[a-z][a-z0-9+.-]*:\/\//i, "")
  const slash = rest.indexOf("/")
  let path = slash < 0 ? "" : rest.slice(slash + 1)
  path = path.replace(/[?#].*$/, "").replace(/\/+$/, "")
  let name = path.slice(path.lastIndexOf("/") + 1)
  name = decodePercent(name).replace(/\//g, "_")
  name = name.replace(/[\u0000-\u001f\u007f]/g, "").trim()
  if (name === "" || name === "." || name === "..") name = "download"
  if (name.length > 200) name = name.slice(0, 200)
  return name
}

// The last segment of a saved path, as written on disk. Unlike fileName this
// does not decode percent escapes: the path the CLI wrote is already a real
// filename, and decoding it a second time would rename a literal "%20".
function savedName(raw) {
  let path = String(raw || "").trim()
  while (path.length > 1 && path.charAt(path.length - 1) === "/")
    path = path.slice(0, -1)
  const slash = path.lastIndexOf("/")
  const name = slash < 0 ? path : path.slice(slash + 1)
  return name === "." || name === ".." ? "" : name
}

// --- playlists -----------------------------------------------------------
//
// A playlist link is a container, not a video. The wrapper used to download
// its first entry and say nothing, which read as the wrong video; the island
// detects the shape here, lists the entries, and queues them one at a time.

// YouTube's /playlist path, and any link carrying a list= parameter (the
// share sheet adds one to a watch link).
function isPlaylistUrl(raw) {
  const s = String(raw || "").trim()
  if (s === "") return false
  if (/\/playlist(?:[/?#]|$)/i.test(s)) return true
  return /[?&]list=[^&#\s]+/i.test(s)
}

// Middle-click has no card in which to choose entries. Every playlist shape,
// including a watch link carrying list= (YouTube's share links), takes the
// queue path; a plain video takes the single-download path.
function primaryRoute(url) {
  return isPlaylistUrl(url) ? "playlist" : "download"
}

// One line per entry from --playlist-info:
//
//   playlist \t index \t title \t duration \t url
//
// The playlist's own name leads each line, because a watch link that carries
// `list=` still extracts a single video: the first entry's title is not the
// playlist's. A line from an older wrapper has four fields and no name. A
// title may itself contain tabs, so the fields are read from the ends: the
// url ends, the duration sits before it, and whatever is left is the title.
function playlistEntries(text) {
  const out = []
  const lines = String(text || "").split("\n")
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i]
    if (line.trim() === "") continue
    const f = line.split("\t")
    if (f.length < 4) continue
    const url = String(f[f.length - 1]).trim()
    if (url === "") continue
    const duration = String(f[f.length - 2]).trim()
    const named = f.length >= 5
    const label = named ? String(f[0]).trim() : ""
    const playlist = label === "NA" ? "" : label
    let index = String(f[named ? 1 : 0]).trim()
    if (index === "" || index === "NA") index = String(out.length + 1)
    const title = f.slice(named ? 2 : 1, f.length - 2).join(" ").trim()
    out.push({ index: index, title: title, duration: duration, url: url,
      playlist: playlist })
  }
  return out
}

// The playlist's own name, from the leading field of the listing. Empty when
// the extractor does not know it ("NA"), or when the listing is an older
// four-field one.
function playlistTitle(text) {
  const lines = String(text || "").split("\n")
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i]
    if (line.trim() === "") continue
    const f = line.split("\t")
    if (f.length < 5) return ""
    const name = String(f[0]).trim()
    return name === "NA" ? "" : name
  }
  return ""
}

// A playlist downloads into a folder named after it, so the name has to be a
// filesystem name rather than a video title: separators and control characters
// go, the dots and spaces a path cannot keep are trimmed from the edges, and
// the result is bounded so a long album title cannot exceed a name limit.
// "Playlist" is the fallback because an empty name is not a folder.
function folderName(raw) {
  let name = String(raw || "")
    .replace(/[\u0000-\u001f\u007f]/g, " ")
    .replace(/[\/\\:*?"<>|]/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .replace(/^[.\s]+|[.\s]+$/g, "")
  if (name === "." || name === "..") name = ""
  if (name.length > 80) name = name.slice(0, 80).replace(/[.\s]+$/, "")
  return name === "" ? "Playlist" : name
}

// The quality choices a playlist offers. A playlist cannot show a format
// table - every entry has its own - so the choice is made once for the batch,
// and it is an explicit one: the batch never silently takes "best".
// Every entry but Best is a CAP: "best at or below this height", so a tier
// the video does not have falls through to the best one it does (yt-dlp's
// selector already carries the fallback). `color` is the palette leaf the
// chip wears - a ramp from the top tier down, with the warm orange standing
// apart for the audio-only capture - so the row reads as a ladder.
var QUALITY_OPTIONS = [
  { key: "best", label: "Best", color: "accent",
    selector: "bestvideo+bestaudio/best" },
  { key: "2160", label: "4K", color: "purple",
    selector: "bestvideo[height<=2160]+bestaudio/best[height<=2160]" },
  { key: "1440", label: "2K", color: "blue",
    selector: "bestvideo[height<=1440]+bestaudio/best[height<=1440]" },
  { key: "1080", label: "1080p", color: "cyan",
    selector: "bestvideo[height<=1080]+bestaudio/best[height<=1080]" },
  { key: "720", label: "720p", color: "green",
    selector: "bestvideo[height<=720]+bestaudio/best[height<=720]" },
  { key: "audio", label: "Audio", color: "orange", selector: "bestaudio/best" }
]

function qualityOptions() {
  return QUALITY_OPTIONS.slice()
}

function qualitySelector(key) {
  const k = String(key || "")
  for (let i = 0; i < QUALITY_OPTIONS.length; i++) {
    if (QUALITY_OPTIONS[i].key === k) return QUALITY_OPTIONS[i].selector
  }
  return QUALITY_OPTIONS[0].selector
}

// The line a cancelled run leaves in the module's error slot. One spelling:
// the module writes it, the card recognises it (and fades it away on the next
// action) instead of matching a bare string across two files.
function cancelMessage() {
  return "Download cancelled"
}

// The preset's own short name, for the folder a second run of the same
// playlist writes into. Unknown keys fall back like the selector: the first
// option is the one a missing key downloads with.
function qualityLabel(key) {
  const k = String(key || "")
  for (let i = 0; i < QUALITY_OPTIONS.length; i++) {
    if (QUALITY_OPTIONS[i].key === k) return QUALITY_OPTIONS[i].label
  }
  return QUALITY_OPTIONS[0].label
}

// --- history matching ---------------------------------------------------
//
// The history remembers one format id per download, so a re-fetch can say
// which rows are already on disk. The CLI normalizes YouTube links before it
// stores them (youtu.be/x becomes www.youtube.com/watch?v=x), so matching the
// stored URL against what is in the field needs a key both spellings share.
function urlKey(raw) {
  const s = String(raw || "").trim()
  if (s === "") return ""
  const bare = s.replace(/^[a-z][a-z0-9+.-]*:\/\//i, "")
  // The embed host is a YouTube spelling too: the CLI normalizes it before a
  // download, and a line stored by an older run has to key the same way.
  if (/^(?:[a-z0-9-]+\.)*(?:youtube\.com|youtu\.be|youtube-nocookie\.com)\//i.test(bare)) {
    const m = bare.match(/(?:[?&]v=|youtu\.be\/|\/(?:shorts|live|embed|v)\/)([A-Za-z0-9_-]+)/i)
    if (m !== null) return "yt:" + m[1]
  }
  // Host names are case-insensitive; a path is not. Lowercasing the whole
  // spelling made /AbC and /abc the same video.
  const cut = bare.search(/[/?#]/)
  const host = (cut < 0 ? bare : bare.slice(0, cut)).toLowerCase()
    .replace(/^www\./, "")
  const tail = cut < 0 ? "" : bare.slice(cut)
  const rest = tail.charAt(0) === "/"
    ? tail.replace(/[?#].*$/, "").replace(/\/+$/, "")
    : ""
  return host + rest
}

// The leading id of a stored selector. A merged pick is recorded the way the
// wrapper sent it ("137+bestaudio/137"), while the table marks plain ids, so
// the comparison has to look past the merge.
function baseFormatId(raw) {
  return String(raw || "").split(/[+/]/)[0].trim()
}

// The engine a history row used. Field 6 is a format id for a yt-dlp row and a
// tool marker ("wget" or "aria2c") for a direct file. Anything else is the
// media engine, which older rows left implicit.
function historyEngine(row) {
  const format = String(row && row.format || "")
  if (format === "wget" || format === "aria2c") return format
  return "yt-dlp"
}

function isFileHistory(row) {
  return historyEngine(row) !== "yt-dlp"
}

// URL keys the playlist can treat as already held. A row with no path cannot
// prove a file exists, and a row whose path is gone is a memory of a moved or
// deleted copy - not a reason to keep the entry out of a new batch.
function downloadedKeys(history, gone) {
  const absent = Array.isArray(gone) ? gone : []
  const rows = Array.isArray(history) ? history : []
  const out = []
  for (let i = 0; i < rows.length; i++) {
    const row = rows[i]
    if (!row) continue
    if (isPlaylistHistory(row)) {
      const entries = Array.isArray(row.entries) ? row.entries : []
      for (let k = 0; k < entries.length; k++) {
        const entry = entries[k]
        if (!entry || !entry.path) continue
        if (absent.indexOf(String(entry.path)) >= 0) continue
        const key = urlKey(entry.url)
        if (key !== "" && out.indexOf(key) < 0) out.push(key)
      }
      continue
    }
    if (!row.path) continue
    if (absent.indexOf(String(row.path)) >= 0) continue
    const key = urlKey(row.url)
    if (key !== "" && out.indexOf(key) < 0) out.push(key)
  }
  return out
}

// Format ids already downloaded for the URL in the field. A history line from
// before the format column existed names no id, so it marks nothing. A row
// whose file is gone (`gone` carries those paths) names nothing either: the
// line remembers a file that is no longer there, and marking its row would
// take away the one action that brings it back.
function downloadedFormats(history, url, gone) {
  const key = urlKey(url)
  const out = []
  if (key === "") return out
  const absent = Array.isArray(gone) ? gone : []
  const rows = Array.isArray(history) ? history : []
  for (let i = 0; i < rows.length; i++) {
    const row = rows[i]
    if (!row || !row.format) continue
    if (isFileHistory(row) || isPlaylistHistory(row)) continue
    if (row.path && absent.indexOf(String(row.path)) >= 0) continue
    if (urlKey(row.url) !== key) continue
    const id = baseFormatId(row.format)
    if (id === "") continue
    if (out.indexOf(id) < 0) out.push(id)
  }
  return out
}

// The file a history row saved for the picked format, or "" when there is no
// copy to open. The key rules are downloadedFormats' own: the URL key picks
// the rows, the leading id of the stored selector picks the format, and a row
// whose file was reported gone names nothing. Rows arrive newest first, so the
// first match is the latest copy.
function downloadedPath(history, url, format, gone) {
  const key = urlKey(url)
  const want = baseFormatId(format)
  if (key === "" || want === "") return ""
  const absent = Array.isArray(gone) ? gone : []
  const rows = Array.isArray(history) ? history : []
  for (let i = 0; i < rows.length; i++) {
    const row = rows[i]
    if (!row || !row.path) continue
    if (isPlaylistHistory(row)) continue
    if (urlKey(row.url) !== key) continue
    if (baseFormatId(row.format) !== want) continue
    if (absent.indexOf(String(row.path)) >= 0) continue
    return String(row.path)
  }
  return ""
}

// Human-readable size for history rows that already store raw bytes, and a
// pass-through for yt-dlp's own "~ 39MiB" strings. Format rows reach it as
// `sizeLabel(row.size)`, so the table and the history read one way.
function sizeLabel(raw) {
  const s = String(raw || "").trim()
  if (s === "") return ""
  if (!/^[0-9]+$/.test(s)) return s
  const n = Number(s)
  if (n < 1024) return n + " B"
  // A value one byte below a unit boundary rounds up to that boundary; it
  // must not print as "1024 KiB" or "1024.0 MiB", which reads as the next
  // unit with the wrong scale factor.
  const kib = n / 1024
  if (kib < 1024) {
    const rounded = Math.round(kib)
    return rounded < 1024 ? rounded + " KiB" : "1.0 MiB"
  }
  const mib = n / 1048576
  if (mib < 1024) {
    const rounded = mib.toFixed(1)
    return Number(rounded) < 1024 ? rounded + " MiB" : "1.00 GiB"
  }
  return (n / 1073741824).toFixed(2) + " GiB"
}
