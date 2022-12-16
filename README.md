# Swift Cross-Compilation Destinations Generator

Build and run with `swift run sdk-generator`. This will download and produce an SDK for `aarch64` Ubuntu Jammy in
`cc-destination.artifactbundle` subdirectory of the project.

You can then use the newly produced CC SDK with

```
swift build --destination <path_to_the_generator_source_dir>/cc-destination.artifactbundle/x86_64-unknown-linux-gnu/ubuntu-jammy-destination.json
```
