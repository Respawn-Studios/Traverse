"""Existing native feature checks; runtime code, not an app build input.

The ordinary dev CLI loads this module only for native-check. It reuses the
same App checks, generated fixtures, product proof and operation owners.
"""
from __future__ import annotations

import ctypes
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import re
import stat
import struct
import subprocess
import tarfile
import time
import uuid
import zipfile
import zlib

from dev import (
    APP, BUILD, ROOT, build, compiled_debug_inputs, environment, local_directory,
    product_inputs, read_artifact, require_unlocked_console,
)

def generated_quarantine(path: Path) -> bytes:
    """Read one generated regular file's bounded raw mark through public Darwin fd APIs."""
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        facts = os.fstat(descriptor)
        if not stat.S_ISREG(facts.st_mode) or facts.st_nlink != 1 or facts.st_uid != os.geteuid():
            raise RuntimeError("Generated quarantine source is not an owned regular file")
        native = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
        call = native.fgetxattr
        call.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t,
                         ctypes.c_uint32, ctypes.c_int]
        call.restype = ctypes.c_ssize_t
        count = call(descriptor, b"com.apple.quarantine", None, 0, 0, 0)
        if not 1 <= count <= 4096:
            raise RuntimeError("Generated quarantine mark is absent or outside its read bound")
        data = ctypes.create_string_buffer(count)
        if call(descriptor, b"com.apple.quarantine", data, count, 0, 0) != count:
            raise RuntimeError("Generated quarantine mark changed during its read")
        return data.raw[:count]
    finally:
        os.close(descriptor)


def verify_native_archive_creation(case: Path, feature: str, *, marked_source_create: bool, gzip_tar: bool = False) -> Path:
    """Finish independent archive checks without launching another App process."""
    if feature not in ("create-zip", "create-tar"):
        raise ValueError("Only generated archive creation can use this verification")
    evidence = case / "evidence"
    report = json.loads((evidence / "native.json").read_bytes())
    expected_format = "tar.gz" if gzip_tar else "tar" if feature == "create-tar" else "zip"
    if report.get("passed") is not True or report.get("format") != expected_format:
        raise RuntimeError("Native archive creation receipt is missing or unsuccessful")
    if marked_source_create:
        if report.get("markedSource") is not True or report.get("coldUndoSucceeded") is not True \
                or report.get("sourceMarkUnchanged") is not True or report.get("outputRemoved") is not True:
            raise RuntimeError("Marked archive cold Undo did not preserve the generated source")
        warm = json.loads((evidence / "marked-create.json").read_bytes())
        output_name = warm.get("outputName")
        if warm.get("passed") is not True or warm.get("format") != expected_format \
                or warm.get("coldUndoPending") is not True or not isinstance(output_name, str) \
                or not output_name or "/" in output_name or output_name in (".", "..") \
                or not output_name.endswith("." + expected_format) \
                or (case / "source/Input" / output_name).exists():
            raise RuntimeError("Marked archive warm Create receipt or cold output state changed")
        source_mark = generated_quarantine(case / "source/Input/Root.txt")
        if hashlib.sha256(source_mark).hexdigest() != warm.get("sourceQuarantineSHA256"):
            raise RuntimeError("Independent generated source mark check failed after cold Undo")
    source_report = json.loads((evidence / "source.json").read_bytes())
    if feature == "create-tar":
        with tarfile.open(evidence / ("Created.tar.gz" if gzip_tar else "Created.tar"), mode="r:gz" if gzip_tar else "r:") as archive:
            members = archive.getmembers()
            if len(members) != source_report["files"] + source_report["folders"] or any(
                    not (member.isfile() or member.isdir()) for member in members):
                raise RuntimeError("Independent TAR namespace/type check failed")
            names = [member.name.rstrip("/") for member in members]
            if len(set(names)) != len(names) or dict(zip(names,
                    ("directory" if member.isdir() else "file" for member in members))) != source_report["members"]:
                raise RuntimeError("Independent TAR exact namespace/duplicate check failed")
            actual = {member.name: hashlib.sha256(archive.extractfile(member).read()).hexdigest()
                      for member in members if member.isfile()}
    else:
        with zipfile.ZipFile(evidence / "Created.zip") as archive:
            if archive.testzip() is not None:
                raise RuntimeError("Independent ZIP creation CRC check failed")
            actual = {member.filename: hashlib.sha256(archive.read(member)).hexdigest()
                      for member in archive.infolist() if not member.is_dir()}
    if actual != source_report["hashes"]:
        raise RuntimeError("Independent archive payload comparison failed")
    result = {"passed": True, "format": expected_format, "files": len(actual), "allBodiesExact": True}
    receipt = evidence / "independent-creation.json"
    if receipt.exists():
        if json.loads(receipt.read_bytes()) != result:
            raise RuntimeError("Existing independent archive receipt differs from current verification")
    else:
        with receipt.open("x") as output:
            json.dump(result, output); output.write("\n")
    return receipt


def verify_stopped_marked_archive_creation(case: Path) -> Path:
    """Resume only the independent final check of an exact generated two-process case."""
    base = BUILD / "traverse-development"
    if case.parent != base or case.resolve() != case or str(uuid.UUID(case.name)).upper() != case.name:
        raise ValueError("Resume requires an exact generated archive creation case")
    facts = case.lstat()
    if not stat.S_ISDIR(facts.st_mode) or facts.st_uid != os.geteuid() or facts.st_mode & 0o077:
        raise ValueError("Resume case is not an owned private directory")
    marker = json.loads((case / "reservation.json").read_bytes())
    if marker.get("packet") != "traverse-development-v1" or marker.get("action") != "archive-creation" \
            or marker.get("markedSourceCreate") is not True or marker.get("format") not in ("zip", "tar"):
        raise ValueError("Resume case has no marked archive creation reservation")
    compiled = json.loads((case / "evidence/compiled-inputs.json").read_bytes())
    if compiled.get("format") != "traverse-native-build-v1" or compiled.get("passed") is not True \
            or compiled.get("configuration") != "Debug" or compiled.get("application") != str(APP) \
            or not isinstance(compiled.get("productSHA256"), dict) or not compiled["productSHA256"]:
        raise RuntimeError("The stopped case has no compiled ordinary App receipt")
    feature = "create-tar" if marker["format"] == "tar" else "create-zip"
    return verify_native_archive_creation(case, feature, marked_source_create=True)


