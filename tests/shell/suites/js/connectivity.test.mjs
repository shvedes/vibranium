#!/usr/bin/env node
// Suite: the connectivity watcher's pure policy.
//
// The watcher itself is a Boot-resident singleton (timers, bus reads and
// cards), but every decision it makes is a pure function here: the NM value
// tables, the busctl reply shape, the print-config parse and the argv it
// hands to notify-send. A wrong table or a malformed argv is a silent
// feature, so both are pinned.
import path from 'node:path'
import { loadLib } from '../../lib/qmlloader.mjs'
import {
  suite, section, group, eq, is, contains, notContains, finish,
} from '../../lib/assert.mjs'

const SHELL = path.resolve(import.meta.dirname, '..', '..', '..', '..', 'shell')
const CL = loadLib(path.join(SHELL, 'services/system/ConnectivityLib.js'))

suite('connectivity', 'ConnectivityLib')

// ---------------------------------------------------------------------------
section('state tables - the NM D-Bus vocabularies')

group('isPortal names only the portal state', () => {
  eq('portal', CL.isPortal(2), true)
  eq('none', CL.isPortal(1), false)
  eq('limited', CL.isPortal(3), false)
  eq('full', CL.isPortal(4), false)
  eq('unknown', CL.isPortal(0), false)
  eq('unreadable', CL.isPortal(-1), false)
  eq('a numeric string coerces', CL.isPortal('2'), true)
  eq('garbage', CL.isPortal('portal'), false)
})

group('isOnline is full or limited', () => {
  eq('full', CL.isOnline(4), true)
  eq('limited', CL.isOnline(3), true)
  eq('portal', CL.isOnline(2), false)
  eq('none', CL.isOnline(1), false)
  eq('unknown', CL.isOnline(0), false)
})

group('isMetered counts yes and guess-yes', () => {
  eq('yes', CL.isMetered(1), true)
  eq('guess-yes', CL.isMetered(3), true)
  eq('no', CL.isMetered(2), false)
  eq('guess-no', CL.isMetered(4), false)
  eq('unknown', CL.isMetered(0), false)
  eq('unreadable', CL.isMetered(-1), false)
})

group('linkNote gates the island suffix', () => {
  eq('portal first', CL.linkNote(2, 1, true), 'portal')
  eq('offline over metered', CL.linkNote(1, 1, true), 'offline')
  eq('limited counts as offline: the check never answered', CL.linkNote(3, 2, true), 'offline')
  eq('metered on a full link', CL.linkNote(4, 1, true), 'metered')
  eq('metered guess on a full link', CL.linkNote(4, 3, true), 'metered')
  eq('a plain full link is silent', CL.linkNote(4, 2, true), '')
  eq('no reading yet is silent', CL.linkNote(2, 1, false), '')
  eq('no reading yet is silent without a flag', CL.linkNote(2, 1), '')
  eq('unknown connectivity reads offline', CL.linkNote(0, 2, true), 'offline')
  eq('a dark link still setting up reads configuring', CL.linkNote(1, 2, true, false, true), 'configuring')
  eq('setup softens the dark verdict only: portal still gates', CL.linkNote(2, 2, true, false, true), 'portal')
  eq('and a verified link never reads configuring', CL.linkNote(4, 2, true, false, true), '')
  eq('metered still warns under setup', CL.linkNote(4, 1, true, false, true), 'metered')
  eq('limited under a tunnel is silent', CL.linkNote(3, 2, true, true), '')
  eq('metered under a tunnel still warns', CL.linkNote(3, 1, true, true), 'metered')
  eq('a portal under a tunnel still gates first', CL.linkNote(2, 2, true, true), 'portal')
})

group('hasInternet is full and nothing else', () => {
  eq('full', CL.hasInternet(4), true)
  eq('limited', CL.hasInternet(3), false)
  eq('portal', CL.hasInternet(2), false)
  eq('none', CL.hasInternet(1), false)
  eq('unknown', CL.hasInternet(0), false)
})

group('hasInternet counts a tunnel carrying the default route', () => {
  eq('limited under a tunnel', CL.hasInternet(3, true), true)
  eq('none under a tunnel', CL.hasInternet(1, true), true)
  eq('unknown under a tunnel', CL.hasInternet(0, true), true)
  eq('a portal value with a tunnel still answers true (call sites gate portals first)', CL.hasInternet(2, true), true)
  eq('a failed route read keeps the raw verdict', CL.hasInternet(3, null), false)
  eq('full needs no tunnel', CL.hasInternet(4, false), true)
})

// ---------------------------------------------------------------------------
section('parseUintProp - the one pinned busctl shape')

group('the json=short get-property reply', () => {
  eq('portal', CL.parseUintProp('{"type":"u","data":2}'), 2)
  eq('full', CL.parseUintProp('{"type":"u","data":4}'), 4)
  eq('zero', CL.parseUintProp('{"type":"u","data":0}'), 0)
  eq('whitespace around it', CL.parseUintProp('  {"type":"u","data":1}\n'), 1)
})

