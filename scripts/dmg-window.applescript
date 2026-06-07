-- Configure the DMG window via Finder so Finder writes a valid .DS_Store.
-- Usage: osascript dmg-window.applescript <volume-name>
-- The close/reopen/re-set-bounds dance is required: a single `set bounds`
-- before `update` is often discarded, leaving the window larger than the
-- background image (white border). Re-applying bounds after reopening locks it.
on run argv
	set volName to item 1 of argv
	set appName to volName & ".app"
	tell application "Finder"
		tell disk volName
			open
			set current view of container window to icon view
			set toolbar visible of container window to false
			set statusbar visible of container window to false
			set the bounds of container window to {200, 120, 860, 520}
			set opts to the icon view options of container window
			set arrangement of opts to not arranged
			set icon size of opts to 128
			set text size of opts to 14
			set background picture of opts to file ".background:dmg-background@2x.png"
			set position of item appName of container window to {180, 176}
			set position of item "Applications" of container window to {480, 176}
			close
			open
			set the bounds of container window to {200, 120, 860, 520}
			update without registering applications
			delay 2
			close
		end tell
	end tell
end run