def _run_generated_sftp_finder_promise(command: list[str], case: Path, env: dict[str, str], output) -> subprocess.CompletedProcess:
    """Drive the existing generated SFTP case through one actual Finder callback."""
    destination = case / "source/Destination"
    process = subprocess.Popen(command, cwd=ROOT, env=env, stdin=subprocess.PIPE,
                               stdout=output, stderr=subprocess.STDOUT)
    offset, pending, opened, completed, sent = 0, b"", False, False, False
    began, settled = time.monotonic(), None
    try:
        while True:
            output.flush()
            data = (case / "evidence/process.log").read_bytes()
            if len(data) > 2 << 20:
                raise RuntimeError("Generated SFTP receiver output exceeded its bound")
            pending += data[offset:]
            offset = len(data)
            while b"\n" in pending:
                line, pending = pending.split(b"\n", 1)
                if not line.startswith(b"TRAVERSE_PROMISE "):
                    continue
                event = json.loads(line[len(b"TRAVERSE_PROMISE "):])
                kind, values = event.get("event"), event.get("values", {})
                if kind == "failed":
                    raise RuntimeError(f"Generated SFTP Finder promise failed at {values.get('stage', 'unknown')}")
                if kind == "ready" and not opened:
                    if next(destination.iterdir(), None) is not None:
                        raise RuntimeError("Generated Finder destination was not empty")
                    opened = subprocess.run(["/usr/bin/open", "-b", "com.apple.finder", str(destination)],
                                            capture_output=True, timeout=15).returncode == 0
                    if not opened:
                        raise RuntimeError("Could not open the generated Finder destination")
                    print(f"Drag the selected generated SFTP file into Finder at {destination}; choose that exact folder if prompted.", flush=True)
                if kind == "write-completed":
                    if values.get("nativeCallback") is not True or values.get("parentChoices") != 1 or completed:
                        raise RuntimeError("The generated external callback or parent choice was not exact")
                    completed = True
                    settled = time.monotonic()
            if completed and not sent and settled is not None and time.monotonic() - settled >= 0.75:
                leaf = destination / "Generated Promise.txt"
                expected = b"Traverse generated promise control\n"
                if read_artifact(leaf, len(expected)) != expected:
                    raise RuntimeError("Generated Finder output differs from the expected body")
                if process.stdin is None:
                    raise RuntimeError("Generated SFTP control pipe closed")
                process.stdin.write(b"finish\n")
                process.stdin.flush()
                process.stdin.close()
                sent = True
            if process.poll() is not None:
                break
            if time.monotonic() - began > 300:
                raise RuntimeError("Generated SFTP Finder gesture deadline; success not inferred")
            time.sleep(0.1)
        return subprocess.CompletedProcess(command, process.returncode)
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)


