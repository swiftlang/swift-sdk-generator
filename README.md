# Swift SDK Generator

## Overview

This repository provides a command-line utility for generation of Swift SDKs for cross-compilation,
as specified in [SE-0387](https://github.com/apple/swift-evolution/blob/main/proposals/0387-cross-compilation-destinations.md)
Swift Evolution proposal.

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

| Platform | Host | Target |
| -: | :- | :- |
| macOS            | ✅ macOS 13.0+    | ❌     |
| Ubuntu | ⚠️ (WIP) | ✅ 20.04 / 22.04    |
| RHEL |  ⚠️ (WIP) | ✅ UBI 9    |

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

## Swift SDK distribution

The `.artifactbundle` directory produced in the previous section can be packaged as a `.tar.gz` archive and redistributed
in this form. Users of such Swift SDK bundle archive can easily install it with `swift experimental-sdk install`
command, which supports both local file system paths and public `http://` and `https://` URLs as an argument.


## Contributing

There are several ways to contribute to Swift SDK Generator. To learn about the policies, best practices that govern contributions to the Swift project, and instructions for setting up the development environment please read the [Contributor Guide](CONTRIBUTING.md).


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
