# ipptool request templates

Nine IPP request templates driven by `Printers.qml` through `runIpp()`, with
their responses parsed by `PrintersLib.js`. They are data: a template is a
request body, not code.

| Template | Operation |
| --- | --- |
| `printers.test` | CUPS-Get-Printers |
| `jobs.test` | Get-Jobs |
| `hold.test` | Hold-Job |
| `release.test` | Release-Job |
| `cancel-job.test` | Cancel-Job |
| `sub-create.test` | Create-Printer-Subscription |
| `sub-renew.test` | Renew-Subscription |
| `sub-cancel.test` | Cancel-Subscription |
| `sub-list.test` | Get-Subscriptions |

## Variables

`$user`, `$puri`, `$jobid` and `$subid` are `ipptool` variable references the
caller substitutes; they are not literals. `requesting-user-name` must be
identical across every request, because a different value in any one
template would make CUPS treat the subscription as belonging to somebody
else, and the queue would stop being owned by this shell. Each template
carries `ATTR name requesting-user-name $user`.

## Requested attributes

Each template names the attributes it will read. `requested-attributes` is an
explicit list per operation, and `parseReport()` in `../PrintersLib.js` is
anchored on one of them (`printer-name` for `printers.test`, `job-id` for
`jobs.test`). A template that stops sending its anchor, or an anchor that
moves out of the list, silently produces zero rows.

Only the three list-returning templates carry `requested-attributes`. The six
mutating ones cannot: Hold-Job, Release-Job, Cancel-Job and the subscription
operations return no attribute groups to name.

## Subscription identity

`sub-create.test` also carries the notifier identity:
`notify-recipient-uri dbus://`, the `notify-events` set
(`printer-state-changed`, `job-state-changed`, `job-created`,
`job-progress`), a `notify-lease-duration` of 86400, and
`notify-user-data VB01-printers`.

No printer-level admin operations.

## Coverage

The templates have no coverage at all: a malformed template is a runtime
failure in `Printers.qml` with nothing to catch it at test time. This suite
is the closest thing to that coverage - it validates grammar, the shared
`requesting-user-name`, the per-operation attribute lists and the
subscription identity by reading the files, without starting a printer or a
cupsd.
