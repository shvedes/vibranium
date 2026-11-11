.pragma library

.import "./text/Format.js" as Format
.import "./text/Duration.js" as DurationFmt
.import "./math/Range.js" as Range
.import "./text/StringUtils.js" as SU

// Shared NowPlaying helpers: player sort, mm:ss, seek math, the player// volume path (gate, mute/resume memory, and the round-trip probe that
// finds out whether a player takes a volume write at all).
// Pure JS, no Mpris import: callers pass plain values so both the
// bar island and the lockscreen pill share one implementation.
// 2-space indent, ASCII only.

function sortPlayers(src, isPlaying) {
  const playing = []
  const rest = []
  for (let i = 0; i < src.length; i++) {
    const p = src[i]
    if (p === null || p === undefined) continue
    if (isPlaying(p)) playing.push(p)
    else rest.push(p)
  }
  return playing.concat(rest)
}

// Which slot the bar pill should address after a regroup. `previous` is the
// view it was addressing, `next` the one a fresh sortPlayers just produced,
// `isPlaying` the same predicate that sort took.
//
// The island deliberately does not call this. It settles its card once, at
// open, and holds it while open, so a surface that hands the card over on a
// regroup is a different rule rather than a better one.
//
// Sorting alone does not decide what a surface shows. A surface that only
// clamps its index throws the ordering away: the slot it held now contains
// whatever regrouped into it, so a card parked on a paused client keeps
// showing that client while an actively playing one sits one slot over. A
// surface that snaps to slot 0 on every regroup does the mirror image, moving
// off a client that is still making sound because a peer happened to reorder.
// So the rule is layered:
//
//   * a held client that is still playing keeps the surface where it is,
//     because a playing client is what the user asked to hear and any other
//     playing client is a coin flip, not an improvement;
//   * a held client that has gone silent hands the surface to the head when
//     some other client is playing - the sort put it first for exactly this;
//   * a view with nothing playing keeps the hold, which is what stops an
//     all-paused set from collapsing onto slot 0 and losing the last track
//     the user had up.
//
// A hold whose client left the view has no identity to keep, so the index is
// only clamped: the payload swaps in place, which is the established
// dead-client recovery. A slot that was never held has no identity either, and
// there the head is the answer - the sort exists to make the head the active
// client, so falling back to it is never a worse pick than an arbitrary one.
function pickPlayerIndex(previous, next, currentIndex, isPlaying) {
  const last = next.length - 1
  if (last < 0) return 0
  const raw = Number(currentIndex)
  const at = isFinite(raw) ? Range.clamp(Math.trunc(raw), 0, last) : 0
  const held = previous[at]
  if (held === null || held === undefined) return 0
  const found = next.indexOf(held)
  if (found < 0) return at
  if (isPlaying(held)) return found
  for (let i = 0; i <= last; i++) {
    if (isPlaying(next[i])) return i
  }
  return found
}

// Browser tabs (and messenger voice notes) leak into the media set under
// the client's own bus name, so they are matched as whole tokens of the
// lowercased bus name and identity: "firefox" matches, "firefoxctl" does
// not. Substring matching catches whatever merely
// contains a vendor string; tokens only catch the vendor itself.
//
// Covered: the Chromium family (chrome, chromium, edge, brave, opera,
// vivaldi), the Gecko family (firefox, zen, waterfox), the WebKit ones
// with a Linux build (epiphany, falkon), and Telegram Desktop, whose
// voice messages would otherwise surface as a media track. No Safari: it
// ships no Linux build, so a token for it could only ever collide.
// Pure: takes plain strings so QML callers pass p.dbusName/p.identity.
var BROWSER_TOKENS = ["chromium", "chrome", "firefox", "edge", "msedge",
  "brave", "opera", "vivaldi", "zen", "waterfox", "epiphany", "falkon",
  "telegram", "telegramdesktop"]

function isBrowserPlayer(dbusName, identity) {
  const words = String(dbusName || "").toLowerCase().split(/[^a-z0-9]+/)
    .concat(String(identity || "").toLowerCase().split(/[^a-z0-9]+/))
  for (let i = 0; i < words.length; i++) {
    if (BROWSER_TOKENS.indexOf(words[i]) >= 0) return true
  }
  return false
}

function filterBrowsers(src) {
  const out = []
  for (let i = 0; i < src.length; i++) {
    const p = src[i]
    if (p === null || p === undefined) continue
    if (isBrowserPlayer(p.dbusName, p.identity)) continue
    out.push(p)
  }
  return out
}

