# shell

The QML shell. Four layers, one direction of imports.

## Layers and import direction

```
boot ──────────────►  everything else
features ──────►  common, services, own layer
services  ──────►  common, own layer
common   ──────►  nothing but Qt/Quickshell + sibling common code
```

- `common` must never import any other layer, relative or versioned.
- `services` must never import `features/`.
- `features` must never import `boot/`, or `features/bar` <-> `features/wallpaper`.
- `boot` must never be imported by anything else.

## Files

| Layer | Files |
| --- | --- |
| `boot/` | 4 |
| `common/` | 150 |
| `features/` | 157 |
| `services/` | 25 |
| `shell.qml` | 1 |
