on run
	try
		set renderFiles to choose file with prompt "Choose GLB or Drop & View render packages" with multiple selections allowed
	on error number -128
		return
	end try
	my renderItems(renderFiles)
end run

on open renderFiles
	my renderItems(renderFiles)
end open

on renderItems(renderFiles)
	set appBundlePath to POSIX path of (path to me)
	set commandPath to appBundlePath & "../Render with Cycles.command"
	set shellCommand to quoted form of commandPath
	repeat with renderFile in renderFiles
		set shellCommand to shellCommand & space & quoted form of POSIX path of renderFile
	end repeat

	tell application "Terminal"
		activate
		do script shellCommand
	end tell
end renderItems
