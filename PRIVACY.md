# Privacy in Traverse

This describes Traverse's direct release and current source. Older
beta builds retain their own published release notes and feature limits.

Traverse processes your file work on your Mac. The app has no advertising SDK,
usage analytics, tracking identifier or automatic crash-report submission.
Optional development support does not track whether you donated or unlock
features. This describes Traverse's own behavior; macOS and services you choose
to use have their own settings and policies.

## Files, search and connections

Browsing and storage analysis use filesystem metadata. Opening, editing,
previewing, hashing, copying or archiving a file reads its contents as required
by that action. File-body indexing and cloud inference are not silently enabled
by browsing. Local preferences, remembered locations, analyses and recovery data
stay in the selected app data location.

Open With and Compare Files hand the selected paths to another local app.
Open Terminal Here hands off the current folder. Those apps use their own
settings, permissions and privacy policies.

SFTP and SMB communicate with the server you select. Those connections are not
local-only operations. Saved sign-in information uses the macOS Keychain only
when the relevant Remember option is chosen; connection profiles and refreshed
certificate access keep their own consent and verification rules. An account
with an administrative role does not grant the app permission to bypass a
server's filesystem permissions.

## App logs and crash reports

App Logs contain bounded technical events, versions, timings and failure codes.
They exclude file contents, filenames, paths, search text and passwords. Export
is an explicit action; review the exported material before sending it anywhere.

Local crash capture is separately controllable in Settings. A native capture can
contain process paths, loaded-image information, exception text and register
values. It stays in a private app-owned location, subject to both a five-report
count and a 4 MiB encoded storage limit; large captures may fill the limit sooner.
If storage cannot be confirmed or is full, Traverse keeps existing data and
pauses new capture. Capture cannot cover every termination, power loss, hang or
worker failure. It does not replace macOS's own crash reporting.

Help → Crash Reports & Feedback creates an editable sharing projection. It omits
native paths, registers, memory contents and free-form exception messages.
Binary UUIDs, code addresses and system/app versions remain useful for debugging
and can identify software versions. Add comments only if you intend to share
them. Hide Private Details is a convenience for common paths, URLs and contact
information, not a guarantee of anonymity. Inspect the final text yourself.

Reports include device details by default. Where the native capture provides
them, the hardware model and physical/logical core counts describe the Mac at
capture. A separate editable snapshot adds the current CPU family, logical
processor count, installed RAM and Traverse's resident memory when you prepare
the report. Current measurements are clearly labelled and do not describe the
moment of a past crash. Traverse does not collect serial numbers, device
identifiers, hostnames, memory contents or a background performance history.

Open GitHub Draft puts the reviewed text in a browser URL. Opening it sends that
text to GitHub and browser history before you submit the issue. Reports that
exceed Traverse's URL limit become explicitly abbreviated drafts; Copy Report
and Save Report keep the full reviewed text. Traverse never submits the issue.
You choose whether to attach material and publish it. GitHub issues may be public;
attachments upload as soon as they are attached, before an issue is submitted.
Never attach keys, tokens, private files or an unreviewed native capture.

Remove Local Copy removes Traverse's retained copy, not an OS report, a browser
copy, a backup or a GitHub issue. Ordinary deletion does not promise secure
erasure from SSDs or snapshots. Crash-capture preference changes apply on the
next launch.

## Updates and external links

Update checks contact the selected Respawn Studios feed when requested or when
you enable automatic checking. The direct edition uses a separate feed from the
older scoped edition. System profiling and automatic crash upload are disabled.
Normal network infrastructure can still observe a request's IP address and
technical HTTP data; this is not a claim that contacting a server is anonymous.

Source, community, documentation and voluntary-support links open the chosen
site in your browser. GitHub, Discord and Buy Me a Coffee have their own privacy
policies. Traverse does not load those pages or payment forms in the background.

For a vulnerability, do not post private evidence in a public issue. Use the
repository's private vulnerability-reporting channel when it is enabled. General
questions belong in the [community](https://discord.gg/UdKp2uQBQy) or
[project repository](https://github.com/Respawn-Studios/Traverse).
