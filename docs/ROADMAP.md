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
- **Get to the bottom of a change.** Compare folders or text side by side,
  search across a diff, and copy missing files after a review. In a local Git
  checkout you can browse revisions and stage or unstage a file or a block.
- **Archives you can work in.** Browse and edit supported ZIPs, make ZIP or TAR
  archives, and work with members of plain, gzip and bzip2 TARs. Open familiar
  ZIP-based packages like JARs, EPUBs, CBZs and Python wheels.
- **A small editor with good habits.** Jump to a file or symbol, fold a long
  block, check a JSON draft or compare your changes with a Git revision. Save
  eligible local, archive or remote files without leaving Traverse.
- **Servers that feel at home.** Remembered SFTP and SMB connections, familiar
  file and folder actions, transfers between panes, and a useful way back after
  a disconnect.
- **A clearer picture of your storage.** Folder charts, saved analyses, supported
  SMART readings and file-based benchmarks with latency and matched comparisons.
- **The essentials around the app.** A dependable updater, local crash reports
  you can review before sharing, and a source tree contributors can find their
  way around.

Traverse runs on Apple Silicon and Intel with macOS 15 or later. The
[release notes](https://github.com/Respawn-Studios/Traverse/releases) tell you
what's in each downloadable build; the [feature guide](guides/features.md) goes
deeper into the current app.

## Next: make the good parts better

### Less tidying, more doing

We'd like to build on folder comparison with better ways to collect, filter and
review a batch before putting it to work. Better queue controls could let you
pause a transfer or give it less bandwidth when the connection supports it.
Git reviews could bring more of the surrounding history and conflict context
within reach of the file you're looking at.

### Archives without the detour

We want to make it easier to get just what you need out of an archive, with fewer
dialogs for the everyday actions and a fuller range of options when you need
them. We're exploring more formats, including XZ, and more of the same keyboard
and clipboard workflows you'd use in an ordinary folder.

### A lightweight editor that earns its place

We'd love to make more languages feel at home, from finding structure and
previewing a draft to spotting an issue and fixing it where you're already
typing. We'd also like to bring more of those review tools to remote and archive
editing. Think quick fixes between file operations and a comfortable place to
spend an afternoon in the same project.

### Know your drives

Faster refreshes that reuse earlier analysis, clearer scan history, richer
benchmark results, and health information for more drives and enclosures.
Useful charts should help you spot a change, rather than make you decipher a
wall of numbers.

We’re exploring clearer partition and volume maps, more useful workload choices,
and safe APFS volume management. Disk Utility is the handoff for formatting and
physical-drive changes today.

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