// `m:ss`, or `h:mm:ss` once the reference crosses an hour, with the leading
// zeroes dropped from the first field and kept on the ones below it.
//
// `ref` is the length of the track, and it - not the value being formatted -
// decides whether an hour field appears. That is what makes a reserved column
// hold: a caller measures the column once, from the track's own length, and the
// two fields either side of a lane then keep that shape for the whole track
// instead of the readout reflowing at the 59:59 -> 1:00:00 crossing. Deciding
// from the value would put the hour in only after the crossing, which is the
// one tick where the column cannot afford to change.
//
// A one-argument call decides from its own value, which is the right answer for
// a lone duration with nothing to be consistent with. `fmtDuration` is the
// other shape entirely and belongs in prose (the OSD tooltip), where no layout
// has committed to a width.
function fmtTime(s, ref) {
  const t = Math.max(0, Math.floor(Number(s) || 0))
  const r = ref === undefined || ref === null
    ? t : Math.max(0, Math.floor(Number(ref) || 0))
  const mm = Format.pad2(Math.floor(t % 3600 / 60))
  const ss = Format.pad2(t % 60)
  return r >= 3600 ? Math.floor(t / 3600) + ":" + mm + ":" + ss    : Math.floor(t / 60) + ":" + ss
}

function clampRatio(x, w) {
  if (!(w > 0)) return 0
  return Range.clamp01(x / w)
}

function canSetPlayerVolume(player) {
  return !!player && player.canControl === true && player.volumeSupported === true
}

// The counterpart gate for position, and the one capability the bus answers
// honestly - which is why it needs no round trip where volume needs one.
// `volumeSupported` is a *declaration* a player can ignore, but a track with
// no length is an absence: `playerLength` returns 0 both when the player
// publishes no `mpris:length` and when it publishes a zero one, so a live
// stream is 0 rather than a number that grows with the position.
//
// The length is the load-bearing term. `canSeek` and `positionSupported` are
// declarations, and a player that fakes either still cannot be asked to seek
// to a target that does not exist, so requiring a real length is what stops a
// stream from being treated as a track that is permanently over.
function canSetPlayerPosition(player) {
  if (!player) return false
  if (player.canSeek !== true || player.positionSupported !== true) return false
  return playerLength(player) > 0
}

// MPRIS says a player that cannot take a volume write has no Volume
// property, and a player that takes one emits the change. The wild
// disagrees: every browser MPRIS adapter declares Volume, answers a Set
// with success and never applies it. Quickshell stores a write before
// the bus does, so `volumeSupported` stays true, the island's fill
// follows the shell's own copy, and the player hears nothing - which is
// the live slider that moves and does nothing.
//
// Neither flag can see that, and Quickshell offers no re-read of a
// property it has already cached, so the only sound test is a round trip
// off the bus: write a probe level, let the bus settle, then read Volume
// back. A reading that lands on the probe is the player's own number; one
// that lands anywhere else is the level the player kept, which is a
// dropped write. `volumeProbeTarget` picks the level, `volumeProbeTook`
// judges the answer and `volumeReadback` is the only thing that turns a
// busctl reply into a number.

// Default probe step, and the floor under `volumeProbeTarget`'s step: large
// enough to outrun any player's volume quantization, small enough that the
// level a probe takes away is not audible (0.02 is about 0.17 dB).
function volumeProbeStep() {
  return 0.02
}

// A player that is already silent is probed upwards from the step, because
// 0.02 is about -34 dB - silence - while a step *down* from 0 would be a
// mute. Everywhere else the probe steps down, so it can only make a playing
// track quieter for the length of the readback, never louder.
function volumeProbeTarget(current, step) {
  const c = normalizeVolume(current)
  const s = Number(step)
  const d = isFinite(s) && s > 0 ? Math.min(s, 0.5) : volumeProbeStep()
  const down = c - d
  return down >= 0.01 ? down : Math.min(1, c + d)
}

// Players quantize - spotify stores 1/65535 steps, vlc 1/320 - so the
// verdict compares with a tolerance rather than for equality. The tolerance
// stays well under the probe step, so a rounded reading still counts as
// taken while a dropped write cannot be mistaken for a rounded one.
function volumeProbeTook(target, observed, tolerance) {
  const t = Number(target)
  const o = Number(observed)
  if (!isFinite(t) || !isFinite(o)) return false
  const e = Number(tolerance)
  const limit = isFinite(e) && e > 0 ? e : volumeProbeStep() / 4
  return Math.abs(o - t) <= limit
}

