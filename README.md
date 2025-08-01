# Swift SDK Generator

## Overview

With Swift supporting many different platforms, cross-compilation can boost developer productivity. In certain cases it's
the only way to build a Swift package.

[SE-0387](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0387-cross-compilation-destinations.md) proposal
introduces Swift SDKs, which bundle together all components required for cross-compilation in a single archive, and
make cross builds as easy as running a single command.

Swift SDK authors can assemble such archive manually, but the goal of Swift SDK Generator developed in this repository
is to automate this task as much as possible. If you're a platform maintainer, or someone who would like to make
cross-compiling easy to your favorite platform, you can tailor the generator source code to your needs and publish
a newly generated Swift SDK for users to install.

## Requirements

Usage of Swift SDKs requires Swift 5.9, follow [installation instructions on swift.org](https://www.swift.org/install/) to install it first.

After that, verify that the `experimental-sdk` command is available:

```
swift experimental-sdk list
```

The output will either state that no Swift SDKs are available, or produce a list of those you previously had installed, in case you've used the `swift experimental-sdk install` command before.

### macOS Requirements

The generator depends on the following dependencies to be installed on macOS:

- `xz`: used for more efficient downloading of package lists for Ubuntu. If `xz` is not found, the generator will fallback on `gzip`.
- `cmake` and `ninja`: required for building LLVM native for versions of Swift before 6.0.
- `zstd`: required to decompress certain downloaded artifacts that use [Zstandard](https://github.com/facebook/zstd) compression.

These dependencies can be installed from the `Brewfile`:

```bash
brew bundle install
```

## Supported platforms and minimum versions

macOS as a host platform and Linux as both host and target platforms are supported by the generator.
The generator also allows cross-compiling between any Linux distributions officially supported by the Swift project.

| Platform       | Supported Version as Host | Supported Version as Target |
| -:             | :-                        | :-                          |
| macOS (arm64)  | ✅ macOS 13.0+            | ❌                         |
| macOS (x86_64) | ✅ macOS 13.0+[^1]        | ❌                         |
| Ubuntu         | ✅ 20.04+                 | ✅ 20.04+                  |
| Debian         | ✅ 11, 12[^2]             | ✅ 11, 12[^2]              |
| RHEL           | ✅ Fedora 39, UBI 9       | ✅ Fedora 39, UBI 9[^3]    |
| Amazon Linux 2 | ✅ Supported              | ✅ Supported[^3]           |

[^1]: Since LLVM project doesn't provide pre-built binaries of `lld` for macOS on x86_64, it will be automatically built
from sources by the generator, which will increase its run by at least 15 minutes on recent hardware. You will also
need CMake and Ninja preinstalled (e.g. via `brew install cmake ninja`).
[^2]: Swift does not officially support Debian 11 or Debian 12 with Swift versions before 5.10.1. However, the Ubuntu 20.04/22.04 toolchains can be used with Debian 11 and 12 (respectively) since they are binary compatible.
[^3]: These versions are technically supported but require custom commands and a Docker container to build the Swift SDK, as the generator will not download dependencies for these distributions automatically. See [issue #138](https://github.com/swiftlang/swift-sdk-generator/issues/138).

## How to use it

Clone this repository into a directory of your choice and make it the current directory. Build and run it with this command:

```
swift run swift-sdk-generator make-linux-sdk
```

This will download required components and produce a Swift SDK for Ubuntu Jammy in the `Bundles` subdirectory. Follow the steps
printed at the end of generator's output for installing the newly generated Swift SDK.

Additional command-line options are available for specifying target platform features, such as Linux distribution name,
version, and target CPU architecture. Pass `--help` flag to see all of the available options:

```
swift run swift-sdk-generator make-linux-sdk --help
```

After installing a Swift SDK, verify that it's available to SwiftPM:

```
swift experimental-sdk list
```

The output of the last command should contain `ubuntu22.04`. Note the full Swift SDK ID in the output, we'll refer to it
subsequently as `<generated_sdk_id>`.

Create a new project to verify that the SDK works:

```
mkdir cross-compilation-test
cd cross-compilation-test
swift package init --type executable
```

Build this project with the SDK:

```
swift build --experimental-swift-sdk <generated_sdk_id>
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

You can then copy this binary to a Docker image that has Swift runtime libraries installed. For example,
for Ubuntu Jammy and Swift 5.9 this would be `swift:5.9-jammy-slim`. If you'd like to copy the binary to
an arbitrary Ubuntu Jammy system, make sure you pass `--static-swift-stdlib` flag to `swift build`, in addition
to the `--experimental-swift-sdk` option.

## Common Generator Options

By default, on macOS hosts running on Apple Silicon, the Swift SDK Generator will create Swift SDKs
for Ubuntu Jammy on aarch64, which matches the CPU architecture of the host. However, it is possible to change
the default target architecture by passing the `--target-arch` flag:

```bash
swift run swift-sdk-generator make-linux-sdk --target-arch x86_64
```

This will default to building the Swift SDK for `x86_64-unknown-linux-gnu`. To build for other
platforms and environments, supply the `--target` flag with the full target triple instead.

The Linux distribution name and version can also be passed to change from the default of Ubuntu Jammy:

```bash
swift run swift-sdk-generator make-linux-sdk --distribution-name ubuntu --distribution-version 24.04
```

### Host Toolchain

The host toolchain is not included in the generated Swift SDK by default on Linux to match the behavior
of the [Static Linux Swift SDKs](https://www.swift.org/documentation/articles/static-linux-getting-started.html)
downloadable from [swift.org](https://www.swift.org/install/). However, on macOS, since most users are using Xcode
and are likely not using the Swift OSS toolchain to build and run Swift projects, the Swift host toolchain
is included by *default*. This default behavior can be changed by passing  `--no-host-toolchain`:

```bash
swift run swift-sdk-generator make-linux-sdk --no-host-toolchain --target-arch x86_64
```

To generate the Swift SDK on Linux with the host toolchain included, add `--host-toolchain`:

```bash
swift run swift-sdk-generator make-linux-sdk --host-toolchain --target-arch aarch64
```

## Building an SDK from a container image

You can base your SDK on a container image, such as one of the
[official Swift images](https://hub.docker.com/_/swift).   By
default, the command below will build an SDK based on the Ubuntu
Jammy image:
```
swift run swift-sdk-generator make-linux-sdk --with-docker
```
To build a RHEL images, use the `--distribution-name` option.
The following command will build a `ubi9`-based image:
```
swift run swift-sdk-generator make-linux-sdk --with-docker --distribution-name rhel
```

You can also specify the base container image by name:

```
swift run swift-sdk-generator make-linux-sdk --from-container-image swift:5.9-jammy
```

```
swift run swift-sdk-generator make-linux-sdk --with-docker --distribution-name rhel --from-container-image swift:5.9-rhel-ubi9
```

### Including extra Linux libraries

If your project depends on Linux libraries which are not part of a
standard base image, you can build your SDK from a custom container
image which includes them.

Prepare a `Dockerfile` which derives from one of the standard images
and installs the packages you need.   This example installs SQLite
and its dependencies on top of the Swift project's Ubuntu Jammy image:

```
FROM swift:5.9-jammy
RUN apt update && apt -y install libsqlite3-dev && apt -y clean
```

Build the new container image:
```
docker build -t my-custom-image -f Dockerfile .
```

Finally, build your custom SDK:
```
swift run swift-sdk-generator make-linux-sdk --with-docker --from-container-image my-custom-image:latest --sdk-name 5.9-ubuntu-with-sqlite
```

## Swift SDK distribution

The `.artifactbundle` directory produced in the previous section can be packaged as a `.tar.gz` archive and redistributed
in this form. Users of such Swift SDK bundle archive can easily install it with `swift experimental-sdk install`
command, which supports both local file system paths and public `http://` and `https://` URLs as an argument.


## Contributing

There are several ways to contribute to Swift SDK Generator. To learn about the policies, best practices that govern contributions to the Swift project, and instructions for setting up the development environment please read the [Contributor Guide](CONTRIBUTING.md).

If you're interested in adding support for a new platform, please open an issue on this repository first so that the best implementation strategy can be discussed before proceeding with an implementation. 

## Reporting issues

If you have any trouble with the Swift SDK Generator, help is available. We recommend:

* Generator's [bug tracker](https://github.com/swiftlang/swift-sdk-generator/issues);
* The [Swift Forums](https://forums.swift.org/c/development/swiftpm/).

When reporting an issue please follow the bug reporting guidelines, they can be found in [contribution guide](./CONTRIBUTING.md#how-to-submit-a-bug-report).

If you’re not comfortable sharing your question with the list, contact details for the code owners can be found in [CODEOWNERS](.github/CODEOWNERS); however, Swift Forums is usually the best place to go for help.

## License

Copyright 2022 - 2024 Apple Inc. and the Swift project authors. Licensed under Apache License v2.0 with Runtime Library Exception.

See [https://swift.org/LICENSE.txt](https://swift.org/LICENSE.txt) for license information.

See [https://swift.org/CONTRIBUTORS.txt](https://swift.org/CONTRIBUTORS.txt) for Swift project authors.
