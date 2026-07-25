// uTerm/Views/CodeBody.swift
import SwiftUI

/// 转发到 Editor 模块。Spec §2 之后所有编辑逻辑都在 uTerm/Editor/。
struct CodeBody: View {
    let buffer: FileBuffer
    var language: String = ""
    var focusRequest: EditorFocusRequest? = nil

    var body: some View {
        CodeEditorView(buffer: buffer, language: language, focusRequest: focusRequest)
    }
}
