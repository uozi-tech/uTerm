// uTermTests/Editor/TreeSitterHelloWorldTests.swift
import XCTest
import SwiftTreeSitter
import TreeSitterGo
@testable import uTerm

/// C.Verify hello-world test: confirms SwiftTreeSitter + TreeSitterGo SPM packages
/// link correctly and can parse a trivial Go snippet.
final class TreeSitterHelloWorldTests: XCTestCase {

    func test_goGrammar_parsesSimpleDeclaration() {
        let lang = Language(language: tree_sitter_go())
        let parser = Parser()
        try? parser.setLanguage(lang)
        let tree = parser.parse("package main")
        XCTAssertNotNil(tree, "Expected a parse tree for 'package main'")
        XCTAssertEqual(tree?.rootNode?.nodeType, "source_file")
    }

    func test_goGrammar_parsesEmptyString() {
        let lang = Language(language: tree_sitter_go())
        let parser = Parser()
        try? parser.setLanguage(lang)
        let tree = parser.parse("")
        XCTAssertNotNil(tree)
    }
}
