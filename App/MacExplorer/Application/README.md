# App-wide owners

ApplicationOperationCoordinator.swift, ApplicationStorageAnalysis.swift, ApplicationLocalTextEditors.swift, ApplicationSFTPConnections.swift and ApplicationSMBConnections.swift compose reusable domain modules. They own actual work and shutdown; views do not.

`ApplicationRemoteTextEditors.swift` registers the exact capable SFTP session and
working-copy store. It retains open/preparing/draining documents independently
of tab visits. Returning from its last editor requests a bounded refresh of the
same owner's current folder; it never navigates back to an old editor location
or replaces the generation of another still-open/pending document.

`ApplicationRemoteTextViews.swift` owns explicit current-server read-only captures.
It reserves before awaiting the existing bounded reader, closes the private lease
before presentation and reports protected leftovers rather than claiming removal.
Its immutable windows share editor presentation but no write/export authority.
Disconnect joins pending reads; Quit joins reads and native presentation teardown.
The old editor may select this path after a definite sync-unavailable refusal only
for an unchanged automatic Open request. Explicit Edit retains its write contract.
Read-only window presentation does not activate binary Download; product,
container and installed-helper admission remain independent.

These are folders within the same App module, not additional packages. Consult App/README.md and docs/engineering/README.md from the repository root.
