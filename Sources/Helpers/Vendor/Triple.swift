//===--------------- Triple.swift - Swift Target Triples ------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2019 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

/// Helper for working with target triples.
///
/// Target triples are strings in the canonical form:
///   ARCHITECTURE-VENDOR-OPERATING_SYSTEM
/// or
///   ARCHITECTURE-VENDOR-OPERATING_SYSTEM-ENVIRONMENT
///
/// This type is used for clients which want to support arbitrary
/// configuration names, but also want to implement certain special
/// behavior for particular configurations. This class isolates the mapping
/// from the components of the configuration name to well known IDs.
///
/// At its core the Triple class is designed to be a wrapper for a triple
/// string; the constructor does not change or normalize the triple string.
/// Clients that need to handle the non-canonical triples that users often
/// specify should use the normalize method.
///
/// See autoconf/config.guess for a glimpse into what target triples
/// look like in practice.
///
/// This is a port of https://github.com/apple/swift-llvm/blob/stable/include/llvm/ADT/Triple.h
@dynamicMemberLookup
public struct Triple {
  /// `Triple` proxies predicates from `Triple.OS`, returning `false` for an unknown OS.
  public subscript(dynamicMember predicate: KeyPath<OS, Bool>) -> Bool {
    self.os?[keyPath: predicate] ?? false
  }

  /// The original triple string.
  public let triple: String

  /// The parsed arch.
  public let arch: Arch?

  /// The parsed subarchitecture.
  public let subArch: SubArch?

  /// The parsed vendor.
  public let vendor: Vendor?

  /// The parsed OS.
  public let os: OS?

  /// The parsed Environment type.
  public let environment: Environment?

  /// The object format type.
  public let objectFormat: ObjectFormat?

  /// Represents a version that may be present in the target triple.
  public struct Version: Equatable, Comparable, CustomStringConvertible {
    public static let zero = Version(0, 0, 0)

    public var major: Int
    public var minor: Int
    public var micro: Int

    public init(parse string: some StringProtocol) {
      let components = string.split(separator: ".", maxSplits: 3).map { Int($0) ?? 0 }
      self.major = components.count > 0 ? components[0] : 0
      self.minor = components.count > 1 ? components[1] : 0
      self.micro = components.count > 2 ? components[2] : 0
    }

    public init(_ major: Int, _ minor: Int, _ micro: Int) {
      self.major = major
      self.minor = minor
      self.micro = micro
    }

    public static func < (lhs: Version, rhs: Version) -> Bool {
      (lhs.major, lhs.minor, lhs.micro) < (rhs.major, rhs.minor, rhs.micro)
    }

    public var description: String {
      "\(self.major).\(self.minor).\(self.micro)"
    }
  }

  public init(_ string: String, normalizing: Bool = false) {
    var parser = TripleParser(string, allowMore: normalizing)

    // First, see if each component parses at its expected position.
    var parsedArch = parser.match(ArchInfo.self, at: 0)
    var parsedVendor = parser.match(Vendor.self, at: 1)
    var parsedOS = parser.match(OS.self, at: 2)
    var parsedEnv = parser.match(EnvInfo.self, at: 3)

    if normalizing {
      // Next, try to fill in each unmatched field from the rejected components.
      parser.rematch(&parsedArch, at: 0)
      parser.rematch(&parsedVendor, at: 1)
      parser.rematch(&parsedOS, at: 2)
      parser.rematch(&parsedEnv, at: 3)

      let isCygwin = parser.componentsIndicateCygwin
      let isMinGW32 = parser.componentsIndicateMinGW32

      if
        let parsedEnv,
        parsedEnv.value.environment == .android,
        parsedEnv.substring.hasPrefix("androideabi")
      {
        let androidVersion = parsedEnv.substring.dropFirst("androideabi".count)

        parser.components[3] = "android\(androidVersion)"
      }

      // SUSE uses "gnueabi" to mean "gnueabihf"
      if parsedVendor?.value == .suse && parsedEnv?.value.environment == .gnueabi {
        parser.components[3] = "gnueabihf"
      }

      if parsedOS?.value == .win32 {
        parser.components.resize(toCount: 4, paddingWith: "")
        parser.components[2] = "windows"
        if parsedEnv?.value.environment == nil {
          if let objectFormat = parsedEnv?.value.objectFormat, objectFormat != .coff {
            parser.components[3] = Substring(objectFormat.name)
          } else {
            parser.components[3] = "msvc"
          }
        }
      } else if isMinGW32 {
        parser.components.resize(toCount: 4, paddingWith: "")
        parser.components[2] = "windows"
        parser.components[3] = "gnu"
      } else if isCygwin {
        parser.components.resize(toCount: 4, paddingWith: "")
        parser.components[2] = "windows"
        parser.components[3] = "cygnus"
      }

      if isMinGW32 || isCygwin || (parsedOS?.value == .win32 && parsedEnv?.value.environment != nil) {
        if let objectFormat = parsedEnv?.value.objectFormat, objectFormat != .coff {
          parser.components.resize(toCount: 5, paddingWith: "")
          parser.components[4] = Substring(objectFormat.name)
        }
      }

      // Now that we've parsed everything, we construct a normalized form of the
      // triple string.
      self.triple = parser.components.map { $0.isEmpty ? "unknown" : $0 }.joined(separator: "-")
    } else {
      self.triple = string
    }

    // Unpack the parsed data into the fields. If no environment info was found,
    // attempt to infer it from other fields.
    self.arch = parsedArch?.value.arch
    self.subArch = parsedArch?.value.subArch
    self.vendor = parsedVendor?.value
    self.os = parsedOS?.value

    if let parsedEnv {
      self.environment = parsedEnv.value.environment
      self.objectFormat = parsedEnv.value.objectFormat
        ?? ObjectFormat.infer(
          arch: parsedArch?.value.arch,
          os: parsedOS?.value
        )
    } else {
      self.environment = Environment.infer(archName: parsedArch?.substring)
      self.objectFormat = ObjectFormat.infer(
        arch: parsedArch?.value.arch,
        os: parsedOS?.value
      )
    }
  }
}

extension Triple: Codable {
  public init(from decoder: Decoder) throws {
    try self.init(decoder.singleValueContainer().decode(String.self))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(self.triple)
  }
}

