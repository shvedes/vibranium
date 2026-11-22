// Probe: BAR-8 and BAR-12.
//
// Two checks share this probe, in the shape of bar-pill-frames.qml:
//
//   1. Model check. A small charge-session machine is driven through a
//      plug/charge/unplug cycle with the boot seed arriving on either of its
//      two signals. The announcement sequence must be identical and must fire
//      once per plug-in. The entrance gate is driven with and without motion;
//      the modules must release on the slide edge or immediately.
//
//   2. Source check. The suites pass the two real files in through the
//      environment, so the structural half of the contract is checked against
//      the files under test. A model probe alone would stay green however the
//      real files were edited.

import QtQuick
import Quickshell

Item {
  id: root
  width: 400
  height: 240

  readonly property string batterySrc: Quickshell.env("BAR_BATTERY_SRC") || ""
  readonly property string barSrc: Quickshell.env("BAR_BAR_SRC") || ""

  function countOf(s, needle) {
    let n = 0
    let at = 0
    while (true) {
      const found = s.indexOf(needle, at)
      if (found < 0) return n
      n++
      at = found + needle.length
    }
  }

  function kv(key, value) { console.log("##KV## " + key + "=" + String(value)) }

  // --- charge session model (BAR-8) ---------------------------------------

  function newChargeModel() {
    return {
      seeded: false,
      inOnBattery: true,
      inCharging: false,
      inCharged: false,
      inHasMain: true,
      onBattery: true,
      lastCharging: false,
      lastCharged: false,
      acSessionId: 0,
      announcedSessionId: -1,
      log: ""
    }
  }

  // The announcement word is a pure read of the live tuple. A fresh crossing
  // to 100% reads "Charged"; an edge into an already full pack reads
  // "Fully charged"; anything else on AC reads "Charging". On battery there
  // is nothing to announce.
  function chargeKind(m) {
    if (!m.inHasMain || m.onBattery) return ""
    if (m.inCharged && !m.lastCharged) return "Charged"
    return m.inCharged ? "Fully charged" : "Charging"
  }

  function observeCharge(m) {
    const onB = m.inOnBattery
    const chg = m.inCharging
    const chd = m.inCharged
    if (!m.seeded) {
      m.seeded = true
      m.onBattery = onB
      m.lastCharging = chg
      m.lastCharged = chd
      m.announcedSessionId = onB ? -1 : m.acSessionId
      return
    }
    // The only session boundary: a real adapter edge.
    if (onB !== m.onBattery) {
      m.onBattery = onB
      m.acSessionId++
      const plugKind = chargeKind(m)
      m.lastCharging = chg
      m.lastCharged = chd
      if (plugKind === "") return
      m.announcedSessionId = m.acSessionId
      m.log += plugKind + ";"
      return
    }
    const kind = chargeKind(m)
    if (kind !== "") {
      if (chd && !m.lastCharged) {
        m.announcedSessionId = m.acSessionId
        m.log += kind + ";"
      } else if (chg && !m.lastCharging && m.announcedSessionId !== m.acSessionId) {
        m.announcedSessionId = m.acSessionId
        m.log += kind + ";"
      }
    }
    m.lastCharging = chg
    m.lastCharged = chd
  }

  function driveCycle(m, seedRoute) {
    // Boot on battery: the first snapshot seeds from live values.
    m.inOnBattery = true; m.inHasMain = true; m.inCharging = false; m.inCharged = false
    if (seedRoute === "ac") observeCharge(m); else observeCharge(m)
    // Plug: the adapter edge speaks while UPower is still Pending.
    m.inOnBattery = false
    observeCharge(m)
    // Pending settles into Charging ten seconds later: no second flash.
    m.inCharging = true
    observeCharge(m)
    // Last pack reaches 100%; charging flips off in the same update.
    m.inCharging = false; m.inCharged = true
    observeCharge(m)
    // Unplug opens a fresh session, replug while full announces once more.
    m.inOnBattery = true
    observeCharge(m)
    m.inOnBattery = false
    observeCharge(m)
  }

  function driveBootOnAc(m) {
    m.inOnBattery = false; m.inHasMain = true; m.inCharging = false; m.inCharged = false
    observeCharge(m)
    m.inCharging = true
    observeCharge(m)
  }

  // --- entrance gate model (BAR-12) ---------------------------------------

  function gateModulesReady(g) {
    return g.entranceReady && (g.entranceSlideDone || !g.motionEnabled)
  }

  Component.onCompleted: {
    const rowsFirst = root.newChargeModel()
    const acFirst = root.newChargeModel()
    const acBoot = root.newChargeModel()
    root.driveCycle(rowsFirst, "rows")
    root.driveCycle(acFirst, "ac")
    root.driveBootOnAc(acBoot)
    root.kv("charge.rowsFirst", rowsFirst.log)
    root.kv("charge.acFirst", acFirst.log)
    root.kv("charge.sessions", rowsFirst.acSessionId)
    root.kv("charge.bootOnAc", acBoot.log)

    const onMotion = { entranceReady: false, entranceSlideDone: false, motionEnabled: true }
    onMotion.entranceReady = true
    root.kv("gate.motionBeforeSlide", root.gateModulesReady(onMotion))
    onMotion.entranceSlideDone = true
    root.kv("gate.motionAfterSlide", root.gateModulesReady(onMotion))
    const noMotion = { entranceReady: false, entranceSlideDone: false, motionEnabled: false }
    noMotion.entranceReady = true
    root.kv("gate.noMotion", root.gateModulesReady(noMotion))

    // --- source checks ---------------------------------------------------
    const b = root.batterySrc
    const ocFrom = b.indexOf("Component.onCompleted:")
    const ocTo = ocFrom >= 0 ? b.indexOf("readonly property real displayPct", ocFrom) : -1
    const ocBlock = ocFrom >= 0 && ocTo > ocFrom ? b.slice(ocFrom, ocTo) : ""
    root.kv("src.batteryPresent", b.length > 0)
    root.kv("src.batterySingleSeed", b.indexOf("_acSeeded") < 0
      && b.indexOf("_powerSeeded") < 0 && root.countOf(b, "_chargeSeeded") >= 2)
    root.kv("src.batteryAnnouncedDerived",
      b.indexOf("readonly property bool _chargeAnnounced") >= 0
      && b.indexOf("announcedSessionId === root.acSessionId") >= 0
      && root.countOf(b, "root._chargeAnnounced =") === 0)
    root.kv("src.batteryOneSessionBump", root.countOf(b, "root.acSessionId++") === 1)
    root.kv("src.batteryAnnounceKindDerived",
      b.indexOf("readonly property string announceKind") >= 0
      && root.countOf(b, "root.announceKind =") === 0)
    root.kv("src.batteryOneObserver", root.countOf(b, "function _observeCharge()") === 1
      && b.indexOf("function onOnBatteryChanged() { root._observeCharge() }") >= 0
      && b.indexOf("onRowsChanged: root._observeCharge()") >= 0)
    root.kv("src.batteryCompletedOnlySeeds", ocBlock.indexOf("root._observeCharge()") >= 0
      && ocBlock.indexOf("root._onBattery") < 0
      && ocBlock.indexOf("root.acSessionId") < 0
      && ocBlock.indexOf("root.announcedSessionId") < 0)
    root.kv("src.batteryFlashGateKept", b.indexOf("root._flashPending") >= 0
      && b.indexOf("root.fullscreenActive") >= 0)

    const s = root.barSrc
    root.kv("src.barPresent", s.length > 0)
    root.kv("src.barEntranceDerived",
      s.indexOf("readonly property bool entranceModulesReady:") >= 0
      && s.indexOf("entranceSlideDone || !MotionPolicy.enabled") >= 0)
    root.kv("src.barNoEntranceWrites", root.countOf(s, "root.entranceModulesReady =") === 0)
    root.kv("src.barSlideDoneOneWriter", root.countOf(s, "root.entranceSlideDone =") === 1
      && s.indexOf("onFinished: root.entranceSlideDone = true") >= 0)
    root.kv("src.barNoPause", s.indexOf("entranceModulesPause") < 0)
    root.kv("src.barBootContractKept", s.indexOf("noteBootEntranceSettled()") >= 0
      && s.indexOf("noteBootEntrancePlayed") >= 0
      && s.indexOf("entranceWarmOpacity") >= 0
      && s.indexOf("entrancePlayedPause") >= 0
      && s.indexOf("function _latchEntrance()") >= 0)

    console.log("##DONE##")
  }
}
