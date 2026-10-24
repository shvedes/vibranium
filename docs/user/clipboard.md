# Clipboard

Vibranium ships its own clipboard manager, built directly into the shell - no
bash middleman, no [cliphist](https://github.com/sentriz/cliphist), no extra
daemon. History persists under `$VIBRANIUM_CACHE/clipboard.json`
as `{version, entries:[...]}` (and image snapshots under `clipboard-img`),
surviving reboots. The file and its directory are created mode `0600` and
`0700`.

Those modes come from the clipboard's own helper chain rather than from the
write path: `install -m 0700` creates the parent directory and
`install -m 0600` creates the history file itself, so the first payload byte
only ever reaches a node that is already `0600`. Every write waits for that
`install` to exit zero. If the mode cannot be confirmed, no file is created
and nothing is written: the payload waits in memory, the history stays
available for the rest of the session, and a single toast reports that saving
is held. The chain is re-driven, so a helper that fails once and then
succeeds still ends in a write. Writes after that are atomic replaces, and
`chmod 0600` re-asserts the mode on the node each replace leaves behind. A
node that something outside the clipboard left wider than `0600` keeps that
wider mode across the replace until the `chmod` runs; the `install` step
narrows it at session start, so the clipboard's own writes never leave it
wide.

Credential entries are the exception to persistence: their payload is kept in
memory only and handed to `wl-copy` through the process's standard input, so
it never appears in a command line, a process listing, or the history file. A
credential you copy is therefore available for the rest of the session and is
gone on the next login - there is no keyring behind it to keep it safe. It is
still listed as `Sensitive content`, and copying it is a no-op once the session
that captured it is gone. The history is capped at 20 entries (pinned entries
are exempt from trimming) and the window is permanently sized for seven rows.

Use ++super+v++ to open it.

## Browsing the list

Every entry shows an icon reflecting its type, a title and a subtext line with
details, plus the time it was copied on the right:

| Type | Title | Subtext |
| ---- | ----- | ------- |
| Plain text | The text itself (trimmed) | word and symbol count |
| Web URL | The URL | `Web URL` |
| File | Path (cut from the front so the file name stays visible) | file size |
| Folder | Path | number of files inside |
| Archive | Path | archive size |
| Several files | `N files` | item count, folder/file breakdown, total size |
| Image | file path, or format name for image snapshots | dimensions and size |
| Network storage | share path without `proto://` (elided from the front) | protocol and host, e.g. `SMB • server` |
| Credentials | `Sensitive content` - payload never rendered or searched | `Credentials • Hidden` |

The preview pane on the right shows the full text of text entries and renders
images as stills. Folders show an info card (name, file count, total size)
built from the already-captured metadata - nothing is walked. A folder that
is a git checkout additionally lists branch, working-tree status, sync state,
last commit with date, author, and remote, gathered in the background when
the folder is copied and persisted per entry (revalidated each session), so
the rows are already there on first open. Binary files
show their name and path with no skeleton. Remaining non-previewable content
(file lists, videos, GIF animation, documents, databases) shows a placeholder
- the manager will not try to render them. Moving through entries fades the
pane from one contents to the next instead of swapping in one frame, and row
subtext swaps the same way.

## Pinning

Type `@` to enter the pinned mode (the chip appears in the search field) and
leave by clearing the query with ++backspace++. Pinned entries are skipped by
history trimming, survive a full clear and are marked with an accent bar.

| Action                          | Keys                        |
| ------------------------------- | --------------------------- |
| Move selection                  | ++up++ / ++down++ / ++tab++ |
| Copy selection to clipboard     | ++enter++ (all entries) |
| Type-to-filter / back to list   | just type / ++backspace++   |
| Pinned mode                     | type `@`                    |
| Delete selected entry           | ++delete++                  |
| Clear history (pinned survives) | ++shift+delete++            |
| Pin / unpin selected entry      | ++ctrl+p++                  |
| Close                           | ++escape++                  |

Pressing ++enter++ copies the selected entry back to the system clipboard
and promotes it to the top of the history, regardless of its type.

Use ++super+shift+v++ to clear the clipboard history without opening the
window.

External image data is snapshotted to `$VIBRANIUM_CACHE/clipboard-img` for
previewing and is removed when its entry is deleted or trimmed. Path-backed
image entries, including screenshots, are re-copied as `text/uri-list` file
URIs.

Deleting (or clearing) the entry the system clipboard currently serves also
empties the system clipboard, so the content cannot resurrect itself after a
reboot - wl-clipboard otherwise keeps re-offering whatever it served last.

Credential entries carried over from an older history file keep their row and
their metadata but never their payload: the file that held the cipher text also
held the key that opened it, which protects nothing, so the payload is read
once into memory if the key is present and dropped on the next write. A row
whose credential cannot be recovered reports itself as unavailable instead of
silently doing nothing when you press ++enter++.

## IPC

The service registers a `clipboard` IPC target, so scripts can drive it:

```sh
vb-shell clipboard toggle           # open/close (what super+v runs)
vb-shell clipboard status           # JSON counters
qs -p "$VIBRANIUM/shell" ipc call clipboard list              # history metadata JSON
qs -p "$VIBRANIUM/shell" ipc call clipboard view 0            # entry at filtered index
qs -p "$VIBRANIUM/shell" ipc call clipboard copy 2            # copy filtered index to system clipboard
qs -p "$VIBRANIUM/shell" ipc call clipboard remove 1          # delete filtered index
qs -p "$VIBRANIUM/shell" ipc call clipboard pin 0             # toggle pin
qs -p "$VIBRANIUM/shell" ipc call clipboard clear
```

### `list` returns metadata, not history

This is a deliberate break: `list` used to return the raw history array, and
anything that parsed it has to be updated.

The old payload was the history itself - every internal field, including the
entry's raw content. `list` now returns a wrapper object and, per entry, only
metadata plus a preview where a preview is safe:

```json
{
  "version": 2,
  "total": 12,
  "count": 11,
  "secrets": 1,
  "entries": [
    { "id": 7, "type": "text", "title": "notes", "subLeft": "2 words - 11 chars",
      "timeStr": "14:32", "pinned": false, "mime": "text/plain",
      "filePaths": [], "preview": "notes" }
  ]
}
```

What changed:

- `entries` is an array of objects, not the raw history array. `total` is the
  history length, `count` the number of listed entries, and `secrets` how many
  credential rows were withheld.
- Credential entries are never listed. `secrets` reports that they exist, but
  the rows themselves are absent, so there is no path from `list` to a
  credential.
- A `preview` is present for `text`, `url`, and `network` entries only, cut to
  200 characters. Image, file, folder, archive, and multi-select entries have
  no `preview` field at all.
- `raw`, `hay`, `words`, `icon`, `pathLike`, `imageFile`, `imageDataFile`,
  `imageSha`, and the derived counters are gone. `fileSize` appears when it is
  known; `filePaths` remains for path-backed entries.

`view` uses the same per-entry shape, so a script can read one entry from
`view` and the matching element of `list` without a second code path. Index
verbs (`copy`, `view`, `pin`, `remove`) still address the filtered list, not
the projected one, so a withheld credential does not shift an index.
