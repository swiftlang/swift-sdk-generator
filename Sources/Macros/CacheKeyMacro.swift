//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

public enum CacheKeyMacro: ExtensionMacro {
  /// Unique identifier for messages related to this macro.
  private static let messageID = MessageID(domain: "Macros", id: "CacheKeyMacro")

  public static func expansion(
    of node: AttributeSyntax,
    attachedTo declaration: some DeclGroupSyntax,
    providingExtensionsOf type: some TypeSyntaxProtocol,
    conformingTo protocols: [TypeSyntax],
    in context: some MacroExpansionContext
  ) throws -> [ExtensionDeclSyntax] {
    guard let structDecl = declaration.as(StructDeclSyntax.self) else {
      throw SimpleDiagnosticMessage(
        message: "Macro `CacheKey` can only be applied to a struct",
        diagnosticID: self.messageID,
        severity: .error
      )
    }

    let expressions = structDecl.memberBlock.members.map(\.decl).compactMap { declaration -> CodeBlockItemSyntax? in
      guard let storedPropertyIdentifier = declaration.as(
        VariableDeclSyntax.self
      )?.bindings.first?.pattern.as(IdentifierPatternSyntax.self) else {
        return nil
      }

      return "\(storedPropertyIdentifier.identifier).hash(with: &hashFunction)"
    }

    let inheritanceClause = InheritanceClauseSyntax(inheritedTypesBuilder: {
      InheritedTypeSyntax(type: IdentifierTypeSyntax(name: "CacheKeyProtocol"))
    })

    let cacheKeyExtension = try ExtensionDeclSyntax(extendedType: type, inheritanceClause: inheritanceClause) {
      try FunctionDeclSyntax("func hash(with hashFunction: inout some HashFunction)") {
        "String(reflecting: Self.self).hash(with: &hashFunction)"
        for expression in expressions {
          expression
        }
      }
    }

    return [cacheKeyExtension]
  }
}
