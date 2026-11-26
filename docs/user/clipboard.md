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

Image data, including screenshots, is snapshotted to
`$VIBRANIUM_CACHE/clipboard-img` for previewing and is removed when its entry
is deleted or trimmed. Snapshot entries are re-copied as raw image data;
path-backed image entries are re-copied as `text/uri-list` file URIs.

Deleting (or clearing) the entry the system clipboard currently serves also
empties the system clipboard, so the content cannot resurrect itself after a
reboot - wl-clipboard otherwise keeps re-offering whatever it served last. When
a single delete removes that entry, the row that moves into the top slot is
copied to the clipboard in its place, so paste returns the new first entry
instead of the one just deleted.

Credential entries carried over from an older history file keep their row and
their metadata but never their payload: the file that held the cipher text also
held the key that opened it, which protects nothing, so the payload is read
once into memory if the key is present and dropped on the next write. A row
whose credential cannot be recovered reports itself as unavailable instead of
silently doing nothing when you press ++enter++.

## CLI

The public scripting surface is `vb-shell clipboard`; the old native
`qs ipc call clipboard ...` verbs are retired.

```sh
vb-shell clipboard window toggle         # show/hide (what super+v runs)
vb-shell clipboard window toggle pinned  # show pinned when opening
vb-shell clipboard window open pinned    # open in the pinned view
vb-shell clipboard status                # counters plus copyBusy; no content
vb-shell clipboard list                  # normal bucket
vb-shell clipboard list pinned           # pinned bucket
vb-shell clipboard list current          # open panel's current filter
vb-shell clipboard pin 0                 # pin a normal-bucket row
vb-shell clipboard unpin 0               # unpin a pinned-bucket row
vb-shell clipboard purge 1               # delete a normal-bucket row
vb-shell clipboard purge pinned 0        # delete a pinned-bucket row
vb-shell clipboard clear                 # clear normal; pinned rows survive
vb-shell clipboard clear pinned          # clear pinned; normal rows survive
vb-shell clipboard select 2              # seat a row of the open panel
vb-shell clipboard copy entry regular 2
```

`vb-shell --help` is the local CLI guide; it does not contact the shell.
`-j`/`--json` selects typed JSON, where a success is
`{"v":1,"ok":true,"data":...,"format":...,"next":...}` and a failure is
`{"v":1,"ok":false,"error":{"code":"...","message":"..."}}` on stderr. A
silent operation omits `data` (it is not the same as `"data":null`), and paged
lists arrive as `items` with an optional `next` cursor. Exit status is 0 for
success, 2 for `usage`/`unknown-target`/`unknown-command`/`invalid-argument`,
and 1 for every other failure. `copy` stream formats are the client-owned exception
that take data on stdin or a private client route; no payload is ever placed
in argv, a socket frame sent to the shell, a log, or a reply. Protected rows
and invalid indices fail with `invalid-index` and never leak content in either
output format.

### Lists project content, not metadata

`list`, `list pinned` and `list current` return **only** `{index,content}` rows:

```json
[ { "index": 0, "content": "notes" }, { "index": 1, "content": "<image>" } ]
```

Text content is a bounded safe preview (whitespace folded, terminal controls
removed, at most 80 Unicode code points). Non-text rows use the fixed markers
`<image>`, `<file>`, `<folder>`, `<archive>` and `<binary>`. Paths, MIME types,
entry ids and raw payloads are never published. Protected rows (secrets,
credential MIME types and rows holding a secret handle) are omitted from
lists; an indexed read or action on one fails with `invalid-index`, exactly
like an out-of-range or nondecimal index.

Indices are ephemeral positions in the bucket or current filter. Resolve one
with `list`, `list pinned` or `list current` immediately before using it; it is
not a long-lived id. `select` addresses the open panel's current filter only.
Unpinning a row is not a delete; purging uses the same staged deletion path as
the UI.

### Writing new data

`vb-shell clipboard copy` writes directly to the system clipboard with
`wl-copy --type <mime>`. The shell's own watcher captures the write as a normal
history entry; no special entry is injected. The payload never appears in a
command envelope, temporary file, log or reply.

```sh
vb-shell clipboard copy text 'hello world'
printf 'from stdin' | vb-shell clipboard copy text -
vb-shell clipboard copy text -- -        # a literal dash, not stdin
vb-shell clipboard copy uri 'https://example.org/a'
vb-shell clipboard copy file ./notes.txt
vb-shell clipboard copy image image/png - < shot.png
```

Text from stdin is strict UTF-8 and capped at 32 MiB. Image bytes must match
the declared PNG/JPEG/GIF/WebP/BMP/TIFF magic and are also capped at 32 MiB;
they are written unchanged. The command confirms `clipboard ping` before
writing and uses a five-second writer deadline.