def native_check(feature: str, *, skip_build: bool, interactive: bool, motion: bool, large_interface: bool = False,
                 motion_mode: str = "full", offscreen: bool = False,
                 generated_port: int | None = None, private_input: bytes | None = None,
                 generated_fingerprint: str | None = None,
                 generated_flow: str = "uploads", sample_health: bool = False, random_benchmark: bool = False,
                 quick_mix_benchmark: bool = False,
                 promise_flow: bool = False, folder_flow: bool = False, external_promise_receiver: bool = False,
                 public_tree: bool = False, public_archive: bool = False,
                 incremental_analysis: bool = False, connection_phase: str = "persistence",
                 marked_source_create: bool = False) -> Path:
    """Run existing feature checks in the ordinary app, with generated data only."""
    gzip_tar = feature == "create-targz"
    if gzip_tar:
        if marked_source_create:
            raise ValueError("gzip TAR has a separate development creation route")
        feature = "create-tar"
    gzip_tar_editor = feature == "tar-gzip-editor"
    tar_editor = feature in ("tar-editor", "tar-gzip-editor")
    marked_archive_editor = tar_editor and marked_source_create
    if marked_archive_editor:
        marked_source_create = False
    native_zip_recovery = feature == "zip-editor-native-recovery"
    native_zip_update = feature in ("zip-update-native", "zip-editor-native", "zip-editor-native-recovery")
    if feature in ("zip-editor-native", "zip-editor-native-recovery", "tar-editor", "tar-gzip-editor"):
        feature = "editor-preferences"
    if not offscreen:
        require_unlocked_console()
    if connection_phase not in ("address", "find", "selection", "persistence", "completion", "escape", "viewport", "pin-readiness") \
            or feature != "connection-metadata" and connection_phase != "persistence":
        raise ValueError("Choose a connection phase only for connection-metadata")
    if incremental_analysis and (feature != "analysis-persistence" or
                                 any((interactive, motion, large_interface))):
        raise ValueError("Incremental analysis uses the existing two-process standard persistence flow")
    if feature == "analysis-persistence" and offscreen and any((interactive, motion, large_interface)):
        raise ValueError("Offscreen analysis is functional only, without motion, visual sizing or interaction")
    if sample_health and feature != "drive-status" or (random_benchmark or quick_mix_benchmark) and feature != "drive-benchmark" \
            or random_benchmark and quick_mix_benchmark:
        raise ValueError("Choose the matching existing drive flow for hardware sampling or a random benchmark")
    if folder_flow:
        promise_flow = True
    if external_promise_receiver:
        promise_flow = True
        if feature != "sftp-batch-download" or any((folder_flow, offscreen, motion, large_interface, interactive,
                                                     generated_port is not None, generated_fingerprint is not None,
                                                     private_input is not None)):
            raise ValueError("The generated external promise uses only the visible single-file SFTP Finder flow")
    if public_archive and feature not in ("tar-archive", "compressed-tar"):
        raise ValueError("Public TAR candidates reuse the existing plain/compressed TAR flow")
    if marked_source_create and (feature not in ("create-zip", "create-tar") or not offscreen
                                 or any((interactive, motion, large_interface))):
        raise ValueError("Marked archive creation uses only the generated offscreen ZIP/TAR flow")
    if public_tree and not (feature == "archive-pane" or feature == "sftp-batch-download" and folder_flow):
        raise ValueError("The public-tree candidate reuses archive-pane or the SFTP folder flow")
    if promise_flow and (feature != "sftp-batch-download" or motion or large_interface or offscreen):
        raise ValueError("Promise callbacks use the existing visible SFTP receive flow without motion/layout variants")
    if feature == "sftp-connected-actions":
        if generated_port is None or not 1024 < generated_port < 65536 \
                or generated_fingerprint is None or re.fullmatch(r"SHA256:[A-Za-z0-9+/]{43}", generated_fingerprint) is None \
                or private_input is not None or generated_flow not in ("uploads", "remote-moves", "remote-cut") \
                or any((offscreen, interactive, motion, large_interface, promise_flow, folder_flow)):
            raise ValueError("The scoped generated SFTP listener and exact public host fingerprint are required")
    elif generated_fingerprint is not None:
        raise ValueError("A generated host fingerprint applies only to sftp-connected-actions")
    elif feature == "smb-connected-uploads":
        if generated_flow not in ("uploads", "uploads-folders", "uploads-new-items", "file-actions", "directory-actions", "file-actions-move", "file-actions-cut", "file-actions-copy", "editor-original", "download-drops", "download-drops-gestures", "download-drops-folder"):
            raise ValueError("Unknown generated SMB flow")
        if generated_port is None or not 1024 < generated_port < 65536 or private_input is None \
                or len(private_input) != 129 or private_input[-1:] != b"\n" \
                or any(value not in b"0123456789abcdef" for value in private_input[:-1]):
            raise ValueError("The scoped generated SMB listener and private stdin secret are required")
        # The existing native reader expects hexadecimal-encoded UTF-8, not
        # the generated password's already-hexadecimal text itself.
        decoded = bytes.fromhex(private_input[:-1].decode("ascii"))
        if len(decoded) != 64 or any(value not in b"0123456789abcdef" for value in decoded):
            raise ValueError("The exact generated SMB password encoding is required")
    elif generated_port is not None or private_input is not None or generated_flow != "uploads":
        raise ValueError("Private SMB inputs apply only to the consolidated Upload flow")
    specifications = {
        "sidebar-layout": ("native-sidebar-layout", "--check-sidebar-layout", "sidebar-layout-result.json"),
        "local-editor": ("editor-native-application", "--check-local-editor", "native-editor-app.json"),
        "operation-access": ("operation-access-recovery", "--check-operation-access", "result.json"),
        "archive-pane": ("traverse-archive-pane-destination", "--check-archive-pane-destination", "result.json"),
        "trash-command": ("trash-app-route-generated", "--check-trash-app-route-generated", "result.json"),
        "remote-properties": ("remote-item-properties", "--check-remote-properties", "native-remote-properties.json"),
        "support-details": ("support-details", "--check-support-details", "native.json"),
        "transfer-diagnostics": ("transfer-diagnostics", "--check-transfer-diagnostics", "native-transfer-diagnostics.json"),
        "clipboard-admission": ("clipboard-admission-diagnostics", "--check-clipboard-diagnostics", "native-clipboard-diagnostics.json"),
        "connection-fields": ("native-connection-fields", "--check-connection-fields", "native-connection-fields.json"),
        "editor-preferences": ("native-editor-preferences", "--check-editor-preferences", "native-editor-preferences.json"),
        "drive-benchmark": ("native-drive-benchmark", "--check-drive-benchmark-native", "native-drive-benchmark.json"),
        "drive-status": ("native-drive-storage-status", "--check-drive-storage-status", "native-storage-status.json"),
        "startup-analysis": ("native-properties-capacity", "--check-properties-capacity", "properties-capacity.json"),
        "editor-lines": ("native-editor-line-commands", "--check-editor-line-commands", "editor-line-commands.json"),
        "tar-archive": ("plain-tar-native", "--check-tar-archive", "native-tar-archive.json"),
        "compressed-tar": ("plain-tar-native", "--check-tar-archive", "native-tar-archive.json"),
        "create-zip": ("archive-creation", "--check-zip-creation", "native.json"),
        "create-tar": ("archive-creation", "--check-zip-creation", "native.json"),
        "batch-rename": ("batch-rename", "--check-batch-rename", "native.json"),
        "selection-group": ("selection-group-native", "--check-selection-group-native", "native-selection-group-recover.json"),
        "zip-update-add": ("native-zip-rename-copy", "--check-zip-rename-copy", "native-zip-rename-copy.json"),
        "zip-update-rename": ("native-zip-rename-copy", "--check-zip-rename-copy", "native-zip-rename-copy.json"),
        "zip-update-tracked": ("native-zip-rename-copy", "--check-zip-rename-copy", "native-zip-rename-copy.json"),
        "zip-update-native": ("native-zip-rename-copy", "--check-zip-rename-copy", "native-zip-rename-copy.json"),
        "zip-update-new-folder": ("native-zip-rename-copy", "--check-zip-rename-copy", "native-zip-rename-copy.json"),
        "zip-update-duplicate": ("native-zip-rename-copy", "--check-zip-rename-copy", "native-zip-rename-copy.json"),
        "zip-update-move": ("native-zip-rename-copy", "--check-zip-rename-copy", "native-zip-rename-copy.json"),
        "zip-update-copy": ("native-zip-rename-copy", "--check-zip-rename-copy", "native-zip-rename-copy.json"),
        "zip-new-folder-copy": ("native-zip-rename-copy", "--check-zip-rename-copy", "native-zip-rename-copy.json"),
        "zip-update-folder": ("native-zip-rename-copy", "--check-zip-rename-copy", "native-zip-rename-copy.json"),
        "zip-update-remove": ("native-zip-rename-copy", "--check-zip-rename-copy", "native-zip-rename-copy.json"),
        "zip-update-empty": ("native-zip-rename-copy", "--check-zip-rename-copy", "native-zip-rename-copy.json"),
        "zip-add-copy": ("native-zip-rename-copy", "--check-zip-rename-copy", "native-zip-rename-copy.json"),
        "zip-rename-copy": ("native-zip-rename-copy", "--check-zip-rename-copy", "native-zip-rename-copy.json"),
        "zip-rename-folder-copy": ("native-zip-rename-copy", "--check-zip-rename-copy", "native-zip-rename-copy.json"),
        "zip-remove-copy": ("native-zip-rename-copy", "--check-zip-rename-copy", "native-zip-rename-copy.json"),
        "zip-remove-folder-copy": ("native-zip-rename-copy", "--check-zip-rename-copy", "native-zip-rename-copy.json"),
        "analysis-persistence": ("native-analysis-persistence", "--check-analysis-persistence", "persistence-repair-result.json"),
        "settings-motion": ("settings-sidebar-v1", "--check-settings-sidebar", "native-settings-sidebar.json"),
        "help-motion": ("help-form-motion-v1", "--check-help-motion", "native-help-motion.json"),
        "tool-windows": ("motion-audit", "--check-development-motion", "native.json"),
        "storage-chart": ("motion-audit", "--check-development-motion", "native.json"),
        "server-prompts": ("motion-audit", "--check-development-motion", "native.json"),
        "sftp-profiles": ("motion-audit", "--check-development-motion", "native.json"),
        "folder-default": ("folder-default-app-composition", "--check-folder-default-composition", "native-folder-default.json"),
        "hover-summary": ("hover-summary-readability", "--check-summary-hover", "native-hover-summary.json"),
        "connection-metadata": ("connection-navigation-v1", "--check-connection-navigation", "native-connection-navigation.json"),
        "sftp-batch-download": ("native-sftp-download-batch", "--check-sftp-download-ui", "native-download-batch.json"),
        "sftp-group-upload": ("native-sftp-drop-upload", "--check-sftp-drop-upload", "native-sftp-drop-upload.json"),
        "smb-transfer-menus": ("smb-selected-download-ordinary-native", "--check-smb-selected-download", "native-smb-download.json"),
        "connect-model": ("native-smb-connect-model", "--check-smb-connect-standalone", "connect.json"),
        "smb-connected-uploads": ("native-smb-connected-uploads", "--check-smb-connect-live", "connect-live-uploads.json"),
        "sftp-connected-actions": ("sftp-native-auth-transfer", "--check-sftp-auth-transfer", "native-auth-transfer.json"),
    }
    if not skip_build:
        build()
    action, flag, report = specifications[feature]
    if feature == "smb-connected-uploads":
        report = f"connect-live-{generated_flow}.json"
    elif folder_flow:
        report = "native-sftp-folder-drop.json"
    elif external_promise_receiver:
        report = "native-sftp-external-promise.json"
    elif promise_flow:
        report = "native-sftp-promise.json"
    elif incremental_analysis:
        report = "persistence-unchanged-reopen-result.json"
    controller_inputs = {name: hashlib.sha256(read_artifact(ROOT / name, 1 << 20)).hexdigest()
                         for name in ("tools/dev.py", "tools/native_checks.py")}
    compiled_bytes, compiled = compiled_debug_inputs(require_current_source=marked_source_create)
    case = local_directory("traverse-development/" + str(uuid.uuid4()).upper())
    case.chmod(0o700)
    # The older sealed Trash adapter owns capitalized State; avoid a second
    # spelling on the default case-insensitive macOS filesystem.
    directories = ("source", "cache", "evidence") if feature == "trash-command" else ("source", "state", "cache", "evidence")
    for name in directories:
        (case / name).mkdir(mode=0o700)
    marker = {"packet": "traverse-development-v1",
              "action": "native-sftp-promise-gesture" if external_promise_receiver else action}
    if external_promise_receiver:
        marker["externalPromiseReceiver"] = True
    if marked_source_create:
        marker.update(markedSourceCreate=True, format="tar" if feature == "create-tar" else "zip")
    if sample_health:
        if feature != "drive-status":
            raise ValueError("Hardware sampling applies only to the existing drive-status flow")
        marker["healthSamplesMaximum"] = 5
    (case / "reservation.json").write_text(json.dumps(marker) + "\n")
    # Preserve the compact compiled snapshot, not another product/source copy.
    # Independent source work may continue while this immutable app is checked.
    (case / "evidence/compiled-inputs.json").write_bytes(compiled_bytes)
    (case / "evidence/controller-inputs.json").write_text(json.dumps(controller_inputs, sort_keys=True) + "\n")
    if feature == "selection-group":
        mode = "off-light150" if large_interface or motion_mode == "off" else motion_mode + "-dark"
        items = case / "source/Items"
        for name in ("Folder", "Empty", "Taken", "Away"):
            (items / name).mkdir(mode=0o700, parents=True)
        for name, body in {"Alpha.txt": b"generated alpha", "Folder/Child.txt": b"generated child",
                           "Stale.txt": b"generated stale", "Restart.txt": b"generated restart"}.items():
            (items / name).write_bytes(body)
            (items / name).chmod(0o600)
        for phase in ("suite", "recover"):
            (case / f"selection-group-admission-{phase}.json").write_text(json.dumps(dict(
                format="ordinary-selection-group-review-v1", case=case.name, mode=mode, phase=phase)) + "\n")
    if feature == "trash-command":
        # Reuse the existing sealed rename adapter and actual Browser command;
        # this regression makes no macOS Trash call and needs no copied App.
        (case / "reservation.json").chmod(0o600)
        for name in ("Input", "Returned", "State"):
            (case / name).mkdir(mode=0o700)
        fixture = case / "Input/Generated.bin"
        fixture.write_bytes(b"Traverse generated App Trash route v1\n")
        fixture.chmod(0o600)
    if feature == "operation-access":
        (case / "source/Destination").mkdir(mode=0o700)
        (case / "source/Generated.txt").write_bytes(b"Generated access UI fixture.\n")
        with zipfile.ZipFile(case / "source/Access.zip", mode="x", compression=zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("Received.txt", b"Generated cold Undo access.\n")
        marker["archiveSHA256"] = hashlib.sha256((case / "source/Access.zip").read_bytes()).hexdigest()
        (case / "reservation.json").write_text(json.dumps(marker) + "\n")
    if feature == "archive-pane":
        for name in ("Source", "Destination/Existing", "Alternative"):
            (case / "source" / name).mkdir(mode=0o700, parents=True)
        payloads = {"Selected/Keep.txt": b"Generated pane extraction\n" * 16,
                    "Selected/Deep/Nested.txt": b"Generated selected child\n" * 13,
                    "Unselected.txt": b"Generated unselected payload\n" * 11}
        with zipfile.ZipFile(case / "source/Source/Generated.zip", mode="x", compression=zipfile.ZIP_DEFLATED) as archive:
            for name, body in payloads.items():
                archive.writestr(name, body)
        (case / "source/Source/Copy.txt").write_bytes(b"Generated existing pane Copy regression\n")
        (case / "source/Destination/Existing/Keep.txt").write_bytes(b"Generated existing destination sentinel\n")
        expected = {name: hashlib.sha256(body).hexdigest() for name, body in payloads.items()}
        (case / "oracle.json").write_text(json.dumps(dict(whole=expected,
            selected={name: digest for name, digest in expected.items() if name.startswith("Selected/")})) + "\n")
    upload_bodies = {"First.txt": b"Generated first file", "Last.txt": b"Generated last file",
                     "Folder/Member.txt": b"Generated folder member"}
    if feature == "transfer-diagnostics":
        (case / "source/Source").mkdir(mode=0o700)
        (case / "source/Destination").mkdir(mode=0o700)
        (case / "source/Source/Generated-private-file.txt").write_bytes(b"Generated private diagnostic body.\n")
    if feature == "clipboard-admission":
        source = case / "source/PRIVATE-SOURCE"
        source.mkdir(mode=0o700)
        (source / "PRIVATE-CLIPBOARD.txt").write_bytes(b"Generated clipboard acceptance only.\n")
        (source / "PRIVATE-CLIPBOARD.txt").chmod(0o600)
        (case / "source/Destination").mkdir(mode=0o700)
        (case / "source/Denied").mkdir(mode=0o500)
        (case / "source/Blocker").write_bytes(b"Generated non-directory.\n")
    if feature == "sftp-group-upload":
        local = case / "source/Local"
        (local / "Folder").mkdir(mode=0o700, parents=True)
        for name, body in upload_bodies.items():
            (local / name).write_bytes(body)
    if feature == "sftp-connected-actions":
        local = case / "source/Local"
        local.mkdir(mode=0o700)
        (local / "Upload.bin").write_bytes(b"Traverse generated permission continuation.\n")
    if feature == "smb-connected-uploads" and generated_flow not in ("uploads-new-items", "file-actions-copy", "editor-original"):
        local = case / "source/Local"
        for name in ("Generated Folder/Empty", "Generated Folder/Nested", "Mixed Folder"):
            (local / name).mkdir(mode=0o700, parents=True)
        files = {"Final.bin": bytes(range(128)), "Verified.bin": bytes(index % 251 for index in range(32769)),
                 "Existing.bin": b"Generated collision input.\n", "Mixed.txt": b"Generated mixed upload.\n",
                 "Generated Folder/Note.txt": b"Generated folder note.\n",
                 "Generated Folder/Nested/Member.bin": bytes((index + 7) % 251 for index in range(32785)),
                 "Mixed Folder/Member.txt": b"Generated mixed folder.\n"}
        for name, data in files.items():
            (local / name).write_bytes(data); (local / name).chmod(0o600)
    if feature == "local-editor":
        # Legacy fixture-kind token consumed by the existing verifier, not a
        # copied source graph or an additional authorization/retention packet.
        (case / "editor-app-admission.json").write_text(json.dumps({"master": "46F68181-FA2B-4308-8713-7D518F2FF08C"}) + "\n")
    if feature in ("settings-motion", "help-motion"):
        marker = "settings-admission.json" if feature == "settings-motion" else "help-motion-admission.json"
        (case / marker).write_text(json.dumps({"master": "46F68181-FA2B-4308-8713-7D518F2FF08C", "mode": motion_mode}) + "\n")
    if feature == "tool-windows":
        (case / "source/Upload.txt").write_bytes(b"Generated upload review only.\n")
    if feature == "folder-default":
        (case / "folder-default-composition-admission.json").write_text(json.dumps({
            "master": "46F68181-FA2B-4308-8713-7D518F2FF08C", "liveHandlerQueries": 0,
            "liveAssociationSetters": 0, "fakeBackendOnly": True,
            "captureProfile": "folder-default-static-dark-v1"}) + "\n")
    if feature == "hover-summary":
        folder = case / "source/steamapps"
        folder.mkdir(mode=0o700)
        for name in ("One.txt", "Two.txt"):
            with (folder / name).open("xb") as output:
                output.write(b"Generated folder summary fixture.\n.")
    if feature == "connection-metadata":
        (case / "source/GeneratedMetadataOnly.txt").write_bytes(b"Generated metadata only.\n")
        (case / "packet-admission.json").write_text(json.dumps({
            "master": "46F68181-FA2B-4308-8713-7D518F2FF08C", "phase": connection_phase}) + "\n")
    if feature == "batch-rename":
        parent = case / "source/Items"
        parent.mkdir(mode=0o700)
        for name, body in (("One.txt", b"one\n"), ("Two.txt", b"two\n"), ("Three.json", b"{}\n")):
            (parent / name).write_bytes(body)
        with zipfile.ZipFile(case / "source/Batch Rename.zip", mode="x", compression=zipfile.ZIP_DEFLATED) as archive:
            for name, body in (("Folder/", b""), ("Folder/Empty/", b""), ("Folder/Child.txt", b"child\n"),
                               ("Top.txt", b"top\n"), ("Occupied/Keep.txt", b"keep\n")):
                archive.writestr(name, body)
    if feature in ("create-zip", "create-tar"):
        from verify_zip_creation import fixture as creation_fixture
        creation_fixture(case, False)
        if feature == "create-tar":
            source = case / "source/Input"
            (source / "Folder/Stream 01.bin").rename(source / "Folder" / ("日本語-" + "λ" * 60 + ".bin"))
            report_path = case / "evidence/source.json"
            source_report = json.loads(report_path.read_bytes())
            source_report["hashes"] = {str(path.relative_to(source)): hashlib.sha256(path.read_bytes()).hexdigest()
                                       for path in source.rglob("*") if path.is_file()}
            report_path.write_text(json.dumps(source_report) + "\n")
        report_path = case / "evidence/source.json"
        source_report = json.loads(report_path.read_bytes())
        source_report["members"] = {str(path.relative_to(case / "source/Input")):
                                    "directory" if path.is_dir() else "file"
                                    for path in (case / "source/Input").rglob("*")}
        report_path.write_text(json.dumps(source_report) + "\n")
    if feature in ("tar-archive", "compressed-tar"):
        # A tiny independent PNG without external assets. Its encoded body is
        # deliberately above the text/hex limit to exercise the image route.
        def png_chunk(tag: bytes, body: bytes) -> bytes:
            return struct.pack(">I", len(body)) + tag + body + struct.pack(">I", zlib.crc32(tag + body))
        width, height = 420, 240
        raster = bytearray()
        for y in range(height):
            raster.append(0)
            for x in range(width):
                dusk = (x - 258) ** 2 + (y - 108) ** 2 < 58 ** 2
                land = y > 160 + 22 * ((x // 55) % 2) + x % 55 // 4
                raster.extend((246, 187, 124) if dusk else (18, 65, 83) if land else (26 + y // 6, 99 + y // 5, 133 + y // 4))
        poster = (b"\x89PNG\r\n\x1a\n" + png_chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
                  + png_chunk(b"IDAT", zlib.compress(raster, level=0)) + png_chunk(b"IEND", b""))
        invalid_image = b"Generated data with a mismatched filename."
        data = io.BytesIO()
        with tarfile.open(fileobj=data, mode="w", format=tarfile.PAX_FORMAT if feature == "compressed-tar" else tarfile.USTAR_FORMAT) as archive:
            for name, body in (("Folder/", None), ("Folder/Empty/", None),
                               ("Folder/Member.txt", b"abc"), ("Note.txt", b"note"),
                               ("Folder/Poster.png", poster), ("Folder/Broken.png", invalid_image)):
                entry = tarfile.TarInfo(name)
                entry.mode = 0o700 if body is None else 0o600
                entry.type = tarfile.DIRTYPE if body is None else tarfile.REGTYPE
                entry.size = 0 if body is None else len(body)
                if name == "Folder/Member.txt":
                    entry.mtime = 1_700_000_123.125 if feature == "compressed-tar" else 1_700_000_123
                archive.addfile(entry, None if body is None else io.BytesIO(body))
        source = case / "source" / ("Review.tar.gz" if feature == "compressed-tar" else "Review.tar")
        source.write_bytes(gzip.compress(data.getvalue(), mtime=0) if feature == "compressed-tar" else data.getvalue())
        if feature == "tar-archive":
            with zipfile.ZipFile(case / "source/Review.zip", mode="x", compression=zipfile.ZIP_DEFLATED) as archive:
                item = zipfile.ZipInfo("Note.txt", date_time=(2024, 2, 29, 13, 34, 56))
                item.compress_type = zipfile.ZIP_DEFLATED
                archive.writestr(item, b"note")
                archive.writestr("Poster.png", poster)
                archive.writestr("Broken.png", invalid_image)
                archive.writestr("Folder/", b"")
                archive.writestr("Folder/Empty/", b"")
                archive.writestr("Folder/Member.txt", b"abc")
    if feature in ("zip-add-copy", "zip-rename-copy", "zip-rename-folder-copy", "zip-remove-copy", "zip-remove-folder-copy", "zip-new-folder-copy") or feature.startswith("zip-update-"):
        folder = case / "source/Input"
        folder.mkdir(mode=0o700)
        # Use an independent, ordinary ZIP producer rather than exercising
        # only the exact flags emitted by Traverse's own creation engine.
        entries = [("Project/", b""), ("Project/Empty/", b""),
                   ("Project/Note.txt", b"inside\n"), ("Project/Other.txt", b"other\n"),
                   ("Top.txt", b"top\n")]
        if feature in ("zip-update-move", "zip-update-copy"):
            entries.extend([("Move Folder/", b""), ("Move Folder/Empty/", b""),
                            ("Move Folder/Member.txt", b"move\n")])
        if feature == "zip-update-copy":
            entries.extend([("Project/Top.txt", b"occupied\n"), ("Project/Top (1).txt", b"reserved\n")])
        if feature == "zip-update-add":
            entries.extend([("Project/Added.txt", b"old\n"), ("Project/Added (1).txt", b"reserved\n"),
                            ("Project/Bundle/Old.txt", b"old tree\n")])
        with zipfile.ZipFile(folder / "Original.zip", mode="x") as archive:
            for name, body in entries:
                entry = zipfile.ZipInfo(name, date_time=(2026, 11, 1, 0, 0, 0))
                entry.create_system = 3
                entry.external_attr = ((0o40700 << 16) | 0x10) if name.endswith("/") else (0o100600 << 16)
                entry.compress_type = zipfile.ZIP_DEFLATED if name == "Project/Note.txt" else zipfile.ZIP_STORED
                if feature == "zip-update-copy" and name == "Top.txt":
                    entry.create_system = 10
                    entry.external_attr = 0x20
                    entry.extra = struct.pack("<HHIHHQQQ", 0x000A, 32, 0, 1, 24, 132_000_000_000_000_000, 0, 0)
                    entry.comment = b"Generated entry comment\xff"
                archive.writestr(entry, body)
    if feature in ("zip-add-copy", "zip-update-add"):
        first = case / "source/Added Parent A"
        tree = case / "source/Added Parent B/Bundle"
        first.mkdir(mode=0o700)
        (tree / "Empty").mkdir(mode=0o700, parents=True)
        (first / "Added.txt").write_bytes(b"added\n")
        (tree / "Child.txt").write_bytes(b"nested\n")
    command = [str(APP / "Contents/MacOS/Mac Explorer"), "--verify-ui", flag]
    if public_tree or public_archive:
        command.append("--public-tree-candidate")
    if public_archive:
        command.append("--public-tar-file-candidate")
    if feature == "selection-group":
        command += ["--group-mode", mode]
    if feature in ("create-zip", "create-tar", "batch-rename"):
        command += ["--analysis-source", str(case)]
        if feature == "create-tar":
            command.append("--create-tar")
            if gzip_tar:
                command.append("--gzip-tar")
    if offscreen:
        command.append("--offscreen")
    if marked_source_create:
        command.append("--marked-source-create")
    if feature == "hover-summary":
        command += ["--hover-readability", "--analysis-source", str(case / "source")]
    if feature == "connection-metadata":
        command += ["--connection-phase", connection_phase]
        if connection_phase == "persistence":
            command.append("--capture-connection-properties")
    if sample_health:
        command.append("--sample-selected-internal-health")
    if random_benchmark:
        command.append("--random-benchmark")
    if quick_mix_benchmark:
        command.append("--quick-mix-benchmark")
    if feature == "compressed-tar":
        command.append("--compressed-tar")
    if feature == "startup-analysis":
        command.append("--startup-data-fallback")
    if feature == "sftp-batch-download":
        command.append("--batch-flow")
        if promise_flow:
            command.append("--promise-flow")
        if external_promise_receiver:
            command += ["--interactive-sftp-promise", "--external-promise-receiver"]
        if folder_flow:
            command.append("--folder-flow")
    if feature == "sftp-connected-actions":
        command += ["--generated-port", str(generated_port), "--generated-fingerprint", generated_fingerprint,
                    "--generated-method", "prompts", "--generated-transfer", "success", "--independent-openssh",
                    "--ordinary-exclusive-upload", "--remote-move-flow" if generated_flow in ("remote-moves", "remote-cut") else "--upload-permission-flow"]
        if generated_flow == "remote-cut":
            command.append("--remote-cut-flow")
    if feature == "smb-transfer-menus":
        command += ["--smb-download-scenario", "menus", "--generated-port", "10445"]
    if feature in ("tool-windows", "server-prompts", "sftp-profiles"):
        surface = {"tool-windows": "tools", "server-prompts": "ssh-prompts", "sftp-profiles": "ssh"}[feature]
        command += ["--motion-surface", surface]
    if feature == "storage-chart":
        command += ["--motion-surface", "chart"]
    if feature == "connect-model":
        command += ["--check-smb-connect-model-only", "--analysis-source", str(case)]
    if feature == "support-details":
        command += ["--analysis-source", str(case)]
        if not offscreen:
            command.append("--capture-support-details")
    if feature == "smb-connected-uploads":
        command += ["--live-phase", generated_flow, "--analysis-source", str(case), "--generated-port", str(generated_port)]
    if feature in ("zip-remove-copy", "zip-remove-folder-copy", "zip-update-remove", "zip-update-empty"):
        command.append("--remove-members")
    if feature in ("zip-add-copy", "zip-update-add"):
        command.append("--add-members")
    if feature in ("zip-remove-folder-copy", "zip-update-empty"):
        command.append("--remove-folders")
    if feature in ("zip-rename-folder-copy", "zip-update-folder"):
        command.append("--rename-folder")
    if feature.startswith("zip-update-"):
        command.append("--update-original")
    if feature == "zip-update-tracked":
        command.append("--tracked-zip")
    if tar_editor:
        command.extend(["--tar-editor", "--archive-editor-only"])
        if gzip_tar_editor:
            command.append("--gzip-tar-editor")
        if marked_archive_editor:
            command.append("--marked-archive-editor")
    if native_zip_update:
        command.append("--native-original-update")
    if native_zip_recovery:
        command.append("--interrupt-native-original-update")
    if native_zip_update and feature == "editor-preferences":
        command.append("--archive-editor-only")
    if feature in ("zip-update-new-folder", "zip-new-folder-copy"):
        command.append("--new-folder")
    if feature == "zip-update-duplicate":
        command.append("--duplicate-members")
    if feature == "zip-update-move":
        command.append("--move-members")
    if feature == "zip-update-copy":
        command.append("--clipboard-copy-members")
    if large_interface:
        command.append("--large-interface")
    if feature in ("settings-motion", "help-motion", "tool-windows", "server-prompts", "sftp-profiles", "storage-chart"):
        command += ["--motion-mode", motion_mode]
        if large_interface:
            command += ["--motion-large", "--motion-light"]
    if interactive:
        command.append("--interactive-tar-member-drag" if tar_editor else
                       "--interactive-zip-move" if feature == "zip-update-move" else "--interactive-sidebar-review")
    if motion:
        command.append("--record-download-motion" if feature == "sftp-batch-download" else
                       "--record-connection-fields" if feature == "connection-fields" else
                       "--record-drive-benchmark" if feature == "drive-benchmark" else
                       "--record-remote-properties" if feature == "remote-properties" else
                       "--record-storage-status" if feature == "drive-status" else
                       "--record-analysis-persistence" if feature == "analysis-persistence" else "--check-development-motion")
    env = environment(tooling=False)
    env["MAC_EXPLORER_TEST_ROOT"] = str(case)
    if feature == "support-details":
        env["MAC_EXPLORER_STATE_ROOT"] = str(case / "state")
        env["MAC_EXPLORER_CACHE_ROOT"] = str(case / "cache")
    print(f"Native {feature}: {case}", flush=True)
    if marked_source_create:
        phases = ("create", "cold-undo")
    elif feature == "analysis-persistence":
        phases = ("unchanged", "unchanged-reopen") if incremental_analysis else ("seed", "reopen", "repair")
    elif feature == "selection-group":
        phases = ("suite", "recover")
    elif tar_editor and not interactive:
        phases = ("suite", "cold-undo")
    else:
        phases = (None,)
    for phase in phases:
        if marked_source_create:
            phase_command = command + (["--archive-create-cold-undo"] if phase == "cold-undo" else [])
        elif feature == "selection-group":
            phase_command = command + ["--group-phase", phase]
        elif tar_editor:
            phase_command = command + (["--tar-editor-cold-undo"] if phase == "cold-undo" else [])
        else:
            phase_command = command + ([phase] if phase else [])
        log_name = f"process-{phase}.log" if phase else "process.log"
        with (case / "evidence" / log_name).open("xb") as output:
            if external_promise_receiver:
                result = _run_generated_sftp_finder_promise(phase_command, case, env, output)
            else:
                result = subprocess.run(phase_command, cwd=ROOT, env=env, input=private_input,
                                        stdout=output, stderr=subprocess.STDOUT,
                                        timeout=1500 if feature == "smb-connected-uploads" and generated_flow.startswith("download-drops")
                                            else 750 if feature == "sftp-group-upload" and interactive else 240)
        if result.returncode:
            raise RuntimeError(f"Native {feature} {phase or ''} failed; inspect {case / 'evidence'}")
        if tar_editor:
            phase_receipt = case / "evidence" / ("native-editor-preferences-cold.json" if phase == "cold-undo" else "native-editor-preferences.json")
            phase_value = json.loads(phase_receipt.read_text()) if phase_receipt.is_file() else {}
            if phase_value.get("passed") is not True or phase_value.get("actualOwnerDrain") is not True:
                raise RuntimeError(f"Native TAR editor {phase or ''} failed at {phase_value.get('failure', 'missing report')}; inspect {case / 'evidence'}")
        if marked_source_create:
            phase_receipt = case / "evidence/native.json"
            phase_value = json.loads(phase_receipt.read_text()) if phase_receipt.is_file() else {}
            if phase_value.get("passed") is not True or phase_value.get("markedSource") is not True \
                    or phase_value.get("format") != marker["format"] \
                    or (phase == "create" and phase_value.get("coldUndoPending") is not True) \
                    or (phase == "cold-undo" and phase_value.get("coldUndoSucceeded") is not True):
                raise RuntimeError(f"Native {feature} {phase} failed; inspect {case / 'evidence'}")
            if phase == "create":
                warm_receipt = case / "evidence/marked-create.json"
                if warm_receipt.exists():
                    raise RuntimeError("Generated marked Create receipt already exists")
                phase_receipt.rename(warm_receipt)
        elif feature == "analysis-persistence":
            phase_receipt = case / "evidence" / f"persistence-{phase}-result.json"
            phase_value = json.loads(phase_receipt.read_text()) if phase_receipt.is_file() else {}
            if phase_value.get("passed") is not True or phase_value.get("ownerIdle") is not True:
                raise RuntimeError(f"Native {feature} {phase} failed at {phase_value.get('failure', 'missing report')}; inspect {case / 'evidence'}")
        elif feature == "selection-group":
            phase_receipt = case / "evidence" / ("native-selection-group-recover.json" if phase == "recover" else "native-selection-group.json")
            phase_value = json.loads(phase_receipt.read_text()) if phase_receipt.is_file() else {}
            if phase_value.get("passed") is not True or phase_value.get("coordinatorIdle") is not True:
                raise RuntimeError(f"Native {feature} {phase} failed at {phase_value.get('failureStage', 'missing report')}; inspect {case / 'evidence'}")
    receipt = case / report if feature in ("trash-command", "operation-access", "archive-pane") else case / "evidence" / report
    value = json.loads(receipt.read_text()) if receipt.is_file() else {}
    if result.returncode or value.get("passed") is not True:
        stage = next((value[key] for key in ("failure", "failureStage", "line", "failureLine", "stage", "failures")
                      if value.get(key) is not None), "missing report")
        failure_type = f" ({value['failureType']})" if value.get("failureType") else ""
        raise RuntimeError(f"Native {feature} failed at {stage}{failure_type}; inspect {case / 'evidence'}")
    if external_promise_receiver and (value.get("actualFinderReceiver") is not True
                                      or value.get("actualReceiverDrag") is not True
                                      or value.get("nativeProviderCallbacks") != 1
                                      or (case / "source/Destination/Generated Promise.txt").exists()):
        raise RuntimeError(f"Generated SFTP Finder promise evidence is incomplete; inspect {case / 'evidence'}")
    if compiled["productSHA256"] != product_inputs(APP):
        raise RuntimeError("The checked app changed during native acceptance")
    if feature == "sftp-group-upload" and any(
            (case / "source/Local" / name).read_bytes() != body for name, body in upload_bodies.items()):
        raise RuntimeError("Native upload admission changed its generated local originals")
    if feature in ("create-zip", "create-tar"):
        verify_native_archive_creation(case, feature, marked_source_create=marked_source_create, gzip_tar=gzip_tar)
    if feature == "batch-rename":
        with zipfile.ZipFile(case / "source/Batch Rename.zip") as original, \
             zipfile.ZipFile(case / "evidence/Batch Edited.zip") as edited:
            expected = {("Reviewed " + name if name.startswith("Folder/") or name == "Top.txt" else name): original.read(name)
                        for name in original.namelist()}
            names = edited.namelist()
            if len(set(names)) != len(names) or edited.testzip() is not None \
                    or {name: edited.read(name) for name in names} != expected:
                raise RuntimeError("Independent ZIP batch namespace/contents check failed")
        (case / "evidence/independent-batch.json").write_text(json.dumps({"passed": True, "members": len(names),
            "allNamesAndBodiesExact": True, "ordinaryLocalAndZIPFlow": True}) + "\n")
    if feature.startswith("zip-"):
        if feature == "zip-update-new-folder":
            with zipfile.ZipFile(case / "source/Input/Original.zip") as original, \
                 zipfile.ZipFile(case / "evidence/Grouped Edited.zip") as grouped:
                group_expected = {("Project/Grouped Items/" + name[len("Project/"):] if name in
                                  ("Project/Note.txt", "Project/Other.txt") else name): original.read(name)
                                  for name in original.namelist()}
                group_expected["Project/Grouped Items/"] = b""
                group_names = grouped.namelist()
                if len(group_names) != len(set(group_names)) or grouped.testzip() is not None \
                        or {name: grouped.read(name) for name in group_names} != group_expected:
                    raise RuntimeError("Independent ZIP grouping namespace/CRC/body check failed")
        if feature == "zip-update-add":
            with zipfile.ZipFile(case / "source/Input/Original.zip") as original, \
                 zipfile.ZipFile(case / "evidence/Replacement Edited.zip") as replaced:
                replacement_expected = {name: original.read(name) for name in original.namelist()}
                replacement_expected["Project/Added.txt"] = b"added\n"
                replacement_names = replaced.namelist()
                if len(replacement_names) != len(set(replacement_names)) or replaced.testzip() is not None \
                        or {name: replaced.read(name) for name in replacement_names} != replacement_expected:
                    raise RuntimeError("Independent ZIP replacement namespace/CRC/body check failed")
        with zipfile.ZipFile(case / "source/Input/Original.zip") as original, \
             zipfile.ZipFile(case / "evidence/Edited.zip") as edited:
            expected = {name: original.read(name) for name in original.namelist()}
            if feature == "zip-update-add":
                expected |= {"Project/Added (2).txt": b"added\n", "Project/Bundle (1)/": b"",
                             "Project/Bundle (1)/Empty/": b"", "Project/Bundle (1)/Child.txt": b"nested\n"}
            elif feature == "zip-add-copy":
                expected |= {"Project/Added.txt": b"added\n", "Project/Bundle/": b"",
                             "Project/Bundle/Empty/": b"", "Project/Bundle/Child.txt": b"nested\n"}
            elif feature in ("zip-update-new-folder", "zip-new-folder-copy"):
                expected["Project/Fresh Folder/"] = b""
            elif feature == "zip-update-duplicate":
                expected |= {("Project (1)/" + name[len("Project/"):] if name.startswith("Project/") else "Top (1).txt"): body
                             for name, body in expected.items()}
            elif feature == "zip-update-move":
                expected = {("Project/" + name if name == "Top.txt" or name.startswith("Move Folder/") else name): body
                            for name, body in expected.items()}
            elif feature == "zip-update-copy":
                expected |= {"Project/" + name: body for name, body in expected.items() if name.startswith("Move Folder/")}
                expected["Project/Top (2).txt"] = expected["Top.txt"]
            elif feature in ("zip-remove-folder-copy", "zip-update-empty"):
                expected = {}
            elif feature in ("zip-remove-copy", "zip-update-remove"):
                expected = {name: body for name, body in expected.items()
                            if name not in ("Project/Note.txt", "Project/Other.txt")}
            elif feature in ("zip-rename-folder-copy", "zip-update-folder"):
                expected = {("Renamed Project/" + name[len("Project/"):] if name.startswith("Project/") else name): body
                            for name, body in expected.items()}
            else:
                expected["Project/Renamed.txt"] = expected.pop("Project/Note.txt")
            if len(edited.namelist()) != len(expected) or set(edited.namelist()) != set(expected) or edited.testzip() is not None:
                raise RuntimeError("Independent Python ZIP namespace/CRC check failed")
            if any(edited.read(name) != body for name, body in expected.items()):
                raise RuntimeError("Independent Python ZIP body check failed")
            if feature == "zip-update-copy":
                source_info = original.getinfo("Top.txt")
                for name in ("Top.txt", "Project/Top (2).txt"):
                    info = edited.getinfo(name)
                    if (info.comment, info.extra, info.external_attr, info.create_system) != (
                            source_info.comment, source_info.extra, source_info.external_attr, source_info.create_system):
                        raise RuntimeError("Independent Python ZIP metadata check failed")
        (case / "evidence/independent-zip-edit.json").write_text(json.dumps({"passed": True,
            "producer": "python-zipfile", "records": len(expected), "allBodiesExact": True,
            "windowsMetadataPreserved": feature == "zip-update-copy"}) + "\n")
    if any(hashlib.sha256(read_artifact(ROOT / name, 1 << 20)).hexdigest() != digest
           for name, digest in controller_inputs.items()):
        raise RuntimeError("The native feature controller changed during its check")
    print(f"Native {feature}: passed; evidence {receipt}")
    return case
