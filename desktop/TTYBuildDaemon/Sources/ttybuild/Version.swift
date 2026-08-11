/// The released CLI version, shown by `ttybuild --version`.
///
/// Local builds report "dev". Release builds are stamped by
/// `scripts/build-cli-release.sh`, which substitutes the marker below with
/// the desktop release version so the CLI and the app that embeds it always
/// carry the same number.
enum TTYBuildVersion {
    static let current = "dev" // ttybuild-release-version-marker
}
