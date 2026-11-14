"""One transparent source download, derived from an immutable source export.

The kit binds ordinary project and dependency archives; it grants no privacy,
clean-build, binary-correspondence or publication qualification. Inspection reads
bounded archive streams without extracting files or running their contents.
"""
from __future__ import annotations

from contextlib import contextmanager
import gzip
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import tarfile

from distribution.artifact_files import read

MAX_KIT_BYTES = 256 << 20
MAX_PROJECT_BYTES = 128 << 20
MAX_SOURCE_FILE_BYTES = 16 << 20
MAX_SOURCE_FILES = 8192
MAX_METADATA_BYTES = 8 << 20
FORMAT = "traverse-source-kit-v1"
SHA256 = re.compile(r"[a-f0-9]{64}")
GIT_OBJECT = re.compile(r"[a-f0-9]{40}")


def _sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _path(name: str) -> str:
    if not isinstance(name, str) or not name or len(name.encode("utf-8")) > 1024 \
            or str(PurePosixPath(name)) != name or name.startswith("/") \
            or any(part in ("", ".", "..") for part in name.split("/")) or "\\" in name \
            or any(ord(c) < 32 or ord(c) == 127 for c in name):
        raise RuntimeError("Source archive needs canonical relative paths")
    return name


def _json(data: bytes) -> dict:
    def pairs(values):
        result = {}
        for key, value in values:
            if key in result:
                raise RuntimeError("Duplicate source metadata field")
            result[key] = value
        return result
    if len(data) > MAX_METADATA_BYTES:
        raise RuntimeError("Source metadata exceeds its size bound")
    value = json.loads(data, object_pairs_hook=pairs)
    if not isinstance(value, dict):
        raise RuntimeError("Source metadata must be an object")
    return value


class _LimitedReader:
    """Bound even tar extension headers before tarfile allocates their bodies."""
    def __init__(self, stream, limit):
        self.stream, self.remaining = stream, limit

    def read(self, size=-1):
        data = self.stream.read(min(size if size >= 0 else self.remaining + 1,
                                    self.remaining + 1))
        self.remaining -= len(data)
        if self.remaining < 0:
            raise RuntimeError("Expanded source archive exceeds its size bound")
        return data


@contextmanager
def _archive(data: bytes, limit: int):
    with gzip.GzipFile(fileobj=io.BytesIO(data), mode="rb") as compressed:
        bounded = _LimitedReader(compressed, limit)
        with tarfile.open(fileobj=bounded, mode="r|") as archive:
            yield archive
            # Include tarfile's prefetched bytes. Draining only `bounded` would
            # miss an appended payload already held in the tar stream buffer.
            while tail := archive.fileobj.read(65536):
                if tail.strip(b"\0"):
                    raise RuntimeError("Unexpected data after source archive end")
        # Validate the gzip trailer as well as members preceding tar's end marker.
        while bounded.read(65536):
            pass


def _object_table(value: dict) -> dict[str, str]:
    if not isinstance(value, dict) or len(value) > MAX_SOURCE_FILES:
        raise RuntimeError("Invalid source object inventory")
    for name, object_id in value.items():
        _path(name)
        if not isinstance(object_id, str) or not GIT_OBJECT.fullmatch(object_id):
            raise RuntimeError("Invalid source Git object")
    return value


def _project(data: bytes, prefix: str, expected: dict[str, str]):
    expected = _object_table(expected)
    ancestors = {prefix}
    for name in expected:
        ancestors.update(str(parent) for parent in PurePosixPath(prefix, name).parents
                         if str(parent) != ".")
    found, entries, copies, total = {}, set(), {}, 0
    with _archive(data, MAX_PROJECT_BYTES + (16 << 20)) as archive:
        for member in archive:
            name = _path(member.name)
            if name in entries or len(entries) >= MAX_SOURCE_FILES * 3:
                raise RuntimeError("Duplicate or excessive project archive entries")
            entries.add(name)
            if member.isdir():
                if name not in ancestors:
                    raise RuntimeError("Unexpected source archive directory")
                continue
            relative = name.removeprefix(prefix + "/")
            if not member.isfile() or not name.startswith(prefix + "/") or relative not in expected:
                raise RuntimeError("Unexpected project source archive member")
            total += member.size
            if member.size < 0 or member.size > MAX_SOURCE_FILE_BYTES or total > MAX_PROJECT_BYTES:
                raise RuntimeError("Source archive member size exceeds its bound")
            body = archive.extractfile(member).read(MAX_SOURCE_FILE_BYTES + 1)
            if len(body) != member.size:
                raise RuntimeError("Source archive member size differs")
            blob = hashlib.sha1(b"blob " + str(len(body)).encode() + b"\0" + body).hexdigest()
            if blob != expected[relative]:
                raise RuntimeError("Source archive differs from its Git object")
            found[relative] = _sha(body)
            if relative in ("LICENSE", "Distribution/ThirdPartyNotices.txt",
                            "Distribution/SourceDependencies.json"):
                copies[relative] = body
    if set(found) != set(expected):
        raise RuntimeError("Source export omitted committed files")
    return found, copies