// MARK: - Triple component parsing

private protocol TripleComponent {
  static func parse(_ component: Substring) -> Self?

  static func valueIsValid(_ value: Substring) -> Bool
}

extension TripleComponent {
  static func valueIsValid(_ value: Substring) -> Bool {
    parse(value) != nil
  }
}

private struct ParsedComponent<Value: TripleComponent> {
  let value: Value
  let substring: Substring

  /// Attempts to parse `component` with `parser`, placing it in `rejects` if
  /// it does not succeed.
  ///
  /// - Returns: `nil` if `type` cannot parse `component`; otherwise, an
  ///   instance containing the component and its parsed value.
  init?(_ component: Substring, as type: Value.Type) {
    guard let value = type.parse(component) else {
      return nil
    }

    self.value = value
    self.substring = component
  }
}

/// Holds the list of components in this string, as well as whether or not we
/// have matched them.
///
/// In normalizing mode, the triple is parsed in two steps:
///
/// 1. Try to match each component against the type of component expected in
///    that position. (`TripleParser.match(_:at:)`.)
/// 2. For each type of component we have not yet matched, try each component
///    we have not yet found a match for, moving the match (if found) to the
///    correct location. (`TripleParser.rematch(_:at:)`.)
///
/// In non-normalizing mode, we simply skip the second step.
private struct TripleParser {
  var components: [Substring]
  var isMatched: Set<Int> = []

  var componentsIndicateCygwin: Bool {
    self.components.count > 2 ? self.components[2].hasPrefix("cygwin") : false
  }

  var componentsIndicateMinGW32: Bool {
    self.components.count > 2 ? self.components[2].hasPrefix("mingw") : false
  }

  init(_ string: String, allowMore: Bool) {
    self.components = string.split(
      separator: "-", maxSplits: allowMore ? Int.max : 3,
      omittingEmptySubsequences: false
    )
  }

  /// Attempt to parse the component at position `i` as a `Value`, marking it as
  /// matched if successful.
  mutating func match<Value: TripleComponent>(_: Value.Type, at i: Int)
    -> ParsedComponent<Value>?
  {
    guard
      i < self.components.endIndex,
      let parsed = ParsedComponent(components[i], as: Value.self)
    else {
      return nil
    }

    precondition(!self.isMatched.contains(i))
    self.isMatched.insert(i)

    return parsed
  }

  /// If `value` has not been filled in, attempt to parse all unmatched
  /// components with it, correcting the components list if a match is found.
  mutating func rematch<Value: TripleComponent>(
    _ value: inout ParsedComponent<Value>?, at correctIndex: Int
  ) {
    guard value == nil else { return }

    precondition(
      !self.isMatched.contains(correctIndex),
      "Lost the parsed component somehow?"
    )

    for i in self.unmatchedIndices {
      guard Value.valueIsValid(self.components[i]) else {
        continue
      }

      value = ParsedComponent(self.components[i], as: Value.self)
      self.shiftComponent(at: i, to: correctIndex)
      self.isMatched.insert(correctIndex)

      return
    }
  }

  /// Returns `component.indices` with matched elements lazily filtered out.
  private var unmatchedIndices: LazyFilterSequence<Range<Int>> {
    self.components.indices.lazy.filter { [isMatched] in
      !isMatched.contains($0)
    }
  }

  /// Rearrange `components` so that the element at `actualIndex` now appears
  /// at `correctIndex`, without moving any components that have already
  /// matched.
  ///
  /// The exact transformations performed by this function are difficult to
  /// describe concisely, but they work well in practice for the ways people
  /// tend to permute triples. Essentially:
  ///
  /// * If a component appears later than it ought to, it is moved to the right
  ///   location and other unmatched components are shifted later.
  /// * If a component appears earlier than it ought to, empty components are
  ///   either found later in the list and moved before it, or created from
  ///   whole cloth and inserted before it.
  /// * If no movement is necessary, this is a no-op.
  ///
  /// - Parameter actualIndex: The index that the component is currently at.
  /// - Parameter correctIndex: The index that the component ought to be at.
  ///
  /// - Precondition: Neither `correctIndex` nor `actualIndex` are matched.
  private mutating func shiftComponent(
    at actualIndex: Int,
    to correctIndex: Int
  ) {
    // Don't mark actualIndex as matched until after you've called this method.
    precondition(
      !self.isMatched.contains(actualIndex),
      "actualIndex was already matched to something else?"
    )
    precondition(
      !self.isMatched.contains(correctIndex),
      "correctIndex already had something match it?"
    )

    if correctIndex < actualIndex {
      // Repeatedly swap `actualIndex` with its leftward neighbor, skipping
      // matched components, until it finds its way to `correctIndex`.

      // Compute all of the indices that we'll shift, not including any that
      // have matched, and then build a reversed list of adjacent pairs. (That
      // is, if the filter returns `[1,2,4]`, the resulting list will be
      // `[(4,2),(2,1)]`.)
      let swaps = self.unmatchedIndices[correctIndex...actualIndex]
        .zippedPairs().reversed()

      // Swap each pair. This has the effect of moving `actualIndex` to
      // `correctIndex` and shifting each unmatched element between them to
      // take up the space. Swapping instead of assigning ought to avoid retain
      // count traffic.
      for (earlier, later) in swaps {
        self.components.swapAt(earlier, later)
      }
    }

    // The rest of this method is concerned with shifting components rightward.
    // If we don't need to do that, we're done.
    guard correctIndex > actualIndex else { return }

    // We will essentially insert one empty component in front of `actualIndex`,
    // then recurse to shift `actualIndex + 1` if necessary. However, we want to
    // avoid shifting matched components and eat empty components, so this is
    // all a bit more complicated than just that.

    // Create a new empty component. We call it `removed` because for most
    // of this variable's lifetime, `removed` is a component that has been
    // removed from the list.
    var removed: Substring = ""

    // This loop has the effect of inserting the empty component and
    // shifting other unmatched components rightward until we either remove
    // an empty unmatched component, or remove the last element of the list.
    for i in self.unmatchedIndices[actualIndex...] {
      swap(&removed, &self.components[i])

      // If the element we removed is empty, consume it rather than reinserting
      // it later in the list.
      if removed.isEmpty { break }
    }

    // If we shifted a non-empty component off the end, add it back in.
    if !removed.isEmpty {
      self.components.append(removed)
    }

    // Find the next unmatched index after `actualIndex`; that's where we moved
    // the element at `actualIndex` to.
    let nextIndex = self.unmatchedIndices[(actualIndex + 1)..<correctIndex].first ??
      correctIndex

    // Recurse to move or create another empty component if necessary.
    self.shiftComponent(at: nextIndex, to: correctIndex)
  }
}

