# Swift SDK Generator

## Overview

With Swift supporting many different platforms, cross-compilation can boost developer productivity. In certain cases it's
the only way to build a Swift package.

[SE-0387](https://github.com/apple/swift-evolution/blob/main/proposals/0387-cross-compilation-destinations.md) proposal
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

The output will either state that no Swift SDKs are available, or produce a list of those you previously had 
installed, in case you've used the `swift experimental-sdk install` command before.

## Supported platforms and minimum versions

macOS as a host platform and a few Linux distributions as target platforms are supported by the generator.
Support for Linux as a host platform is currently in development. Eventually, the generator will allow cross-compiling between any
Linux distributions officially supported by the Swift project.

| Platform       | Supported Version as Host | Supported Version as Target |
| -:             | :-                        | :-                          |
| macOS (arm64)  | ✅ macOS 13.0+            | ❌                         |
| macOS (x86_64) | ✅ macOS 13.0+[^1]        | ❌                         |
| Ubuntu         | ⚠️ (WIP)                  | ✅ 20.04 / 22.04           |
| RHEL           | ⚠️ (WIP)                  | ✅ UBI 9                   |


[^1]: Since LLVM project doesn't provide pre-built binaries of `lld` for macOS on x86_64, it will be automatically built
from sources by the generator, which will increase its run by at least 15 minutes on recent hardware. You will also
need CMake and Ninja preinstalled (e.g. via `brew install cmake ninja`).

## How to use it

Clone this repository into a directory of your choice and make it the current directory. Build and run it with this command:

```
swift run swift-sdk-generator
```

This will download required components and produce a Swift SDK for Ubuntu Jammy in the `Bundles` subdirectory. Follow the steps
printed at the end of generator's output for installing the newly generated Swift SDK.

Additional command-line options are available for specifying target platform features, such as Linux distribution name,
version, and target CPU architecture. Pass `--help` flag to see all of the available options:

```
swift run swift-sdk-generator --help
```

After installing a Swift SDK, verify that it's available to SwiftPM:

```
swift experimental-sdk list
```

The output of the last command should contain `ubuntu22.04`. Note the full Swift SDK ID in the output, we'll refer to it
subsequently as `<generated_sdk_id>`.

Create a new project to verify that the SDK works:

```
mkdir cross-compilation test
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

## Building an SDK from a container image

You can base your SDK on a container image, such as one of the
[official Swift images](https://hub.docker.com/_/swift).   By
default, the command below will build an SDK based on the Ubuntu
Jammy image:
```
swift run swift-sdk-generator --with-docker
```
To build a RHEL images, use the `--linux-distribution-name` option.
The following command will build a `ubi9`-based image:
```
swift run swift-sdk-generator --with-docker --linux-distribution-name rhel
```

You can also specify the base container image by name:

```
swift run swift-sdk-generator --with-docker --from-container-image swift:5.9-jammy
```

```
swift run swift-sdk-generator --with-docker --linux-distribution-name rhel --from-container-image swift:5.9-rhel-ubi9
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
swift run swift-sdk-generator --with-docker --from-container-image my-custom-image:latest --sdk-name 5.9-ubuntu-with-sqlite
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

* Generator's [bug tracker](https://github.com/apple/swift-sdk-generator/issues);
* The [Swift Forums](https://forums.swift.org/c/development/swiftpm/).

When reporting an issue please follow the bug reporting guidelines, they can be found in [contribution guide](./CONTRIBUTING.md#how-to-submit-a-bug-report).

If you’re not comfortable sharing your question with the list, contact details for the code owners can be found in [CODEOWNERS](.github/CODEOWNERS); however, Swift Forums is usually the best place to go for help.

## License

Copyright 2022 - 2023 Apple Inc. and the Swift project authors. Licensed under Apache License v2.0 with Runtime Library Exception.

See [https://swift.org/LICENSE.txt](https://swift.org/LICENSE.txt) for license information.

See [https://swift.org/CONTRIBUTORS.txt](https://swift.org/CONTRIBUTORS.txt) for Swift project authors.
