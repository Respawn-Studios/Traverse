# Storage analysis

FileProperties.swift and StorageAnalysisWindow.swift are the two user surfaces. StorageScanPresentation.swift shares scan wording/time formatting. Application/ApplicationStorageAnalysis.swift owns scanners/results; ExplorerKit/StorageAnalysis and the Rust worker own traversal/classification/query behavior.

`AppStorageInventory.swift` contains the shared declared app-state metadata
preparation, separate from Properties' view/controller. Its application owner
runs inspection off-main. This is a source relocation within the same App
module; it adds no traversal, state, mutation or package boundary.

Recent explicit analyses use `ApplicationRecordedAnalysis` and the existing
StorageAnalysis retained owner. Properties and the full window share a revocable,
read-only recorded view. A dated chart is never proof of current usage or file
mutation authority. Refresh uses the same ordinary scanner; Forget removes only
the saved catalog/index after readers finish. Hover first borrows an existing
standard saved analysis for the exact folder or its nearest recorded parent,
including across launches. A bounded page lookup returns that descendant's
recorded totals and original scan date; it never follows symlinks or treats a
missing folder as zero. The current parent access/identity check remains required.
At most32 catalog pages and64 path components are admitted within a2s lookup
budget; an individual existing query retains its own timeout and real drain.
Unavailable/busy/out-of-budget lookups fall back to ordinary bounded hover work.
This is dated metadata reuse, not incremental validation or a faster full scan.

The ordinary Properties and Analyzer **Refresh** actions reuse eligible saved
standard local-folder observations by default. A shared coordinator consumes
the next request's metadata scope first, then chooses changed-folder refresh
or full traversal. Application-data, unsupported or uncertain refreshes fall
back to full traversal. **Scan Every Folder** in either surface's Scan options
always requests full traversal; Settings can also turn reuse off. No new scan
starts on a passive reopen. Change hints choose metadata enumeration and the
same retained owner publishes a new immutable generation; reused observation
dates and actual retained scan duration remain explicit.

While a Refresh keeps earlier totals on screen, Properties labels their duration
as **Previous scan time**, rather than presenting it as the new scan's elapsed
time. Analyzer cleanup commands follow the current build's actual admission;
held builds point users to the ordinary Traverse browser. Both analyzer Undo
availability and execution apply the same recovery-record policy as browser Undo.
This does not enable direct cleanup or grant authority to saved observations.

`python3 tools/dev.py native-check analysis-persistence` exercises the real
Properties/full-window flow over three processes with a tiny generated source:
save, cold reopening/descendant hover/Refresh/Forget, then explicit interruption repair. The
domain's reusable retained tests cover interruption and cold storage failure.
Do not create another app/package copy for this feature.

The same command supports `--offscreen` for the complete generated functional
journey, including `--incremental-analysis` for its strict retained-source pair.
It hides only this generated process's windows after explicit presentation,
performs no capture or physical input, and reports no visual acceptance. Motion,
interactive and enlarged-interface checks still need the normal visible route.
This lets metadata/recovery checks continue while the Mac is locked without
claiming that the interface was inspected.

The refresh event plan now retains one recursive subtree instead of redundant
descendant scopes. Direct-only parents and byte-distinct sibling/Unicode paths
remain distinct, with the same256-path/48KiB limits and full-scan safety fallbacks.
Both a borrowed empty listing and a borrowed file count as earlier observations;
an explicitly0/0 result keeps its current scan date and claims no old reuse.

These are folders within the same App module, not additional packages. Consult App/README.md and docs/engineering/README.md from the repository root.

`native-check storage-chart` reuses the existing generated-data review and motion
recorder without creating an analysis owner or scanner. The renderer keeps one
presented hover pose while the latest request replaces its pending target;
retarget/exit and the finite idle deadline share the ordinary animation driver.
Full/Reduced/Off respect the same preferences as Properties and Analyzer.