private extension Collection {
  func zippedPairs() -> Zip2Sequence<SubSequence, SubSequence> {
    zip(dropLast(), dropFirst())
  }
}

// MARK: - Parse Arch

extension Triple {
  fileprivate struct ArchInfo: TripleComponent {
    var arch: Triple.Arch
    var subArch: Triple.SubArch?

    fileprivate static func parse(_ component: Substring) -> ArchInfo? {
      // This code assumes that all architectures with a subarch also have an arch.
      // This is slightly different from llvm::Triple, whose
      // startswith/endswith-based logic might occasionally recognize a subarch
      // without an arch, e.g. "xxkalimba5" would have an unknown arch and a
      // kalimbav5 subarch. I'm pretty sure that's undesired behavior from LLVM.

      guard let arch = Triple.Arch.parse(component) else { return nil }
      return ArchInfo(arch: arch, subArch: Triple.SubArch.parse(component))
    }
  }

  public enum Arch: String, CaseIterable, Decodable {
    /// ARM (little endian): arm, armv.*, xscale
    case arm
    // ARM (big endian): armeb
    case armeb
    /// AArch64 (little endian): aarch64
    case aarch64
    /// AArch64e (little endian): aarch64e
    case aarch64e
    /// AArch64 (big endian): aarch64_be
    case aarch64_be
    // AArch64 (little endian) ILP32: aarch64_32
    case aarch64_32
    /// ARC: Synopsys ARC
    case arc
    /// AVR: Atmel AVR microcontroller
    case avr
    /// eBPF or extended BPF or 64-bit BPF (little endian)
    case bpfel
    /// eBPF or extended BPF or 64-bit BPF (big endian)
    case bpfeb
    /// Hexagon: hexagon
    case hexagon
    // M68k: Motorola 680x0 family
    case m68k
    /// MIPS: mips, mipsallegrex, mipsr6
    case mips
    /// MIPSEL: mipsel, mipsallegrexe, mipsr6el
    case mipsel
    // MIPS64: mips64, mips64r6, mipsn32, mipsn32r6
    case mips64
    // MIPS64EL: mips64el, mips64r6el, mipsn32el, mipsn32r6el
    case mips64el
    // MSP430: msp430
    case msp430
    // PPC: powerpc
    case ppc
    // PPC64: powerpc64, ppu
    case ppc64
    // PPC64LE: powerpc64le
    case ppc64le
    // R600: AMD GPUs HD2XXX - HD6XXX
    case r600
    // AMDGCN: AMD GCN GPUs
    case amdgcn
    // RISC-V (32-bit): riscv32
    case riscv32
    // RISC-V (64-bit): riscv64
    case riscv64
    // Sparc: sparc
    case sparc
    // Sparcv9: Sparcv9
    case sparcv9
    // Sparc: (endianness = little). NB: 'Sparcle' is a CPU variant
    case sparcel
    // SystemZ: s390x
    case systemz
    // TCE (http://tce.cs.tut.fi/): tce
    case tce
    // TCE little endian (http://tce.cs.tut.fi/): tcele
    case tcele
    // Thumb (little endian): thumb, thumbv.*
    case thumb
    // Thumb (big endian): thumbeb
    case thumbeb
    // X86: i[3-9]86
    case x86 = "i386"
    // X86-64: amd64, x86_64
    case x86_64
    // XCore: xcore
    case xcore
    // NVPTX: 32-bit
    case nvptx
    // NVPTX: 64-bit
    case nvptx64
    // le32: generic little-endian 32-bit CPU (PNaCl)
    case le32
    // le64: generic little-endian 64-bit CPU (PNaCl)
    case le64
    // AMDIL
    case amdil
    // AMDIL with 64-bit pointers
    case amdil64
    // AMD HSAIL
    case hsail
    // AMD HSAIL with 64-bit pointers
    case hsail64
    // SPIR: standard portable IR for OpenCL 32-bit version
    case spir
    // SPIR: standard portable IR for OpenCL 64-bit version
    case spir64
    // Kalimba: generic kalimba
    case kalimba
    // SHAVE: Movidius vector VLIW processors
    case shave
    // Lanai: Lanai 32-bit
    case lanai
    // WebAssembly with 32-bit pointers
    case wasm32
    // WebAssembly with 64-bit pointers
    case wasm64
    // 32-bit RenderScript
    case renderscript32
    // 64-bit RenderScript
    case renderscript64

