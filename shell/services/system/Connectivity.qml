pragma Singleton
pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Networking
import qs.common
import "ConnectivityLib.js" as Lib
import "../../common/process/CommandSpec.js" as CommandSpec

// Connectivity watcher: captive-portal and metered-network announcements
// over D-Bus through `notify-send`, like every other in-shell emitter.
//
// Quickshell's Notifications service cannot be posted to from QML, so
// `Exec.run` is the only channel. The source is NetworkManager's own
// verdict, read off the system bus: `Connectivity` (0 unknown, 1 none,
// 2 portal, 3 limited, 4 full) and `Metered` (0 unknown, 1 yes, 2 no,
// 3 guess-yes, 4 guess-no). Link signals drive: verdict moves, radio
// toggles and device association all poll at once, collapsed onto a
// trailing poll when they burst. The heartbeat below is only the
// backstop for a missed signal - minutes apart, so its forks are noise;
// each poll is two short `busctl` forks plus one `ip` route read, more
// only while metered or dark.
//
// Cards are transition-gated, never re-sent: entering portal/metered posts
// one persistent (`-t 0`) card, leaving it replaces that card in place via
// the synchronous `x-vb-tag` (a numeric `-r` never stabilises on this
// daemon) with a short expiring follow-up, so no id bookkeeping is needed
// to withdraw one. A failed or unparsable poll keeps the previous reading,
// so a busctl hiccup never flashes cards off and on.
//
// The portal button is the whole reason the card goes through a blocking
// sender: `-A` implies `--wait`, so the clicked action name arrives on the
// waiter's stdout and that is the click channel. The login page is NM's
// own connectivity-check URI (a portal intercepts plain HTTP, which is
// what the check polls), read at click time so an admin-edited URI is
// honoured, with Android's portal probe as the fallback.
Singleton {
  id: root

  readonly property string tag: "connectivity"

  readonly property string _scope: "connectivity:poll"
  // Backstop cadence; the link signals above do the real driving.
  readonly property int _pollMs: 300000
  readonly property int _readTimeoutMs: 2000
  // Fast-lane floor: link signals can burst while NM settles (a roam walks
  // several device states), so kicks inside this window collapse onto one
  // trailing poll instead of one fork per signal.
  readonly property int _kickFloorMs: 3000
  property double _lastPollMs: 0

  // Last applied readings. -1 is unknown: never announced, and a poll that
  // cannot read leaves these standing rather than transitioning through it.
  property int _connectivity: -1
  property int _metered: -1
  // Whether the default route currently leaves through a tunnel device
  // (an NM VPN or an out-of-band client like AmneziaVPN). Read fresh on
  // every poll; a failed read keeps the previous value, so an `ip`
  // hiccup never flashes cards off and on.
  property bool _vpnUp: false
  property bool _polling: false
  // Poll generation: every _poll bumps it and every async hop re-checks it,
  // so a late reply from a superseded poll can never clobber fresh state.
  // (With the guard below supersedes are rare, but bus timeouts are slow
  // enough that "rare" still happens.) Stale hops abort silently.
  property int _pollSeq: 0
  // A real reading has landed at least once. The island suffix and the
  // verdicts below read it, so the pre-first-poll state is silence rather
  // than an "offline" flash on every boot.
  property bool _hasReading: false

  // The island suffix verdict for the connected row: "portal",
  // "configuring", "offline", "metered" or "". Same readings as the cards,
  // so the row and the pile can never disagree about what the link is -
  // except during setup, where the row says "configuring" while the card
  // correctly stays silent through the grace.
  readonly property string linkNote: Lib.linkNote(root._connectivity, root._metered, root._hasReading, root._vpnUp, root._isSettingUp())
  // Optimistic full-internet answer for plugin rows: true until the first
  // poll proves otherwise, so a query typed before the watcher lands reads
  // "fetching" and then either a rate or the explicit offline row - never
  // a "no internet" flash on a machine that has it. A tunnel carrying the
  // default route counts as internet here, the same as in the card edge
  // below, so a VPN the NM check cannot see never reads as offline.
  readonly property bool online: !root._hasReading || Lib.hasInternet(root._connectivity, root._vpnUp)

  // Whether each persistent card is currently up. The episode memory: what
  // has been said is the only thing a new reading is compared against, so a
  // portal that stays a portal posts exactly one card even across polls,
  // and dismissing it does not re-arm it.
  property bool _portalShown: false
  property bool _meteredShown: false
  // Connection profile name behind the metered card. Refreshed on every
  // metered poll so a roam mid-episode renames the card in place.
  property string _ssid: ""
  // Associated wifi network behind the join confirmation. Null until the
  // first reading lands, so boot never congratulates a link it never saw
  // come up.
  property var _prevWifiSsid: null
  // Previous connectivity reading for the offline edge. -1 is no reading
  // yet: a first poll that lands offline announces like a transition,
  // the same way a pre-existing low battery announces at startup.
  property int _prevConn: -1
  // Previous tunnel reading behind the same edge. A tunnel that was up
  // when the link went dark announces at once (like a previous full
  // reading), so dropping a VPN still surfaces instead of reading as
  // steady-dark silence.
  property bool _prevVpnUp: false
  // Whether the offline card is up, and the server id a `--print-id`
  // send reported for it. Tracked so the reconnect close names exactly
  // one card; a portal taking over leaves it standing beside the login
  // card, and both retire when the link recovers.
  property bool _offlineShown: false
  property int _offlineNotifId: 0
  // Offline episode generation: every transition that raises or clears the
  // offline card bumps it, and every pending resolve/send captures it. A
  // late reply from a superseded episode (announce -> withdraw ->
  // re-announce while the first resolve is still in flight) aborts instead
  // of double-posting with the old network's name; a late id for a dead
  // episode closes the orphan it just posted instead of filing it.
  property int _offlineSeq: 0
  // Whether the previous poll held a link. False before the first
  // reading, after any linkless one, and after any fresh association
  // (see _noteFreshLink), so a roam onto a dark network defers through
  // the grace like a first join. Online and portal polls set it without
  // a read: both imply an association.
  property bool _prevLinked: false
  // Association moment the grace reads against, 0 when unknown. Stamped
  // on the first linked observation, cleared with the link, and re-stamped
  // on every fresh association (roam) so the grace always measures the
  // network that is up now, never the one just left.
  property double _linkUpAtMs: 0
  // Link-loss moment behind the deferred optimistic edge, 0 when the link
  // is up or no loss is pending. Armed on an unexpected drop, cleared on
  // heal: a roam gap heals before the grace lapses and stays silent.
  property double _linkDownAtMs: 0
  // Whether the wifi radio carried the link when the pending loss armed
  // (the previous signal's wifiUp). A radio toggle that lands while the
  // edge is still pending explains a wifi-carried loss even when it arrives
  // second, so the toggle retires it; a wired loss survives the toggle.
  property bool _linkDownWifi: false
  // Link and radio memory for the optimistic edge. Null until the first
  // signal, so boot never announces on state it never saw up.
  property var _prevLinkUp: null
  property var _prevWifiUp: null
  property var _prevWifiOn: null
  // The offline card came from the optimistic edge (link loss) rather
  // than a poll verdict. A radio toggle under one retires it silently;
  // a poll verdict stands on its own reading.
  property bool _offlineOptimistic: false

  // The blocked metered sender (its stdout is the mute button) and the
  // in-flight connectivity-URI read. At most one of each; killed on
  // episode end and on teardown.
  property var _waiter: null
  property var _meteredWaiter: null
  property var _urlProbe: null

  function _poll() {
    // Single-flight with a trailing edge: a kick that lands mid-poll is not
    // dropped, it collapses onto kickTimer, whose fire retries while busy.
    // Without this a burst during slow bus reads (timeouts are 2s per fork)
    // loses signals - including the heal that cancels a pending loss.
    if (root._polling) {
      kickTimer.restart()
      return
    }
    root._polling = true
    root._lastPollMs = Date.now()
    root._pollSeq++
    const seq = root._pollSeq
    root._readProp("Connectivity", conn => {
      if (seq !== root._pollSeq) return
      if (conn < 0) {
        root._pollDone(seq)
        return
      }
      root._readProp("Metered", met => {
        if (seq !== root._pollSeq) return
        if (met < 0) {
          root._pollDone(seq)
          return
        }
        // The tunnel read rides every poll: one `ip` fork next to the two
        // `busctl` ones, so a VPN that NM cannot see still reaches the
        // verdict on the same tick as the readings it qualifies.
        root._readVpnUp((vpn, table) => {
          if (seq !== root._pollSeq) return
          if (!Lib.isMetered(met)) {
            root._finishPoll(conn, met, "", vpn, seq)
            return
          }
          root._resolveSsid(ssid => {
            if (seq !== root._pollSeq) return
            root._finishPoll(conn, met, ssid, vpn, seq)
          })
        })
      })
    })
  }

  // Terminal of every poll, sync or async: releases single-flight for the
  // generation that owns it. A stale generation is a superseded poll and
  // releases nothing. Trailing work needs no re-arm here: every busy _poll
  // already collapsed onto kickTimer, which retries while busy.
  function _pollDone(seq) {
    if (seq !== root._pollSeq) return
    root._polling = false
  }

  function _finishPoll(conn, met, ssid, vpnUp, seq) {
    if (seq !== root._pollSeq) return
    // Polling stays held through _evaluate's association read below, so two
    // polls can never interleave their link-memory updates. The offline
    // card post itself runs past release, guarded by the episode (_offlineSeq).
    root._connectivity = conn
    root._metered = met
    // Null is a failed `ip` read: keep the previous tunnel value, the
    // same way a failed bus read keeps its previous reading.
    if (vpnUp === true || vpnUp === false) root._vpnUp = vpnUp
    root._hasReading = true
    root._evaluate(ssid, seq)
  }

  // One NM root property read. `done` answers the parsed uint, or -1 on
  // any failure: refusal, missing bus, or a reply outside the pinned
  // `{"type":"u","data":N}` shape.
  function _readProp(prop, done) {
    const spec = CommandSpec.argv(Lib.propArgv(prop))
    let job = null
    try {
      job = ProcessRegistry.start(spec, root._scope, {
        timeoutMs: root._readTimeoutMs,
        onFinished: result => {
          const out = result !== null && result !== undefined && result.code === "ok"
            ? String(result.stdout ?? "") : ""
          done(Lib.parseUintProp(out))
        },
        onFailed: () => done(-1)
      })
    } catch (ignored) {
      job = null
    }
    if (job === null) done(-1)
  }

  // One default-route read. `done` answers whether any default leaves
  // through a tunnel device, or null on any failure: an unreadable route
  // table keeps the previous tunnel value instead of flapping the
  // verdict, the same way a failed bus read keeps its reading.
  function _readVpnUp(done) {
    const spec = CommandSpec.argv(Lib.vpnRouteArgv())
    let job = null
    try {
      job = ProcessRegistry.start(spec, root._scope, {
        timeoutMs: root._readTimeoutMs,
        onFinished: result => {
          if (result === null || result === undefined || result.code !== "ok") {
            done(null, "")
            return
          }
          const table = String(result.stdout ?? "")
          done(Lib.parseVpnUp(table), table)
        },
        onFailed: () => done(null, "")
      })
    } catch (ignored) {
      job = null
    }
    if (job === null) done(null, "")
  }

  // One NM object property read, answering the raw stdout ("" on any
  // failure). The chain behind the metered card's network name reads
  // through here; the uint verdicts above stay on _readProp.
  function _busProp(object, iface, prop, done) {
    const spec = CommandSpec.argv(["busctl", "get-property", "--json=short",
      "org.freedesktop.NetworkManager", object, iface, prop])
    let job = null
    try {
      job = ProcessRegistry.start(spec, root._scope, {
        timeoutMs: root._readTimeoutMs,
        onFinished: result => {
          done(result !== null && result !== undefined && result.code === "ok"
            ? String(result.stdout ?? "") : "")
        },
        onFailed: () => done("")
      })
    } catch (ignored) {
      job = null
    }
    if (job === null) done("")
  }

  // Default-route connection object, "" when the machine holds no link
  // at all (radio off, cable out). The offline card answers a network
  // that is up but dark - toggling everything off is silence, not news -
  // so the edge gates on this rather than on the verdict alone.
  function _defaultConnection(done) {
    root._busProp("/org/freedesktop/NetworkManager",
      "org.freedesktop.NetworkManager", "PrimaryConnection",
      out => done(Lib.parseObjectPath(out)))
  }

  // Active connection profile name (the SSID on wifi) for the metered
  // card: primary connection object, then its Id. "" when there is none
  // or any hop fails - the card falls back to its generic body, so an
  // unreadable name is never a missing card.
  function _resolveSsid(done) {
    root._defaultConnection(active => {
      if (active === "") {
        done("")
        return
      }
      root._busProp(active,
        "org.freedesktop.NetworkManager.Connection.Active", "Id",
        idOut => done(Lib.parseStringProp(idOut)))
    })
  }

  // Fresh association: the link just (re)associated, possibly onto a new
  // SSID. Re-stamps the offline grace for the network that is up now, so a
  // roam A->B waits out the grace on B instead of announcing instantly on
  // A's old stamp. Cancels a pending link-loss edge (the gap healed) and
  // retires a stale link-loss card for the network just left; the next dark
  // poll then defers and, if still dark after the grace, announces with the
  // current name. A poll-verdict card stays: same-network flaps keep it
  // instead of flashing. Idempotent.
  function _noteFreshLink() {
    root._linkUpAtMs = Date.now()
    root._prevLinked = false
    optimisticTimer.stop()
    root._linkDownAtMs = 0
    root._linkDownWifi = false
    if (!root._offlineShown || !root._offlineOptimistic) return
    root._offlineShown = false
    root._offlineOptimistic = false
    root._offlineSeq++
    const id = root._offlineNotifId
    root._offlineNotifId = 0
    if (id > 0) Exec.run(Lib.closeArgv(id))
  }

  // Transition effects live here; the decisions live in the library as
  // pure steps, so synthetic sequences can drive every episode below.
  // Runs single-flight: polling releases only at the terminals below,
  // so the association read's link-memory updates can never interleave
  // with a newer poll. The card post runs past release, guarded by the
  // episode (_offlineSeq).
  function _evaluate(ssid, seq) {
    if (seq !== root._pollSeq) return
    const conn = root._connectivity
    const prev = root._prevConn
    root._prevConn = conn
    const prevVpn = root._prevVpnUp
    root._prevVpnUp = root._vpnUp
    const portal = Lib.portalStep(root._portalShown, conn)
    if (portal === "announce") {
      root._portalShown = true
      Log.info("connectivity portal: login required")
      root._spawnWaiter()
      // A login explains the dark: retire a standing offline card rather
      // than stacking a generic "no internet" beside the specific one.
      // Both still retire together when the link recovers.
      if (root._offlineShown) {
        root._offlineShown = false
        root._offlineOptimistic = false
        root._offlineSeq++
        const oid = root._offlineNotifId
        root._offlineNotifId = 0
        if (oid > 0) Exec.run(Lib.closeArgv(oid))
      }
    } else if (portal === "clear" || portal === "lost") {
      root._portalShown = false
      root._killProc(root._waiter)
      root._waiter = null
      Exec.run(portal === "clear" ? Lib.portalClearArgv() : Lib.portalLostArgv())
    }
    const metered = Lib.meteredStep(root._meteredShown, root._ssid,
      root._metered, ssid, root._mutedMetered(ssid))
    if (metered === "announce" || metered === "rename") {
      // A rename reuses the announce path: the same tag adopts the card,
      // so it renames in place instead of stacking.
      root._meteredShown = true
      root._ssid = ssid
      if (metered === "announce") Log.info("connectivity metered")
      root._sendMeteredCard(ssid)
    } else if (metered === "retire" || metered === "withdraw") {
      // Newly muted by click, roamed onto a muted network, or recovered:
      // retire the card with no follow-up, except the plain recovery,
      // which adopts the tag into a short confirmation. The click path
      // confirms by itself, and a roam is silence by design.
      root._meteredShown = false
      root._ssid = ""
      root._killProc(root._meteredWaiter)
      root._meteredWaiter = null
      if (metered === "withdraw") Exec.run(Lib.meteredClearArgv())
    }
    // Join confirmation: one expiring toast per fresh wifi association,
    // whatever follows. Backend read, so it costs no fork; the verdict
    // cards own everything after the join. A join also re-arms the offline
    // grace for the network just joined (see _noteFreshLink): without it a
    // dark first poll on the new link would announce instantly on the old
    // link's stamp, with the old network's name.
    const joined = Lib.connectStep(root._prevWifiSsid, root._wifiSsid())
    root._prevWifiSsid = joined.ssid
    if (joined.announce) {
      Log.info("connectivity joined " + Log.summarize(joined.ssid))
      Exec.run(Lib.connectArgv(joined.ssid))
      root._noteFreshLink()
    }
    // Offline card: persistent while associated but dark - a toggled-off
    // radio is silence, not news, so the edge gates on the link as well
    // as the verdict. `limited` counts as dark here unless a tunnel
    // carries the default route: the NM check never answered, but the
    // user's traffic leaves through the tunnel, which from the user's
    // side is internet even though the check says otherwise. The link
    // read runs only on the dark-and-unshown path; every other path
    // decides without it. A fresh link waits out the grace before
    // announcing, and the service re-polls when it lapses so a truly
    // dark link still surfaces seconds in.
    const dark = !Lib.isPortal(conn) && !Lib.hasInternet(conn, root._vpnUp)
    if (dark && !root._offlineShown) {
      root._defaultConnection(active => {
        if (seq !== root._pollSeq) return
        const stepped = Lib.offlineStep(false, conn, prev, root._prevLinked,
          active !== "" && root._anyLinkUp(), root._linkUpAtMs, Date.now(), root._vpnUp, prevVpn)
        root._prevLinked = stepped.prevLinked
        root._linkUpAtMs = stepped.linkUpAtMs
        if (stepped.act === "defer") {
          graceTimer.interval = Math.max(1000,
            Lib.OFFLINE_GRACE_MS - (Date.now() - stepped.linkUpAtMs))
          graceTimer.restart()
          root._pollDone(seq)
          return
        }
        graceTimer.stop()
        if (stepped.act !== "announce") {
          root._pollDone(seq)
          return
        }
        Log.info("connectivity offline")
        root._offlineShown = true
        root._offlineOptimistic = false
        root._offlineSeq++
        const mySeq = root._offlineSeq
        root._pollDone(seq)
        root._resolveSsid(name => {
          if (mySeq !== root._offlineSeq || !root._offlineShown) return
          root._sendOfflineCard(Lib.offlineArgv(name), mySeq)
        })
      })
    } else {
      const stepped = Lib.offlineStep(root._offlineShown, conn, prev,
        root._prevLinked, null, root._linkUpAtMs, Date.now(), root._vpnUp, prevVpn)
      root._prevLinked = stepped.prevLinked
      root._linkUpAtMs = stepped.linkUpAtMs
      graceTimer.stop()
      const wd = (stepped.act === "withdraw")
      root._pollDone(seq)
      if (!wd) return
      // Silent recovery: CloseNotification by the id the `--print-id`
      // send reported. An unknown id is a send that failed and carried
      // no card, so there is nothing to close and no toast to send
      // instead - the request was no toast on recovery.
      root._offlineShown = false
      root._offlineOptimistic = false
      root._offlineSeq++
      const id = root._offlineNotifId
      root._offlineNotifId = 0
      if (id > 0) Exec.run(Lib.closeArgv(id))
      else Log.info("connectivity offline card id unknown; left standing")
    }
  }

  // One blocked-sender factory for every card that reads an answer
  // back: waiters (stdout is the button), one-shot id sends and the
  // URI probe share the shape, and only the exit parsing differs, so
  // it lives with the caller. Returns the child, or null when no
  // sender could be built - the caller owns the fallback.
  function _spawnReader(command, onExit) {
    const proc = procComp.createObject(root, { command: command })
    if (proc === null || proc === undefined) return null
    proc.exited.connect(code => {
      const out = root._stdout(proc)
      proc.destroy()
      onExit(code, out)
    })
    proc.running = true
    return proc
  }

  // The offline card goes through a one-shot `--print-id` sender: the id
  // it reports is what the silent recovery close above names. A send
  // that reports no id carries no card either, so 0 doubles as
  // nothing-to-close. Episode-guarded: a reply from a superseded episode
  // never files its id, and closes the orphan it just posted instead of
  // leaving it standing beside the current card.
  function _sendOfflineCard(argv, mySeq) {
    root._spawnReader(argv, (code, out) => {
      const id = Lib.parseNotifId(out)
      if (mySeq !== root._offlineSeq || !root._offlineShown) {
        if (id > 0) Exec.run(Lib.closeArgv(id))
        return
      }
      if (id > 0) root._offlineNotifId = id
    })
  }

  // The metered card goes through a blocked sender like the portal one:
  // `-A` implies `--wait`, so the clicked mute action arrives on its
  // stdout and that is the whole button channel. A send that cannot
  // block falls back to fire-and-forget - the card shows, the button is
  // dead for that episode.
  function _sendMeteredCard(ssid) {
    root._killProc(root._meteredWaiter)
    root._meteredWaiter = null
    const forSsid = String(ssid ?? "")
    const proc = root._spawnReader(Lib.meteredArgv(forSsid), (code, out) => {
      if (root._meteredWaiter !== proc) return
      root._meteredWaiter = null
      const acted = out.split("\n").some(line => line.trim() === "ignore")
      if (!acted || !root._meteredShown) return
      root._muteMetered(forSsid)
      root._meteredShown = false
      root._ssid = ""
      Exec.run(Lib.meteredMutedArgv(forSsid))
    })
    if (proc === null) {
      Exec.run(Lib.meteredArgv(forSsid))
      return
    }
    root._meteredWaiter = proc
  }

  function _mutedMetered(ssid) {
    return Lib.isMuted(ShellCache.section("connectivity"), ssid)
  }

  function _muteMetered(ssid) {
    ShellCache.setSection("connectivity",
      Lib.withMuted(ShellCache.section("connectivity"), ssid))
  }

  // The blocked sender behind the portal card. Its stdout names the clicked
  // action; anything else (dismiss, replacement, expiry) is silence. The
  // click is honoured only while the episode is still live, so a late
  // answer can never open a page for a portal that already resolved. A
  // send that cannot block falls back to fire-and-forget, like the
  // metered path.
  function _spawnWaiter() {
    root._killProc(root._waiter)
    root._waiter = null
    const proc = root._spawnReader(Lib.portalArgv(), (code, out) => {
      if (root._waiter !== proc) return
      root._waiter = null
      if (out.trim() === "login" && root._portalShown) root._openLoginPage()
    })
    if (proc === null) {
      Exec.run(Lib.portalArgv())
      return
    }
    root._waiter = proc
  }

  function _stdout(proc) {
    try {
      if (proc === null || proc === undefined || proc.stdout === null
        || proc.stdout === undefined) return ""
      return String(proc.stdout.text ?? "")
    } catch (ignored) {
      return ""
    }
  }

  function _openLoginPage() {
    root._killProc(root._urlProbe)
    root._urlProbe = null
    const proc = root._spawnReader(Lib.resolveUriArgv(), (code, out) => {
      if (root._urlProbe !== proc) return
      root._urlProbe = null
      if (!root._portalShown) return
      Exec.run(Lib.openUrlArgv(Lib.portalUrl(Lib.parseConnectivityUri(out))))
    })
    if (proc === null) {
      if (root._portalShown) Exec.run(Lib.openUrlArgv(Lib.portalFallbackUrl()))
      return
    }
    root._urlProbe = proc
  }

  // SIGKILL to the process group, then the object. A waiter that outlives
  // its episode is the failure this exists to prevent: a click landing
  // after the portal resolved must find no channel left to answer on.
  function _killProc(proc) {
    if (proc === null || proc === undefined) return
    try {
      proc.signal(9)
    } catch (ignored) {
    }
    proc.destroy()
  }

  Component {
    id: procComp

    Process {
      stdout: StdioCollector {}
      stderr: StdioCollector {}
    }
  }

  Timer {
    id: pollTimer

    interval: root._pollMs
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root._poll()
  }

  // Trailing edge of a kick burst: one poll for the whole storm. Named
  // kickCoalesceMs (the kick/grace vocabulary): kicks inside the window
  // collapse onto this one poll.
  readonly property int kickCoalesceMs: 2500
  Timer {
    id: kickTimer

    interval: root.kickCoalesceMs
    repeat: false
    onTriggered: {
      // Retry while busy rather than dropping: a trailing poll that lands
      // mid-read restarts the coalesce instead of losing the signal.
      if (root._polling) {
        kickTimer.restart()
        return
      }
      root._poll()
    }
  }

  // Grace recheck: fires when a fresh link's grace lapses so a truly
  // dark link surfaces seconds in rather than on the next cadence.
  // A busy poll collapses onto the kick trail instead of being dropped,
  // which would otherwise silence a truly-dark link until the heartbeat.
  Timer {
    id: graceTimer

    interval: Lib.OFFLINE_GRACE_MS
    repeat: false
    onTriggered: {
      if (root._polling) {
        kickTimer.restart()
        return
      }
      root._poll()
    }
  }

  // Deferred link-loss edge: fires when an unexpected drop survives the
  // grace, so a roam gap (down then up to a new AP within seconds) stays
  // silent while a genuine loss still surfaces seconds in rather than on
  // the next cadence. Cancelled on heal; the poll verdict owns everything
  // after the grace.
  Timer {
    id: optimisticTimer

    interval: Lib.OFFLINE_GRACE_MS
    repeat: false
    onTriggered: root._fireOptimistic()
  }

  // A link signal arrived (verdict moved, radio toggled, device set or
  // device state moved): poll now unless one just ran, in which case arm
  // the trailing edge. The heartbeat stays the backstop; kicks are what
  // make a drop or a join land in seconds rather than on the cadence.
  //
  // The loss edge is deferred through the grace: it arms a timer instead of
  // sending at once, so a roam gap (down then up to a new AP within seconds)
  // heals before it fires and stays silent, while a genuine loss still
  // surfaces seconds in without waiting for NM's verdict to catch up. A loss
  // explained by a radio toggle in the same breath stays silent.
  function kick() {
    const up = root._anyLinkUp()
    const wifiUp = root._wifiUp()
    const wifiOn = Networking.wifiEnabled
    const wasUp = root._prevLinkUp
    if (Lib.linkLostEdge(root._prevLinkUp, up, root._prevWifiUp, wifiOn,
      root._hasReading, root._offlineShown)) {
      if (!optimisticTimer.running) {
        root._linkDownAtMs = Date.now()
        root._linkDownWifi = (root._prevWifiUp === true)
        optimisticTimer.start()
      }
    } else if (up === true) {
      if (optimisticTimer.running) optimisticTimer.stop()
      root._linkDownAtMs = 0
      root._linkDownWifi = false
    }
    // Mirror ordering of the toggle race: the device update landed first
    // and armed (or fired) optimistically, then the toggle arrived. A radio
    // toggle explains a wifi-carried loss even when it arrives second, so it
    // cancels the pending edge as well as retiring the card - otherwise the
    // deferred edge fires minutes of intent later with a false card, and
    // toggling everything off is silence, not news. A pending wired loss
    // survives the toggle: it was unexpected either way. A poll verdict
    // stands on its own reading and stays.
    if (root._prevWifiOn === true && wifiOn === false) {
      if (optimisticTimer.running && root._linkDownWifi) {
        optimisticTimer.stop()
        root._linkDownAtMs = 0
        root._linkDownWifi = false
      }
      if (root._offlineShown && root._offlineOptimistic) {
        root._offlineOptimistic = false
        root._offlineShown = false
        root._offlineSeq++
        const id = root._offlineNotifId
        root._offlineNotifId = 0
        if (id > 0) Exec.run(Lib.closeArgv(id))
      }
    }
    root._prevLinkUp = up
    root._prevWifiUp = wifiUp
    root._prevWifiOn = wifiOn
    // Join toast live on the signal: it needs no verdict, only the
    // backend name, so it skips the poll, the floor and the forks
    // below. Shares state with the evaluate backstop, so whichever
    // sees a join first announces once and the other stays silent.
    const joined = Lib.connectStep(root._prevWifiSsid, root._wifiSsid())
    root._prevWifiSsid = joined.ssid
    if (joined.announce) {
      Log.info("connectivity joined " + Log.summarize(joined.ssid))
      Exec.run(Lib.connectArgv(joined.ssid))
    }
    // Fresh association re-arms the offline grace for the network just
    // joined: a link that healed (down->up, including first up after boot)
    // or a wifi SSID that changed restamps the grace and cancels a pending
    // loss, so the next dark poll defers on the new link instead of
    // announcing instantly on the old link's stamp.
    if ((wasUp === false && up === true) || (wasUp === null && up === true)
      || joined.announce) {
      root._noteFreshLink()
    }
    if (Date.now() - root._lastPollMs < root._kickFloorMs) {
      kickTimer.restart()
      return
    }
    root._poll()
  }

  // Whether the link is still being set up: a device or network stuck in
  // the Connecting state, or a fresh link still inside the offline grace
  // (associated but NM has not verified it yet). Read inside the linkNote
  // binding, so every backend state flip re-evaluates the suffix with no
  // extra watchers. Direction-correct on purpose: Disconnecting never
  // counts, so tearing down never reads as setting up.
  function _isSettingUp() {
    if (graceTimer.running) return true
    const devices = Networking.devices ? Networking.devices.values : []
    for (let i = 0; i < devices.length; i++) {
      const d = devices[i]
      if (!d) continue
      if (d.state === ConnectionState.Connecting) return true
      const nets = d.networks ? d.networks.values : []
      for (let j = 0; j < nets.length; j++) {
        if (nets[j] && nets[j].state === ConnectionState.Connecting) return true
      }
    }
    return false
  }

  // Any associated device, wifi or wired: the link half of the offline
  // edge. NM's verdict can lag the drop by seconds; this does not.
  function _anyLinkUp() {
    const devices = Networking.devices ? Networking.devices.values : []
    for (let i = 0; i < devices.length; i++) {
      if (devices[i] && devices[i].connected === true) return true
    }
    return false
  }

  // Associated wifi network, or "" when none is. Read off the backend
  // like the bar pill does: no bus round trip, so the join check costs
  // nothing on top of the poll that already ran.
  function _wifiSsid() {
    const devices = Networking.devices ? Networking.devices.values : []
    for (let i = 0; i < devices.length; i++) {
      const d = devices[i]
      if (!d || d.type !== DeviceType.Wifi) continue
      const nets = d.networks ? d.networks.values : []
      for (let j = 0; j < nets.length; j++) {
        if (nets[j] && nets[j].connected) return String(nets[j].name ?? "")
      }
    }
    return ""
  }

  // Whether the wifi radio currently carries the link. Decides if a
  // drop belongs to a radio toggle, independently of signal order.
  function _wifiUp() {
    const devices = Networking.devices ? Networking.devices.values : []
    for (let i = 0; i < devices.length; i++) {
      const d = devices[i]
      if (d && d.type === DeviceType.Wifi && d.connected === true) return true
    }
    return false
  }

  // Deferred link-loss edge firing: an unexpected drop that survived the
  // grace. Re-checks the link - healing in the meantime is silence, never
  // a flash - then posts through the same card path as the poll verdict.
  // A wifi-carried loss that ends with the radio off is silence too: the
  // toggle explains it even when it arrived after the drop armed the edge.
  function _fireOptimistic() {
    // A full disconnect (no AP / no connected network) never raises the
    // "No internet connection" card: that card answers a network that is up
    // but dark. Stay silent on a link loss and let the poll verdict (which
    // gates on an actual association) own the transition.
    const downWifi = root._linkDownWifi
    root._linkDownAtMs = 0
    root._linkDownWifi = false
    return
  }

  // Link-loss card, without waiting for the verdict: marks the episode
  // first so a poll landing mid-resolve cannot double-send. Only ever runs
  // from the deferred edge above, so a roam gap that healed in the meantime
  // never reaches here; a false alarm that still slips through costs a flash
  // and no toast, since the recovery close is silent.
  function _optimisticOffline() {
    if (root._offlineShown) return
    root._offlineShown = true
    root._offlineOptimistic = true
    root._linkDownAtMs = 0
    root._linkDownWifi = false
    root._offlineSeq++
    const mySeq = root._offlineSeq
    Log.info("connectivity offline (link lost)")
    root._resolveSsid(name => {
      if (mySeq !== root._offlineSeq || !root._offlineShown) return
      root._sendOfflineCard(Lib.offlineArgv(name), mySeq)
    })
  }

  // One watcher per network device, mirroring BatteryAlert's per-device
  // set: the devices model only moves as a SET, while association moves
  // on the device itself, so the set signal alone would miss a drop.
  property var _devWatchers: []

  function _syncDeviceWatchers() {
    const devices = Networking.devices ? Networking.devices.values : []
    const live = []
    for (let i = 0; i < devices.length; i++) {
      if (devices[i]) live.push(devices[i])
    }
    for (let i = 0; i < live.length; i++) {
      let found = false
      for (let j = 0; j < root._devWatchers.length; j++) {
        if (root._devWatchers[j].device === live[i]) {
          found = true
          break
        }
      }
      if (found) continue
      const watcher = devWatcherComp.createObject(root, { device: live[i] })
      root._devWatchers = root._devWatchers.concat([
        { device: live[i], watcher: watcher }
      ])
    }
    const keep = []
    for (let k = 0; k < root._devWatchers.length; k++) {
      const entry = root._devWatchers[k]
      if (live.indexOf(entry.device) >= 0) {
        keep.push(entry)
        continue
      }
      if (entry.watcher !== null && entry.watcher !== undefined) entry.watcher.destroy()
    }
    root._devWatchers = keep
  }

  Component {
    id: devWatcherComp

    Connections {
      property var device: null

      target: device

      function onConnectedChanged() { root.kick() }
      function onStateChanged() { root.kick() }
    }
  }

  Connections {
    target: Networking

    function onConnectivityChanged() { root.kick() }
    function onWifiEnabledChanged() { root.kick() }
  }

  Connections {
    target: Networking.devices

    function onValuesChanged() {
      root._syncDeviceWatchers()
      root.kick()
    }
  }

  // Fresh reading on demand: restarts the cadence and polls now (the
  // in-flight guard dedups). The network island calls this when it opens,
  // so looking never reads a poll from before the join.
  function refresh() {
    pollTimer.restart()
    root._poll()
  }

  Component.onCompleted: {
    // Registered, not offered: a watcher drives it and the cards it owes
    // are `notify-send` cards, not replies, so like batteryAlert it makes
    // no IPC promise. An offer with no verbs would read as a fault in
    // every `shell doctor` answer.
    Registry.register(root.tag, root)
    // Device watchers for the kick lane; the verdict poll below covers a
    // backend whose device set is already settled.
    root._syncDeviceWatchers()
  }

  Component.onDestruction: {
    pollTimer.stop()
    kickTimer.stop()
    graceTimer.stop()
    optimisticTimer.stop()
    for (let i = 0; i < root._devWatchers.length; i++) {
      const watcher = root._devWatchers[i].watcher
      if (watcher !== null && watcher !== undefined) watcher.destroy()
    }
    root._devWatchers = []
    root._killProc(root._waiter)
    root._waiter = null
    root._killProc(root._meteredWaiter)
    root._meteredWaiter = null
    root._killProc(root._urlProbe)
    root._urlProbe = null
    Registry.unregister(root.tag)
  }
}
