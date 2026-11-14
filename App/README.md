# Native application source

The application module remains `MacExplorer`; the product is Traverse. Xcode's
filesystem-synchronized group discovers Swift files recursively, so feature
folders do not create extra targets, libraries or build copies.

Start with `MacExplorer/App.swift` (app entry/composition) and
`MacExplorer/AppStorageLocations.swift` (profile locations). Then follow:

- `Application/`: app-wide operation/queue, access, analysis, editor and server owners.
- `Browser/`: the real browser controller, table/icon canvas, address, tabs,
  selection, clipboard, sidebar and commands.
- `Features/`: Archives, Connections, Drives, Editor, Help, Onboarding,
  Operations, PrivateNames, Search, Settings, Sharing, StorageAnalysis, Trash and Workspace.
- `Shared/Presentation/`: `ToolWindowPresentation.swift`, `Appearance.swift`,
  `InterfaceSizing.swift`, material, motion and reusable control appearance.
- `Development/Checks/`: generated native checks and debug-only support.

Each source file has one location. Debug fixture guards bind checks to the
compiled checkout and its generated roots.

Reuse shared window/theme/motion policy. Keep filesystem mutations in the existing
operation modules and app owners, not in view callbacks. See the
[engineering guide](../docs/engineering/README.md) for development and verification.

Native file promises rely on `NSFilePromiseReceiver`'s coordinated callback
lifetime. Do not acquire a second coordinator for that same destination inside
the callback. The concrete archive/server owner retains its source/session,
checked destination access, cancellation, durable operation outcome and
exactly-once completion. AppKit coordination grants no folder access and does
not activate an independently held distribution feature.

After a real destination choice and a successful fresh destination check,
archive/server exports may retain that exact scope-bearing URL through the
existing browser folder-access owner for the session. Each job keeps its own
lease until drain; a later job reacquires access and revalidates the destination.
Cancel retains no grant. This creates no saved bookmark and does not share a
pending chooser's cancellation owner.
