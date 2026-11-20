# Generated native workflows

Use existing journeys after relevant behavior changes. They share the ordinary
app and incremental build. Start with `python3 -B tools/dev.py native-check --help`
and choose the check that exercises the changed route. See the
[engineering guide](../docs/engineering/README.md) for validation levels and
[file operations](../docs/FILE_OPERATIONS.md) for integrity contracts.

| Area | Existing entry |
| --- | --- |
| Local text editing | `native-check local-editor`, `editor-preferences`, `editor-lines` |
| Native text diff, exact match navigation and change previews | `check section editor-comparison` or `native-check editor-comparison` |
| Text diff stacking and reflow while resizing | `native-check editor-comparison --motion` |
| Local folder and pane comparison | `verify-ui --check-substantial --count 160` |
| Git tools, index actions, revision pickers and file history | `verify-ui --check-git --count 160` |
| Guarded Stage and Unstage only | `check section git-index` or `verify-ui --check-git --git-index-only --count 160` |
| Archive creation | `native-check create-zip`, `create-tar` |
| ZIP edits | `native-check zip-add-copy`, `batch-rename` and the relevant editor journey |
| Compressed TAR | `native-check compressed-tar` |
| Archive native exports | `native-check archive-export --archive-format zip`; choose TAR/gzip/bzip2 for its concrete producer |
| Grouped operations | `native-check selection-group` |
| New Folder and inline rename motion in Details, List and Icons | `native-check selection-group --motion`, optionally add `--large-interface` for Light at 150% |
| Saved analyses | `native-check analysis-persistence`; `--incremental-analysis` adds the retained-source refresh pair |
| Generated chart presentation | `native-check storage-chart` |
| Support report review | `native-check support-details` |
| Native Terminal and FileMerge handoff | `native-check external-tools --interactive` |
| Shared tool windows | `native-check tool-windows` |
| Settings, Help, Properties and Analyzer opening/closing | `native-check window-lifecycle` |
| Pane motion, geometry and authenticated tab routing | `native-check pane-motion` |
| Properties Storage grouping, scroll position and stored-result handoff | `native-check storage-chart-integration` |
| Remote metadata | `native-check connection-metadata --connection-phase find` or `viewport` |

Run entries through `python3 -B tools/dev.py`. Use each entry's help for accepted
flags; recording and layout flags are feature-specific. Existing Settings/Help/
Drives flows support normal, reduced and off motion, with enlarged/light options
where offered. [Motion review](ui_motion/README.md) describes retained capture
inspection and the cached decoder.

Offscreen mode, where supported, exercises generated functional commands without
visible-input or visual acceptance. Native focus, materials, motion and physical
input require an unlocked foreground session and the exact generated app/window.
An Accessibility press or value setter alone does not establish actual keyboard
input, submitted binding or successful connection. Do not inspect password values.

Generated flows own only their marked repository-local fixtures. They do not
authorize personal documents, real Trash, credentials, a server, OS preferences or
publication. Real-connection checks require explicit generated listeners and
private secret input; the native check does not start a server implicitly.
Body-transfer, external receiver, sandbox grant, device and installed signature
validation remain separate from metadata or view checks.

Archive exports use the same `native-check` owner and current Debug build as the
other journeys. Callback checks do not establish a physical Finder drag. Add
`--external-promise-receiver` for actual file/folder delivery into its generated
Finder destination and matching Undo. Build first, then use `--skip-build` while
that product is current. Neither flow grants access to personal files or
qualifies a sandboxed distribution.

The explicit external-tools check opens Apple's Terminal on one generated folder
and FileMerge on two tiny generated text files. It refuses to start while
FileMerge already has a running session. Ordinary Open With/Share regression
checks keep their injected launch sinks. Confirm the resulting folder and diff,
then close only those generated windows; leave existing Terminal work alone.
The handoff receipt distinguishes API acceptance from visible app verification.

The local-editor Save/focus journey retains native key-window guards and has no
offscreen mode. Before automated input, verify the exact generated process,
window and selection. Keep failure receipts and recovery data; inspect a failed
wait before retrying the journey. A passing fixture check is evidence only for
its exercised operation, source, product and runtime conditions.