group('anything else is unknown, never a state', () => {
  eq('empty output', CL.parseUintProp(''), -1)
  eq('a bus error line', CL.parseUintProp('Failed to get property: Access denied'), -1)
  eq('truncated json', CL.parseUintProp('{"type":"u",'), -1)
  eq('a null reply', CL.parseUintProp('null'), -1)
  eq('missing data', CL.parseUintProp('{"type":"u"}'), -1)
  eq('a negative value', CL.parseUintProp('{"type":"u","data":-1}'), -1)
  eq('a fractional value', CL.parseUintProp('{"type":"u","data":2.5}'), -1)
  eq('a string value', CL.parseUintProp('{"type":"u","data":"2"}'), 2)
  eq('no arguments', CL.parseUintProp(), -1)
})

group('a string payload reads, anything else is no name', () => {
  eq('an id', CL.parseStringProp('{"type":"s","data":"MyWifi"}'), 'MyWifi')
  eq('an empty string', CL.parseStringProp('{"type":"s","data":""}'), '')
  eq('a non-string payload', CL.parseStringProp('{"type":"u","data":2}'), '')
  eq('missing data', CL.parseStringProp('{"type":"s"}'), '')
  eq('garbage', CL.parseStringProp('nope'), '')
  eq('empty', CL.parseStringProp(''), '')
})

group('an object path reads, a bare slash is no object', () => {
  eq('an active connection', CL.parseObjectPath('{"type":"o","data":"/org/freedesktop/NetworkManager/ActiveConnection/3"}'), '/org/freedesktop/NetworkManager/ActiveConnection/3')
  eq('no primary connection', CL.parseObjectPath('{"type":"o","data":"/"}'), '')
  eq('garbage', CL.parseObjectPath('nope'), '')
})

group('escapeMarkup keeps an SSID as text', () => {
  eq('plain', CL.escapeMarkup('MyWifi'), 'MyWifi')
  eq('ampersands', CL.escapeMarkup('a&b'), 'a&amp;b')
  eq('tags', CL.escapeMarkup('<b>x</b>'), '&lt;b&gt;x&lt;/b&gt;')
  eq('missing', CL.escapeMarkup(), '')
  eq('null', CL.escapeMarkup(null), '')
})

group('propArgv names the NM root property on the system bus', () => {
  // busctl defaults to the system bus, so no --system flag is spelled: the
  // Inhibitor and MediaState readbacks share this exact shape.
  eq('connectivity', CL.propArgv('Connectivity'), ['busctl', 'get-property', '--json=short',
    'org.freedesktop.NetworkManager', '/org/freedesktop/NetworkManager',
    'org.freedesktop.NetworkManager', 'Connectivity'])
  eq('metered differs only in the last element', CL.propArgv('Metered')[6], 'Metered')
})

// ---------------------------------------------------------------------------
section('portal URL - NM\'s own check URI first')

group('parseConnectivityUri reads the first uri under [connectivity]', () => {
  eq('a plain section', CL.parseConnectivityUri('[connectivity]\nuri=http://ping.example/nm-check.txt\n'), 'http://ping.example/nm-check.txt')
  eq('other sections ignored', CL.parseConnectivityUri('[main]\nuri=http://wrong/\n[connectivity]\nuri=http://right/\n'), 'http://right/')
  eq('first uri wins', CL.parseConnectivityUri('[connectivity]\nuri=http://first/\nuri=http://second/\n'), 'http://first/')
  eq('comments and blanks skipped', CL.parseConnectivityUri('# global\n\n[connectivity]\n; note\nuri=http://x/\n'), 'http://x/')
  eq('section match is case-insensitive', CL.parseConnectivityUri('[Connectivity]\nuri=http://x/\n'), 'http://x/')
  eq('key match is case-insensitive', CL.parseConnectivityUri('[connectivity]\nURI=http://x/\n'), 'http://x/')
  eq('a quoted value sheds its quotes', CL.parseConnectivityUri('[connectivity]\nuri="http://x/"\n'), 'http://x/')
  eq('no connectivity section', CL.parseConnectivityUri('[main]\nuri=http://x/\n'), '')
  eq('empty uri', CL.parseConnectivityUri('[connectivity]\nuri=\n'), '')
  eq('empty input', CL.parseConnectivityUri(''), '')
  eq('no input', CL.parseConnectivityUri(), '')
})

group('portalUrl falls back to the generic probe', () => {
  eq('the NM uri', CL.portalUrl('http://ping.example/x'), 'http://ping.example/x')
  eq('blank falls back', CL.portalUrl('   '), CL.portalFallbackUrl())
  eq('empty falls back', CL.portalUrl(''), CL.portalFallbackUrl())
  eq('missing falls back', CL.portalUrl(), CL.portalFallbackUrl())
  is('the fallback is plain http (portals intercept port 80)',
    CL.portalFallbackUrl(), (v) => v.startsWith('http://'), 'an http:// URL')
})

