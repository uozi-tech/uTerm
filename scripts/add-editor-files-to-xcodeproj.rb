#!/usr/bin/env ruby
# scripts/add-editor-files-to-xcodeproj.rb
#
# NOTE: This script is provided for reference and future use (e.g., if the project
# ever switches away from PBXFileSystemSynchronizedRootGroup to explicit PBXFileReference
# entries). As of Xcode 16 with objectVersion=77, the uTerm.xcodeproj uses
# PBXFileSystemSynchronizedRootGroup for both uTerm/ and uTermTests/ groups, which
# means all files placed under those directories are automatically included in the
# respective build targets WITHOUT any xcodeproj edits.
#
# To verify: grep -c "PBXFileSystemSynchronizedRootGroup" uTerm.xcodeproj/project.pbxproj
#
# Usage (if ever needed for a traditional PBXGroup project):
#   export PATH="$HOME/.gem/ruby/2.6.0/bin:$PATH"
#   ruby scripts/add-editor-files-to-xcodeproj.rb

require 'xcodeproj'

PROJECT_PATH = File.expand_path('../../uTerm.xcodeproj', __FILE__)
EDITOR_FILES = [
  'uTerm/Editor/CodeEditorView.swift',
  'uTerm/Editor/CodeEditorController.swift',
  'uTerm/Editor/EditorTheme.swift',
  'uTerm/Editor/Highlighting/SyntaxHighlighter.swift',
  'uTerm/Editor/Highlighting/TreeSitterHighlighter.swift',
  'uTerm/Editor/Highlighting/GrammarRegistry.swift',
  'uTerm/Editor/Highlighting/NoopHighlighter.swift',
  'uTerm/Editor/Selection/ActiveLineOverlay.swift',
  'uTerm/Editor/Selection/SameWordEmphasis.swift',
  'uTerm/Editor/Find/FindReplaceBar.swift',
  'uTerm/Editor/Find/FindReplaceController.swift',
  'uTerm/Editor/Find/FindMatcher.swift',
].freeze

project = Xcodeproj::Project.open(PROJECT_PATH)

uterm_group = project.main_group['uTerm']
if uterm_group.is_a?(Xcodeproj::Project::Object::PBXFileSystemSynchronizedRootGroup)
  puts "Project uses PBXFileSystemSynchronizedRootGroup — files are auto-discovered."
  puts "No xcodeproj edits needed. Files on disk:"
  EDITOR_FILES.each { |f| puts "  #{f}" }
  exit 0
end

# Legacy path for traditional PBXGroup projects:
target = project.targets.find { |t| t.name == 'uTerm' }
raise "uTerm target not found" unless target

def find_or_create_group(parent, name)
  parent[name] || parent.new_group(name)
end

editor_group       = find_or_create_group(uterm_group, 'Editor')
highlighting_group = find_or_create_group(editor_group, 'Highlighting')
selection_group    = find_or_create_group(editor_group, 'Selection')
find_group         = find_or_create_group(editor_group, 'Find')

groups = {
  'uTerm/Editor'              => editor_group,
  'uTerm/Editor/Highlighting' => highlighting_group,
  'uTerm/Editor/Selection'    => selection_group,
  'uTerm/Editor/Find'         => find_group,
}

refs = EDITOR_FILES.map do |rel_path|
  abs_path = File.expand_path("../../#{rel_path}", __FILE__)
  dir      = File.dirname(rel_path)
  group    = groups[dir] || editor_group
  ref      = group.new_file(abs_path)
  puts "Added #{rel_path}"
  ref
end

target.add_file_references(refs)
project.save

puts "Done. Saved #{PROJECT_PATH}"
