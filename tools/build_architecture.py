"""One thin macOS architecture shared by the app and its bundled workers.

Development defaults to the host. Cross-builds pass TRAVERSE_BUILD_ARCH and
the same single Xcode ARCHS value; mixed or unknown selections are refused.
"""
from __future__ import annotations

from dataclasses import dataclass
import os
from pathlib import Path
import platform
from typing import Mapping


@dataclass(frozen=True)
class Architecture:
    name: str
    rust_target: str

    @property
    def clang_target(self) -> str:
        return self.name + "-apple-macos15.0"

    @property
    def direct_update_lane(self) -> str:
        # Keep the established ARM endpoint compatible with installed releases.
        return "direct-updates" if self.name == "arm64" else "direct-updates-intel"

    @property
    def direct_feed_url(self) -> str:
        return "https://respawn-studios.com/products/traverse/" + self.direct_update_lane + "/appcast.xml"

    def cache_directory(self, root: Path) -> Path:
        # Preserve the established ARM cache; Intel cannot overwrite it.
        return root if self.name == "arm64" else root / self.name

    def cargo_arguments(self) -> list[str]:
        return [] if self.name == host().name else ["--target", self.rust_target]

    def cargo_product(self, root: Path, binary: str) -> Path:
        target = root if self.name == host().name else root / self.rust_target
        return target / "release" / binary


ARCHITECTURES = {
    "arm64": Architecture("arm64", "aarch64-apple-darwin"),
    "x86_64": Architecture("x86_64", "x86_64-apple-darwin"),
}


def named(name: str) -> Architecture:
    try:
        return ARCHITECTURES[name]
    except (KeyError, TypeError):
        raise ValueError("Expected one macOS architecture: arm64 or x86_64") from None


def host() -> Architecture:
    return named(platform.machine())


def direct_app_architecture(info: Mapping) -> Architecture:
    # Releases before Intel support did not carry the marker and were ARM only.
    return named(info.get("TraverseDirectArchitecture", "arm64"))


def selected(environment: Mapping[str, str] | None = None) -> Architecture:
    env = os.environ if environment is None else environment
    requested = env.get("TRAVERSE_BUILD_ARCH")
    xcode = env.get("ARCHS", "").split()
    if xcode and len(xcode) != 1:
        raise ValueError("Build each installer with one matching app/helper architecture")
    if requested is not None:
        result = named(requested)
        if xcode and xcode[0] != result.name:
            raise ValueError("App and helper architecture selections differ")
        return result
    return named(xcode[0]) if xcode else host()
