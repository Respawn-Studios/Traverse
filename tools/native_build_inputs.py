"""One finite source inventory for ordinary builds and their consumers.

Runtime controllers, fixtures, evidence and compiler outputs are not compiled
inputs. They keep their own execution records instead of invalidating an app.
"""
from __future__ import annotations

import hashlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def digest(path: Path) -> str:
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"Native build input must be a regular file: {path.relative_to(ROOT)}")
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            value.update(block)
    return value.hexdigest()


def source_inputs() -> dict[str, str]:
    from build_crash_reporter import verify_sources as crash_reporter_sources
    paths: set[Path] = set()
    paths.update(ROOT / name for name in crash_reporter_sources())
    paths.add(ROOT / "LICENSE")
    for root in (ROOT / "App/MacExplorer", ROOT / "Packages/ExplorerKit/Sources"):
        paths.update(path for path in root.rglob("*") if path.is_file()
                     and path.suffix not in (".md", ".orig", ".rej", ".bak")
                     and all(not part.startswith(".") for part in path.relative_to(root).parts))
    paths.update(path for path in (ROOT / "Workers/StorageScanner").iterdir()
                 if path.suffix in (".rs", ".c", ".h", ".sql", ".tsv"))
    paths.add(ROOT / "Workers/StorageScanner/frozen-origin.json")
    paths.update((ROOT / "tools/sftp_reader/qualification/src").rglob("*.rs"))
    paths.update((ROOT / "tools/smb_reader/smb2-browser").rglob("*.rs"))
    for directory, names in (
        ("App/Config", ("DevelopmentSigning.xcconfig", "BundleOutputs-network.xcfilelist", "BundleOutputs-local-only.xcfilelist")),
        ("tools", ("dev.py", "native_build_inputs.py", "generate_project.py", "native_swift_frontend.py",
                   "completion_helper_gate.py",
                   "folder_services.py",
                   "build_storage_worker.py", "build_network_helpers.py", "build_drive_health_worker.py",
                   "bundle_helper.py", "build_crash_reporter.py", "build_architecture.py")),
        ("Packages/ExplorerKit", ("Package.swift",)),
        ("tools/sftp_reader", ("build_ordinary_worker.py", "packet.py", "catalog/catalog.rs")),
        ("tools/sftp_reader/qualification", ("Cargo.toml", "Cargo.lock", "build.rs")),
        ("tools/smb_reader", ("packet.py", "helper_manifest.py", "vendor_verified_source.py",
                              "common.rs", "auth_security.rs", "catalog/catalog.rs",
                              "catalog/selected_catalog.rs", "catalog/StoreAuthority.c")),
        ("tools/smb_reader/smb2-browser", ("Cargo.toml", "Cargo.lock")),
        ("tools/smb_resolver", ("main.swift",)),
        ("tools/ssh_profiles", ("packet.py",)),
        ("Vendor/smb2", ("PROVENANCE.json", "DOWNSTREAM.patch")),
        ("Distribution", ("ThirdPartyManifest.json", "ThirdPartyNotices.txt", "PrivacyInfo.xcprivacy", "ReleaseHistory.json")),
        ("tools/distribution", ("artifact_files.py", "notices.py", "bundle_notices.py", "release_notes.py",
                                "helper_symbols.py", "remote_editor_qa.py", "store_helpers.py",
                                "traverse_packet.py", "sparkle.py")),
        ("MacExplorer.xcodeproj", ("project.pbxproj", "xcshareddata/xcschemes/MacExplorer.xcscheme")),
    ):
        paths.update(ROOT / directory / name for name in names)
    lock = ROOT / "MacExplorer.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
    if lock.exists():
        paths.add(lock)
    return {str(path.relative_to(ROOT)): digest(path) for path in sorted(paths)}


def product_inputs(application: Path) -> dict[str, str]:
    """Code and its identity/manifests; codesign verifies the resource seal."""
    paths = {application / "Contents/Info.plist", application / "Contents/_CodeSignature/CodeResources"}
    for name in ("MacOS", "Helpers", "XPCServices", "Frameworks"):
        paths.update(path for path in (application / "Contents" / name).rglob("*")
                     if path.is_file() and not path.is_symlink())
    paths.update((application / "Contents/Resources").glob("*Manifest.plist"))
    return {str(path.relative_to(application)): digest(path) for path in sorted(paths)}