// ---------------------------------------------------------------------------
section('notification argv - what the daemon actually receives')

group('the portal card is persistent with one login action', () => {
  const argv = CL.portalArgv()
  eq('the sender', argv[0], 'notify-send')
  contains('never expires', argv, '0')
  contains('the adoption tag', argv, 'string:x-vb-tag:' + CL.PORTAL_TAG)
  contains('the login action', argv, 'login=Open login page')
  eq('critical urgency', argv[argv.indexOf('-u') + 1], 'critical')
})

group('the metered card is persistent with a mute button', () => {
  const argv = CL.meteredArgv()
  contains('never expires', argv, '0')
  contains('the adoption tag', argv, 'string:x-vb-tag:' + CL.METERED_TAG)
  contains('the wifi glyph', argv, 'wifi-3')
  contains('the mute action', argv, "ignore=Don't show again")
  eq('no name, generic body', argv[argv.length - 1], 'This network is metered. Large downloads and updates can use up mobile data.')
})

group('a known network is named in bold in the body', () => {
  const argv = CL.meteredArgv('MyWifi')
  contains('the name in bold', argv, '<b>MyWifi</b>')
  eq('the summary stays generic', argv[argv.length - 2], 'Metered connection')
  const hostile = CL.meteredArgv('<b>x</b> & co')
  contains('a hostile name survives as text', hostile, '&lt;b&gt;x&lt;/b&gt; &amp; co')
  notContains('no live tag rides it', hostile, '<b>x</b>')
  eq('blank is generic', CL.meteredArgv('   ')[CL.meteredArgv('   ').length - 1], CL.meteredArgv()[CL.meteredArgv().length - 1])
})

group('withdrawals reuse the tag with a short expiry', () => {
  for (const [label, argv] of [
    ['portal clear', CL.portalClearArgv()],
    ['portal lost', CL.portalLostArgv()],
    ['metered clear', CL.meteredClearArgv()],
  ]) {
    contains(`${label} keeps the tag`, argv, 'string:x-vb-tag:')
    eq(`${label} expires`, argv[argv.indexOf('-t') + 1], '4000')
    eq(`${label} carries no action`, argv.includes('-A'), false)
  }
  contains('portal clear keeps the portal tag', CL.portalClearArgv(), 'string:x-vb-tag:' + CL.PORTAL_TAG)
  contains('metered clear keeps the metered tag', CL.meteredClearArgv(), 'string:x-vb-tag:' + CL.METERED_TAG)
})

group('the mute confirmation adopts the card and fades', () => {
  const argv = CL.meteredMutedArgv('MyWifi')
  contains('the tag', argv, 'string:x-vb-tag:' + CL.METERED_TAG)
  eq('expires', argv[argv.indexOf('-t') + 1], '4000')
  eq('no action flag', argv.includes('-A'), false)
  contains('the name in bold', argv, '<b>MyWifi</b>')
  eq('nameless still confirms', CL.meteredMutedArgv()[CL.meteredMutedArgv().length - 1], "You won't be reminded again.")
})

group('suppression is keyed per network, hostile names included', () => {
  eq('unmuted', CL.isMuted(null, 'MyWifi'), false)
  eq('unmuted on an empty section', CL.isMuted({}, 'MyWifi'), false)
  eq('unmuted on a missing map', CL.isMuted({ other: 1 }, 'MyWifi'), false)
  eq('unmuted on a malformed map', CL.isMuted({ mutedMetered: true }, 'MyWifi'), false)
  const section = CL.withMuted({}, 'MyWifi')
  eq('muted after muting', CL.isMuted(section, 'MyWifi'), true)
  eq('a neighbour is not muted', CL.isMuted(section, 'Other'), false)
  eq('the key is namespaced', Object.keys(section.mutedMetered), ['ssid:MyWifi'])
  eq('muting twice keeps one key', Object.keys(CL.withMuted(section, 'MyWifi').mutedMetered), ['ssid:MyWifi'])
  eq('the input section is untouched', section.mutedMetered['ssid:Other'], undefined)
  const hostile = CL.withMuted({}, '__proto__')
  eq('a hostile name files as an own key', Object.keys(hostile.mutedMetered), ['ssid:__proto__'])
  eq('and reads back', CL.isMuted(hostile, '__proto__'), true)
  eq('missing ssid keys on empty', CL.mutedKey(), 'ssid:')
})

