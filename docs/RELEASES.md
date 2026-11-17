# Versions and releases

[← Back to the README](../README.md)

This page explains how Kyklos versions are numbered, what a release publishes, and how the [`Kyklos Launcher`](COMPONENTS.md#kyklos-launcher) decides which [`Kyklos Bridge`](COMPONENTS.md#kyklos-bridge) version to run.

## How a version is numbered

Every Kyklos version has three parts: `MAJOR.MINOR.<build>`.

- `MAJOR.MINOR` is chosen by the project. Kyklos is still young, so the major part is `0`.
- `<build>` is the number of the build that produced the release. It only grows, so a later build always has a higher version.

**Every release gets a new minor version** (`0.7`, then `0.8`, then `0.9`, ...). Two releases never share a minor version: before a release is published, a check compares its minor version with the newest version already on NuGet.org and stops the release when it is not higher. So the minor version alone tells two releases apart.

The three components of one release carry the **same version**: the Launcher, the Bridge and the Plugin are built, tested and published together.

## What a release publishes

Each release publishes the same version in three places:

| Where | What | How to check it |
|---|---|---|
| The [Kyklos releases page](https://github.com/DogmaSolutions/Kyklos/releases) on GitHub, as the release `v<version>` | the Launcher bundles (`kyklos-launcher-win-x64.zip`, `kyklos-launcher-linux-x64.zip`), the Bridge programs (`kyklos-bridge-win-x64.exe`, `kyklos-bridge-linux-x64`, `kyklos-bridge-osx-arm64`), the licence files, `kyklos-release.json` (the version and the SHA-256 checksum of each file, which the Launcher reads) and `SHA256SUMS.txt` (the same checksums, one line per file) | compare a file's SHA-256 (`Get-FileHash` on Windows, `sha256sum` elsewhere) with its line in `SHA256SUMS.txt`; the Windows Launcher and Bridge programs also carry a code signature from Dogma Solutions |
| [NuGet.org](https://www.nuget.org/packages/DogmaSolutions.Kyklos.Bridge) | the Bridge as the .NET tool `DogmaSolutions.Kyklos.Bridge` (`dotnet tool install --global DogmaSolutions.Kyklos.Bridge`) | NuGet.org signs every package it serves (`dotnet nuget verify`), and the Bridge's own files inside it are signed |
| The Kyklos marketplace, the [Kyklos GitHub repository](https://github.com/DogmaSolutions/Kyklos) | a snapshot of the Plugin, installed with `claude plugin install kyklos@dogmasolutions` | the release is refused unless the marketplace already carries the Plugin of the same version |

## How the Launcher picks the Bridge version

You do not choose a Bridge version by hand. At every launch the Launcher:

1. reads `kyklos-release.json` of the **latest** release on the release page named by the setting `Launcher:Bridge:ReleaseUrl` (by default the Kyklos releases page; no token is needed for a public page). That file names the version and the checksum of each file;
2. takes the Bridge program for the host's platform from its local cache, or downloads it from that release when the cache does not hold it;
3. starts it only when its SHA-256 equals the checksum the release published. A download whose checksum differs, or a cached copy that was changed, is never run.

When the release page cannot be reached, the Launcher works offline: it keeps a running Bridge that was started with the current configuration, or starts the newest checked copy in its cache. With no checked copy it starts no Bridge and says why, naming its cache folder.

An organisation that keeps its own package registry sets `Launcher:Bridge:PackageProjectId` (with the registry's address and read token, see the [Launcher's settings](INSTALL_AND_CONFIG.md)). The registry then replaces the release page as the source: the Launcher takes the highest version published there, compared by number, and checks it the same way.

The Launcher keeps a few older checked versions in its cache, so a recent version can start offline, and never deletes the version a running Bridge was started from.

## How the Launcher learns about its own updates

The Launcher never updates itself. At start it reads the same source (the latest release's `kyklos-release.json`, or the package registry when one is set) and, when a newer version exists, shows a banner with the update step for the way it was installed. Installing the newer release is your decision.

## Related pages

[The three components](COMPONENTS.md), [Installing and configuring Kyklos](INSTALL_AND_CONFIG.md), [Secrets](SECRETS.md), and [the README](../README.md) for the full list.
