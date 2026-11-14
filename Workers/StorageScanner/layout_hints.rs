//! Isolated application-layout explanation candidate. This module performs no
//! I/O, reads no manifests/bodies/environment and grants no access or cleanup
//! authority. Production traversal/classification does not call it yet.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Anchor {
    /// Root/ancestors needed for a default-location rule were not observed.
    Unknown,
    /// Components are relative to the separately verified startup Data root.
    StartupData,
    /// Components are relative to the separately verified startup System root.
    StartupSystem,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(usize)]
pub enum Hint {
    Unclassified,
    ApplicationBundle,
    SteamInstalled,
    SteamWorkshop,
    SteamDownloads,
    SteamShaders,
    XcodeDerivedData,
    XcodeArchives,
    InstalledDeveloperTools,
    AndroidDeviceData,
    VirtualMachinePackage,
    AppleDeviceBackups,
    PhotosLibrary,
    VideoLibrary,
    HuggingFaceModels,
    HuggingFaceDatasets,
    HuggingFaceSpaces,
    OllamaModels,
    DockerVirtualDisk,
}
pub const COUNT: usize = 19;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Evidence {
    None,
    DirectorySuffix,
    VerifiedSourceLayout,
    ConfirmedSteamLayout,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Explanation {
    pub hint: Hint,
    pub evidence: Evidence,
    /// First matching directory, relative to the caller's admitted root.
    pub root: usize,
}
impl Explanation {
    const NONE: Self = Self { hint: Hint::Unclassified, evidence: Evidence::None, root: 0 };
}

fn valid(parts: &[&[u8]]) -> bool {
    parts.len() <= 64 && parts.iter().all(|part| !part.is_empty() && part.len() <= 255
        && !part.contains(&0) && !part.contains(&b'/') && *part != b"." && *part != b"..")
}
fn at(parts: &[&[u8]], start: usize, sequence: &[&[u8]]) -> bool {
    parts.get(start..start.saturating_add(sequence.len())) == Some(sequence)
}

/// The optional Steam index must name a root whose common directory was
/// already observed by the existing classifier. A steamapps name alone is not
/// sufficient. Components contain directories only, never a same-suffix file.
pub fn directories(parts: &[&[u8]], anchor: Anchor, steam: Option<usize>) -> Explanation {
    if !valid(parts) { return Explanation::NONE; }
    let home = if anchor == Anchor::StartupData && parts.len() >= 2 && parts[0] == b"Users" && parts[1] != b"Shared" {
        Some(2)
    } else { None };
    // First specialized ancestor wins: a cache-looking guest/backup/library
    // subtree must not escape its outer package's layout interpretation.
    for (index, name) in parts.iter().enumerate() {
        let package = if name.ends_with(b".vmwarevm") || name.ends_with(b".pvm") { Some(Hint::VirtualMachinePackage) }
            else if name.ends_with(b".photoslibrary") { Some(Hint::PhotosLibrary) }
            else if name.ends_with(b".fcpbundle") { Some(Hint::VideoLibrary) }
            else if name.ends_with(b".xcarchive") { Some(Hint::XcodeArchives) }
            else if name.ends_with(b".app") { Some(Hint::ApplicationBundle) } else { None };
        if let Some(hint) = package { return Explanation { hint, evidence: Evidence::DirectorySuffix, root: index }; }
        if steam == Some(index) && *name == b"steamapps" {
            let hint = match parts.get(index + 1).copied() {
                Some(b"common") => Hint::SteamInstalled,
                Some(b"workshop") => Hint::SteamWorkshop,
                Some(b"downloading" | b"temp") => Hint::SteamDownloads,
                Some(b"shadercache") => Hint::SteamShaders,
                _ => Hint::Unclassified,
            };
            if hint != Hint::Unclassified { return Explanation { hint, evidence: Evidence::ConfirmedSteamLayout, root: index + 1 }; }
        }
        if anchor == Anchor::StartupData && index == 0 && at(parts, 0, &[b"Library", b"Developer", b"CommandLineTools"]) {
            return Explanation { hint: Hint::InstalledDeveloperTools, evidence: Evidence::VerifiedSourceLayout, root: 2 };
        }
        let Some(home) = home.filter(|home| *home == index) else { continue; };
        let candidates: &[(&[&[u8]], Hint)] = &[
            (&[b"Library", b"Developer", b"Xcode", b"DerivedData"], Hint::XcodeDerivedData),
            (&[b"Library", b"Developer", b"Xcode", b"Archives"], Hint::XcodeArchives),
            (&[b"Library", b"Developer", b"Packages"], Hint::InstalledDeveloperTools),
            (&[b"Library", b"Android", b"sdk"], Hint::InstalledDeveloperTools),
            (&[b"Library", b"Application Support", b"MobileSync", b"Backup"], Hint::AppleDeviceBackups),
            (&[b".ollama", b"models"], Hint::OllamaModels),
        ];
        for (sequence, hint) in candidates {
            if at(parts, home, sequence) { return Explanation { hint: *hint, evidence: Evidence::VerifiedSourceLayout, root: home + sequence.len() - 1 }; }
        }
        if at(parts, home, &[b".android", b"avd"])
            && parts.get(home + 2).is_some_and(|name| name.ends_with(b".avd")) {
            return Explanation { hint: Hint::AndroidDeviceData, evidence: Evidence::VerifiedSourceLayout, root: home + 2 };
        }
        if at(parts, home, &[b".cache", b"huggingface", b"hub"]) {
            if let Some(repository) = parts.get(home + 3) {
                let hint = if repository.starts_with(b"models--") && repository.len() > 8 { Hint::HuggingFaceModels }
                    else if repository.starts_with(b"datasets--") && repository.len() > 10 { Hint::HuggingFaceDatasets }
                    else if repository.starts_with(b"spaces--") && repository.len() > 8 { Hint::HuggingFaceSpaces }
                    else { Hint::Unclassified };
                if hint != Hint::Unclassified { return Explanation { hint, evidence: Evidence::VerifiedSourceLayout, root: home + 3 }; }
            }
        }
    }
    Explanation::NONE
}

/// The one exact filename rule does not classify all raw images, all of a
/// container or all of its virtual-machine folder as cache/unused data.
#[cfg(test)]
pub fn file(parts: &[&[u8]], name: &[u8], anchor: Anchor, steam: Option<usize>) -> Explanation {
    if parts.len() >= 64 || !valid(&[name]) { return Explanation::NONE; }
    let inherited = directories(parts, anchor, steam);
    if inherited.hint != Hint::Unclassified || !valid(parts) { return inherited; }
    if docker_parent(parts, anchor) && name == b"Docker.raw" {
        return Explanation { hint: Hint::DockerVirtualDisk, evidence: Evidence::VerifiedSourceLayout, root: 4 };
    }
    Explanation::NONE
}
pub fn docker_parent(parts: &[&[u8]], anchor: Anchor) -> bool {
    valid(parts) && anchor == Anchor::StartupData && parts.len() == 9 && parts[0] == b"Users" && parts[1] != b"Shared"
        && at(parts, 2, &[b"Library", b"Containers", b"com.docker.docker", b"Data", b"vms", b"0", b"data"])
}

#[cfg(test)]
mod tests {
    use super::*;
    fn dirs(path: &str, anchor: Anchor, steam: Option<usize>) -> Explanation {
        directories(&path.split('/').filter(|v| !v.is_empty()).map(str::as_bytes).collect::<Vec<_>>(), anchor, steam)
    }
    #[test] fn package_names_are_hints_and_cannot_change_outer_package_interpretation() {
        for (path, expected) in [("Projects/Machine.pvm/Disk", Hint::VirtualMachinePackage),
            ("VM.vmwarevm/snapshots", Hint::VirtualMachinePackage), ("Pictures/Archive.photoslibrary/originals", Hint::PhotosLibrary),
            ("Movies/Edit.fcpbundle/generated", Hint::VideoLibrary), ("Build.xcarchive/App.app/Contents", Hint::XcodeArchives),
            ("Tool.app/Contents/Resources/Example.photoslibrary", Hint::ApplicationBundle)] {
            let value = dirs(path, Anchor::Unknown, None);
            assert_eq!(value.hint, expected); assert_eq!(value.evidence, Evidence::DirectorySuffix);
        }
        for name in [b"Machine.pvm".as_slice(), b"Archive.photoslibrary", b"Build.xcarchive"] {
            assert_eq!(file(&[], name, Anchor::Unknown, None).hint, Hint::Unclassified);
        }
        assert_eq!(dirs("Virtual Machines/models/sdk", Anchor::Unknown, None).hint, Hint::Unclassified);
    }
    #[test] fn default_layouts_require_a_verified_source_and_complete_observed_context() {
        for (suffix, expected) in [("Library/Developer/Xcode/DerivedData/a", Hint::XcodeDerivedData),
            ("Library/Developer/Xcode/Archives/2026", Hint::XcodeArchives),
            ("Library/Developer/Packages/OS", Hint::InstalledDeveloperTools),
            ("Library/Android/sdk/system-images", Hint::InstalledDeveloperTools),
            ("Library/Application Support/MobileSync/Backup/id", Hint::AppleDeviceBackups),
            (".android/avd/Generated.avd/userdata", Hint::AndroidDeviceData),
            (".ollama/models/blobs", Hint::OllamaModels)] {
            let path = format!("Users/generated/{suffix}");
            assert_eq!(dirs(&path, Anchor::StartupData, None).hint, expected);
            assert_eq!(dirs(&path, Anchor::Unknown, None).hint, Hint::Unclassified);
            assert_eq!(dirs(&format!("Projects/{path}"), Anchor::StartupData, None).hint, Hint::Unclassified);
            assert_eq!(dirs(suffix, Anchor::StartupData, None).hint, Hint::Unclassified);
        }
        assert_eq!(dirs("Library/Developer/CommandLineTools/SDKs", Anchor::StartupData, None).hint, Hint::InstalledDeveloperTools);
        assert_eq!(dirs("Library/Developer/CommandLineTools/SDKs", Anchor::StartupSystem, None).hint, Hint::Unclassified);
        assert_eq!(dirs("Users/Shared/Library/Android/sdk", Anchor::StartupData, None).hint, Hint::Unclassified);
        assert_eq!(dirs("Users/generated/Library/Developer/CoreSimulator", Anchor::StartupData, None).hint, Hint::Unclassified);
    }
    #[test] fn hub_repository_kinds_do_not_claim_all_hugging_face_data_is_models() {
        for (repository, expected) in [("models--org--name", Hint::HuggingFaceModels),
            ("datasets--org--name", Hint::HuggingFaceDatasets), ("spaces--org--name", Hint::HuggingFaceSpaces)] {
            let path = format!("Users/generated/.cache/huggingface/hub/{repository}/blobs");
            assert_eq!(dirs(&path, Anchor::StartupData, None).hint, expected);
            assert_eq!(dirs(&path, Anchor::Unknown, None).hint, Hint::Unclassified);
        }
        for suffix in ["", "token", "hub", "xet", "hub/models--", "hub/random", "hub/Models--name"] {
            assert_eq!(dirs(&format!("Users/generated/.cache/huggingface/{suffix}"), Anchor::StartupData, None).hint, Hint::Unclassified);
        }
        assert_eq!(dirs("Users/generated/.ollama/logs", Anchor::StartupData, None).hint, Hint::Unclassified);
    }
    #[test] fn steam_branches_require_the_existing_confirmed_root() {
        for (child, expected) in [("common", Hint::SteamInstalled), ("workshop", Hint::SteamWorkshop),
            ("downloading", Hint::SteamDownloads), ("temp", Hint::SteamDownloads), ("shadercache", Hint::SteamShaders)] {
            let path = format!("Library/steamapps/{child}/generated");
            assert_eq!(dirs(&path, Anchor::Unknown, Some(1)).hint, expected);
            assert_eq!(dirs(&path, Anchor::Unknown, None).hint, Hint::Unclassified);
            assert_eq!(dirs(&path, Anchor::Unknown, Some(0)).hint, Hint::Unclassified);
        }
        assert_eq!(dirs("steamapps/unrelated", Anchor::Unknown, Some(0)).hint, Hint::Unclassified);
    }
    #[test] fn docker_is_an_exact_file_rule_not_a_raw_suffix_rule() {
        let parts: Vec<_> = "Users/generated/Library/Containers/com.docker.docker/Data/vms/0/data".split('/').map(str::as_bytes).collect();
        assert_eq!(parts.len(), 9);
        assert_eq!(file(&parts, b"Docker.raw", Anchor::StartupData, None).hint, Hint::DockerVirtualDisk);
        assert_eq!(file(&parts, b"Docker.raw", Anchor::Unknown, None).hint, Hint::Unclassified);
        assert_eq!(file(&parts, b"other.raw", Anchor::StartupData, None).hint, Hint::Unclassified);
        assert_eq!(directories(&parts, Anchor::StartupData, None).hint, Hint::Unclassified);
        assert_eq!(file(&[b"Projects", b"vms", b"0", b"data"], b"Docker.raw", Anchor::StartupData, None).hint, Hint::Unclassified);
    }
    #[test] fn invalid_and_maximum_depth_inputs_are_bounded_without_io() {
        for parts in [vec![b"..".as_slice()], vec![b"."], vec![b""], vec![b"bad/name"], vec![b"bad\0name"]] {
            assert_eq!(directories(&parts, Anchor::StartupData, None), Explanation::NONE);
        }
        let long = [b'a'; 256]; assert_eq!(directories(&[&long], Anchor::Unknown, None), Explanation::NONE);
        let max = vec![b"component".as_slice(); 64];
        assert_eq!(directories(&max, Anchor::Unknown, None).hint, Hint::Unclassified);
        let too_deep = vec![b"Tool.app".as_slice(); 65];
        assert_eq!(directories(&too_deep, Anchor::Unknown, None), Explanation::NONE);
        assert_eq!(COUNT, Hint::DockerVirtualDisk as usize + 1);
    }
}