group('the offline card is persistent and named', () => {
  const argv = CL.offlineArgv('MyWifi')
  eq('never expires', argv[argv.indexOf('-t') + 1], '0')
  contains('the wifi-off glyph', argv, 'wifi-off')
  contains('prints its id for the silent close', argv, '-p')
  contains('the red crossing line', argv, 'string:x-vb-icon-color:red')
  contains('the tag', argv, 'string:x-vb-tag:' + CL.OFFLINE_TAG)
  eq('no action flag', argv.includes('-A'), false)
  contains('the name in bold', argv, '<b>MyWifi</b>')
  eq('the summary stays generic', argv[argv.length - 2], 'No internet connection')
  eq('nameless falls back', CL.offlineArgv()[CL.offlineArgv().length - 1], 'The current connection has no internet access.')
  const hostile = CL.offlineArgv('<b>x</b>')
  notContains('no live tag rides it', hostile, '<b>x</b>')
})

group('the silent close names one server id', () => {
  eq('shape', CL.closeArgv(41), ['busctl', '--user', 'call',
    'org.freedesktop.Notifications', '/org/freedesktop/Notifications',
    'org.freedesktop.Notifications', 'CloseNotification', 'u', '41'])
})

group('parseNotifId reads the print-id line', () => {
  eq('a bare id', CL.parseNotifId('41\n'), 41)
  eq('no trailing newline', CL.parseNotifId('7'), 7)
  eq('an action line is not an id', CL.parseNotifId('ignore\n'), 0)
  eq('empty', CL.parseNotifId(''), 0)
  eq('missing', CL.parseNotifId(), 0)
  eq('zero is nothing to close', CL.parseNotifId('0\n'), 0)
  eq('only the first line counts', CL.parseNotifId('41\nignore\n'), 41)
})

group('portalStep names the transition', () => {
  eq('entry announces', CL.portalStep(false, 2), 'announce')
  eq('staying put is silent', CL.portalStep(true, 2), null)
  eq('recovery clears', CL.portalStep(true, 4), 'clear')
  eq('limited recovery clears too', CL.portalStep(true, 3), 'clear')
  eq('a dropped link is lost', CL.portalStep(true, 1), 'lost')
  eq('an unknown reading is lost', CL.portalStep(true, 0), 'lost')
  eq('no portal, no card, nothing', CL.portalStep(false, 4), null)
  eq('offline without a card is nothing', CL.portalStep(false, 1), null)
})

group('meteredStep names the transition', () => {
  eq('entry announces', CL.meteredStep(false, '', 1, 'A', false), 'announce')
  eq('guess-yes announces', CL.meteredStep(false, '', 3, 'A', false), 'announce')
  eq('unmetered is silent', CL.meteredStep(false, '', 2, 'A', false), null)
  eq('muted and unshown is silence', CL.meteredStep(false, '', 1, 'A', true), null)
  eq('recovery withdraws', CL.meteredStep(true, 'A', 2, '', false), 'withdraw')
  eq('muted while shown retires', CL.meteredStep(true, 'A', 1, 'A', true), 'retire')
  eq('a roam renames', CL.meteredStep(true, 'A', 1, 'B', false), 'rename')
  eq('steady is silent', CL.meteredStep(true, 'A', 1, 'A', false), null)
  eq('unknown metered withdraws', CL.meteredStep(true, 'A', 0, '', false), 'withdraw')
})

group('offlineStep names the transition and the link memory', () => {
  const T0 = 1000000
  const G = CL.OFFLINE_GRACE_MS
  eq('online is nothing, and implies a link', CL.offlineStep(false, 4, 1, false, null, 0, T0), { act: null, prevLinked: true, linkUpAtMs: T0 })
  eq('online keeps an old stamp', CL.offlineStep(false, 4, 1, true, null, T0 - 60000, T0), { act: null, prevLinked: true, linkUpAtMs: T0 - 60000 })
  eq('recovery withdraws', CL.offlineStep(true, 4, 1, true, null, T0, T0), { act: 'withdraw', prevLinked: true, linkUpAtMs: T0 })
  eq('portal never touches it', CL.offlineStep(false, 2, 4, true, null, 0, T0), { act: null, prevLinked: true, linkUpAtMs: T0 })
  eq('portal beside a card leaves it', CL.offlineStep(true, 2, 4, true, null, T0, T0), { act: null, prevLinked: true, linkUpAtMs: T0 })
  eq('linkless is silence that clears the memory', CL.offlineStep(false, 1, 4, true, false, T0, T0), { act: null, prevLinked: false, linkUpAtMs: 0 })
  eq('a settled link announces at once', CL.offlineStep(false, 1, 4, true, true, T0 - 60000, T0), { act: 'announce', prevLinked: true, linkUpAtMs: T0 - 60000 })
  eq('a fresh link defers inside the grace', CL.offlineStep(false, 1, 4, false, true, 0, T0), { act: 'defer', prevLinked: false, linkUpAtMs: T0 })
  eq('and announces once it lapses', CL.offlineStep(false, 1, 4, false, true, T0, T0 + G), { act: 'announce', prevLinked: true, linkUpAtMs: T0 })
  eq('a first reading defers too', CL.offlineStep(false, 1, -1, false, true, 0, T0), { act: 'defer', prevLinked: false, linkUpAtMs: T0 })
  eq('steady dark is silent', CL.offlineStep(false, 3, 3, true, true, T0, T0 + G), { act: null, prevLinked: true, linkUpAtMs: T0 })
  eq('shown stays without withdrawing', CL.offlineStep(true, 1, 4, true, null, T0, T0), { act: null, prevLinked: true, linkUpAtMs: T0 })
  eq('shown on limited stays too', CL.offlineStep(true, 3, 4, true, null, T0, T0), { act: null, prevLinked: true, linkUpAtMs: T0 })
})

