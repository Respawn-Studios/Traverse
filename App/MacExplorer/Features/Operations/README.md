# Operation presentation

OperationRecoveryWindow.swift, GroupedCopyRecoveryWindow.swift and OperationProgressViews.swift render work owned by ApplicationOperationCoordinator/FileOperations. Never perform an inverse filesystem operation directly from a view.

The selected operation's App Logs action follows its opaque history identity
through the existing command/worker correlation graph. It never substitutes a
newer command, reads file contents or changes recovery authority. Expired or
unrecorded events can leave that scope empty. The shared operation worker emits
the returned history identity independently of throttled UI progress.

A fully validated v5/v6 ZIP update that stopped with no replacement step can
show “Stopped before ZIP replacement.” This is a historical stage distinction,
not a fresh observation of the ZIP. The saved state stays in review; Undo,
Restore and cleanup still use their existing engine checks. A recorded intent
without a confirmed result remains uncertain.

These are folders within the same App module, not additional packages. Consult App/README.md and docs/engineering/README.md from the repository root.
