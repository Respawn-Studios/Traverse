# Repository media

This directory holds the artwork and real app captures used around the project.
[Branding](branding/README.md) has the banner and existing app icon;
[screenshots](screenshots/README.md) show the workspace with demo folders;
[tutorials](tutorials/README.md) show the public app in motion.
Runtime resources stay with the app, and rough development recordings stay local.

Use these subdirectories when material is ready:

| Location | Intended material |
| --- | --- |
| `branding/` | Repository banners and promotional logo variants |
| `screenshots/` | Accepted-build screenshots for README and user guides |
| `tutorials/` | Short GIF/WebP demonstrations and their editable source notes |

Keep runtime assets in `App/MacExplorer/Resources/` and the existing asset source
owner under `tools/app_assets/`; do not duplicate an icon into application code.
Link large videos through release assets or the project's site rather than
committing repeated video exports to Git. Future media publication is separate
from preparing this directory.

For each capture, record the app version/build, platform, appearance/text-size
settings and task being demonstrated. Use generated filenames and data; inspect
the whole frame for private paths, server/account details and notifications.
Keep edits truthful and preserve the original capture for maintainers.

Use original or appropriately licensed material with clear provenance. Preserve
third-party attribution and do not imply a new media license without an owner
decision. Add useful alt text and a static alternative to motion-heavy tutorials.
Prefer relative links so the README also works in a source archive.
