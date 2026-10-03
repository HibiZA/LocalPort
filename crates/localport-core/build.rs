fn main() {
    // `scripts/build.sh` sets this from the git tag so every binary reports
    // the release version rather than the crate version.
    println!("cargo:rerun-if-env-changed=LOCALPORT_VERSION");
}
