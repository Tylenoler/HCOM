[CmdletBinding()]
param(
    [switch]$Build,
    [string]$FlutterSdk = 'D:\Fluttersdk\flutter',
    [string]$RustRoot = 'D:\HCOM-Rust'
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath "$FlutterSdk\bin\flutter.bat")) {
    throw "Flutter SDK was not found at $FlutterSdk. Pass -FlutterSdk with the SDK directory."
}

if (-not (Test-Path -LiteralPath "$RustRoot\cargo\bin\cargo.exe")) {
    throw "Rust Cargo was not found at $RustRoot. Pass -RustRoot with the local Rust root."
}

$flutter = "$FlutterSdk\bin\flutter.bat"
$env:CARGO_HOME = "$RustRoot\cargo"
$env:RUSTUP_HOME = "$RustRoot\rustup"
$cargo = "$env:CARGO_HOME\bin\cargo.exe"

# Flutter owns generated runner files. This command creates only missing Windows
# platform files and preserves the handwritten lib/ and pubspec sources.
& $flutter create --platforms=windows --project-name hcom --org io.github.tylenoler .
& $flutter pub get
& $cargo fmt --manifest-path core/Cargo.toml -- --check
& $cargo check --manifest-path core/Cargo.toml
& $flutter analyze
& $flutter test

if ($Build) {
    & $cargo build --manifest-path core/Cargo.toml --release
    & $flutter build windows
}