def verify_project(archive: Path, prefix: str, expected: dict[str, str]) -> dict[str, str]:
    """Check the exporter and kit through the same Git-object verification."""
    return _project(read(archive, MAX_PROJECT_BYTES), prefix, expected)[0]


def _readme(commit: str, selection: str) -> bytes:
    return (f"# Traverse source kit\n\nCommit: {commit}\nSelection: {selection}\n\n"
            "This standard archive contains the project, pinned worker dependency sources,\n"
            "Sparkle and its pinned ArgumentParser source. Extract the project archive\n"
            "and start with README.md and docs/engineering/DEVELOPMENT_SETUP.md.\n"
            "Source/dependency rebuilding instructions are in\n"
            "docs/engineering/OPEN_SOURCE_RELEASE.md within the project.\n\n"
            "LICENSE and ThirdPartyNotices.txt are byte-identical copies from that\n"
            "project. source-manifest.json and source-selection.json record the original\n"
            "preparation, hashes and any deliberately omitted historical material.\n"
            "This wrapper does not certify privacy, binary reproducibility or a release.\n").encode()


def _inspect(values: dict[str, bytes]) -> dict:
    manifest = _json(values["source-manifest.json"])
    commit, selection = manifest.get("sourceCommit"), manifest.get("sourceSelection", "full")
    if not isinstance(commit, str) or not GIT_OBJECT.fullmatch(commit) \
            or selection not in ("full", "contributor-v1") \
            or manifest.get("schema") != 1 or manifest.get("prepared") is not True:
        raise RuntimeError("Unreviewed source preparation manifest")
    records = manifest.get("files")
    sdks = manifest.get("sdkSources")
    if not isinstance(records, dict) or not isinstance(sdks, list) or len(sdks) != 2:
        raise RuntimeError("Incomplete source kit inventory")
    expected = {"Traverse-project-source.tar.gz", "WorkerDependencies.tar.gz", "source-selection.json"}
    if {sdk.get("name") for sdk in sdks if isinstance(sdk, dict)} != {"Sparkle", "swift-argument-parser"}:
        raise RuntimeError("Unreviewed SDK source inventory")
    for sdk in sdks:
        revision, filename = sdk.get("commit"), sdk.get("filename")
        if not isinstance(revision, str) or not GIT_OBJECT.fullmatch(revision) \
                or filename != sdk["name"] + "-" + revision + ".tar.gz":
            raise RuntimeError("Unreviewed SDK source filename")
        expected.add(filename)
    if set(records) != expected or set(values) != expected | {
            "source-manifest.json", "LICENSE", "ThirdPartyNotices.txt", "README.source.md"}:
        raise RuntimeError("Source kit has missing or extra files")
    for name, fact in records.items():
        if not isinstance(fact, dict) or set(fact) != {"bytes", "sha256"} \
                or type(fact["bytes"]) is not int or fact["bytes"] != len(values[name]) \
                or not isinstance(fact["sha256"], str) or not SHA256.fullmatch(fact["sha256"]) \
                or fact["sha256"] != _sha(values[name]):
            raise RuntimeError("Source kit differs from its preparation manifest")
    chosen = _json(values["source-selection.json"])
    retained = _object_table(chosen.get("retainedGitObjects"))
    omitted = _object_table(chosen.get("omittedGitObjects"))
    if chosen.get("name") != selection or set(retained) & set(omitted) \
            or len(retained) + len(omitted) > MAX_SOURCE_FILES \
            or manifest.get("projectFiles") != len(retained) or not retained \
            or (selection == "full" and omitted):
        raise RuntimeError("Source selection differs from its manifest")
    hashes, copies = _project(values["Traverse-project-source.tar.gz"], "Traverse-" + commit[:12], retained)
    if copies.get("LICENSE") != values["LICENSE"] \
            or copies.get("Distribution/ThirdPartyNotices.txt") != values["ThirdPartyNotices.txt"] \
            or values["README.source.md"] != _readme(commit, selection):
        raise RuntimeError("Source kit guides or license copies differ")
    pinned = _json(copies.get("Distribution/SourceDependencies.json", b"{}"))
    if pinned.get("schema") != 1 or pinned.get("components") != sdks \
            or any(sdk.get("sha256") != records[sdk["filename"]]["sha256"] for sdk in sdks):
        raise RuntimeError("SDK source differs from the project's dependency pins")
    return {"format": FORMAT, "sourceCommit": commit, "sourceSelection": selection,
            "sourceManifestSHA256": _sha(values["source-manifest.json"]),
            "projectSourceSHA256": hashes,
            **{key: manifest.get(key, "NOT EXERCISED") for key in
               ("privacyReview", "cleanExportBuild", "binaryCorrespondence")}}


