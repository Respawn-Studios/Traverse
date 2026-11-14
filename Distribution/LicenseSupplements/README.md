# Version-bound notice supplements

Four pinned packages omit license files in their published crate archives.
`index.json` binds their declared license supplements to the exact archive
checksum and published `.cargo_vcs_info.json`. Original files retain their bytes;
the combined display document uses canonical LF line endings.

Full upstream license text comes from each archive's recorded base revision.
Published copyright/SPDX headers are retained separately from the verified crate
when present. `russh-util` reports a dirty source revision in its published VCS
metadata; this remains visible in provenance. Its base-revision license is not
described as an exact clean release snapshot. Other package notices continue to
come directly from their checksum-verified published archives.

The explicit acquisition script makes five public-source requests. Ordinary
notice generation and builds are offline and reject changed text, archive/VCS
mismatches, unexpected licenses and conflicting shared components. They never
silently download replacements. Raw supplement URLs, SHA-256 values and the
multi-graph provenance remain in the generated manifest.