group('a roam re-arms the grace for the network just joined', () => {
  // A roam A->B with no linkless poll in between keeps A's stamp unless the
  // watcher restamps on the join (QML _noteFreshLink). Stale timing announces
  // instantly on B's first dark poll; fresh timing defers through the grace
  // on B, then surfaces with B's name (resolved after the grace) or stays
  // silent when B recovers inside it.
  const T0 = 1000000
  const G = CL.OFFLINE_GRACE_MS
  eq('stale stamp announces instantly (the bug)', CL.offlineStep(false, 1, 4, true, true, T0 - 60000, T0).act, 'announce')
  eq('fresh stamp defers (the fix)', CL.offlineStep(false, 1, 4, false, true, T0, T0).act, 'defer')
  eq('still dark after the grace announces', CL.offlineStep(false, 1, 1, false, true, T0, T0 + G).act, 'announce')
  eq('recovering inside the grace is silent', CL.offlineStep(false, 4, 1, false, null, T0, T0 + 3000).act, null)
})

group('offlineStep under a tunnel', () => {
  const T0 = 1000000
  const G = CL.OFFLINE_GRACE_MS
  eq('limited under a tunnel is online, no card', CL.offlineStep(false, 3, 4, true, true, T0 - 60000, T0, true, false),
    { act: null, prevLinked: true, linkUpAtMs: T0 - 60000 })
  eq('a tunnel withdraws a shown card', CL.offlineStep(true, 3, 1, true, null, T0, T0, true, false),
    { act: 'withdraw', prevLinked: true, linkUpAtMs: T0 })
  eq('a portal under a tunnel never touches it', CL.offlineStep(false, 2, 4, true, null, T0, T0, true, false),
    { act: null, prevLinked: true, linkUpAtMs: T0 })
  eq('dropping the tunnel announces at once', CL.offlineStep(false, 1, 3, true, true, T0 - 60000, T0, false, true),
    { act: 'announce', prevLinked: true, linkUpAtMs: T0 - 60000 })
  eq('steady dark after the tunnel stays silent', CL.offlineStep(false, 1, 1, true, true, T0, T0 + G, false, false),
    { act: null, prevLinked: true, linkUpAtMs: T0 })
})

group('parseVpnUp reads the default route table', () => {
  eq('no default is no tunnel', CL.parseVpnUp(''), false)
  eq('a physical default is no tunnel', CL.parseVpnUp('default via 10.61.155.204 dev wlan0 proto dhcp src 10.61.155.101 metric 600\n'), false)
  eq('wired is no tunnel either', CL.parseVpnUp('default via 192.168.1.1 dev enp42s0 proto dhcp metric 100\n'), false)
  eq('a tun default is a tunnel', CL.parseVpnUp('default dev tun0 proto static scope link metric 50\n'), true)
  eq('wireguard counts', CL.parseVpnUp('default dev wg0 proto static scope link metric 50\n'), true)
  eq('an amnezia interface counts', CL.parseVpnUp('default dev amneziawg0 proto static scope link metric 50\n'), true)
  eq('any one tunnel default among several counts', CL.parseVpnUp('default via 10.61.155.204 dev wlan0 proto dhcp metric 600\ndefault dev tun0 proto static scope link metric 50\n'), true)
  eq('a WireGuard /1 hijack counts even with the physical default intact', CL.parseVpnUp('default via 192.168.1.1 dev wlan0 proto dhcp metric 600\n0.0.0.0/1 dev wg0 scope link\n128.0.0.0/1 dev wg0 scope link\n'), true)
  eq('a /1 hijack counts regardless of device name', CL.parseVpnUp('0.0.0.0/1 dev warp0 scope link\n128.0.0.0/1 dev warp0 scope link\n'), true)
  eq('a split-tunnel specific without a default hijack does not', CL.parseVpnUp('default via 192.168.1.1 dev wlan0 metric 600\n10.8.0.0/24 dev tun0 proto kernel scope link src 10.8.0.2\n'), false)
  eq('no input is no tunnel', CL.parseVpnUp(), false)
  eq('the argv lists the full table so /1 hijacks are visible', CL.vpnRouteArgv(), ['ip', 'route', 'show'])
  eq('a tunnel stem matches', CL.isTunnelDev('tun0'), true)
  eq('a physical name does not', CL.isTunnelDev('wlan0'), false)
  eq('missing is not a tunnel', CL.isTunnelDev(), false)
})

