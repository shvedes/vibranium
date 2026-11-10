# Boot

The boot layer brings the shell up and owns the unit catalog. It is the only
layer allowed to import every other layer.

## Files

| File | Role |
| --- | --- |
| Boot.qml | the composition root, the unit catalog and the phases |
| BootBar.qml | the bar that appears while the session settles |
| BootServices.qml | services started before the first frame |
| BootLate.qml | deferred work that runs once the shell is up |

## The catalog

`Boot.qml` declares 51 descriptors, 14 `essential` and 37 optional. Each
descriptor has nine fields:

| Field | Meaning |
| --- | --- |
| `id` | unique; the dependency graph is keyed on it |
| `criticality` | `essential` or `optional` |
| `activation` | `eager`, `resident`, `first_use`, `gated_compat` or `facade` |
| `dependencies` | unit ids that must be ready first; the graph is validated, not assumed |
| `phase` | the boot phase the unit starts in |
| `ready` | the predicate the gate waits on |
| `resolver` | the unit implementation |
| `retry` | bounded: `maxAttempts`, `backoffMs`, `maxBackoffMs` |
| `teardown` | how the unit is stopped |

The essential 14, in dependency order, are log, paths, watch, settings,
hyprlandSettings, miscSettings, systemFont, theme, ui, icons, exec, state,
session and lockscreen.

`clipboard` and `lockscreen` are plain `resident` units with no controller
split. `activation: "eager"` is not a substitute for a dependency: the graph
is what orders the units. A `ready` that returns `true` unconditionally
converts the whole mechanism into a no-op, so every predicate names a real
condition. The gate rejects a catalog dependency cycle or a later-only
dependency at load time.
