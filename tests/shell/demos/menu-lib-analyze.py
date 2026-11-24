#!/usr/bin/env python3
"""Frame-level checks for the menu live trace suite.

The trace is produced by MenuPanel.deepSnapshot(): every sampled frame carries
the full visible row tree, the card's reactive verdicts, the viewport and the
one handoff value. End-state assertions let "wrong, then right" pass; these
checks look at every frame of every phase instead.

Usage: menu-lib-analyze.py <trace.json> <animations|noanim>
"""

import json
import sys

EXPECTED = {
    # id: (type, child count, stored value)
    "grm-devices": ("group", 7, ""),
    "grm-names": ("group", 8, ""),
    "grm-choices": ("group", 6, ""),
    "grm-expanded": ("group", 6, ""),
    "grm-branches": ("group", 3, ""),
    "grm-guards": ("group", 5, ""),
    "grm-tail": ("group", 3, ""),
    "br-a": ("group", 2, ""),
    "br-a1": ("group", 2, ""),
    "br-a1a": ("group", 2, ""),
    "cho-color": ("select", 0, "green"),
    "cho-duplicates": ("select", 0, "a"),
    "cho-prompt": ("select", 0, "preset"),
    "cho-action": ("select", 0, "first"),
    "br-b": ("select", 0, "first"),
    "dev-broken-step": ("number", 0, "7"),
}

failures = []
seen = set()
stats = {"frames": 0, "rows": 0, "groups": 0, "phases": set()}
previous_heights = {}
covered = set()
grow_heights = {}

TARGETS = {
    "open-group-6": "grm-devices",
    "open-group-7": "grm-names",
    "open-group-8": "grm-choices",
    "open-group-9": "grm-expanded",
    "open-group-10": "grm-branches",
    "open-group-11": "grm-guards",
    "open-group-14": "grm-tail",
    "number-step": "dev-broken-step",
    "flow-next": "cho-flow",
    "deep-body": "bod-article",
    "deep-tail-select": "tl-three",
}


def fail(phase, rule, detail):
    key = (phase, rule, detail)
    if key not in failures:
        failures.append(key)


def near(a, b, tol=2.0):
    try:
        return abs(float(a) - float(b)) <= tol
    except (TypeError, ValueError):
        return False


def check_row(phase, r, base, row_path, heights):
    rid = r.get("id", "")
    stats["rows"] += 1
    if rid == TARGETS.get(phase) and (r.get("expanded") or r.get("editor")):
        covered.add(phase)
    if rid in EXPECTED and not base.get("searching"):
        seen.add(rid)
        etype, ecount, evalue = EXPECTED[rid]
        if r.get("type") != etype:
            fail(phase, "expected-type", f"{rid}: {r.get('type')} != {etype}")
        if ecount and r.get("childCount") != ecount:
            fail(phase, "expected-children", f"{rid}: {r.get('childCount')} != {ecount}")
        if evalue and str(base.get("value", "")) != evalue and base.get("index", -1) >= 0:
            # value belongs to the CURRENT row; only check it when this row is
            # the cursor, otherwise it is a different row's reading.
            if base.get("rowLabel") == r.get("label"):
                fail(phase, "expected-value", f"{rid}: {base.get('value')} != {evalue}")

    h, settled = r.get("h"), r.get("settled")
    if settled and h is not None and settled > 0:
        heights[row_path] = (h, settled)
        # A fold starts at the live height, even though its target changes
        # immediately. Each frame must stay below the target or keep closing.
        last_height, last_target = previous_heights.get(row_path, (h, settled))
        ceiling = max(settled, last_height)
        if last_target != settled:
            # The old tween can advance between the prior sample and retarget.
            ceiling = max(ceiling, last_target)
        if h > ceiling + 2:
            fail(phase, "row-overshoot",
                 f"{rid or r.get('label')}: h={h} prior={last_height} settled={settled}")

    g = r.get("group")
    if not isinstance(g, dict):
        return
    stats["groups"] += 1
    natural, colh, boxh = g.get("natural"), g.get("colH"), g.get("box")
    if not (near(natural, float(colh) + float(boxh), 2.5)):
        fail(phase, "stale-natural-height",
             f"{rid}: natural={natural} col={colh} box={boxh}")
    if not g.get("capped"):
        if float(g.get("h", 0)) + 2 < float(natural):
            fail(phase, "content-behind-border",
                 f"{rid}: box={g.get('h')} content={natural}")
        if float(g.get("colY", 0)) == 0 and float(g.get("scroll", 0)) == 0 \
                and float(g.get("overflow", 0)) == 0:
            if float(g.get("colY", 0)) + float(colh) > float(g.get("h", 0)) + 2:
                fail(phase, "column-overflows-box",
                     f"{rid}: colY={g.get('colY')} colH={colh} box={g.get('h')}")
    elif float(g.get("h", 0)) > float(g.get("ceiling", 0)) + 2:
        fail(phase, "capped-box-too-tall",
             f"{rid}: box={g.get('h')} ceiling={g.get('ceiling')}")
    bar_y, bar_h = float(g.get("barY", 0)), float(g.get("barH", 0))
    if bar_h > 0 and bar_y + bar_h > float(g.get("h", 0)) + 2:
        fail(phase, "focus-bar-outside-box",
             f"{rid}: barY={bar_y} barH={bar_h} box={g.get('h')}")


