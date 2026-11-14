#!/usr/bin/env python3
"""Build/cache the bundled scanner; no downloads or benchmark-fixture admission.

Xcode invokes --embed with its current product paths. The isolated qualification
drivers remain separate and never become prerequisites for an ordinary build.
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import sys
import uuid
from bundle_helper import publish, regular
from distribution import helper_symbols
from distribution import remote_editor_qa

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "Workers/StorageScanner"
OUTPUT = ROOT / ".build/storage-scanner"
RUSTC = ROOT / ".build/b06-toolchain/rust-1.99.1/bin/rustc"
# Qualified compact observations, first-observation references and explicit
# per-request metadata policies and qualified committed-prefix presentation.
# Owner approved4,096-row temporary checkpoints after native/paired/failure
# qualification. Test generators, profiling, prepared-SQL and dense experiments
# stay out. Classification v3 is separately owner-approved after System/Data,
# same-observation audit and native ordinary-route gates. This is a cache input.
# Delegated19 October activation after fixed-partition/source-free/refusal,
# signed native lifecycle and actual System/Data gates. This optional query
# capability preserves the v3 catalog and adds no eager scan/sealing work.
# B06.3 read-only location queries passed source-free/ancestry, fresh native
# System/Data and generated origin/cancellation gates. No cleanup authority.
# Optional sorted-page revision1 is qualified with bounded257-row selection;
# existing catalog/index/checkpoint and source access are unchanged.
# Optional source-free Largest Files revision1 passed literal/UInt64/path,
# retained100k catalog and native lifecycle/layout/motion qualification. Its
# bounded heap/query adds no ingestion, schema, index or access-scope change.
#24 October local-development selection: explicit results use the separately
# versioned128-component contract after literal boundary/query/source/Stop and
# frozen equal-work gates. Core/automatic summaries remain64. Native activation
# is qualified separately; published source capsules are unchanged.
# The24October versioned adaptive candidate retains the first4096 observation
# checkpoint and FULL barriers, then at most16384 pending rows / a250ms check
# after4096. Frozen generated gains25.10/27.42%, exact oracles/Stop/quota/crash,
# wire15/16 and actual two-root native decoder controls pass. Current native
# integration/build gates own adoption; published release capsules stay frozen.
# V4's appended data/scientific group, wire17/18, prefix5 and catalog1015/1016
# pass literal/four-metric/pair/Stop, actual frozen-reader refusal, unchanged
# timing gates and native Properties/full-analysis/150% checks. Scope, FULL
# barriers and the qualified adaptive traversal remain unchanged.
#25 October purpose-project/location queries preserve the v4 catalog and writer.
# Exact partitions, bounded100k-directory replay/Stop and native guarded
# Trash/Results/Undo pass before bundled development activation. No source-body
# access or user-file operation format is added by this optional capability.
RESULT_CONFIG = ("b06_compact_values", "b06_reference_index", "b06_app_data", "b06_live_totals", "b06_checkpoint4096", "b06_classification_v3", "b06_layout_explanations", "b06_application_layouts", "b06_stored_locations", "b06_sorted_pages", "b06_largest_files", "b06_deep128", "b06_adaptive_checkpoint", "b06_classification_v4", "b06_purpose_journey")
EDITOR_RELEASE_PREFIX = 'local.macexplorer.sandbox.editor.'
EMBED_RECEIPT_FORMAT = 'storage-scanner-embed-v1'


def sandbox_editor_release_case(env):
    tag = env.get('MAC_EXPLORER_SANDBOX_EDITOR_RELEASE_CASE', '')
    if not tag:
        return None
    if env.get('MAC_EXPLORER_SANDBOX_FOUNDATION_CASE'):
        raise ValueError('Mixed sandbox qualification cases')
    try:
        if str(uuid.UUID(tag)).upper() != tag: raise ValueError('Noncanonical sandbox editor case')
    except (ValueError, AttributeError):
        raise ValueError('Invalid sandbox editor case') from None
    case = ROOT / '.build/traverse-development' / tag
    identifier = EDITOR_RELEASE_PREFIX + tag.lower().replace('-', '')
    target = Path(env.get('TARGET_BUILD_DIR', '/'))
    if case.resolve() != case or env.get('PRODUCT_BUNDLE_IDENTIFIER') != identifier \
            or env.get('CONFIGURATION') != 'Release' \
            or target != case / 'Products/Release' \
            or target.resolve() != target \
            or env.get('CONTENTS_FOLDER_PATH') != 'Mac Explorer.app/Contents' \
            or env.get('ENABLE_APP_SANDBOX') != 'YES':
        raise ValueError('Sandbox editor Release output, identity or policy mismatch')
    marker = case / 'reservation.json'
    admission = case / 'evidence/editor-release-admission.json'
    for path in [marker, admission]:
        if path.is_symlink() or not path.is_file():
            raise ValueError('Sandbox editor Release admission unavailable')
        facts = path.stat()
        if facts.st_uid != os.getuid() or facts.st_nlink != 1 or facts.st_size > 4096:
            raise ValueError('Sandbox editor Release admission identity')
    reservation = json.loads(marker.read_bytes())
    if reservation.get('packet') != 'traverse-development-v1' \
            or reservation.get('action') != 'sandbox-editor-release':
        raise ValueError('Sandbox editor Release reservation differs')
    values = json.loads(admission.read_bytes())
    if values.get('packet') != 'sandbox-editor-release-v1' or values.get('case') != tag \
            or values.get('bundleIdentifier') != identifier or values.get('buildAndInspectOnly') is not True:
        raise ValueError('Sandbox editor Release purpose differs')
    return case


def sandbox_foundation_case(env):
    """A local-only QA build cannot accidentally inherit the development SMB lane."""
    editor = sandbox_editor_release_case(env)
    if editor is not None:
        return editor
    tag = env.get('MAC_EXPLORER_SANDBOX_FOUNDATION_CASE', '')
    identifier = env.get('PRODUCT_BUNDLE_IDENTIFIER', '')
    if not tag:
        if identifier == 'local.macexplorer.sandbox.qualification' or identifier.startswith(EDITOR_RELEASE_PREFIX):
            raise ValueError('Sandbox qualification identity requires its exact generated case')
        return None
    try:
        if str(uuid.UUID(tag)).upper() != tag: raise ValueError('Noncanonical sandbox case')
    except (ValueError, AttributeError):
        raise ValueError('Invalid sandbox foundation case') from None
    case = ROOT / '.build/distribution-qualification' / tag
    target = Path(env.get('TARGET_BUILD_DIR', '/'))
    if identifier != 'local.macexplorer.sandbox.qualification' \
            or target != case / 'Products/Debug' or target.resolve() != target \
            or env.get('CONTENTS_FOLDER_PATH') != 'Mac Explorer.app/Contents' \
            or env.get('ENABLE_APP_SANDBOX') != 'YES':
        raise ValueError('Sandbox foundation output, identity or policy mismatch')
    marker = case / 'reservation.json'
    if marker.is_symlink() or not marker.is_file() or marker.stat().st_size > 4096 \
            or json.loads(marker.read_bytes()).get('packet') != 'sandbox-foundation-v1':
        raise ValueError('Sandbox foundation reservation is unavailable')
    return case


def directory(path: Path) -> None:
    current = Path(path.anchor)
    for component in path.parts[1:]:
        current /= component
        if current.is_symlink():
            raise ValueError("Refusing a redirected scanner build directory")
        if not current.exists():
            current.mkdir(exist_ok=True)
        if current.is_symlink() or not current.is_dir():
            raise ValueError("Scanner build path is not a directory")


def sha(path: Path) -> str:
    if path.is_symlink() or not path.is_file() or path.stat().st_nlink != 1:
        raise ValueError("Refusing a redirected/shared scanner artifact")
    return hashlib.sha256(path.read_bytes()).hexdigest()


@contextmanager
def build_lock():
    """Debug, Release and manual builds share one compiler/output owner.

    Hold through embed/signing too: a source edit must not start replacing the
    cached executable while another configuration copies it into its bundle.
    """
    directory(OUTPUT)
    path = OUTPUT / "build.lock"
    try:
        descriptor = os.open(path, os.O_CREAT | os.O_RDWR | os.O_CLOEXEC | os.O_NOFOLLOW, 0o600)
    except OSError as error:
        raise ValueError("Refusing an unavailable or redirected scanner build lock") from error
    try:
        value = os.fstat(descriptor)
        if not stat.S_ISREG(value.st_mode) or value.st_nlink != 1 or value.st_uid != os.geteuid() or value.st_mode & 0o077:
            raise ValueError("Refusing an unsafe scanner build lock")
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        current = path.lstat()
        if (current.st_dev, current.st_ino) != (value.st_dev, value.st_ino):
            raise ValueError("Scanner build lock changed while waiting")
        yield
    finally:
        os.close(descriptor)


def build() -> Path:
    with build_lock():
        return _build_locked()


def current_input(*, symbols: bool) -> tuple[dict, str, dict[str, str]]:
    """The existing one-binary cache key, including selected native tools/SDK."""
    if not RUSTC.is_file():
        raise ValueError("The repo-local Rust1.99.1 toolchain is required. See Workers/StorageScanner/README.md; no compiler is downloaded by Xcode.")
    sdk = subprocess.check_output(["/usr/bin/xcrun", "--show-sdk-path"], text=True).strip()
    clang = subprocess.check_output(["/usr/bin/xcrun", "--find", "clang"], text=True).strip()
    sdk_version = subprocess.check_output(["/usr/bin/xcrun", "--show-sdk-version"], text=True).strip()
    xcode = subprocess.check_output(["/usr/bin/xcodebuild", "-version"], text=True).strip()
    if not sdk:
        raise ValueError("Selected scanner compiler or SDK identity is unavailable")
    selected_clang = Path(clang).resolve(strict=True)
    selected_sdk = Path(sdk).resolve(strict=True)
    sdk_settings = (selected_sdk / "SDKSettings.plist").resolve(strict=True)
    if not sdk_version or not xcode or not selected_clang.is_file() or not sdk_settings.is_file():
        raise ValueError("Selected scanner compiler or SDK identity is unavailable")
    sdk = str(selected_sdk)
    env = {key: value for key, value in os.environ.items() if not key.startswith(("DYLD_", "B06_", "AUDIT_", "RUST", "CARGO"))}
    env.update(TMPDIR=str(OUTPUT / "tmp"), SDKROOT=sdk, MACOSX_DEPLOYMENT_TARGET="15.0",
               CARGO_HOME=str(OUTPUT / "cargo-home"), RUSTUP_HOME=str(OUTPUT / "rustup-home"))
    compiler = subprocess.check_output([str(RUSTC), "-vV"], env=env, text=True)
    clang_version = subprocess.check_output([str(selected_clang), "--version"], env=env, text=True)
    if not compiler.startswith("rustc 1.99.1 "):
        raise ValueError("Unexpected scanner toolchain version")
    sources = {p.name: sha(p) for p in SOURCE.iterdir() if p.suffix in (".rs", ".c", ".h", ".tsv", ".sql")}
    fingerprint = dict(schema=4, sources=sources, compiler=compiler, compiler_sha256=sha(RUSTC), sdk=sdk,
                       sdk_resolved=str(selected_sdk), sdk_version=sdk_version,
                       sdk_settings_path=str(sdk_settings), sdk_settings_sha256=sha(sdk_settings), xcode=xcode,
                       clang=str(selected_clang), clang_version=clang_version, clang_sha256=sha(selected_clang),
                       target="aarch64-apple-darwin", deployment="15.0", optimization="3/thin/1/abort",
                       result_config=list(RESULT_CONFIG), symbols=helper_symbols.POLICY if symbols else None,
                       **helper_symbols.rust_source_path_fingerprint(symbols))
    return fingerprint, sdk, env


def signed_facts(path: Path, *, identifier: str, team: str | None = None,
                 adhoc: bool | None = None, runtime: bool | None = None) -> dict:
    """Accept a scanner helper only with its intact, expected code signature."""
    regular(path)
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(path)],
                   check=True, capture_output=True, timeout=30)
    result = subprocess.run(["/usr/bin/codesign", "-d", "--verbose=4", str(path)],
                            check=True, capture_output=True, text=True, timeout=30)
    lines = result.stderr.splitlines()
    fields = dict(line.split("=", 1) for line in lines if "=" in line and line.split("=", 1)[0]
                  in ("Identifier", "TeamIdentifier", "Signature"))
    flags = next((int(match.group(1), 16) for line in lines
                  if (match := re.search(r"\bflags=0x([0-9a-fA-F]+)", line))), None)
    if fields.get("Identifier") != identifier or flags is None:
        raise ValueError("Unexpected scanner helper identifier or signing flags")
    actual_adhoc = fields.get("Signature") == "adhoc"
    actual_team = fields.get("TeamIdentifier", "not set")
    if team is not None and actual_team != team:
        raise ValueError("Scanner helper signing team changed")
    if adhoc is not None and actual_adhoc != adhoc:
        raise ValueError("Scanner helper signing kind changed")
    if actual_adhoc:
        if actual_team != "not set" or any(line.startswith("Authority=") for line in lines):
            raise ValueError("Unexpected ad-hoc scanner authority")
    elif actual_team == "not set" or not any(line.startswith("Authority=") for line in lines):
        raise ValueError("Scanner helper has no identified signing authority")
    actual_runtime = bool(flags & 0x10000)
    if runtime is not None and actual_runtime != runtime:
        raise ValueError("Scanner helper hardened-runtime flag changed")
    rights = subprocess.run(["/usr/bin/codesign", "-d", "--entitlements", "-", "--xml", str(path)],
                            check=True, capture_output=True, timeout=30).stdout
    if (plistlib.loads(rights) if rights.strip() else {}) != {}:
        raise ValueError("Unexpected scanner helper entitlements")
    return dict(identifier=identifier, team=actual_team, adhoc=actual_adhoc, runtime=actual_runtime)


def embed_signing_input(identity: str, arguments: list[str], *, symbols: bool,
                        sandbox: bool, environment: dict[str, str]) -> dict | None:
    """Only exact identities enter the local-development reuse lane."""
    if identity != "-" and not re.fullmatch(r"[0-9a-fA-F]{40}", identity):
        return None
    entitlements = ROOT / "Distribution/HelperInherit.entitlements" if sandbox else None
    return dict(identity=identity.upper(), arguments=arguments[1:],
                entitlements_sha256=sha(entitlements) if entitlements else None,
                symbols=symbols, sandbox=sandbox,
                codesign_sha256=sha(Path("/usr/bin/codesign")),
                developer_dir=environment.get("DEVELOPER_DIR", ""),
                codesign_allocate=environment.get("CODESIGN_ALLOCATE", ""))


def _build_receipt() -> dict:
    path = OUTPUT / "build.json"
    regular(path)
    if path.stat().st_size > 65536:
        raise ValueError("Scanner build receipt exceeds bound")
    value = json.loads(path.read_bytes())
    if not isinstance(value, dict):
        raise ValueError("Invalid scanner build receipt")
    return value


def _record_embed(binary: Path, helper: Path, signing: dict, facts: dict) -> None:
    value = _build_receipt()
    if value.get("binary_sha256") != sha(binary):
        raise ValueError("Scanner binary changed before embedding receipt")
    value["embed"] = dict(format=EMBED_RECEIPT_FORMAT, destination=str(helper),
                          binary_sha256=value["binary_sha256"], signing=signing,
                          facts=facts, helper_sha256=sha(helper))
    path = OUTPUT / "build.json"
    stage = OUTPUT / ("build." + str(uuid.uuid4()).upper() + ".stage")
    try:
        with stage.open("xb") as output:
            os.fchmod(output.fileno(), 0o600)
            output.write((json.dumps(value, sort_keys=True, indent=2) + "\n").encode())
            output.flush(); os.fsync(output.fileno())
        os.replace(stage, path)
    finally:
        if stage.exists(): stage.unlink()  # Only this call's owned stage.


def embedded_provenance(helper: Path, *, signing: dict | None = None,
                        current: bool = False) -> dict | None:
    """A missing/stale receipt requires signing; it never grants reuse."""
    try:
        value = _build_receipt()
        embedded = value.get("embed")
        if not isinstance(embedded, dict) or embedded.get("format") != EMBED_RECEIPT_FORMAT:
            return None
        binary = OUTPUT / "storage-scanner-worker"
        if value.get("binary_sha256") != sha(binary) or embedded.get("binary_sha256") != value["binary_sha256"]:
            return None
        if current and value.get("input") != current_input(symbols=False)[0]:
            return None
        if embedded.get("destination") != str(helper) or embedded.get("helper_sha256") != sha(helper):
            return None
        if signing is not None and embedded.get("signing") != signing:
            return None
        spec = embedded.get("signing")
        facts = embedded.get("facts")
        if not isinstance(spec, dict) or not isinstance(facts, dict):
            return None
        identity = spec.get("identity")
        if (identity != "-" and (not isinstance(identity, str) or not re.fullmatch(r"[0-9A-F]{40}", identity))) \
                or spec.get("arguments") != ["--force", "--sign", identity, "--timestamp=none",
                                            "--identifier", "storage-scanner-worker"] \
                or spec.get("sandbox") is not False or spec.get("symbols") is not False \
                or spec.get("entitlements_sha256") is not None \
                or spec.get("codesign_sha256") != sha(Path("/usr/bin/codesign")):
            return None
        observed = signed_facts(helper, identifier="storage-scanner-worker",
                                team="not set" if identity == "-" else "CDLNJRG82U",
                                adhoc=identity == "-", runtime=False)
        if observed != facts:
            return None
        return dict(input=value["input"], binary_sha256=value["binary_sha256"])
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
        return None


def _build_locked() -> Path:
    directory(OUTPUT)
    for name in ("tmp", "cargo-home", "rustup-home"):
        directory(OUTPUT / name)
    symbols = helper_symbols.requested(os.environ)
    fingerprint, sdk, env = current_input(symbols=symbols)
    binary = OUTPUT / "storage-scanner-worker"
    receipt = OUTPUT / "build.json"
    for path in (binary, OUTPUT / "ScannerNative.o", receipt):
        if path.is_symlink() or (path.exists() and (not path.is_file() or path.stat().st_nlink != 1)):
            raise ValueError("Refusing a redirected scanner build output")
    if receipt.exists() and not receipt.is_symlink() and receipt.stat().st_size < 65536:
        cached = json.loads(receipt.read_text())
        if cached.get("input") == fingerprint and binary.exists() and sha(binary) == cached.get("binary_sha256"):
            if symbols:
                helper_symbols.validate(binary, binary.with_name(binary.name + '.dSYM'))
            return binary
    commands = [
        ["/usr/bin/clang", "-O3", *(['-gline-tables-only'] if symbols else []), "-target", "arm64-apple-macosx15.0", "-isysroot", sdk,
         "-c", str(SOURCE / "ScannerNative.c"), "-o", str(OUTPUT / "ScannerNative.o")],
        [str(RUSTC), *helper_symbols.rust_source_path_arguments(symbols),
         *[item for flag in RESULT_CONFIG for item in ("--cfg", flag)],
         "--edition=2024", "--target=aarch64-apple-darwin", "-C", "opt-level=3",
         "-C", "panic=abort", "-C", "lto=thin", "-C", "codegen-units=1", "-C", "linker=/usr/bin/clang",
         *(['-C', 'debuginfo=line-tables-only', '-C', 'split-debuginfo=packed'] if symbols else []),
         "-C", "link-arg=-isysroot", "-C", "link-arg=" + sdk, "-C", "link-arg=" + str(OUTPUT / "ScannerNative.o"),
         str(SOURCE / "main.rs"), "-o", str(binary)],
    ]
    for command in commands:
        subprocess.run(command, cwd=ROOT, env=env, check=True)
    if {p.name: sha(p) for p in SOURCE.iterdir() if p.suffix in (".rs", ".c", ".h", ".tsv", ".sql")} != fingerprint["sources"]:
        raise ValueError("Scanner sources changed during compilation")
    if symbols:
        helper_symbols.validate(binary, binary.with_name(binary.name + '.dSYM'))
    receipt.write_text(json.dumps(dict(input=fingerprint, binary_sha256=sha(binary)), sort_keys=True, indent=2) + "\n")
    return binary


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--embed", action="store_true")
    args = parser.parse_args()
    with build_lock():
        _main_locked(args.embed)


def _main_locked(embed: bool) -> None:
    qualification = sandbox_foundation_case(os.environ) if embed else None
    remote_editor_qa_case = remote_editor_qa.admitted_build(os.environ) if embed else None
    binary = _build_locked()
    if not embed:
        print(binary)
        return
    target = Path(os.environ["TARGET_BUILD_DIR"]).absolute()
    relative = Path(os.environ["CONTENTS_FOLDER_PATH"])
    if relative.is_absolute() or ".." in relative.parts or target == Path("/"):
        raise ValueError("Invalid Xcode product path")
    destination = target / relative / "Helpers"
    directory(destination)
    helper = destination / binary.name
    if helper.is_symlink() or (helper.exists() and (not helper.is_file() or helper.stat().st_nlink != 1)):
        raise ValueError("Refusing a redirected bundled helper")
    identity = remote_editor_qa.signer(remote_editor_qa_case)[0] if remote_editor_qa_case \
        else os.environ.get("EXPANDED_CODE_SIGN_IDENTITY") or "-"
    if os.environ.get('PRODUCT_BUNDLE_IDENTIFIER') == 'com.respawnstudios.traverse':
        from distribution.store_helpers import configuration
        identity = configuration(target / relative.parent, os.environ)
    signing_env = os.environ.copy()
    # The tooling-only Foundation cache shim must not redirect the signing
    # service's identity lookup. Xcode also derives a build-only HOME from
    # that shim. Omit only that derived value so Security uses the real user
    # directory; do not assign a replacement HOME or change any search list.
    # These changes affect this codesign child only.
    signing_env.pop("CFFIXED_USER_HOME", None)
    if signing_env.get("HOME") == str(ROOT / ".build/xcode-user"):
        signing_env.pop("HOME", None)
    if qualification and signing_env.get('HOME') == str(ROOT / '.build/distribution-tooling/user'):
        signing_env.pop('HOME', None)
    local_development = os.environ.get('PRODUCT_BUNDLE_IDENTIFIER') == 'local.macexplorer.development' \
        and os.environ.get('ENABLE_APP_SANDBOX') != 'YES'
    arguments = ["/usr/bin/codesign", "--force", "--sign", identity, "--timestamp=none"]
    if local_development:
        arguments += ["--identifier", helper.name]
    if os.environ.get('PRODUCT_BUNDLE_IDENTIFIER') == 'com.respawnstudios.traverse' or remote_editor_qa_case:
        arguments += ['--options', 'runtime']
    if os.environ.get('ENABLE_APP_SANDBOX') == 'YES':
        arguments += ['--entitlements', str(ROOT / 'Distribution/HelperInherit.entitlements')]
    symbols = helper_symbols.requested(os.environ)
    signing = embed_signing_input(identity, arguments, symbols=symbols, sandbox=False,
                                  environment=signing_env) if local_development else None
    reused = signing is not None and embedded_provenance(helper, signing=signing) is not None
    if not reused:
        publish(binary, helper, staging_root=(target / relative).parent.parent / '.mac-explorer-helper-staging',
            signing_arguments=arguments, signing_environment=signing_env, strip_debug=symbols)
        if signing is not None:
            facts = signed_facts(helper, identifier=helper.name, adhoc=identity == '-', runtime=False)
            if facts['team'] == ('not set' if identity == '-' else 'CDLNJRG82U'):
                _record_embed(binary, helper, signing, facts)
    helper_symbols.publish_for_xcode(binary, helper, os.environ)
    print("Bundled verified storage scanner" if reused else "Bundled signed storage scanner")
    if qualification:
        # This packet tests local sandbox grants, not distribution SMB trust.
        # Refuse stale network code rather than deleting or reinterpreting it.
        app = target / relative.parent
        if any((destination / name).exists() or (destination / name).is_symlink()
               for name in ['smb-browser-worker', 'smb-resolver-worker']) \
                or (app / 'Contents/Resources/SMBHelperManifest.plist').exists():
            raise ValueError('Unexpected network artifacts in local sandbox qualification')
        from distribution.bundle_notices import embed as embed_notices
        embed_notices(target / 'Mac Explorer.app')
        print('Local-only sandbox foundation: network helpers are intentionally absent')
        return
    # Keep the owner's existing Xcode phase intact. Each helper family retains
    # its own build/cache module; all are embedded before Xcode seals the app.
    from build_drive_health_worker import embed as embed_drive_health
    embed_drive_health(target / relative.parent, environment=os.environ)
    subprocess.run([sys.executable, "-B", str(ROOT / "tools/build_network_helpers.py"), "--embed"], check=True)


if __name__ == "__main__":
    main()