section('metered data-usage milestones - sysfs counters, NM verdict')

group('parseDefaultIface names the default-route interface', () => {
  eq('no table is no interface', CL.parseDefaultIface(''), '')
  eq('a wifi default', CL.parseDefaultIface('default via 10.61.155.204 dev wlan0 proto dhcp metric 600\n'), 'wlan0')
  eq('the first default wins', CL.parseDefaultIface('default via 192.168.1.1 dev enp42s0 metric 100\ndefault dev tun0 scope link metric 50\n'), 'enp42s0')
  eq('a table without a default is no interface', CL.parseDefaultIface('10.8.0.0/24 dev tun0 proto kernel scope link src 10.8.0.2\n'), '')
  eq('hijack lines are ignored', CL.parseDefaultIface('0.0.0.0/1 dev wg0 scope link\n128.0.0.0/1 dev wg0 scope link\n'), '')
  eq('missing is no interface', CL.parseDefaultIface(), '')
})

group('usageKey files totals per network', () => {
  eq('a named network', CL.usageKey('Home'), 'ssid:Home')
  eq('an unnamed one is still a key', CL.usageKey(''), 'ssid:')
  eq('a hostile name cannot set a prototype', CL.usageKey('__proto__'), 'ssid:__proto__')
})

group('meteredUsageStep only files bytes consumed while metered', () => {
  const GB = CL.GB_BYTES
  const tick = { iface: 'wlan0', rx: 10 * GB, tx: GB }
  eq('the first sample seeds the baseline and files nothing',
    CL.meteredUsageStep(null, tick, 'Home', true), {
      state: { iface: 'wlan0', rx: 10 * GB, tx: GB, metered: true, ssid: 'Home' }, delta: 0, key: 'ssid:Home',
    })
  eq('an unmetered poll files nothing and drops the baseline',
    CL.meteredUsageStep({ iface: 'wlan0', rx: 10 * GB, tx: GB, metered: true, ssid: 'Home' }, tick, 'Home', false), {
      state: { iface: '', rx: 0, tx: 0, metered: false, ssid: 'Home' }, delta: 0, key: '',
    })
  eq('returning to metered reseeds instead of counting the gap',
    CL.meteredUsageStep({ iface: '', rx: 0, tx: 0, metered: false, ssid: 'Home' }, tick, 'Home', true), {
      state: { iface: 'wlan0', rx: 10 * GB, tx: GB, metered: true, ssid: 'Home' }, delta: 0, key: 'ssid:Home',
    })
  eq('steady metered files rx plus tx',
    CL.meteredUsageStep(
      { iface: 'wlan0', rx: 10 * GB, tx: GB, metered: true, ssid: 'Home' },
      { iface: 'wlan0', rx: 11 * GB, tx: 1.5 * GB }, 'Home', true), {
      state: { iface: 'wlan0', rx: 11 * GB, tx: 1.5 * GB, metered: true, ssid: 'Home' },
      delta: 1.5 * GB, key: 'ssid:Home',
    })
  eq('a roam reseeds under the new name',
    CL.meteredUsageStep(
      { iface: 'wlan0', rx: 11 * GB, tx: 1.5 * GB, metered: true, ssid: 'Home' },
      { iface: 'wlan0', rx: 11 * GB, tx: 1.5 * GB }, 'Cafe', true), {
      state: { iface: 'wlan0', rx: 11 * GB, tx: 1.5 * GB, metered: true, ssid: 'Cafe' },
      delta: 0, key: 'ssid:Cafe',
    })
  eq('an interface change reseeds',
    CL.meteredUsageStep(
      { iface: 'wlan0', rx: 11 * GB, tx: GB, metered: true, ssid: 'Home' },
      { iface: 'usb0', rx: GB, tx: GB }, 'Home', true).delta, 0)
  eq('a counter reset after reboot reseeds instead of counting a download',
    CL.meteredUsageStep(
      { iface: 'wlan0', rx: 11 * GB, tx: GB, metered: true, ssid: 'Home' },
      { iface: 'wlan0', rx: GB, tx: GB }, 'Home', true).delta, 0)
  eq('an unreadable sample files nothing', CL.meteredUsageStep(
    { iface: 'wlan0', rx: 10 * GB, tx: GB, metered: true, ssid: 'Home' }, null, 'Home', true).delta, 0)
  eq('and an unreadable sample keeps no baseline to corrupt the next tick',
    CL.meteredUsageStep(
      { iface: '', rx: 0, tx: 0, metered: true, ssid: 'Home' },
      { iface: 'wlan0', rx: 10 * GB, tx: GB }, 'Home', true).delta, 0)
})

