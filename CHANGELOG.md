# Changelog

Public Traverse releases live here. Each download also has its own notes on
[GitHub Releases](https://github.com/Respawn-Studios/Traverse/releases).
Earlier private-beta version numbers belong to a separate release history.

## Unreleased

### In development

- Plain and prepared gzip/bzip2 TAR member editing through the shared archive workbench and native
  editor: Rename, batch Rename, Remove, Duplicate, Move, Add, Create File/Folder, Group and
  Cut/Copy/Paste. Original updates retain the earlier archive for guarded Undo.
  This remains a development feature pending distribution qualification.
- TAR.gz and TAR.bz2 creation through the shared archive publisher, with
  compression choices and guarded Undo. Gzip edits preserve bounded optional
  headers; bzip2 edits keep the current compression setting by default.
  Common `.tgz`, `.tbz2` and `.tbz` names keep their wrapper identity through
  opening, editing and creation.
- A saved Quick Compress format in Operations settings. Development builds
  offer ZIP, TAR, TAR.gz and TAR.bz2; the one-click command uses the selected
  format and numbers occupied names without splitting compound extensions.
  Compress… keeps the full creation controls.
- Explicit Replace Files for TAR additions, with binary-file support, a
  captured preview, unchanged local inputs and guarded Undo. Keep Both remains
  the default; folder replacement and merging are refused.
- Benchmark block-size and file-cache options, with requested and actual cache
  behavior recorded in results and exports.
- A bounded Quick Mix benchmark, matched suite comparisons and readable
  per-block latency distributions alongside the existing result metrics.
  Copied text and JSON results include the same completed-call distribution.
- Deliberate compressed-TAR Open in Development includes bounded preparation.
  Passive restore and return to a changed archive still wait for Prepare.
- Archive export completion keeps the same selection ready for another drag,
  while late work cannot replace a newer archive view's message.
  Early destination/admission refusals leave a source-window explanation and
  a sanitized diagnostic event.
- Editor closing follows animation preferences while retaining text until the
  native window closes. Quit joins a Close or its chosen Save already in progress.

### Fixed

- Saving a copy of an edited, marked ZIP uses a fresh macOS protection mark
  without copying the source's security attributes. The original stays intact
  and the new copy supports guarded Undo.
- Creating a folder and finishing Rename keep the current listing visible while
  its replacement loads.
- Pane transitions leave unchanged neighbours still, preserve Glass backgrounds
  and finish sooner. Larger interface sizes reserve enough room for the footer.
- Details lists avoid a layout loop when restoring the sidebar in a split workspace.
- Properties keeps its chart and scroll position steady when changing storage
  groups, drilling into a slice or going Back. Repeated groups reuse stored totals.
- Settings, What's New, Properties and Analyzer share native opening and closing
  transitions. Discarding an unsaved Properties draft follows the same close flow.
- Separate ZIP and TAR browser windows follow the same motion preferences,
  including an interrupted Close and reopening the existing window.

## [0.2.0] - 2026-11-15

### Added

- Separate Intel and Apple Silicon packages built from one source revision.
  The app and every bundled worker match the selected CPU. macOS 15 remains
  the minimum; Intel compatibility was exercised under Rosetta, with native
  Intel testing still welcome.
- Architecture-specific signed update feeds and automatic package selection in
  the Homebrew tap. Existing Apple Silicon clients keep their established feed.
- Wiki walkthroughs for the workspace, servers, archives, editing, storage and
  recovery, plus this public changelog.

### Security

- Updated russh to 0.65.1 and Tokio to 1.54.1 across the production and retained
  qualification lockfiles. The Windows-only transitive Pageant dependency is
  also patched to 0.2.5; it is not shipped in the Mac app.
- Refreshed checksum-bound source and license notices for both macOS targets.
- Release admission binds the actual app/helper architecture and signed marker
  to the requested case before notarization and installer readback.

Build 95. Existing file-operation protections and access policies are unchanged.

## [0.1.1] - 2026-11-15

### Fixed

- A successful update check keeps “You're up to date” in Help after its alert
  closes, instead of showing a misleading failure.
- About uses public-release wording alongside the exact version and build.
- The optional support invitation appears after the second launch, remembers
  each released update and respects its local opt-out. Every feature stays free.

Build 94. File operations and access policies are unchanged from 0.1.0.

## [0.1.0] - 2026-11-15

Our first public, open-source release. Build 93 targets Apple Silicon and
macOS 15 or later.

### Added

- Tabs, up to four panes, saved workspaces and an editable address with suggestions.
- Local file operations, collision choices, native macOS Trash and guarded Undo.
- SFTP and SMB transfers, supported server actions and text editing with saved
  versions and protection against overwriting a changed remote file.
- ZIP/TAR browsing, creation and extraction, plus changes inside supported ZIPs.
- A native text editor with syntax colours, Find/Replace, smart indentation and
  familiar Undo/Redo.
- Metadata-based storage analysis, saved results and supported drive tools.
- Local crash reports with a reviewed GitHub issue draft, a signed updater and
  Homebrew installation.

The [feature guide](docs/guides/features.md) covers formats, limits and supported
workflows. Intel builds, broad external-drive SMART support and physical drive
formatting were not qualified for this release.

[0.2.0]: https://github.com/Respawn-Studios/Traverse/releases/tag/v0.2.0
[0.1.1]: https://github.com/Respawn-Studios/Traverse/releases/tag/v0.1.1
[0.1.0]: https://github.com/Respawn-Studios/Traverse/releases/tag/v0.1.0
