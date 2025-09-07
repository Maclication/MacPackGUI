import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ZIPFoundation
import TOMLDecoder

// MARK: - Metadata from TOML
struct MacPackMetadata: Decodable {
    let package: Package
}

struct Package: Decodable {
    let name: String
    let description: String?
    let version: String
    let author: String
    let exec: String
}

// MARK: - Saved Apps
struct AppEntry: Identifiable, Codable, Equatable {
    let id = UUID()
    let name: String
    let description: String
    let path: String
}

// MARK: - File Picker
struct FilePicker: NSViewControllerRepresentable {
    let onPick: (URL?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeNSViewController(context: Context) -> NSViewController {
        let controller = NSViewController()
        DispatchQueue.main.async {
            let panel = NSOpenPanel()
            panel.title = "Choose a .mpb Bundle"
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            if #available(macOS 11.0, *) {
                if let mpbType = UTType(filenameExtension: "mpb") {
                    panel.allowedContentTypes = [mpbType]
                }
            } else {
                panel.allowedFileTypes = ["mpb"]
            }
            if panel.runModal() == .OK, let url = panel.url, url.pathExtension.lowercased() == "mpb" {
                context.coordinator.onPick(url)
            } else {
                context.coordinator.onPick(nil)
            }
        }
        return controller
    }

    func updateNSViewController(_ nsViewController: NSViewController, context: Context) {}
    
    class Coordinator {
        let onPick: (URL?) -> Void
        init(onPick: @escaping (URL?) -> Void) { self.onPick = onPick }
    }
}

// MARK: - ContentView
struct ContentView: View {
    @State private var bundlePath: String = ""
    @State private var outputMessage: String = ""
    @State private var selectedPath: String?
    @State private var showingPicker = false
    @State private var apps: [AppEntry] = []
    @State private var showingError = false
    @State private var errorMessage = ""

    private let appsFile = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("apps.txt")

    var body: some View {
        VStack(spacing: 15) {
            // Top toolbar row
            HStack(spacing: 15) {
                Text("MacPack")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.blue, .teal, .orange],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                
                HStack {
                    TextField("Path to bundle (.mpb)...", text: Binding(
                        get: { selectedPath ?? "" },
                        set: { selectedPath = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 300)
                    
                    Button(action: { showingPicker = true }) {
                        Image(systemName: "folder")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(BorderlessButtonStyle())
                }
                
                Button("Run") {
                    guard let path = selectedPath, !path.isEmpty else {
                        showError("Please select a bundle first.")
                        return
                    }
                    bundlePath = path
                    runBundle(bundlePath: bundlePath)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal)
            
            Divider()
            
            // Apps Grid
            Text("Apps")
                .font(.title2.bold())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
            
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250))], spacing: 15) {
                    ForEach(apps) { app in
                        AppCardView(
                            app: app,
                            runAction: { runBundle(bundlePath: app.path) },
                            removeAction: {
                                withAnimation {
                                    apps.removeAll { $0.id == app.id }
                                    saveApps()
                                }
                            }
                        )
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                }
                .padding()
            }
            
            Divider()
            
            // Output
            if !outputMessage.isEmpty {
                ScrollView {
                    Text(outputMessage)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color(NSColor.windowBackgroundColor))
                        .cornerRadius(6)
                }
                .frame(height: 120)
                .padding(.horizontal)
            }
        }
        .padding(.vertical)
        .frame(minWidth: 600, minHeight: 500)
        .sheet(isPresented: $showingPicker) {
            FilePicker { url in
                selectedPath = url?.path
                showingPicker = false
            }
        }
        .onAppear(perform: loadApps)
        .alert("Error", isPresented: $showingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: apps)
    }
    
    // MARK: Run Bundle
    func runBundle(bundlePath: String) {
        let process = Process()
        let pipe = Pipe()
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let macpackPath = homeDir.appendingPathComponent(".macpack/bin/macpack")
        let fullBundlePath = URL(fileURLWithPath: bundlePath).standardized
        
        process.executableURL = macpackPath
        process.arguments = [fullBundlePath.path]
        process.standardOutput = pipe
        process.standardError = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                outputMessage = output
            }
            
            if let metadata = readMacPackMetadata(from: fullBundlePath) {
                let entry = AppEntry(
                    name: metadata.package.name,
                    description: metadata.package.description ?? "No description provided.",
                    path: fullBundlePath.path
                )
                if !apps.contains(where: { $0.name == entry.name }) {
                    withAnimation {
                        apps.append(entry)
                    }
                    saveApps()
                }
            }
        } catch {
            showError("Error running Rust command: \(error.localizedDescription)")
        }
    }
    
    // MARK: Read Metadata
    func readMacPackMetadata(from mpbURL: URL) -> MacPackMetadata? {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        do {
            try FileManager.default.unzipItem(at: mpbURL, to: tempDir)
        } catch {
            showError("Failed to unzip .mpb: \(error.localizedDescription)")
            return nil
        }
        
        var tomlURL = tempDir.appendingPathComponent("macpack.toml")
        if !FileManager.default.fileExists(atPath: tomlURL.path) {
            let baseName = mpbURL.deletingPathExtension().lastPathComponent
            tomlURL = tempDir.appendingPathComponent(baseName).appendingPathComponent("macpack.toml")
        }
        
        guard FileManager.default.fileExists(atPath: tomlURL.path) else {
            showError("macpack.toml not found in bundle")
            return nil
        }
        
        do {
            let tomlData = try Data(contentsOf: tomlURL)
            let decoder = TOMLDecoder()
            return try decoder.decode(MacPackMetadata.self, from: tomlData)
        } catch {
            showError("Failed to parse macpack.toml: \(error.localizedDescription)")
            return nil
        }
    }
    
    // MARK: Save/Load Apps
    func saveApps() {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(apps) {
            try? data.write(to: appsFile)
        }
    }
    
    func loadApps() {
        let decoder = JSONDecoder()
        if let data = try? Data(contentsOf: appsFile),
           let savedApps = try? decoder.decode([AppEntry].self, from: data) {
            apps = savedApps
        }
    }
    
    // MARK: Show Error
    func showError(_ message: String) {
        errorMessage = message
        showingError = true
    }
}

// MARK: - App Card View
struct AppCardView: View {
    let app: AppEntry
    let runAction: () -> Void
    let removeAction: () -> Void
    
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: runAction) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("[No icons yet]: \(app.name)")
                        .font(.headline)
                    Text(app.description)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(10)
                .shadow(radius: 2)
            }
            .buttonStyle(.plain)

            // Remove button
            Button(action: removeAction) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.red)
                    .padding(6)
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Preview
#if DEBUG
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .onAppear {
                // You can temporarily populate state for preview
                // Use `DispatchQueue.main.async` if needed
            }
            .frame(width: 600, height: 500)
    }
}
#endif
