# Swift Cross-Compilation (CC) Destinations Generator

## Requirements

This project assumes you're running macOS 13 Ventura on Apple Silicon. It hasn't been tested with `x86_64` hosts and
targets, but we think only small tweaks would be needed to enable those. While we recommend presence of `docker`
command-line utility, for easier customization of default destinations, we also maintain a CLI option of generating a
destination without Docker.

Usage of cross-compilation destinations requires a recent trunk development snapshot. Download and install one from
swift.org, at the time of writing [16 January 2023
snapshot](https://download.swift.org/development/xcode/swift-DEVELOPMENT-SNAPSHOT-2023-01-16-a/swift-DEVELOPMENT-SNAPSHOT-2023-01-16-a-osx.pkg)
has been verified to work.

Enable the installed snapshot in your terminal environment:

```
export TOOLCHAINS=org.swift.57202301161a
```

Verify that the `experimental-destination` command is available:

```
swift experimental-destination list
```

If all goes well it will produce no output, or a list of CC destinations in case you previously had any installed.

## How to use it

Build and run with `swift run sdk-generator`. This will download required components and produce an SDK for `aarch64`
Ubuntu Jammy in `cc-destination.artifactbundle` subdirectory of this project.

Move the newly produced artifact bundle to a directory where SwiftPM can find it:

```
mv cc-destination.artifactbundle ~/.swiftpm/destinations
```

Verify that SwiftPM detects the new destination:

```
swift experimental-destination list
```

The output of the last command should contain `ubuntu22.04_aarch64`.

Create a new project to verify that the destination works:

```
mkdir cross-compilation test
cd cross-compilation-test
swift package init --type executable
```

Build this project with the destination:

```
swift build --experimental-destination-selector ubuntu22.04_aarch64
```

Verify that the produced binary is compatible with Linux:

```
file .build/debug/cross-compilation-test
```

That should produce output similar to this:

```
.build/debug/cross-compilation-test: ELF 64-bit LSB pie executable, ARM aarch64, version 1 (SYSV), 
dynamically linked, interpreter /lib/ld-linux-aarch64.so.1, for GNU/Linux 3.7.0, with debug_info, not stripped
```