    static func parse(_ archName: Substring) -> Triple.Arch? {
      switch archName {
      case "i386", "i486", "i586", "i686":
        .x86
      case "i786", "i886", "i986":
        .x86
      case "amd64", "x86_64", "x86_64h":
        .x86_64
      case "powerpc", "ppc", "ppc32":
        .ppc
      case "powerpc64", "ppu", "ppc64":
        .ppc64
      case "powerpc64le", "ppc64le":
        .ppc64le
      case "xscale":
        .arm
      case "xscaleeb":
        .armeb
      case "aarch64":
        .aarch64
      case "aarch64_be":
        .aarch64_be
      case "aarch64_32":
        .aarch64_32
      case "arc":
        .arc
      case "arm64":
        .aarch64
      case "arm64e":
        .aarch64e
      case "arm64_32":
        .aarch64_32
      case "arm":
        .arm
      case "armeb":
        .armeb
      case "thumb":
        .thumb
      case "thumbeb":
        .thumbeb
      case "avr":
        .avr
      case "m68k":
        .m68k
      case "msp430":
        .msp430
      case "mips", "mipseb", "mipsallegrex", "mipsisa32r6", "mipsr6":
        .mips
      case "mipsel", "mipsallegrexel", "mipsisa32r6el", "mipsr6el":
        .mipsel
      case "mips64", "mips64eb", "mipsn32", "mipsisa64r6", "mips64r6", "mipsn32r6":
        .mips64
      case "mips64el", "mipsn32el", "mipsisa64r6el", "mips64r6el", "mipsn32r6el":
        .mips64el
      case "r600":
        .r600
      case "amdgcn":
        .amdgcn
      case "riscv32":
        .riscv32
      case "riscv64":
        .riscv64
      case "hexagon":
        .hexagon
      case "s390x", "systemz":
        .systemz
      case "sparc":
        .sparc
      case "sparcel":
        .sparcel
      case "sparcv9", "sparc64":
        .sparcv9
      case "tce":
        .tce
      case "tcele":
        .tcele
      case "xcore":
        .xcore
      case "nvptx":
        .nvptx
      case "nvptx64":
        .nvptx64
      case "le32":
        .le32
      case "le64":
        .le64
      case "amdil":
        .amdil
      case "amdil64":
        .amdil64
      case "hsail":
        .hsail
      case "hsail64":
        .hsail64
      case "spir":
        .spir
      case "spir64":
        .spir64
      case _ where archName.hasPrefix("kalimba"):
        .kalimba
      case "lanai":
        .lanai
      case "shave":
        .shave
      case "wasm32":
        .wasm32
      case "wasm64":
        .wasm64
      case "renderscript32":
        .renderscript32
      case "renderscript64":
        .renderscript64
      case _ where archName.hasPrefix("arm") || archName.hasPrefix("thumb") || archName.hasPrefix("aarch64"):
        self.parseARMArch(archName)
      case _ where archName.hasPrefix("bpf"):
        self.parseBPFArch(archName)
      default:
        nil
      }
    }

    enum Endianness {
      case big, little

      // Based on LLVM's ARM::parseArchEndian
      init?(armArchName archName: some StringProtocol) {
        if archName.starts(with: "armeb") || archName.starts(with: "thumbeb") || archName.starts(with: "aarch64_be") {
          self = .big
        } else if archName.starts(with: "arm") || archName.starts(with: "thumb") {
          self = archName.hasSuffix("eb") ? .big : .little
        } else if archName.starts(with: "aarch64") || archName.starts(with: "aarch64_32") {
          self = .little
        } else {
          return nil
        }
      }
    }

    enum ARMISA {
      case aarch64, thumb, arm

      // Based on LLVM's ARM::parseArchISA
      init?(archName: some StringProtocol) {
        if archName.starts(with: "aarch64") || archName.starts(with: "arm64") {
          self = .aarch64
        } else if archName.starts(with: "thumb") {
          self = .thumb
        } else if archName.starts(with: "arm") {
          self = .arm
        } else {
          return nil
        }
      }
    }

    // Parse ARM architectures not handled by `parse`. On its own, this is not
    // enough to correctly parse an ARM architecture.
    private static func parseARMArch(_ archName: some StringProtocol) -> Triple.Arch? {
      let ISA = ARMISA(archName: archName)
      let endianness = Endianness(armArchName: archName)

      let arch: Triple.Arch? = switch (endianness, ISA) {
      case (.little, .arm):
        .arm
      case (.little, .thumb):
        .thumb
      case (.little, .aarch64):
        .aarch64
      case (.big, .arm):
        .armeb
      case (.big, .thumb):
        .thumbeb
      case (.big, .aarch64):
        .aarch64_be
      case (nil, _), (_, nil):
        nil
      }

      let canonicalArchName = self.canonicalARMArchName(from: archName)

      if canonicalArchName.isEmpty {
        return nil
      }

      // Thumb only exists in v4+
      if ISA == .thumb && (canonicalArchName.hasPrefix("v2") || canonicalArchName.hasPrefix("v3")) {
        return nil
      }

      // Thumb only for v6m
      if case let .arm(subArch) = Triple.SubArch.parse(archName), subArch.profile == .m && subArch.version == 6 {
        if endianness == .big {
          return .thumbeb
        } else {
          return .thumb
        }
      }

      return arch
    }

    // Based on LLVM's ARM::getCanonicalArchName
    //
    // MArch is expected to be of the form (arm|thumb)?(eb)?(v.+)?(eb)?, but
    // (iwmmxt|xscale)(eb)? is also permitted. If the former, return
    // "v.+", if the latter, return unmodified string, minus 'eb'.
    // If invalid, return empty string.
    fileprivate static func canonicalARMArchName(from arch: some StringProtocol) -> String {
      var name = Substring(arch)

      func dropPrefix(_ prefix: String) {
        if name.hasPrefix(prefix) {
          name = name.dropFirst(prefix.count)
        }
      }

      let possiblePrefixes = ["arm64_32", "arm64", "aarch64_32", "arm", "thumb", "aarch64"]

      if let prefix = possiblePrefixes.first(where: name.hasPrefix) {
        dropPrefix(prefix)

        if prefix == "aarch64" {
          // AArch64 uses "_be", not "eb" suffix.
          if name.contains("eb") {
            return ""
          }

          dropPrefix("_be")
        }
      }

      // Ex. "armebv7", move past the "eb".
      if name != arch {
        dropPrefix("eb")
      }
      // Or, if it ends with eb ("armv7eb"), chop it off.
      else if name.hasSuffix("eb") {
        name = name.dropLast(2)
      }

      // Reached the end - arch is valid.
      if name.isEmpty {
        return String(arch)
      }

      // Only match non-marketing names
      if name != arch {
        // Must start with 'vN'.
        if name.count >= 2 && (name.first != "v" || !name.dropFirst().first!.isNumber) {
          return ""
        }

        // Can't have an extra 'eb'.
        if name.hasPrefix("eb") {
          return ""
        }
      }

      // Arch will either be a 'v' name (v7a) or a marketing name (xscale).
      return String(name)
    }

    private static func parseBPFArch(_ archName: some StringProtocol) -> Triple.Arch? {
      let isLittleEndianHost = 1.littleEndian == 1

      switch archName {
      case "bpf":
        return isLittleEndianHost ? .bpfel : .bpfeb
      case "bpf_be", "bpfeb":
        return .bpfeb
      case "bpf_le", "bpfel":
        return .bpfel
      default:
        return nil
      }
    }