// busctl answers a property read as {"type":"d","data":0.42}. Only that
// exact shape is a reading: a failure line, a truncated child, a property
// the player dropped, or a differently typed value all answer null, so a
// transport hiccup can never be read as a dropped write.
function volumeReadback(output) {
  const text = SU.textOf(output)
  if (text.trim() === "") return null
  let reply
  try {
    reply = JSON.parse(text)
  } catch (e) {
    return null
  }
  if (!reply || typeof reply !== "object" || reply.type !== "d") return null
  const v = Number(reply.data)
  return isFinite(v) ? v : null
}

function normalizeVolume(volume) {
  const n = Number(volume)
  return isFinite(n) ? Range.clamp01(n) : 0
}

// True when the read is a level the player actually reported, which is the gate
// for anything that WRITES a level derived from a read. MPRIS reserves a
// NEGATIVE Volume for "this client does not know its volume", and
// `normalizeVolume` collapses that - along with every non-finite read - to 0.
// Zero is the right number for a bar to paint and the wrong one to hand back to
// a player as its own level: the restore half of the volume probe writes
// `normalizeVolume(player.volume)` back, so a client answering -1 is given
// Volume = 0 and the shell has muted something no gesture asked it to touch.
// `MediaState` refuses the probe on this, and `NowPlayingIsland.playerVolume`
// documents the same hazard for a write taken off its own clamped fill.
//
// A level of 0 PASSES, because MPRIS reports 0 for a muted player and that is a
// real level worth putting back - the distinction this draws is between "the
// player said zero" and "the player said nothing", never between silent and
// audible. A malformed level above 1 passes too: it is still a number the
// player reported, and restoring what it said is more faithful than clamping it.

// The write gate beside normalizeVolume: true only when the read is a level
// the player actually reported. MPRIS reserves a NEGATIVE Volume for "this
// client does not know its volume", so a clamped negative - or any non-finite
// read - must never be handed back as the player's own level.
function volumeKnown(volume) {
  const n = Number(volume)
  return isFinite(n) && n >= 0
}

function volumeUnmuted(currentVolume, nextVolume) {
  return normalizeVolume(currentVolume) <= 0 && normalizeVolume(nextVolume) > 0
}

function adjustedVolume(volume, direction, step) {
  const current = normalizeVolume(volume)
  const d = Number(direction)
  const s = Number(step)
  if (!isFinite(d) || d === 0 || !isFinite(s) || s <= 0) return current
  return normalizeVolume(current + Math.sign(d) * s)
}

var _unmutedPlayerVolumes = {}

function playerVolumeKey(player) {
  if (!player) return ""
  return String(player.dbusName || player.identity || playerKey(player))
}

var _muteResumePlayers = {}

function setMuteResumePending(player, pending) {
  const key = playerVolumeKey(player)
  if (key === "") return
  if (pending) _muteResumePlayers[key] = true
  else delete _muteResumePlayers[key]
}

function consumeMuteResume(player) {
  const key = playerVolumeKey(player)
  if (key === "" || _muteResumePlayers[key] !== true) return false
  delete _muteResumePlayers[key]
  return true
}

function restorePlayerVolume(player, fallback) {
  const key = playerVolumeKey(player)
  const saved = normalizeVolume(key === "" ? 0 : _unmutedPlayerVolumes[key])
  if (saved > 0) return saved
  const safeFallback = normalizeVolume(fallback)
  return safeFallback > 0 ? safeFallback : 0.5
}

function togglePlayerVolume(player, fallback) {
  const current = normalizeVolume(player ? player.volume : 0)
  const key = playerVolumeKey(player)
  if (current > 0) {
    if (key !== "") _unmutedPlayerVolumes[key] = current
    return 0
  }
  return restorePlayerVolume(player, fallback)
}

var _manualAt = 0
var _manualKind = ""

// Shell-initiated transport intent. Library scripts (.pragma library)
// share one instance per QML engine, so the island (writer) and the
// bar pill (reader) see the same stamp. Never persist, never bind.
function noteManual(kind) {
  _manualKind = String(kind || "")
  _manualAt = Date.now()
}

function manualFresh(maxAgeMs) {
  if (!(_manualAt > 0)) return false
  return Date.now() - _manualAt <= (maxAgeMs > 0 ? maxAgeMs : 3000)
}

