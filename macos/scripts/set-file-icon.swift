// Gives a file (the .dmg) the app icon in Finder.
// Usage: swift set-file-icon.swift icon.icns file
import AppKit

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: set-file-icon.swift icon.icns file\n".utf8))
    exit(1)
}
guard let icon = NSImage(contentsOfFile: CommandLine.arguments[1]) else {
    FileHandle.standardError.write(Data("set-file-icon: can't read icon \(CommandLine.arguments[1])\n".utf8))
    exit(1)
}
exit(NSWorkspace.shared.setIcon(icon, forFile: CommandLine.arguments[2], options: []) ? 0 : 1)
