# A look inside Traverse

These are real app-window captures with made-up folders, taken from development
version **0.1.6 (91)** on **macOS 27.2**, running on Apple Silicon.
They're here to show the current workspace; check your download's release notes
for the features in that build.

- **Side by side:** independent folder panes, several tabs and the shared sidebar.
- **Find your way:** an editable address with folder suggestions. Tab fills a
  suggestion and Return opens it.

The captures use the system's dark appearance, Glass navigation and sidebar,
opaque file content, 100% interface size and Full motion. The frame includes
only the app window. macOS's purple window-sharing indicator is visible in the
title bar.

The images are unretouched. No interface elements, file names or status messages
were reconstructed. [The manifest](manifest.json) records dimensions, hashes and
the source revision so future screenshots are easy to replace together.

For new captures, follow the [media guide](../README.md). Use demo data, give the
window room to breathe, and keep the original capture locally. A static image
should still explain the feature when an animation isn't playing.

## The next screenshots

The [GIFs](../tutorials/README.md) already cover panes, folder operations, storage
breakdowns and address suggestions. These stills would show the other sides of
Traverse. Use a released build and record its version; keep development captures
labelled until those features reach a release.

Save PNGs of the app window at about 1,200 to 1,400 pixels wide, with Dark appearance,
Glass enabled and 100% interface size. Use demo files so the picture can be shared
as it stands. Keep the original PNG, including the window title and footer.

1. **A server beside local files.** Open the main Traverse window with two
   vertical panes. Put a local `Traverse Demo` folder on the left, containing
   `Projects`, `Photos` and `Notes.md`. On the right, open a disposable folder on
   an SFTP server, using a connection name you are happy to share, such as
   `Demo Server`. Put `Documents`, `Images` and `Guide.md` there. Select
   `Guide.md`, leave both lists visible with no menus open, and capture the main
   window. This shows the shared local/server browsing experience.
2. **Edit a file inside a ZIP.** Create `Weekend Project/config.json` with a few
   JSON settings, then compress `Weekend Project` to ZIP in Traverse. Open that
   ZIP and edit `config.json` in Traverse. Change one setting and leave the editor
   open before saving. Capture the editor window with its archive source, line
   numbers, Save controls and JSON mode visible. The main browser is a separate
   optional still if you'd like to show the archive's folder structure too.
3. **A finished drive benchmark.** Open the Drives window and select its
   Benchmark page. Choose a disposable test folder on a writable drive and run
   the default short benchmark once. When it finishes, keep the selected drive,
   workload, read/write results and chart visible. Capture that window with no
   tooltip covering the result. Automatic health monitoring can stay off.
4. **Optional: a conflict with clear choices.** Create `Source/Report.txt` and
   `Destination/Report.txt` in a demo folder. Show Source and Destination in two
   panes, copy the source file into Destination, and capture the main window
   while its conflict choices are open. Cancel afterward. This should show the
   existing file being protected and the choices available to the user.

Two clickable screenshots per row work well in the README. Each thumbnail can
open the full PNG; the feature guide can hold the extra views without making the
front page too long.
