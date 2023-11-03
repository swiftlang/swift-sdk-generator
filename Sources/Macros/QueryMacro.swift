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

public enum QueryMacro: ExtensionMacro {
  /// Unique identifier for messages related to this macro.
  private static let messageID = MessageID(domain: "Macros", id: "QueryMacro")

  public static func expansion(
    of node: AttributeSyntax,
    attachedTo declaration: some DeclGroupSyntax,
    providingExtensionsOf type: some TypeSyntaxProtocol,
    conformingTo protocols: [TypeSyntax],
    in context: some MacroExpansionContext
  ) throws -> [ExtensionDeclSyntax] {
    let inheritanceClause = InheritanceClauseSyntax(inheritedTypesBuilder: {
      InheritedTypeSyntax(type: IdentifierTypeSyntax(name: "QueryProtocol"))
    })

    let queryExtension = ExtensionDeclSyntax(extendedType: type, inheritanceClause: inheritanceClause) {}

    return try [queryExtension] + CacheKeyMacro.expansion(
      of: node,
      attachedTo: declaration,
      providingExtensionsOf: type,
      conformingTo: protocols,
      in: context
    )
  }
}
