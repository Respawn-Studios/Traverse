# Settings

Settings.swift owns preferences and the settings form. BrowserSettingsNavigation.swift/SettingsSearchCatalog.swift provide navigation/search. EditorTools settings are in the Editor feature. Folder-opening/default handlers retain their explicit platform/action semantics.

These are folders within the same App module, not additional packages. Consult App/README.md and docs/engineering/README.md from the repository root.

General's Community preference controls optional update support messages.
SupportReminderPreferences is an additive, local Codable preference; do not put
payment history, account identifiers or support entitlements in browser settings.

Public update checks use the separate default-off `publicAutomaticUpdateChecks`
preference. They never inherit the private beta's existing automatic-check or
saved-invitation choice. The same setup and Help views bind the correct choice;
`ApplicationUpdates` owns its lifecycle rather than the settings form.

Operations stores `quickCompressionFormat` in the versioned settings snapshot.
Older snapshots default to ZIP. Unknown values and newer snapshots stay
preserved rather than being overwritten. The command captures its format before
preparation and checks edition availability again before publishing; a
recognized saved format that is unavailable in this edition stays disabled
instead of switching types.
