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

In development builds, you can compare two folders from one selection or
from neighboring panes. Open a difference, check the bytes, and review the
exact selection before copying missing files across. Inside a local Git checkout,
compare folder trees from two revisions, see what’s staged, and stage or unstage
one block of a text diff. Better batch organization, selection tools and richer
queues are on the list, with bandwidth and pause controls where the connection
supports them.

### Archives without the detour

More writable formats, deeper folder and member editing, and direct actions
for the things people do most often. The aim is simple: working on a file in an
archive should feel as ordinary as working on a file in a folder.

Version 0.3.0 brought the shared workbench and editor to plain, gzip and bzip2
TARs, including creation, member changes, Finder exports and Undo after restart.
Next comes a smoother keyboard and clipboard journey across archive windows.
XZ and other formats are further down the list.

### A lightweight editor that earns its place

The editor in development builds has a project tree, a list of open buffers and
a document outline. Jump to a file by name, then compare the draft with a saved
version or browse its Git history across a rename. We’d love to keep adding
language smarts and bring more of these review tools to remote editing. The goal
is an editor you’re happy to open for a quick fix or leave open for an afternoon.

### Know your drives

Faster refreshes that reuse earlier analysis, clearer scan history, richer
benchmark results, and health information for more drives and enclosures.
Useful charts should help you spot a change, rather than make you decipher a
wall of numbers.

Quick Mix, latency charts and matched comparisons arrived in 0.3.0. Current work
makes those distributions easier to read and brings saved analyses into Drives.
APFS work includes Add Volume for disk images and a formatting
backend being checked on generated images. Normal formatting controls and
physical-drive changes are still ahead; Disk Utility remains the handoff.

## Further down the trail

- **Your storage, wherever you keep it.** Cloud providers alongside open-source
  and self-hosted services, with the same familiar workspace. We want to start
  with folders you choose from macOS, including iCloud Drive and folders made
  available by installed sync apps. A file that still needs downloading should
  look different from one that's ready to use.
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