group('meteredMilestone announces one full threshold at a time', () => {
  const GB = CL.GB_BYTES
  eq('below the threshold is silence', CL.meteredMilestone(GB, 0, 2 * GB), { announce: false, notified: 0 })
  eq('exactly the threshold announces and names the new total', CL.meteredMilestone(2 * GB, 0, 2 * GB), { announce: true, notified: 2 * GB })
  eq('a second threshold announces again', CL.meteredMilestone(4 * GB, 2 * GB, 2 * GB), { announce: true, notified: 4 * GB })
  eq('a jump over two thresholds still posts one card', CL.meteredMilestone(5 * GB, 0, 2 * GB), { announce: true, notified: 5 * GB })
  eq('a zero threshold never announces', CL.meteredMilestone(9 * GB, 0, 0), { announce: false, notified: 0 })
})

group('withMeteredUsage merges totals without touching the mute map', () => {
  const section = { mutedMetered: { 'ssid:Home': true }, meteredUsage: { 'ssid:Home': 100 }, meteredUsageNotified: { 'ssid:Home': 0 } }
  const next = CL.withMeteredUsage(section, 'ssid:Cafe', 50, 0)
  eq('the mute map survives', next.mutedMetered, { 'ssid:Home': true })
  eq('the old total survives', next.meteredUsage, { 'ssid:Home': 100, 'ssid:Cafe': 50 })
  eq('the notified map carries both', next.meteredUsageNotified, { 'ssid:Home': 0, 'ssid:Cafe': 0 })
  eq('the input section is untouched', section.meteredUsage, { 'ssid:Home': 100 })
  eq('a null section starts clean', CL.withMeteredUsage(null, 'ssid:Home', 7, 7), {
    meteredUsage: { 'ssid:Home': 7 }, meteredUsageNotified: { 'ssid:Home': 7 },
  })
})

group('the usage milestone names whole gigabytes and replaces', () => {
  const argv = CL.meteredUsageArgv('MyWifi', 2)
  eq('expiring, not persistent', argv[argv.indexOf('-t') + 1], '8000')
  contains('the wifi glyph', argv, 'wifi-3')
  contains('the usage tag', argv, 'string:x-vb-tag:' + CL.METERED_USAGE_TAG)
  eq('no action flag', argv.includes('-A'), false)
  contains('whole gigabytes in bold', argv, '<b>2 GB</b>')
  contains('the name in bold', argv, '<b>MyWifi</b>')
  eq('the summary stays generic', argv[argv.length - 2], 'Metered data used')
  const hostile = CL.meteredUsageArgv('<b>x</b>', 4)
  notContains('no live tag rides it', hostile, '<b>x</b>')
  contains('but the milestone still reads', hostile, '<b>4 GB</b>')
})

group('synthetic sessions: the transitions in order', () => {
  // Drive the step the way the service does: outputs feed the next
  // inputs, and the clock moves. dt is milliseconds per poll.
  const T0 = 1000000
  function runOffline(steps) {
    let shown = false, prevConn = -1, prevLinked = false, stamp = 0, t = T0
    const acts = []
    for (const [conn, linked, dt] of steps) {
      t += dt
      const r = CL.offlineStep(shown, conn, prevConn, prevLinked, linked, stamp, t)
      acts.push(r.act)
      prevConn = conn
      prevLinked = r.prevLinked
      stamp = r.linkUpAtMs
      if (r.act === 'announce') shown = true
      if (r.act === 'withdraw') shown = false
    }
    return acts
  }
  // Hotel wifi with dead upstream: full -> limited(linked) announces,
  // stays silent, drops to none silently, recovers with a withdraw.
  // The limited poll lands 30s after the online one, so the link age
  // already covers the grace.
  eq('dead-AP session', runOffline([
    [4, null, 0], [3, true, 30000], [3, true, 30000], [1, true, 30000], [4, null, 30000],
  ]), [null, 'announce', null, null, 'withdraw'])
  // Radio toggled off and back onto the same dead network: silence,
  // a grace defer on the reassociation, then the announce.
  eq('toggle session', runOffline([
    [4, null, 0], [1, false, 30000], [1, false, 30000], [3, true, 30000], [3, true, 6000],
  ]), [null, null, null, 'defer', 'announce'])
  // A join that recovers inside the grace never cards at all: dark for
  // one poll, full before the recheck.
  eq('grace recovers silently', runOffline([
    [4, null, 0], [1, false, 30000], [3, true, 30000], [4, null, 6000],
  ]), [null, null, 'defer', null])
  // Captive sign-in: portal announces, offline never fires, recovery
  // clears the portal card.
  eq('portal session', [
    CL.portalStep(false, 2),
    CL.offlineStep(false, 2, 4, true, null, T0, T0).act,
    CL.portalStep(true, 4),
  ], ['announce', null, 'clear'])
  // Muted metered: announce, click retires, roam stays silent, recovery
  // needs no card to withdraw.
  eq('muted session', [
    CL.meteredStep(false, '', 1, 'A', false),
    CL.meteredStep(true, 'A', 1, 'A', true),
    CL.meteredStep(false, 'B', 1, 'B', true),
    CL.meteredStep(false, '', 2, '', false),
  ], ['announce', 'retire', null, null])
})