    /// Whether or not this architecture has 64-bit pointers
    public var is64Bit: Bool { self.pointerBitWidth == 64 }

    /// Whether or not this architecture has 32-bit pointers
    public var is32Bit: Bool { self.pointerBitWidth == 32 }

    /// Whether or not this architecture has 16-bit pointers
    public var is16Bit: Bool { self.pointerBitWidth == 16 }

    /// The width in bits of pointers on this architecture.
    var pointerBitWidth: Int {
      switch self {
      case .avr, .msp430:
        16

      case .arc, .arm, .armeb, .hexagon, .le32, .mips, .mipsel, .nvptx,
           .ppc, .r600, .riscv32, .sparc, .sparcel, .tce, .tcele, .thumb,
           .thumbeb, .x86, .xcore, .amdil, .hsail, .spir, .kalimba, .lanai,
           .shave, .wasm32, .renderscript32, .aarch64_32, .m68k:
        32

      case .aarch64, .aarch64e, .aarch64_be, .amdgcn, .bpfel, .bpfeb, .le64, .mips64,
           .mips64el, .nvptx64, .ppc64, .ppc64le, .riscv64, .sparcv9, .systemz,
           .x86_64, .amdil64, .hsail64, .spir64, .wasm64, .renderscript64:
        64
      }
    }
  }
}

// MARK: - Parse SubArch

public extension Triple {
  enum SubArch: Hashable {
    public enum ARM {
      public enum Profile {
        case a, r, m
      }

      case v2
      case v2a
      case v3
      case v3m
      case v4
      case v4t
      case v5
      case v5e
      case v6
      case v6k
      case v6kz
      case v6m
      case v6t2
      case v7
      case v7em
      case v7k
      case v7m
      case v7r
      case v7s
      case v7ve
      case v8
      case v8_1a
      case v8_1m_mainline
      case v8_2a
      case v8_3a
      case v8_4a
      case v8_5a
      case v8m_baseline
      case v8m_mainline
      case v8r

      var profile: Triple.SubArch.ARM.Profile? {
        switch self {
        case .v6m, .v7m, .v7em, .v8m_mainline, .v8m_baseline, .v8_1m_mainline:
          .m
        case .v7r, .v8r:
          .r
        case .v7, .v7ve, .v7k, .v8, .v8_1a, .v8_2a, .v8_3a, .v8_4a, .v8_5a:
          .a
        case .v2, .v2a, .v3, .v3m, .v4, .v4t, .v5, .v5e, .v6, .v6k, .v6kz, .v6t2, .v7s:
          nil
        }
      }

      var version: Int {
        switch self {
        case .v2, .v2a:
          2
        case .v3, .v3m:
          3
        case .v4, .v4t:
          4
        case .v5, .v5e:
          5
        case .v6, .v6k, .v6kz, .v6m, .v6t2:
          6
        case .v7, .v7em, .v7k, .v7m, .v7r, .v7s, .v7ve:
          7
        case .v8, .v8_1a, .v8_1m_mainline, .v8_2a, .v8_3a, .v8_4a, .v8_5a, .v8m_baseline, .v8m_mainline, .v8r:
          8
        }
      }
    }

    public enum Kalimba {
      case v3
      case v4
      case v5
    }

    public enum MIPS {
      case r6
    }

    case arm(ARM)
    case kalimba(Kalimba)
    case mips(MIPS)

    fileprivate static func parse(_ component: some StringProtocol) -> Triple.SubArch? {
      if component.hasPrefix("mips") && (component.hasSuffix("r6el") || component.hasSuffix("r6")) {
        return .mips(.r6)
      }

      let armSubArch = Triple.Arch.canonicalARMArchName(from: component)

      if armSubArch.isEmpty {
        switch component {
        case _ where component.hasSuffix("kalimba3"):
          return .kalimba(.v3)
        case _ where component.hasSuffix("kalimba4"):
          return .kalimba(.v4)
        case _ where component.hasSuffix("kalimba5"):
          return .kalimba(.v5)
        default:
          return nil
        }
      }

      switch armSubArch {
      case "v2":
        return .arm(.v2)
      case "v2a":
        return .arm(.v2a)
      case "v3":
        return .arm(.v3)
      case "v3m":
        return .arm(.v3m)
      case "v4":
        return .arm(.v4)
      case "v4t":
        return .arm(.v4t)
      case "v5t":
        return .arm(.v5)
      case "v5te", "v5tej", "xscale":
        return .arm(.v5e)
      case "v6":
        return .arm(.v6)
      case "v6k":
        return .arm(.v6k)
      case "v6kz":
        return .arm(.v6kz)
      case "v6m", "v6-m":
        return .arm(.v6m)
      case "v6t2":
        return .arm(.v6t2)
      case "v7a", "v7-a":
        return .arm(.v7)
      case "v7k":
        return .arm(.v7k)
      case "v7m", "v7-m":
        return .arm(.v7m)
      case "v7em", "v7e-m":
        return .arm(.v7em)
      case "v7r", "v7-r":
        return .arm(.v7r)
      case "v7s":
        return .arm(.v7s)
      case "v7ve":
        return .arm(.v7ve)
      case "v8-a":
        return .arm(.v8)
      case "v8-m.main":
        return .arm(.v8m_mainline)
      case "v8-m.base":
        return .arm(.v8m_baseline)
      case "v8-r":
        return .arm(.v8r)
      case "v8.1-m.main":
        return .arm(.v8_1m_mainline)
      case "v8.1-a":
        return .arm(.v8_1a)
      case "v8.2-a":
        return .arm(.v8_2a)
      case "v8.3-a":
        return .arm(.v8_3a)
      case "v8.4-a":
        return .arm(.v8_4a)
      case "v8.5-a":
        return .arm(.v8_5a)
      default:
        return nil
      }
    }
  }
}

// MARK: - Parse Vendor

public extension Triple {
  enum Vendor: String, CaseIterable, TripleComponent {
    case apple
    case pc
    case scei
    case bgp
    case bgq
    case freescale = "fsl"
    case ibm
    case imaginationTechnologies = "img"
    case mipsTechnologies = "mti"
    case nvidia
    case csr
    case myriad
    case amd
    case mesa
    case suse
    case openEmbedded = "oe"