function manualDir() {
  if (!manualFresh(3000)) return 0
  if (_manualKind === "previous") return -1
  if (_manualKind === "next") return 1
  return 0
}

function playerKey(p) {
  if (!p) return ""
  const md = p.metadata && typeof p.metadata === "object" ? p.metadata : {}
  const trackid = md["mpris:trackid"] === undefined ? "" : String(md["mpris:trackid"])
  const uid = p.uniqueId === undefined ? "" : String(p.uniqueId)
  const fallback = uid === "" && trackid === ""
    ? [p.trackTitle, p.trackArtist, p.trackAlbum].map(v => String(v ?? "")).join("\u001f")
    : ""
  return JSON.stringify([String(p.dbusName ?? ""), uid, trackid, fallback])
}

// --- track likes -----------------------------------------------------------
//
// MPRIS has no like/dislike method, and `xesam:userRating` is read-only
// metadata, so a like action is a per-client capability rather than a
// protocol feature. Spotify is the client the shell can drive: its own
// Save/Remove shortcut toggles the track in Liked Songs, and the bar offers
// the action only when the active bus name is Spotify. Every other client
// keeps the transport toggle.
//
// Spotify does not publish whether the current track is already liked, so the
// shell keeps one optimistic answer for the track on screen. It is keyed by
// playerKey, which moves with the track, so the next track starts from
// unliked instead of inheriting the previous verdict. A client that does
// publish a rating seeds the answer through `playerRating`.
var _likeKey = ""
var _likeValue = false

function canLikePlayer(p) {
  if (!p) return false
  return String(p.dbusName || "").toLowerCase()
    .indexOf("org.mpris.mediaplayer2.spotify") === 0
}

// The Hyprland Lua that delivers Spotify's Save/Remove shortcut to its
// window. `class:` is the same selector the window rules use, and the
// down/up pair avoids the stuck-key bug of send_shortcut. Kept here rather
// than in QML so the exact payload is assertion-testable.
function likeShortcutScript() {
  const win = JSON.stringify("class:(?i)^spotify$")
  const down = 'hl.dispatch(hl.dsp.send_key_state({ mods = "ALT SHIFT", key = "B", state = "down", window = ' + win + ' }))'
  const up = 'hl.dispatch(hl.dsp.send_key_state({ mods = "ALT SHIFT", key = "B", state = "up", window = ' + win + ' }))'
  return down + "; " + up
}

function playerRating(p) {
  if (!p) return -1
  const md = p.metadata && typeof p.metadata === "object" ? p.metadata : {}
  const raw = md["xesam:userRating"]
  if (raw === undefined || raw === null || raw === "") return -1
  const n = Number(raw)
  return isFinite(n) ? n : -1
}

function playerLiked(p) {
  if (!p) return false
  const key = playerKey(p)
  if (key !== "" && key === _likeKey) return _likeValue
  return playerRating(p) > 0
}

function toggleLiked(p) {
  const next = !playerLiked(p)
  const key = playerKey(p)
  if (key !== "") {
    _likeKey = key
    _likeValue = next
  }
  return next
}

function playerPosition(p) {
  const n = Number(p && p.position != null ? p.position : 0)
  return isFinite(n) ? Math.max(0, n) : 0
}

// The longest length read as a length at all: a day. Nothing real is longer,
// and every "duration unknown" idiom sits orders of magnitude past it - MPRIS
// says a length of 0 means unknown, and a chromium media session (every
// YouTube live stream) sends INT64_MAX instead, which Quickshell divides down
// to about 9.2e9 seconds and hands out as a length like any other.
const MAX_PLAUSIBLE_LENGTH = 86400

// The widest string an `fmtTime` column can show: the cap itself, which renders
// as `24:00:00`. Nothing within the cap is wider - the hour field only appears
// above an hour, where it is at most two digits, and the two fields below it
// are always padded - so past the cap there is no length at all and no longer
// string ever reaches a column to be sized against.
//
// It is here rather than beside `fmtTime` because it needs the cap, and a
// `.pragma library` is evaluated as one script: a function hoisted above a
// `const` refers to it in its temporal dead zone. A caller reserves a fixed
// column width for a readout whose digits change underneath it, so the sample
// has to be the widest case rather than a representative one. Measured from a
// placeholder, the reserve is the *narrowest* string in the set - a hyphen is
// narrower than a digit in most faces - so a reserve taken that way elides the
// real time before anything is long enough to need the hour field, and a
// truncated time reads as a broken readout rather than as a tight column.
function widestTime() {
  return fmtTime(MAX_PLAUSIBLE_LENGTH)
}