group('linkLostEdge never fires: a disconnect is not a connected network without internet', () => {
  eq('a drop is silent', CL.linkLostEdge(true, false, true, true, true, false), false)
  eq('steady up is silent', CL.linkLostEdge(true, true, true, true, true, false), false)
  eq('steady down is silent', CL.linkLostEdge(false, false, false, false, true, false), false)
  eq('a radio toggle is silent', CL.linkLostEdge(true, false, true, false, true, false), false)
  eq('a drop while the radio was already off is silent', CL.linkLostEdge(true, false, false, false, true, false), false)
  eq('a drop on a wifi that never carried it is silent', CL.linkLostEdge(true, false, false, true, true, false), false)
  eq('no reading yet never fires', CL.linkLostEdge(true, false, true, true, false, false), false)
  eq('no prior up never fires', CL.linkLostEdge(null, false, null, true, true, false), false)
  eq('a card already up never refires', CL.linkLostEdge(true, false, true, true, true, true), false)
})

group('connectStep announces one fresh association', () => {
  eq('a new network', CL.connectStep('Old', 'Home'), { announce: true, ssid: 'Home' })
  eq('unknown previous is silence that stores', CL.connectStep(null, 'Home'), { announce: false, ssid: 'Home' })
  eq('missing previous is silence too', CL.connectStep(undefined, 'Home'), { announce: false, ssid: 'Home' })
  eq('an empty reading while still unknown stays unknown', CL.connectStep(null, ''), { announce: false, ssid: null })
  eq('so the boot join after it stays silent', CL.connectStep(CL.connectStep(null, '').ssid, 'Home'), { announce: false, ssid: 'Home' })
  eq('steady is silent', CL.connectStep('Home', 'Home'), { announce: false, ssid: 'Home' })
  eq('a drop is silent', CL.connectStep('Home', ''), { announce: false, ssid: '' })
  eq('a rejoin after the drop announces', CL.connectStep(CL.connectStep('Home', '').ssid, 'Home'), { announce: true, ssid: 'Home' })
  eq('a roam announces', CL.connectStep('A', 'B'), { announce: true, ssid: 'B' })
})

group('the join toast names the network', () => {
  const argv = CL.connectArgv('MyWifi')
  eq('expires', argv[argv.indexOf('-t') + 1], '4000')
  contains('the wifi glyph', argv, 'wifi-3')
  contains('the tag', argv, 'string:x-vb-tag:' + CL.ONLINE_TAG)
  eq('no action flag', argv.includes('-A'), false)
  contains('the name in bold', argv, '<b>MyWifi</b>')
  eq('the summary stays generic', argv[argv.length - 2], 'Connected')
  const hostile = CL.connectArgv('<b>x</b>')
  notContains('no live tag rides it', hostile, '<b>x</b>')
})

group('openUrlArgv hands one URL to the default browser', () => {
  eq('shape', CL.openUrlArgv('http://x/'), ['xdg-open', 'http://x/'])
})

// ---------------------------------------------------------------------------
section('export surface')

group('every export is covered above', () => {
  const names = ['isPortal', 'isOnline', 'hasInternet', 'isMetered', 'linkNote', 'parseUintProp', 'parseStringProp',
    'parseObjectPath', 'escapeMarkup', 'propArgv', 'vpnRouteArgv', 'parseVpnUp', 'isTunnelDev', 'VPN_TUNNEL_RE',
    'resolveUriArgv', 'parseConnectivityUri', 'portalUrl', 'portalFallbackUrl',
    'portalArgv', 'portalClearArgv', 'portalLostArgv', 'meteredArgv',
    'meteredClearArgv', 'meteredMutedArgv', 'mutedKey', 'isMuted', 'withMuted',
    'offlineArgv', 'closeArgv', 'parseNotifId', 'OFFLINE_GRACE_MS',
    'connectStep', 'connectArgv',
    'GB_BYTES', 'METERED_USAGE_TAG', 'parseDefaultIface', 'usageKey',
    'meteredUsageStep', 'meteredMilestone', 'withMeteredUsage', 'meteredUsageArgv',
    'portalStep', 'meteredStep', 'offlineStep', 'linkLostEdge',
    'openUrlArgv', 'PORTAL_FALLBACK_URL', 'PORTAL_TAG', 'METERED_TAG', 'OFFLINE_TAG', 'ONLINE_TAG']
  // Vars are not functions, so they ride module.exports directly; the
  // count below fails if an export is added without a group above.
  eq('the export count', Object.keys(CL).length, names.length)
  for (const name of names) {
    eq(`export ${name} exists`, CL[name] !== undefined, true)
  }
})

finish()