def inspect_source_kit(path: Path) -> dict:
    """Return verified source identity and hashes; never extract or execute."""
    data = read(path, MAX_KIT_BYTES)
    values, prefix = {}, None
    with _archive(data, MAX_KIT_BYTES * 2) as archive:
        for member in archive:
            name = _path(member.name)
            parts = name.split("/")
            if not member.isfile() or len(parts) != 2 or len(values) >= 12 \
                    or not re.fullmatch(r"Traverse-source-[a-f0-9]{12}", parts[0]) \
                    or (prefix is not None and prefix != parts[0]) or parts[1] in values \
                    or not 0 < member.size <= MAX_PROJECT_BYTES:
                raise RuntimeError("Unexpected source kit archive member")
            prefix = parts[0]
            values[parts[1]] = archive.extractfile(member).read(MAX_PROJECT_BYTES + 1)
            if len(values[parts[1]]) != member.size:
                raise RuntimeError("Source kit member size differs")
    if "source-manifest.json" not in values:
        raise RuntimeError("Source kit manifest is missing")
    result = _inspect(values)
    if prefix != "Traverse-source-" + result["sourceCommit"][:12]:
        raise RuntimeError("Source kit root differs from its commit")
    return {**result, "bytes": len(data), "sha256": _sha(data)}


def create_source_kit(case: Path) -> Path:
    """Wrap a verified source export without changing its original artifacts."""
    if case.resolve() != case.absolute() or not case.is_dir():
        raise RuntimeError("Source export must be an existing unredirected directory")
    manifest_data = read(case / "source-manifest.json", MAX_METADATA_BYTES)
    manifest = _json(manifest_data)
    records = manifest.get("files")
    if not isinstance(records, dict) or len(records) != 5:
        raise RuntimeError("Incomplete source export inventory")
    values = {"source-manifest.json": manifest_data}
    for name in records:
        if _path(name) != Path(name).name:
            raise RuntimeError("Source export artifact must be a leaf filename")
        values[name] = read(case / name, MAX_PROJECT_BYTES)
    chosen = _json(values["source-selection.json"])
    commit = manifest.get("sourceCommit")
    if not isinstance(commit, str) or not GIT_OBJECT.fullmatch(commit):
        raise RuntimeError("Invalid source export commit")
    _, copies = _project(values["Traverse-project-source.tar.gz"], "Traverse-" + commit[:12],
                         chosen.get("retainedGitObjects"))
    values["LICENSE"] = copies.get("LICENSE", b"")
    values["ThirdPartyNotices.txt"] = copies.get("Distribution/ThirdPartyNotices.txt", b"")
    values["README.source.md"] = _readme(commit, manifest.get("sourceSelection", "full"))
    _inspect(values)
    prefix = "Traverse-source-" + commit[:12]
    path, sidecar = case / (prefix + ".tar.gz"), case / "source-kit.json"
    if sidecar.exists():
        raise FileExistsError("Source kit descriptor already exists")
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "wb") as output, gzip.GzipFile(filename="", mode="wb", fileobj=output, mtime=0) as compressed:
        with tarfile.open(fileobj=compressed, mode="w") as archive:
            for name, body in sorted(values.items()):
                member = tarfile.TarInfo(prefix + "/" + name)
                member.mode, member.size = 0o644, len(body)
                archive.addfile(member, io.BytesIO(body))
    result = inspect_source_kit(path)
    # Outside the archive: no self-hash cycle and no rewrite of the original manifest.
    with sidecar.open("x") as output:
        json.dump({"schema": 1, **result}, output, indent=2)
        output.write("\n")
    return path