function playerLength(p) {
  if (!p || p.lengthSupported === false) return 0
  const n = Number(p.length ?? 0)
  if (!isFinite(n) || n <= 0 || n > MAX_PLAUSIBLE_LENGTH) return 0
  return n
}

function normalizePosition(pos, len) {
  const p = Number(pos)
  const l = Number(len)
  const safe = isFinite(p) ? Math.max(0, p) : 0
  return isFinite(l) && l > 0 ? Math.min(safe, l) : safe
}

function progressPercent(pos, len) {
  const l = Number(len)
  if (!isFinite(l) || l <= 0) return -1
  return Range.clamp(normalizePosition(pos, l) / l * 100, 0, 100)
}

// The position a media surface should show for `player`: its own reading,
// clamped to `lengthSec` when the track has a length. The bar island, the
// lyrics overlay and the lock pill each spelled this rule out locally; it is
// the same clamp `normalizePosition` already owns, with the player read named.
function reanchorPosition(player, lengthSec) {
  return normalizePosition(playerPosition(player), lengthSec)
}

// A scrub preview: the lane fraction at `x` of `w`, in seconds of `lengthSec`.
// Pure and non-mutating - the caller moves its strip only, and commits to the
// player once, on release.
function scrubPosition(x, w, lengthSec) {
  return clampRatio(x, w) * Math.max(0, Number(lengthSec) || 0)
}

function fmtDuration(s) {
  return DurationFmt.formatTrackClock(s)
}

// --- synced lyrics ---------------------------------------------------------
//
// MPRIS carries no lyrics: the nearest field is `xesam:asText`, which is plain
// text and most players never publish. Timed lyrics therefore come from a
// provider (LRCLIB, no key), and these helpers are the pure half of that path
// so the parsing and the pick can be asserted without a fetch.
//
// `parseLrc` reads the LRC body a provider returns: one or more `[mm:ss.cc]`
// stamps ahead of the text they time, metadata tags such as `[ar:...]` ignored,
// and an `[offset:...]` tag shifting every stamp. Several stamps on one line
// are several cues for the same words - the format's repeat notation - and a
// row without a stamp or without words (an instrumental gap) is dropped.
function parseLrc(text) {
  const out = []
  if (typeof text !== "string" || text === "") return out
  const stamp = /\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]/g
  // Enhanced LRC times individual words with `<mm:ss.cc>` tags inline, after
  // the line stamp. They time the same cue the line stamp already named, so
  // they are stripped from the words rather than rendered as text.
  const wordStamp = /<\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?>/g
  const offsetTag = /^\s*\[offset:\s*([+-]?\d+)\]\s*$/i
  let offset = 0
  for (const row of text.split(/\r?\n/)) {
    const tag = offsetTag.exec(row)
    if (tag !== null) {
      offset = Number(tag[1]) / 1000
      continue
    }
    const times = []
    stamp.lastIndex = 0
    let match
    while ((match = stamp.exec(row)) !== null) {
      const frac = match[3] === undefined ? 0 : Number("0." + match[3])
      times.push(Number(match[1]) * 60 + Number(match[2]) + frac)
    }
    if (times.length === 0) continue
    const x = row.replace(stamp, "").replace(wordStamp, "").replace(/[ \t]{2,}/g, " ").trim()
    if (x === "") continue
    for (const t of times) out.push({ t: Math.max(0, t + offset), x })
  }
  return out.sort((a, b) => a.t - b.t)
}

// The cue sounding at `time`: the last line whose stamp has passed, or -1
// before the first one. Binary search, because it runs on every position tick.
function lyricIndexAt(lines, time) {
  if (!Array.isArray(lines) || lines.length === 0) return -1
  const t = Number(time)
  if (!isFinite(t)) return -1
  let low = 0
  let high = lines.length - 1
  let found = -1
  while (low <= high) {
    const mid = (low + high) >> 1
    if (Number(lines[mid].t) <= t) {
      found = mid
      low = mid + 1
    } else {
      high = mid - 1
    }
  }
  return found
}

// Plain lyrics, one trimmed non-empty row per line.
function parsePlainLyrics(text) {
  if (typeof text !== "string") return []
  const out = []
  for (const row of text.split(/\r?\n/)) {
    const x = row.trim()
    if (x !== "") out.push(x)
  }
  return out
}

