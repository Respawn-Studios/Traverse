#!/usr/bin/env python3
"""Generate the dependency-free native development project deterministically."""

from __future__ import annotations
from pathlib import Path
import hashlib
import json
from distribution import release_notes

ROOT = Path(__file__).resolve().parents[1]


def identifier(label: str) -> str:
    return hashlib.sha256(label.encode()).hexdigest()[:24].upper()


def source_membership_exceptions():
    """Exclude local editor/patch backups without removing the owner's files."""
    base = ROOT / "App/MacExplorer"
    suffixes = (".orig", ".rej", ".bak", "~")
    backups = sorted(path.relative_to(base).as_posix() for path in base.rglob("*")
                     if path.is_file() and path.name.endswith(suffixes))
    guides = sorted(path.relative_to(base).as_posix() for path in base.rglob("*.md"))
    return ["Info.plist", *backups, *guides]


def generate(*, destination: Path | None = None, traverse: bool = False, direct: bool = False,
             direct_access_qualification: bool = False, private_updater: bool = False,
             public_updater: bool = False, direct_shipping: bool = False) -> None:
    # The distribution project is generated under .build. Never rewrite the
    # owner's development project to select a different name/signing channel.
    product = "Traverse" if traverse else "Mac Explorer"
    target_name = "Traverse" if traverse else "MacExplorer"
    project = destination or ROOT / "MacExplorer.xcodeproj"
    if direct and not traverse:
        raise ValueError("Direct distribution requires the isolated Traverse target")
    if direct_access_qualification and not (traverse and direct):
        raise ValueError("Local-user qualification requires the isolated direct target")
    if private_updater and not (traverse and direct and not direct_access_qualification):
        raise ValueError("Private updates require the isolated sandboxed direct target")
    if public_updater and (private_updater or not (traverse and direct)):
        raise ValueError("Public updates require a separate isolated Developer ID target")
    if direct_shipping and not (traverse and direct and direct_access_qualification and public_updater):
        raise ValueError("Direct shipping requires its separate local-user public target")
    updater = private_updater or public_updater
    if traverse and (project.resolve() != project or not project.is_relative_to(ROOT / ".build")):
        raise ValueError("Traverse project must stay under the isolated build root")
    ids = {name: identifier(name) for name in (
        "project", "main", "products", "app", "sources", "frameworks", "resources",
        "target", "package", "core", "storage", "operations", "search", "analysis", "memory", "core-build", "storage-build", "operations-build", "search-build", "analysis-build", "memory-build", "storage-worker", "signing-config",
        "project-configs", "target-configs", "project-debug", "project-release",
        "target-debug", "target-release", "source-exceptions", "sparkle", "sparkle-build", "sparkle-embed", "updates", "updates-build",
        "crash-reporter", "crash-reporter-build", "crash-reporter-embed",
    )}
    objects = []

    def add(name: str, body: str) -> None:
        objects.append(f"\t\t{ids[name]} = {{ {body} }};")

    add("core-build", f"isa = PBXBuildFile; productRef = {ids['core']};")
    add("storage-build", f"isa = PBXBuildFile; productRef = {ids['storage']};")
    add("operations-build", f"isa = PBXBuildFile; productRef = {ids['operations']};")
    add("search-build", f"isa = PBXBuildFile; productRef = {ids['search']};")
    add("analysis-build", f"isa = PBXBuildFile; productRef = {ids['analysis']};")
    add("memory-build", f"isa = PBXBuildFile; productRef = {ids['memory']};")
    add("crash-reporter", 'isa = PBXFileReference; lastKnownFileType = wrapper.framework; path = ".build/crash-reporter-tooling/derived/Build/Products/Release-macosx/CrashReporter.framework"; sourceTree = "<group>";')
    add("crash-reporter-build", f'isa = PBXBuildFile; fileRef = {ids["crash-reporter"]};')
    add("crash-reporter-embed", 'isa = PBXShellScriptBuildPhase; alwaysOutOfDate = 1; buildActionMask = 2147483647; files = (); inputPaths = (); name = "Embed Crash Reporter"; outputPaths = (); runOnlyForDeploymentPostprocessing = 0; shellPath = /bin/sh; shellScript = "/usr/bin/python3 \\"$SRCROOT/tools/build_crash_reporter.py\\" embed";')
    signing_config = ("Distribution/TraverseDirect.xcconfig" if direct else "Distribution/Traverse.xcconfig") if traverse else "App/Config/DevelopmentSigning.xcconfig"
    if direct_access_qualification:
        signing_config = "Distribution/TraverseDirectQualification.xcconfig"
    if updater:
        signing_config = (("Distribution/TraverseLocalUserPublicShipping.xcconfig" if direct_shipping
            else "Distribution/TraverseLocalUserPublicUpdater.xcconfig") if direct_access_qualification
            else "Distribution/TraversePublicUpdater.xcconfig") if public_updater else "Distribution/TraverseUpdater.xcconfig"
        from distribution.sparkle import prepare
        prepare(public=public_updater, local_user=direct_access_qualification,
            direct_shipping=direct_shipping)
        add("sparkle", 'isa = PBXFileReference; lastKnownFileType = wrapper.framework; path = ".build/traverse-release/tooling/sparkle-2.10.0/unpacked/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"; sourceTree = "<group>";')
        add("sparkle-build", f'isa = PBXBuildFile; fileRef = {ids["sparkle"]};')
        add("updates", f'isa = XCSwiftPackageProductDependency; package = {ids["package"]}; productName = DirectUpdates;')
        add("updates-build", f'isa = PBXBuildFile; productRef = {ids["updates"]};')
        add("sparkle-embed", 'isa = PBXShellScriptBuildPhase; alwaysOutOfDate = 1; buildActionMask = 2147483647; files = (); inputPaths = (); name = "Embed Updater"; outputPaths = (); runOnlyForDeploymentPostprocessing = 0; shellPath = /bin/sh; shellScript = "/usr/bin/python3 \\"$SRCROOT/tools/distribution/sparkle.py\\" embed";')
    add("signing-config", f'isa = PBXFileReference; lastKnownFileType = text.xcconfig; path = {signing_config}; sourceTree = "<group>";')
    add("app", f'isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = "{product}.app"; sourceTree = BUILT_PRODUCTS_DIR;')
    exceptions = ", ".join(json.dumps(path) for path in source_membership_exceptions())
    add("source-exceptions", f"isa = PBXFileSystemSynchronizedBuildFileExceptionSet; membershipExceptions = ({exceptions},); target = {ids['target']};")
    add("sources", f'isa = PBXFileSystemSynchronizedRootGroup; exceptions = ({ids["source-exceptions"]},); explicitFileTypes = {{}}; explicitFolders = (); path = App/MacExplorer; sourceTree = "<group>";')
    sparkle_ref = ids['sparkle'] + ',' if updater else ''
    add("main", f'isa = PBXGroup; children = ({ids["sources"]}, {ids["signing-config"]}, {ids["products"]}, {ids["crash-reporter"]}, {sparkle_ref}); sourceTree = "<group>";')
    add("products", f'isa = PBXGroup; children = ({ids["app"]},); name = Products; sourceTree = "<group>";')
    sparkle_build = ids['sparkle-build'] + ',' + ids['updates-build'] + ',' if updater else ''
    add("frameworks", f'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ({ids["core-build"]}, {ids["storage-build"]}, {ids["operations-build"]}, {ids["search-build"]}, {ids["analysis-build"]}, {ids["memory-build"]}, {ids["crash-reporter-build"]}, {sparkle_build}); runOnlyForDeploymentPostprocessing = 0;')
    add("resources", 'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
    source_phase = identifier("source-phase")
    objects.append(f"\t\t{source_phase} = {{ isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; }};")
    helper_outputs = '$(SRCROOT)/App/Config/BundleOutputs-$(MAC_EXPLORER_HELPER_OUTPUT_PROFILE).xcfilelist'
    add("storage-worker", f'isa = PBXShellScriptBuildPhase; alwaysOutOfDate = 1; buildActionMask = 2147483647; files = (); inputPaths = (); name = "Bundle Storage Scanner"; outputFileListPaths = ({json.dumps(helper_outputs)},); outputPaths = (); runOnlyForDeploymentPostprocessing = 0; shellPath = /bin/sh; shellScript = "/usr/bin/python3 \\"$SRCROOT/tools/build_storage_worker.py\\" --embed";')
    sparkle_phase = ids['sparkle-embed'] + ',' if updater else ''
    updates_product = ids['updates'] + ',' if updater else ''
    add("target", f'isa = PBXNativeTarget; buildConfigurationList = {ids["target-configs"]}; buildPhases = ({source_phase}, {ids["frameworks"]}, {ids["resources"]}, {ids["storage-worker"]}, {ids["crash-reporter-embed"]}, {sparkle_phase}); buildRules = (); dependencies = (); fileSystemSynchronizedGroups = ({ids["sources"]},); name = {target_name}; packageProductDependencies = ({ids["core"]}, {ids["storage"]}, {ids["operations"]}, {ids["search"]}, {ids["analysis"]}, {ids["memory"]}, {updates_product}); productName = "{product}"; productReference = {ids["app"]}; productType = "com.apple.product-type.application";')
    add("package", 'isa = XCLocalSwiftPackageReference; relativePath = Packages/ExplorerKit;')
    add("core", f'isa = XCSwiftPackageProductDependency; package = {ids["package"]}; productName = ExplorerCore;')
    add("storage", f'isa = XCSwiftPackageProductDependency; package = {ids["package"]}; productName = LocalStorage;')
    add("operations", f'isa = XCSwiftPackageProductDependency; package = {ids["package"]}; productName = FileOperations;')
    add("search", f'isa = XCSwiftPackageProductDependency; package = {ids["package"]}; productName = Search;')
    add("analysis", f'isa = XCSwiftPackageProductDependency; package = {ids["package"]}; productName = StorageAnalysis;')
    add("memory", f'isa = XCSwiftPackageProductDependency; package = {ids["package"]}; productName = FileMemory;')
    project_dir = str(ROOT) if traverse else ""
    add("project", f'isa = PBXProject; attributes = {{ BuildIndependentTargetsInParallel = YES; LastSwiftUpdateCheck = 2700; LastUpgradeCheck = 2700; TargetAttributes = {{ {ids["target"]} = {{ CreatedOnToolsVersion = 27.0; }}; }}; }}; buildConfigurationList = {ids["project-configs"]}; compatibilityVersion = "Xcode 16.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base,); mainGroup = {ids["main"]}; minimizedProjectReferenceProxies = 1; packageReferences = ({ids["package"]},); preferredProjectObjectVersion = 77; productRefGroup = {ids["products"]}; projectDirPath = "{project_dir}"; projectRoot = ""; targets = ({ids["target"]},);')
    common_project = 'CLANG_ENABLE_MODULES = YES; MACOSX_DEPLOYMENT_TARGET = 15.0; SDKROOT = macosx; SWIFT_VERSION = 6.0;'
    current_release = release_notes.read()['releases'][0]
    common_target = f'CODE_SIGN_STYLE = Manual; ENABLE_APP_SANDBOX = NO; ENABLE_USER_SCRIPT_SANDBOXING = NO; ENABLE_HARDENED_RUNTIME = NO; GENERATE_INFOPLIST_FILE = NO; INFOPLIST_FILE = App/MacExplorer/Info.plist; LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/../Frameworks"; MARKETING_VERSION = {current_release["version"]}; CURRENT_PROJECT_VERSION = {current_release["build"]}; PRODUCT_BUNDLE_IDENTIFIER = local.macexplorer.development; PRODUCT_NAME = "Mac Explorer"; SWIFT_EMIT_LOC_STRINGS = NO; SWIFT_STRICT_CONCURRENCY = complete;'
    if traverse:
        # App-target settings only: command-line PRODUCT_NAME overrides would
        # also rename Swift package products and cause output collisions.
        common_target = 'ENABLE_USER_SCRIPT_SANDBOXING = NO; LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/../Frameworks"; PRODUCT_NAME = Traverse; SWIFT_EMIT_LOC_STRINGS = NO; SWIFT_STRICT_CONCURRENCY = complete;'
    common_target += ' MAC_EXPLORER_HELPER_OUTPUT_PROFILE = network; FRAMEWORK_SEARCH_PATHS = ("$(inherited)", "$(SRCROOT)/.build/crash-reporter-tooling/derived/Build/Products/Release-macosx");'
    for scope, settings in (("project", common_project), ("target", common_target)):
        for mode in ("debug", "release"):
            extra = 'DEBUG_INFORMATION_FORMAT = dwarf; ONLY_ACTIVE_ARCH = YES; OTHER_SWIFT_FLAGS = "$(inherited) -j4 -driver-batch-count 4"; SWIFT_OPTIMIZATION_LEVEL = "-Onone"; SWIFT_ACTIVE_COMPILATION_CONDITIONS = "$(inherited) DEBUG";' if mode == "debug" else 'DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym"; SWIFT_COMPILATION_MODE = wholemodule;'
            base = f'baseConfigurationReference = {ids["signing-config"]};' if scope == "target" and (mode == "debug" or traverse) else ""
            if scope == "target" and mode == "release" and not traverse:
                extra += ' CODE_SIGN_IDENTITY = "-"; DEVELOPMENT_TEAM = "";'
            add(f"{scope}-{mode}", f'isa = XCBuildConfiguration; {base} buildSettings = {{ {settings} {extra} }}; name = {mode.title()};')
        add(f"{scope}-configs", f'isa = XCConfigurationList; buildConfigurations = ({ids[f"{scope}-debug"]}, {ids[f"{scope}-release"]},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug;')
    project.mkdir(parents=True, exist_ok=True)
    (project / "project.pbxproj").write_text('// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {};\n\tobjectVersion = 77;\n\tobjects = {\n' + "\n".join(objects) + f'\n\t}};\n\trootObject = {ids["project"]};\n}}\n')
    schemes = project / "xcshareddata/xcschemes"
    schemes.mkdir(parents=True, exist_ok=True)
    container = str(project) if traverse else project.name
    reference = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ids["target"]}" BuildableName="{product}.app" BlueprintName="{target_name}" ReferencedContainer="container:{container}"/>'
    (schemes / f"{target_name}.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{reference}</BuildActionEntry></BuildActionEntries></BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables/></TestAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="YES" debugDocumentVersioning="YES" allowLocationSimulation="NO"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')


if __name__ == "__main__":
    generate()
    print("Generated MacExplorer.xcodeproj and its shared MacExplorer scheme.")