def check_frame(frame, mode):
    base = frame.get("base") or {}
    card = frame.get("card") or {}
    scroll = frame.get("scroll") or {}
    phase = frame.get("phase", "?")
    stats["phases"].add(phase)
    stats["frames"] += 1
    if frame.get("an") is not (mode == "animations"):
        fail(phase, "wrong-motion-mode", f"an={frame.get('an')} mode={mode}")
    if base.get("page") not in {"nested-showcase", "grow-demo"}:
        previous_heights.clear()
        return
    if not phase:
        previous_heights.clear()
    if phase.startswith("grow-"):
        grow_heights.setdefault(phase, []).append(card["h"])

    expected = min(float(card.get("chrome", 0)) + float(card.get("rendered", 0)),
                   float(card.get("hardMax", 0)))
    if not near(card.get("h"), expected, 2.0):
        fail(phase, "card-height-not-derived",
             f"h={card.get('h')} expected={expected} rendered={card.get('rendered')}")
    if card.get("listH") is not None and card.get("chrome") is not None:
        if not near(card.get("listH"), float(card.get("h")) - float(card.get("chrome")), 3.0):
            fail(phase, "viewport-not-card-minus-chrome",
                 f"listH={card.get('listH')} card={card.get('h')} chrome={card.get('chrome')}")

    # Qt's contentHeight can lag the measured delegates during a fold.
    max_y = float(scroll["maxY"])
    if float(scroll.get("contentY", 0)) > max_y + 2:
        fail(phase, "seat-past-content",
             f"contentY={scroll.get('contentY')} max={max_y} blank={base.get('blank')}")
    if not scroll.get("clip"):
        fail(phase, "unclipped-viewport", f"page={base['page']}")
    if mode == "noanim" and scroll.get("animating"):
        fail(phase, "scroll-animated-with-motion-off", f"page={base['page']}")
    if (base.get("hlVisible") and not scroll.get("animating")
            and not card.get("heightAnimating") and not card.get("transition")
            and not base.get("handoffActive") and not base.get("fitPending")):
        # The highlight's y is in content space; translate by the live
        # scroll offset before comparing it with the viewport.
        y = float(base.get("hlY", 0)) - float(scroll.get("contentY", 0))
        hh, vh = float(base.get("hlH", 0)), float(scroll.get("h", 0))
        # A moving row can extend past the viewport while its visible portion
        # is clipped. A wholly dislodged highlight has no visible portion.
        if y + hh < -2 or y > vh + 2:
            fail(phase, "highlight-outside-viewport", f"y={y} h={hh} viewport={vh}")

    handoff = float(base.get("handoff", 0))
    if bool(base.get("handoffActive")):
        out = min(handoff * 2, 1)
        inn = max(0.0, (handoff - 0.5) * 2)
        page = 1 - out if handoff <= 0.5 else 0.3 + 0.7 * (1 - (1 - inn) ** 3)
        text = (1 - out) ** 3
        if not near(base.get("pageOpacity"), page, 0.03):
            fail(phase, "handoff-page-drift",
                 f"opacity={base.get('pageOpacity')} expected={page:.3f} handoff={handoff}")
        if not near(base.get("textOpacity"), text, 0.03):
            fail(phase, "handoff-text-drift",
                 f"opacity={base.get('textOpacity')} expected={text:.3f} handoff={handoff}")
        field = max(handoff, 1 - float(card.get("viewFade", 1)))
        if not near(base.get("fieldHandoff"), field, 0.03):
            fail(phase, "handoff-field-drift",
                 f"field={base.get('fieldHandoff')} expected={field:.3f}")

    heights = {}

    def check_rows(rows, parent_path=()):
        for r in rows:
            if not isinstance(r, dict):
                continue
            row_path = parent_path + ((r["idx"], r["id"], r["label"]),)
            check_row(phase, r, base, row_path, heights)
            check_rows(r.get("children") or [], row_path)

    check_rows(frame.get("rows") or [])
    previous_heights.clear()
    previous_heights.update(heights)


def main():
    if len(sys.argv) != 3:
        print("usage: menu-lib-analyze.py <trace.json> <animations|noanim>")
        return 2
    with open(sys.argv[1]) as f:
        frames = json.load(f)
    mode = sys.argv[2]
    if not frames:
        print("no frames in trace - the sampler or IPC chunk reader failed")
        return 2
    for frame in frames:
        check_frame(frame, mode)

    for phase in sorted(TARGETS.keys() - covered):
        fail(phase, "dropdown-not-observed", TARGETS[phase])
    before = grow_heights.get("grow-before", [])
    opened = grow_heights.get("grow-open", [])
    folded = grow_heights.get("grow-fold", [])
    if not (before and opened and folded and opened[-1] > before[-1] + 2
            and near(folded[-1], before[-1])):
        fail("grow", "card-did-not-grow-and-fold",
             f"before={before[-1:]} open={opened[-1:]} fold={folded[-1:]}")

    print(f"frames={stats['frames']} phases={len(stats['phases'])} "
          f"rows={stats['rows']} groups={stats['groups']}")
    missing = sorted(set(EXPECTED) - seen)
    if missing:
        print("unseen expected rows: " + ",".join(missing))
    print(f"failures={len(failures)}")
    for phase, rule, detail in failures[:80]:
        print(f"FAIL {phase} {rule}: {detail}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
