import SwiftUI

func runBundle(bundlePath: String) {
    let process = Process()
    let pipe = Pipe()
    
    // Resolve absolute path for bundle
    let homeDir = FileManager.default.homeDirectoryForCurrentUser
    let macpackPath = homeDir.appendingPathComponent(".macpack/bin/macpack")
    
    // Resolve the full absolute path for the bundlePath if it's not absolute
    let fullBundlePath = URL(fileURLWithPath: bundlePath, isDirectory: true).standardized
    
    process.executableURL = macpackPath
    process.arguments = [fullBundlePath.path]  // Pass the absolute bundle path as the argument
    process.standardOutput = pipe
    process.standardError = pipe
    
    do {
        try process.run()
        process.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let output = String(data: data, encoding: .utf8) {
            print(output)
        }
    } catch {
        print("Error running Rust command: \(error)")
        let pasteboard = NSPasteboard.general
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString("\(error)", forType: .string)
    }
}

@main
struct MacPack: App {
    init() {
        let arguments = CommandLine.arguments
        if arguments.count > 1 {
            if arguments[1] == "-NSDocumentRevisionsDebugMode" {
                print("Debug mode. Not getting any arguments")
                return
            }
            let bundlePath = arguments[1]
            runBundle(bundlePath: bundlePath)
            exit(0)
        } else {
            print("No command-line arguments passed.")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
