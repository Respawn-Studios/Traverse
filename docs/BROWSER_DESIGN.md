# Browser behavior

Traverse combines familiar file workflows with native Mac controls, keyboard
behavior and window presentation. These are implementation principles for
contributors; platform/provider limitations belong in the user-facing
[feature guide](guides/features.md).

## Workspace

The window contains a command header, independent pane tabs, navigation/address
controls, a shared sidebar, file content and a shared bottom operation area.
The optional bottom path bar remains separate from status and progress.

A workspace can contain up to four panes. Each pane keeps its tabs, history,
filter, sort, selection and view mode. The active pane owns file commands; its
sidebar/footer presentation uses the shared workspace hosts. Accepted transfers
and their results remain app-owned when a pane closes. Closing the final pane
cannot leave an invalid workspace.

The sidebar is resizable and fully collapsible through the View command or
native divider. A restore control appears in the footer only while collapsed.
Restore uses the previous expanded width; hiding the sidebar preserves expanded
branches and user ordering. Full, Reduced and Off motion share the same final
geometry and respect the system Reduce Motion setting.

## Navigation and content

Breadcrumbs, literal path editing and current-folder search share the existing
header controls. Navigation accepts a concrete location; a suggestion is not
authority to open or mutate a different item. Stale completions and menus cannot
act on another visit. Switching a search scope preserves the query without
submitting it. Recursive or indexed search starts on explicit submission.

This Mac presents drives and remembered servers in coherent categories. Unknown
capacity, unavailable locations and disconnected servers remain honest states.
Remote folders use the same file-type icons and selection conventions where
supported. Remembering a server is separate from saving credentials or trusting
a changed identity.

Details, List and Icons share selection and command owners. Name remains visible
and takes priority over default metadata columns in narrow panes. User-resized
columns keep their choices, with horizontal scrolling when necessary. Empty
space supports the same live selection rectangle as the icon-side gap.

## Commands and focus

Native text fields, editor Undo, IME composition, system shortcuts and user menu
overrides take priority over browser file commands. A menu captures its actual
browser, visit and selection while open; it cannot authorize another window or
a newer selection. Closing a filter or menu must not steal a different pane's
established focus.

Common context actions appear before advanced options. A direct action performs
the usual task with current preferences; an ellipsis action opens configuration
or review. Commands share implementation across the menu bar, in-window menus,
keyboard shortcuts, context menus and footer controls.

Drag preparation and destination observations run off the main actor. A green
badge or drag preview is presentation, not proof of completed delivery. Native
callbacks retain their exact source and destination through validation, transfer,
completion and cleanup. Existing files are not silently replaced.

## Shared presentation

Use the existing `Shared/Presentation` window, navigation, typography, material
and motion components. Tool windows may have different layouts while retaining
the same theme, sizing, accessibility and close behavior. Keep text readable at
larger interface sizes and inspect actual visible transitions after functional
checks. See [file-operation semantics](FILE_OPERATIONS.md) for integrity rules.
