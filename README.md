# Swift SDK Generator

## Requirements

This project assumes you're running macOS 13 Ventura on Apple Silicon. It hasn't been tested with `x86_64` hosts and
targets, but we think only small tweaks would be needed to enable those. While we recommend presence of `docker`
command-line utility for easier customization of Swift SDKs, we also maintain a CLI option of generating a
a Swift SDK without Docker.

Usage of Swift SDKs requires a recent 5.9 development snapshot. Download and install one from
http://swift.org/download, at the time of writing [11 April 2023
snapshot](https://download.swift.org/swift-5.9-branch/xcode/swift-5.9-DEVELOPMENT-SNAPSHOT-2023-04-11-a/swift-5.9-DEVELOPMENT-SNAPSHOT-2023-04-11-a-osx.pkg)
has been verified to work.

Enable the installed snapshot in your terminal environment:

```
export TOOLCHAINS=org.swift.59202304111a
```

Verify that the `experimental-sdk` command is available:

```
swift experimental-sdk list
```

If all goes well it will output a message saying no Swift SDKs are available, or a list of those you previously had 
installed.

## How to use it

Build and run with

```
swift run swift-sdk-generator
```

This will download required components and produce an SDK for `aarch64` Ubuntu Jammy in the `Bundles` subdirectory of 
this project. Follow the steps printed at the end of generator's output for installing the newly generated Swift SDK.

After installing verify that SwiftPM detects the new SDK:

```
swift experimental-sdk list
```

The output of the last command should contain `ubuntu22.04_aarch64`.

Create a new project to verify that the SDK works:

```
mkdir cross-compilation test
cd cross-compilation-test
swift package init --type executable
```

Build this project with the SDK:

```
swift build --experimental-swift-sdk ubuntu22.04_aarch64
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