    fileprivate static func parse(_ component: Substring) -> Triple.Vendor? {
      switch component {
      case "apple":
        .apple
      case "pc":
        .pc
      case "scei":
        .scei
      case "bgp":
        .bgp
      case "bgq":
        .bgq
      case "fsl":
        .freescale
      case "ibm":
        .ibm
      case "img":
        .imaginationTechnologies
      case "mti":
        .mipsTechnologies
      case "nvidia":
        .nvidia
      case "csr":
        .csr
      case "myriad":
        .myriad
      case "amd":
        .amd
      case "mesa":
        .mesa
      case "suse":
        .suse
      case "oe":
        .openEmbedded
      default:
        nil
      }
    }
  }
}

// MARK: - Parse OS

public extension Triple {
  enum OS: String, CaseIterable, TripleComponent {
    case ananas
    case cloudABI = "cloudabi"
    case darwin
    case dragonFly = "dragonfly"
    case freeBSD = "freebsd"
    case fuchsia
    case ios
    case kfreebsd
    case linux
    case lv2
    case macosx
    case netbsd
    case openbsd
    case solaris
    case win32
    case haiku
    case minix
    case rtems
    case nacl
    case cnk
    case aix
    case cuda
    case nvcl
    case amdhsa
    case ps4
    case elfiamcu
    case tvos
    case watchos
    case mesa3d
    case contiki
    case amdpal
    case hermitcore
    case hurd
    case wasi
    case emscripten
    case noneOS // 'OS' suffix purely to avoid name clash with Optional.none

    var name: String {
      rawValue
    }

    fileprivate static func parse(_ os: Substring) -> Triple.OS? {
      switch os {
      case _ where os.hasPrefix("ananas"):
        .ananas
      case _ where os.hasPrefix("cloudabi"):
        .cloudABI
      case _ where os.hasPrefix("darwin"):
        .darwin
      case _ where os.hasPrefix("dragonfly"):
        .dragonFly
      case _ where os.hasPrefix("freebsd"):
        .freeBSD
      case _ where os.hasPrefix("fuchsia"):
        .fuchsia
      case _ where os.hasPrefix("ios"):
        .ios
      case _ where os.hasPrefix("kfreebsd"):
        .kfreebsd
      case _ where os.hasPrefix("linux"):
        .linux
      case _ where os.hasPrefix("lv2"):
        .lv2
      case _ where os.hasPrefix("macos"):
        .macosx
      case _ where os.hasPrefix("netbsd"):
        .netbsd
      case _ where os.hasPrefix("openbsd"):
        .openbsd
      case _ where os.hasPrefix("solaris"):
        .solaris
      case _ where os.hasPrefix("win32"):
        .win32
      case _ where os.hasPrefix("windows"):
        .win32
      case _ where os.hasPrefix("haiku"):
        .haiku
      case _ where os.hasPrefix("minix"):
        .minix
      case _ where os.hasPrefix("rtems"):
        .rtems
      case _ where os.hasPrefix("nacl"):
        .nacl
      case _ where os.hasPrefix("cnk"):
        .cnk
      case _ where os.hasPrefix("aix"):
        .aix
      case _ where os.hasPrefix("cuda"):
        .cuda
      case _ where os.hasPrefix("nvcl"):
        .nvcl
      case _ where os.hasPrefix("amdhsa"):
        .amdhsa
      case _ where os.hasPrefix("ps4"):
        .ps4
      case _ where os.hasPrefix("elfiamcu"):
        .elfiamcu
      case _ where os.hasPrefix("tvos"):
        .tvos
      case _ where os.hasPrefix("watchos"):
        .watchos
      case _ where os.hasPrefix("mesa3d"):
        .mesa3d
      case _ where os.hasPrefix("contiki"):
        .contiki
      case _ where os.hasPrefix("amdpal"):
        .amdpal
      case _ where os.hasPrefix("hermit"):
        .hermitcore
      case _ where os.hasPrefix("hurd"):
        .hurd
      case _ where os.hasPrefix("wasi"):
        .wasi
      case _ where os.hasPrefix("emscripten"):
        .emscripten
      case _ where os.hasPrefix("none"):
        .noneOS
      default:
        nil
      }
    }

    fileprivate static func valueIsValid(_ value: Substring) -> Bool {
      self.parse(value) != nil || value.hasPrefix("cygwin") || value.hasPrefix("mingw")
    }
  }
}

// MARK: - Parse Environment

extension Triple {
  fileprivate enum EnvInfo: TripleComponent {
    case environmentOnly(Triple.Environment)
    case objectFormatOnly(Triple.ObjectFormat)
    case both(
      environment: Triple.Environment,
      objectFormat: Triple.ObjectFormat
    )

    var environment: Triple.Environment? {
      switch self {
      case let .environmentOnly(env), let .both(env, _):
        env
      case .objectFormatOnly:
        nil
      }
    }

    var objectFormat: Triple.ObjectFormat? {
      switch self {
      case let .objectFormatOnly(obj), let .both(_, obj):
        obj
      case .environmentOnly:
        nil
      }
    }

    fileprivate static func parse(_ component: Substring) -> EnvInfo? {
      switch (
        Triple.Environment.parse(component),
        Triple.ObjectFormat.parse(component)
      ) {
      case (nil, nil):
        nil
      case (nil, let obj?):
        .objectFormatOnly(obj)
      case (let env?, nil):
        .environmentOnly(env)
      case let (env?, obj?):
        .both(environment: env, objectFormat: obj)
      }
    }
  }

  public enum Environment: String, CaseIterable, Equatable {
    case eabihf
    case eabi
    case elfv1
    case elfv2
    case gnuabin32
    case gnuabi64
    case gnueabihf
    case gnueabi
    case gnux32
    case code16
    case gnu
    case android
    case musleabihf
    case musleabi
    case musl
    case msvc
    case itanium
    case cygnus
    case coreclr
    case simulator
    case macabi

