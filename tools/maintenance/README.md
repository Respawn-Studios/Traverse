# Generated-storage maintenance

`storage.py` inventories repository-local generated storage and removes only an
explicitly reviewed directory list. It does not clean source, Git storage,
installed apps, personal files, other worktrees or macOS Trash.

Use a fresh report root beneath `.build/maintenance`:

```sh
python3 -B tools/maintenance/storage.py before --report-root .build/maintenance/storage-review
python3 -B tools/maintenance/storage.py plan --report-root .build/maintenance/storage-review
```

Inspect the plan before running `apply --reviewed` with the same report root.
Keep planning and applying as separate successful commands so a failed plan
cannot fall through to an old file. The tool validates all listed directories
before the first deletion and checks each identity again immediately before
removal. `apply` without explicit review refuses. Use `--help` for supported
options; never widen cleanup by changing a root to a parent directory.

`before` and `after` record logical and allocated totals. Their optional
`--whole-checkout` inventory is metadata-only, does not read bodies or external
symlink targets, and is unavailable for `plan` or `apply`. Take a settled inventory
after build/cleanup rather than repeated walks while totals are changing.

Current Xcode, Swift package, network-worker and release compiler caches stay
protected. Reuse incremental caches. A fixture marker establishes ownership,
not success: routine runners retire only their own newly passing fixtures.
Preserve unresolved failures, current recovery payloads, active work and retained
release artifacts. Archives deliberately preserving evidence are not cache data.

`grouped_fixtures.py` is a fixed-scope archival utility for older generated
`.build/grouped-copy-production` fixtures. Its source-enforced cutoff and owner
markers are not a general retention policy. It prepares a fresh archive and
manifest, reads back files and metadata, then rechecks the source before producing
a plan. It never removes fixtures. Open, changed, newer, unrecognized, linked,
special and separately retained cases stay in place. Before any separate cleanup,
review exclusions and recheck the complete archive manifest and open-file state;
`storage.py apply` does not validate every archived child itself.

See the [engineering guide](../../docs/engineering/README.md) for proportional
validation and generated-output ownership. Do not convert a past successful
cleanup into an automatic permission to delete a new directory.
