// Shared drop-payload resolution: one drag payload -> the single uri a
// wallpaper drop can act on, or the reason there is none.
//
// It exists because the parsing was copy-pasted into four drop targets
// (WallpaperView, WallpaperPickerPanel preview, BarView, MoveWindow) and the
// copies drifted: the bar hovered on a permissive `hasUrls || hasText` while
// the desktop hovered on the strict rule, so the same drag lit the bar and
// was then refused by the bar as "drop only one image at a time". Hover and
// drop have to run the same function, or the first one promises what the
// second one takes back.
//
// The rule is "exactly one image", not "exactly one entry". A browser drag of
// an image that sits inside a link offers both the image and the page holding
// it, which is one image and one page, not two images. So entries are
// classified before the single-item test is applied: the ones naming an image
// by extension win, and only when none of them does a lone https URL stand in.
// A genuine multi-image drag still resolves to several and stays refused -
// it is not silently reduced to the first one.
//
// Classification is string work on the payload alone, so it is safe to run at
// hover time where spawning a process is not. That leaves the extension as
// the sole gate, and it stays a guess: `handleDroppedUri` in the wallpaper
// service is still the authority, and the mime probe after a download is
// still the only thing that decides whether bytes are an image. This module
// narrows a payload to one candidate; it does not decide that a file is one.
//
// The transport gate is included even though the wallpaper service re-checks
// it. http and a credentialed authority are properties of the string, and
// hover has to agree with drop, so the rule lives where both can read it.
.pragma library
.import "ImageExts.js" as ImageExts

// The two messages every drop target reports. They live here so the four
// targets cannot drift into four different wordings for one verdict.
var ERR_MULTI = "Drop failed: drop only one image at a time"
var ERR_UNSUPPORTED = "Drop failed: unsupported drop type"

// Percent-decode a file:// uri into a filesystem path. A localhost authority
// is dropped, a relative remainder is anchored at the root, and a malformed
// escape leaves the text as it arrived rather than throwing: a path is user
// data here, and refusing to decode is not a reason to refuse the drop.
function decodeFileUri(uri) {
  let p = String(uri === null || uri === undefined ? "" : uri)
  if (p.startsWith("file://")) {
    p = p.substring(7)
    if (p.startsWith("localhost")) {
      const slash = p.indexOf("/")
      p = slash >= 0 ? p.substring(slash) : ""
    }
    if (p !== "" && p[0] !== "/") p = "/" + p
  }
  try {
    p = decodeURIComponent(p)
  } catch (ignored) {
  }
  return p
}

// A local filesystem path carried by the payload, or "" for anything that is
// not one: a bare absolute path passes through, a file:// uri is decoded, and
// a remote url, a relative path and empty text map to "".
function localPath(uri) {
  const u = String(uri === null || uri === undefined ? "" : uri).trim()
  if (u.startsWith("/")) return u
  if (u.startsWith("file://")) return decodeFileUri(u)
  return ""
}

// A credentialed authority (`user:password@host`) would be sent to the remote
// end and would sit in a process argv, so a URL carrying userinfo is refused
// before anything is fetched. The authority runs from the scheme to the first
// path, query or fragment delimiter, so an `@` in a query or a path is data
// and stays accepted.
function hasCredentials(s) {
  const rest = s.slice("https://".length)
  const stop = rest.search(/[\/?#]/)
  const authority = stop < 0 ? rest : rest.slice(0, stop)
  return authority.indexOf("@") >= 0
}

// Remote input is https only. Plain http is refused rather than upgraded: the
// scheme is the transport decision, and switching it silently would put a
// wallpaper on both destinations that the remote end never authenticated.
function isRemoteUrl(s) {
  if (!s.startsWith("https://")) return false
  return !hasCredentials(s)
}

// Whether the entry names an image by extension. A remote url is judged on
// the path with the query and fragment removed, so `photo.jpg?w=1920` is a
// jpg while `render?format=webp` is not - a query parameter naming a format
// is not a file extension, and treating it as one would make every URL that
// configures its output look like an image.
function namesImage(entry) {
  if (isRemoteUrl(entry)) {
    return ImageExts.ok(entry.split("?")[0].split("#")[0])
  }
  const p = localPath(entry)
  return p !== "" && ImageExts.ok(p)
}

// Split a uri-list or a dropped text block into entries. Blank lines and `#`
// comment lines are dropped: a fragment marker never starts a uri-list line,
// so this cannot eat a url that merely carries a fragment.
function lines(text) {
  const out = []
  const parts = String(text === null || text === undefined ? "" : text).split(/[\r\n]+/)
  for (let i = 0; i < parts.length; i++) {
    const line = parts[i].trim()
    if (line === "" || line[0] === "#") continue
    out.push(line)
  }
  return out
}

// Every entry the payload carries, in the order Qt reports the formats. urls
// win over text because Qt has already parsed `text/uri-list` into them, and
// a browser that offers both describes one drag in both.
function entries(drop) {
  if (drop === null || drop === undefined) return []
  if (drop.hasUrls === true) {
    const urls = drop.urls
    if (urls === null || urls === undefined) return []
    const out = []
    for (let i = 0; i < urls.length; i++) {
      const s = String(urls[i]).trim()
      if (s !== "") out.push(s)
    }
    return out
  }
  if (drop.hasText === true) return lines(drop.text)
  if (drop.formats !== null && drop.formats !== undefined && drop.formats.length > 0
    && typeof drop.getDataAsString === "function") {
    const raw = drop.getDataAsString("text/uri-list")
    if (raw !== null && raw !== undefined && String(raw).trim() !== "") return lines(raw)
  }
  return []
}

// Duplicates are one drag described twice - some browsers repeat the uri -
// and order is kept so the first spelling is the one acted on.
function unique(list) {
  const out = []
  for (let i = 0; i < list.length; i++) {
    if (out.indexOf(list[i]) < 0) out.push(list[i])
  }
  return out
}

// The payload reduced to the one uri a wallpaper drop can act on.
// `{ ok: true, uri }` or `{ ok: false, error }`.
function resolve(drop) {
  const all = unique(entries(drop))
  if (all.length === 0) return { ok: false, error: ERR_UNSUPPORTED }
  const images = []
  const remote = []
  for (let i = 0; i < all.length; i++) {
    if (namesImage(all[i])) {
      images.push(all[i])
      continue
    }
    if (isRemoteUrl(all[i])) remote.push(all[i])
  }
  if (images.length === 1) return { ok: true, uri: images[0] }
  if (images.length > 1) return { ok: false, error: ERR_MULTI }
  if (remote.length === 1) return { ok: true, uri: remote[0] }
  if (remote.length > 1) return { ok: false, error: ERR_MULTI }
  return { ok: false, error: ERR_UNSUPPORTED }
}

// Whether the payload is one this drop stack can act on. A drop target binds
// its hover feedback to this and nothing else, so the overlay cannot appear
// for a drag that the drop handler is about to refuse.
function supported(drop) {
  return resolve(drop).ok === true
}
