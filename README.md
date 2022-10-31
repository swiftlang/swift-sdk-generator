# Swift Cross-Compilation SDK Generator

Build and run with `swift run sdk-generator`. This will download and produce an SDK for `x86_64` Ubuntu Jammy in
`cc-sdk` subdirectory of the project.

You can then use the newly produced CC SDK with

```
swift build --destination <path_to_the_generator_source_dir>/cc-sdk/x86_64-unknown-linux-gnu/cross-toolchain/ubuntu-jammy-destination.json
```
