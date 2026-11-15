# Where Traverse is going

We want the Mac file manager we keep wishing existed: comfortable enough for
everyday folders, powerful enough for a server, and pleasant enough to leave
open all day. Native Mac feel, fewer clicks, more room for your files.

Here's what we're building, what we'd love to tackle next, and a few ideas that
keep finding their way onto the whiteboard. Pick an area that excites you and
come talk to us in [Discussions](https://github.com/Respawn-Studios/Traverse/discussions).

## Ready to explore

Our first public releases bring the main pieces together:

- **A workspace that stretches with you.** Tabs, up to four panes, a sidebar you
  can rearrange or tuck away, and readable names even in a narrow pane.
- **Everyday actions that stay out of your way.** Copy, move, rename, native
  Trash and Undo, with useful choices when two files want the same name.
- **Archives you can work in.** Browse and edit supported ZIPs, make ZIP or TAR
  archives, and extract or copy what you need without unpacking everything.
- **A small editor with good habits.** Local and remote Save, Find/Replace,
  indentation and saved versions, all without leaving Traverse.
- **Servers that feel at home.** Remembered SFTP and SMB connections, familiar
  file and folder actions, transfers between panes, and a useful way back after
  a disconnect.
- **A clearer picture of your storage.** Folder charts, saved analyses, supported
  SMART readings and file-based benchmarks in one place.
- **The essentials around the app.** A dependable updater, local crash reports
  you can review before sharing, and a source tree contributors can find their
  way around.

We started on Apple Silicon; 0.2.0 brings a separate Intel package too, with
macOS 15 or later required. The
[release notes](https://github.com/Respawn-Studios/Traverse/releases) tell you
what's in each downloadable build; the [feature guide](guides/features.md) goes
deeper into the current app.

## Next: make the good parts better

### Less tidying, more doing

Better batch organization, saved workspaces, selection tools and previews.
Folder comparison is high on our list, followed by synchronization where you
can see exactly which direction changes will travel. We'd also like richer
transfer queues, bandwidth controls and pause/resume where the connection
supports it.

### Archives without the detour

More writable formats, deeper folder and member editing, and direct actions
for the things people do most often. The aim is simple: working on a file in an
archive should feel as ordinary as working on a file in a folder.

Development builds now bring the shared workbench and editor to plain, gzip and
bzip2 TARs. We're working through their delivery and recovery checks before
they join a download. XZ and other formats are further down the list.

### A lightweight editor that earns its place

Richer language support, smarter editing conveniences and better remote editing.
We want it to be the editor you happily use for a quick fix, without turning
Traverse into a giant IDE.

### Know your drives

Faster refreshes that reuse earlier analysis, clearer scan history, richer
benchmark results, and health information for more drives and enclosures.
Useful charts should help you spot a change, rather than make you decipher a
wall of numbers.

The current development work adds a mixed benchmark suite, latency charts and
comparisons. APFS work includes Add Volume for disk images and a formatting
backend being checked on generated images. Normal formatting controls and
physical-drive changes are still ahead; Disk Utility remains the handoff.

## Further down the trail

- **Your storage, wherever you keep it.** Cloud providers alongside open-source
  and self-hosted services, with the same familiar workspace.
- **Your devices, closer together.** Better NAS and network discovery, plus
  native iPhone, iPad and Android companion apps for easy nearby transfers.
  Something with the ease of AirDrop, across more of your devices.
- **More power at your fingertips.** File comparison and hashes, link tools,
  useful Git context, terminal handoffs and custom actions.
- **More hardware stories.** Intel packages join Apple Silicon in 0.2.0. We'd
  love feedback from different Macs, drives and enclosures to make the next
  round of compatibility improvements practical.

## Help shape the journey

Have a workflow that takes ten clicks and should take two? Tell us. Found a
rough edge? [Open an issue](https://github.com/Respawn-Studios/Traverse/issues).
Want to build something? The [contributor guide](../CONTRIBUTING.md) is a good
place to start. Good bug reports, documentation and accessibility improvements
matter just as much as shiny new features.

Traverse stays free and open source. If it saves you time, you can
[buy Respawn Studios a coffee](https://buymeacoffee.com/respawnstudios).
No feature unlocks, just a little more fuel for the next stretch of the trail.