// The record to show out of a provider search: timed lyrics beat untimed ones,
// and among equals the length identifies the right recording - a live or
// remastered cut shares the title and artist and times its words elsewhere.
function lyricsFromSearch(records, lengthSec) {
  if (!Array.isArray(records)) return null
  const len = Number(lengthSec) > 0 ? Number(lengthSec) : 0
  let best = null
  let bestScore = 0
  for (const record of records) {
    if (record === null || typeof record !== "object") continue
    const synced = parseLrc(record.syncedLyrics)
    const plain = parsePlainLyrics(record.plainLyrics)
    if (synced.length === 0 && plain.length === 0) continue
    let score = synced.length > 0 ? 6 : 1
    const d = Number(record.duration)
    if (len > 0 && isFinite(d) && d > 0) {
      const delta = Math.abs(d - len)
      if (delta <= 2) score += 3
      else if (delta <= 8) score += 1
    }
    if (score <= bestScore) continue
    bestScore = score
    best = synced.length > 0
      ? { synced: true, lines: synced }
      : { synced: false, lines: plain.map(x => ({ t: 0, x })) }
  }
  return best
}

// --- lyrics cache ----------------------------------------------------------
//
// The lyrics counterpart of the artwork warmer: it holds what was already
// fetched instead of asking again. Unlike the warmer it is not demand-held -
// a lyric sheet is not something a surface refcounts - so it is bounded by
// time instead: an entry is worth keeping for a while after the track leaves
// the screen, and worth forgetting after that.
//
// It lives in this library because the island is destroyed whenever it closes
// (see IslandHost), so a pane's own memo dies with the pane and every reopen
// on the same track would be another round trip. A .pragma library is shared
// per QML engine, which is exactly the lifetime this wants.
//
// Keyed on the recording, not the client: the same track on another player is
// the same words, and normalization makes `Song ` and `song` one entry. A
// negative answer is an answer and is cached too - a track the provider does
// not know should not cost a request on every open.
const LYRICS_CACHE_MAX = 12
const LYRICS_CACHE_TTL_MS = 30 * 60 * 1000

var _lyricsCache = {}

function lyricsCacheKey(title, artist, album, lengthSec) {
  const norm = (v) => SU.lowerTrim(v).replace(/\s+/g, " ")
  const n = Number(lengthSec)
  const len = isFinite(n) && n > 0 ? Math.round(n) : 0
  return JSON.stringify([norm(title), norm(artist), norm(album), len])
}

// `null` for a miss, `{ result }` for a hit - the wrapper is what keeps a
// cached "no lyrics" (result null) distinguishable from nothing cached at
// all. `now` is for the tests; callers leave it out.
function lyricsCacheGet(key, now) {
  if (typeof key !== "string" || key === "") return null
  const entry = _lyricsCache[key]
  if (entry === undefined) return null
  const at = now === undefined ? Date.now() : Number(now)
  if (!isFinite(at) || at - entry.at > LYRICS_CACHE_TTL_MS) {
    delete _lyricsCache[key]
    return null
  }
  // A read is a use: the sheet stays while a track keeps coming back.
  entry.at = at
  return { result: entry.value }
}

function lyricsCachePut(key, result, now) {
  if (typeof key !== "string" || key === "") return false
  const at = now === undefined ? Date.now() : Number(now)
  if (!isFinite(at)) return false
  _lyricsCache[key] = { value: result === undefined ? null : result, at: at }
  _pruneLyricsCache(at)
  return true
}

// Drop what expired, then the coldest entries past the cap. The list is
// rebuilt rather than deleted in place so eviction order is the timestamps'
// and not the object's key order, which is insertion order only.
function _pruneLyricsCache(now) {
  const keys = Object.keys(_lyricsCache)
  for (let i = 0; i < keys.length; i++) {
    if (now - _lyricsCache[keys[i]].at > LYRICS_CACHE_TTL_MS) delete _lyricsCache[keys[i]]
  }
  const live = Object.keys(_lyricsCache)
  if (live.length <= LYRICS_CACHE_MAX) return
  live.sort((a, b) => _lyricsCache[a].at - _lyricsCache[b].at)
  for (let i = 0; i < live.length - LYRICS_CACHE_MAX; i++) delete _lyricsCache[live[i]]
}

function lyricsCacheSize() {
  return Object.keys(_lyricsCache).length
}

function lyricsCacheClear() {
  _lyricsCache = {}
}