    fileprivate static func parse(_ env: Substring) -> Triple.Environment? {
      switch env {
      case _ where env.hasPrefix("eabihf"):
        .eabihf
      case _ where env.hasPrefix("eabi"):
        .eabi
      case _ where env.hasPrefix("elfv1"):
        .elfv1
      case _ where env.hasPrefix("elfv2"):
        .elfv2
      case _ where env.hasPrefix("gnuabin32"):
        .gnuabin32
      case _ where env.hasPrefix("gnuabi64"):
        .gnuabi64
      case _ where env.hasPrefix("gnueabihf"):
        .gnueabihf
      case _ where env.hasPrefix("gnueabi"):
        .gnueabi
      case _ where env.hasPrefix("gnux32"):
        .gnux32
      case _ where env.hasPrefix("code16"):
        .code16
      case _ where env.hasPrefix("gnu"):
        .gnu
      case _ where env.hasPrefix("android"):
        .android
      case _ where env.hasPrefix("musleabihf"):
        .musleabihf
      case _ where env.hasPrefix("musleabi"):
        .musleabi
      case _ where env.hasPrefix("musl"):
        .musl
      case _ where env.hasPrefix("msvc"):
        .msvc
      case _ where env.hasPrefix("itanium"):
        .itanium
      case _ where env.hasPrefix("cygnus"):
        .cygnus
      case _ where env.hasPrefix("coreclr"):
        .coreclr
      case _ where env.hasPrefix("simulator"):
        .simulator
      case _ where env.hasPrefix("macabi"):
        .macabi
      default:
        nil
      }
    }

    fileprivate static func infer(archName: Substring?) -> Triple.Environment? {
      guard let firstComponent = archName else { return nil }

      switch firstComponent {
      case _ where firstComponent.hasPrefix("mipsn32"):
        return .gnuabin32
      case _ where firstComponent.hasPrefix("mips64"):
        return .gnuabi64
      case _ where firstComponent.hasPrefix("mipsisa64"):
        return .gnuabi64
      case _ where firstComponent.hasPrefix("mipsisa32"):
        return .gnu
      case "mips", "mipsel", "mipsr6", "mipsr6el":
        return .gnu
      default:
        return nil
      }
    }
  }
}

// MARK: - Parse Object Format

public extension Triple {
  enum ObjectFormat {
    case coff
    case elf
    case macho
    case wasm
    case xcoff

    fileprivate static func parse(_ env: Substring) -> Triple.ObjectFormat? {
      switch env {
      // "xcoff" must come before "coff" because of the order-dependendent pattern matching.
      case _ where env.hasSuffix("xcoff"):
        .xcoff
      case _ where env.hasSuffix("coff"):
        .coff
      case _ where env.hasSuffix("elf"):
        .elf
      case _ where env.hasSuffix("macho"):
        .macho
      case _ where env.hasSuffix("wasm"):
        .wasm
      default:
        nil
      }
    }

    fileprivate static func infer(arch: Triple.Arch?, os: Triple.OS?) -> Triple.ObjectFormat {
      switch arch {
      case nil, .aarch64, .aarch64e, .aarch64_32, .arm, .thumb, .x86, .x86_64:
        if os?.isDarwin ?? false {
          return .macho
        } else if os?.isWindows ?? false {
          return .coff
        }
        return .elf
      case .aarch64_be: fallthrough
      case .arc: fallthrough
      case .amdgcn: fallthrough
      case .amdil: fallthrough
      case .amdil64: fallthrough
      case .armeb: fallthrough
      case .avr: fallthrough
      case .bpfeb: fallthrough
      case .bpfel: fallthrough
      case .hexagon: fallthrough
      case .lanai: fallthrough
      case .hsail: fallthrough
      case .hsail64: fallthrough
      case .kalimba: fallthrough
      case .le32: fallthrough
      case .le64: fallthrough
      case .m68k: fallthrough
      case .mips: fallthrough
      case .mips64: fallthrough
      case .mips64el: fallthrough
      case .mipsel: fallthrough
      case .msp430: fallthrough
      case .nvptx: fallthrough
      case .nvptx64: fallthrough
      case .ppc64le: fallthrough
      case .r600: fallthrough
      case .renderscript32: fallthrough
      case .renderscript64: fallthrough
      case .riscv32: fallthrough
      case .riscv64: fallthrough
      case .shave: fallthrough
      case .sparc: fallthrough
      case .sparcel: fallthrough
      case .sparcv9: fallthrough
      case .spir: fallthrough
      case .spir64: fallthrough
      case .systemz: fallthrough
      case .tce: fallthrough
      case .tcele: fallthrough
      case .thumbeb: fallthrough
      case .xcore:
        return .elf
      case .ppc, .ppc64:
        if os?.isDarwin ?? false {
          return .macho
        } else if os == .aix {
          return .xcoff
        }
        return .elf
      case .wasm32, .wasm64:
        return .wasm
      }
    }

    var name: String {
      switch self {
      case .coff: "coff"
      case .elf: "elf"
      case .macho: "macho"
      case .wasm: "wasm"
      case .xcoff: "xcoff"
      }
    }
  }
}

// MARK: - OS tests

public extension Triple.OS {
  var isWindows: Bool {
    self == .win32
  }

  var isAIX: Bool {
    self == .aix
  }

  /// isMacOSX - Is this a Mac OS X triple. For legacy reasons, we support both
  /// "darwin" and "osx" as OS X triples.
  var isMacOSX: Bool {
    self == .darwin || self == .macosx
  }

  /// Is this an iOS triple.
  /// Note: This identifies tvOS as a variant of iOS. If that ever
  /// changes, i.e., if the two operating systems diverge or their version
  /// numbers get out of sync, that will need to be changed.
  /// watchOS has completely different version numbers so it is not included.
  var isiOS: Bool {
    self == .ios || self.isTvOS
  }

  /// Is this an Apple tvOS triple.
  var isTvOS: Bool {
    self == .tvos
  }

  /// Is this an Apple watchOS triple.
  var isWatchOS: Bool {
    self == .watchos
  }

  /// isOSDarwin - Is this a "Darwin" OS (OS X, iOS, or watchOS).
  var isDarwin: Bool {
    self.isMacOSX || self.isiOS || self.isWatchOS
  }
}

// MARK: - Versions

public extension Triple {
  fileprivate func component(at i: Int) -> String {
    let components = self.triple.split(
      separator: "-",
      maxSplits: 3,
      omittingEmptySubsequences: false
    )
    guard i < components.endIndex else { return "" }
    return String(components[i])
  }

  var archName: String { self.component(at: 0) }
  var vendorName: String { self.component(at: 1) }

  /// Returns the name of the OS from the triple string.
  var osName: String { self.component(at: 2) }

  var environmentName: String { self.component(at: 3) }

  /// Parse the version number from the OS name component of the triple, if present.
  ///
  /// For example, "fooos1.2.3" would return (1, 2, 3). If an entry is not defined, it will
  /// be returned as 0.
  ///
  /// This does not do any normalization of the version; for instance, a
  /// `darwin` OS version number is not adjusted to match the equivalent
  /// `macosx` version number. It's usually better to use `version(for:)`
  /// to get Darwin versions.
  var osVersion: Version {
    var osName = self.osName[...]

    // Assume that the OS portion of the triple starts with the canonical name.
    if let os {
      if osName.hasPrefix(os.name) {
        osName = osName.dropFirst(os.name.count)
      } else if os == .macosx, osName.hasPrefix("macos") {
        osName = osName.dropFirst(5)
      }
    }

    return Version(parse: osName)
  }

  var osNameUnversioned: String {
    var canonicalOsName = self.osName[...]

    // Assume that the OS portion of the triple starts with the canonical name.
    if let os {
      if canonicalOsName.hasPrefix(os.name) {
        canonicalOsName = self.osName.prefix(os.name.count)
      } else if os == .macosx, self.osName.hasPrefix("macos") {
        canonicalOsName = self.osName.prefix(5)
      }
    }
    return String(canonicalOsName)
  }
}

// MARK: - Darwin Versions

public extension Triple {
  /// Parse the version number as with getOSVersion and then
  /// translate generic "darwin" versions to the corresponding OS X versions.
  /// This may also be called with IOS triples but the OS X version number is
  /// just set to a constant 10.4.0 in that case.
  ///
  /// Returns true if successful.
  ///
  /// This accessor is semi-private; it's typically better to use `version(for:)` or
  /// `Triple.FeatureAvailability`.
  var _macOSVersion: Version? {
    var version = self.osVersion

    switch self.os {
    case .darwin:
      // Default to darwin8, i.e., MacOSX 10.4.
      if version.major == 0 {
        version.major = 8
      }

      // Darwin version numbers are skewed from OS X versions.
      if version.major < 4 {
        return nil
      }

      if version.major <= 19 {
        version.micro = 0
        version.minor = version.major - 4
        version.major = 10
      } else {
        version.micro = 0
        version.minor = 0
        // darwin20+ corresponds to macOS 11+.
        version.major = version.major - 9
      }

    case .macosx:
      // Default to 10.4.
      if version.major == 0 {
        version.major = 10
        version.minor = 4
      }

      if version.major < 10 {
        return nil
      }

    case .ios, .tvos, .watchos:
      // Ignore the version from the triple.  This is only handled because the
      // the clang driver combines OS X and IOS support into a common Darwin
      // toolchain that wants to know the OS X version number even when targeting
      // IOS.
      version = Version(10, 4, 0)

    default:
      fatalError("unexpected OS for Darwin triple")
    }
    return version
  }

  /// Parse the version number as with getOSVersion.  This should
  /// only be called with IOS or generic triples.
  ///
  /// This accessor is semi-private; it's typically better to use `version(for:)` or
  /// `Triple.FeatureAvailability`.
  var _iOSVersion: Version {
    switch self.os {
    case .darwin, .macosx:
      // Ignore the version from the triple.  This is only handled because the
      // the clang driver combines OS X and iOS support into a common Darwin
      // toolchain that wants to know the iOS version number even when targeting
      // OS X.
      return Version(5, 0, 0)
    case .ios, .tvos:
      var version = self.osVersion
      // Default to 5.0 (or 7.0 for arm64).
      if version.major == 0 {
        version.major = self.arch == .aarch64 ? 7 : 5
      }
      return version
    case .watchos:
      fatalError("conflicting triple info")
    default:
      fatalError("unexpected OS for Darwin triple")
    }
  }

  /// Parse the version number as with getOSVersion. This should only be
  /// called with WatchOS or generic triples.
  ///
  /// This accessor is semi-private; it's typically better to use `version(for:)` or
  /// `Triple.FeatureAvailability`.
  var _watchOSVersion: Version {
    switch self.os {
    case .darwin, .macosx:
      // Ignore the version from the triple.  This is only handled because the
      // the clang driver combines OS X and iOS support into a common Darwin
      // toolchain that wants to know the iOS version number even when targeting
      // OS X.
      return Version(2, 0, 0)
    case .watchos:
      var version = self.osVersion
      if version.major == 0 {
        version.major = 2
      }
      return version
    case .ios:
      fatalError("conflicting triple info")
    default:
      fatalError("unexpected OS for Darwin triple")
    }
  }
}

// MARK: - Catalyst

extension Triple {
  @_spi(Testing)
  public var isMacCatalyst: Bool {
    self.isiOS && !self.isTvOS && self.environment == .macabi
  }

  func isValidForZipperingWithTriple(_ variant: Triple) -> Bool {
    guard self.archName == variant.archName,
          self.arch == variant.arch,
          self.subArch == variant.subArch,
          self.vendor == variant.vendor
    else {
      return false
    }

    // Allow a macOS target and an iOS-macabi target variant
    // This is typically the case when zippering a library originally
    // developed for macOS.
    if self.isMacOSX && variant.isMacCatalyst {
      return true
    }

    // Allow an iOS-macabi target and a macOS target variant. This would
    // be the case when zippering a library originally developed for
    // iOS.
    if variant.isMacOSX && self.isMacCatalyst {
      return true
    }

    return false
  }
}

private extension Array {
  mutating func resize(toCount desiredCount: Int, paddingWith element: Element) {
    if desiredCount > count {
      append(contentsOf: repeatElement(element, count: desiredCount - count))
    } else if desiredCount < count {
      removeLast(count - desiredCount)
    }
  }
}

// MARK: - Linker support

extension Triple {
  /// Returns `true` if a given triple supports producing fully statically linked executables by providing `-static`
  /// flag to the linker. This implies statically linking platform's libc, and of those that Swift supports currently
  /// only Musl allows that reliably.
  var supportsStaticExecutables: Bool {
    self.environment == .musl
  }
}
