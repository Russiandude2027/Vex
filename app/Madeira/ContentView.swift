import SwiftUI

// MARK: - C Bridge / FFI Declarations
@_silgen_name("jit_alloc_pool")
func jit_alloc_pool(_ size: UInt) -> Int32

@_silgen_name("wine_run_full_sequence")
func wine_run_full_sequence() -> Int32

// MARK: - Log Level Definition
enum LogLevel {
    case info
    case success
    case error
}

// MARK: - LogStore Observable Object
class LogStore: ObservableObject {
    @Published var logs: [String] = []
    @Published var uiPaused: Bool = false

    func log(_ message: String, level: LogLevel = .info) {
        DispatchQueue.main.async {
            let prefix: String
            switch level {
            case .info: prefix = "[INFO]"
            case .success: prefix = "[SUCCESS]"
            case .error: prefix = "[ERROR]"
            }
            self.logs.append("\(prefix) \(message)")
        }
    }
}

// MARK: - Main ContentView
struct ContentView: View {
    @StateObject private var logStore = LogStore()
    @AppStorage("poolSizeMB") private var poolSizeMB: Int = 512
    @State private var isRunning = false

    var body: some View {
        VStack(spacing: 16) {
            Text("Wine Runner")
                .font(.largeTitle)
                .bold()

            HStack {
                Text("JIT Pool Size:")
                    .font(.headline)
                Spacer()
                Picker("Pool Size", selection: $poolSizeMB) {
                    Text("256 MB").tag(256)
                    Text("512 MB").tag(512)
                    Text("1024 MB").tag(1024)
                    Text("2048 MB").tag(2048)
                }
                .pickerStyle(.menu)
            }
            .padding(.horizontal)

            Button(action: {
                runWineFullSequence()
            }) {
                HStack {
                    if isRunning {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .padding(.trailing, 8)
                    }
                    Text(isRunning ? "Running Sequence..." : "Start Wine Sequence")
                        .bold()
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(isRunning ? Color.gray : Color.blue)
                .foregroundColor(.white)
                .cornerRadius(12)
            }
            .disabled(isRunning)
            .padding(.horizontal)

            // Log Console Output
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(logStore.logs.enumerated()), id: \.offset) { index, log in
                            Text(log)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(logColor(for: log))
                                .id(index)
                        }
                    }
                    .padding(12)
                }
                .background(Color.black.opacity(0.85))
                .cornerRadius(10)
                .onChange(of: logStore.logs.count) { newCount in
                    if newCount > 0 {
                        proxy.scrollTo(newCount - 1, anchor: .bottom)
                    }
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical)
    }

    private func logColor(for log: String) -> Color {
        if log.contains("[ERROR]") { return .red }
        if log.contains("[SUCCESS]") { return .green }
        return .white
    }

    // MARK: - Core Execution Sequence
    private func runWineFullSequence() {
        guard !isRunning else { return }
        isRunning = true
        logStore.uiPaused = true

        DispatchQueue.global(qos: .userInitiated).async {
            let heartbeat = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                // Keep-alive heartbeat loop
            }

            var ws_log_quiet: Int32 = 1

            // Check Madeira Configuration
            if let configPath = Bundle.main.path(forResource: "madeira", ofType: "cfg"),
               let configContent = try? String(contentsOfFile: configPath, encoding: .utf8) {
                if configContent.contains("MADEIRA_REAL_SUSPEND=1") {
                    let v = 1
                    logStore.log("Real thread suspend: MADEIRA_REAL_SUSPEND=\(v) via madeira.cfg real-suspend")
                }
            }

            // Step 1: Allocate JIT pool
            let poolSize = UInt(poolSizeMB) * 1024 * 1024
            let poolRet = jit_alloc_pool(poolSize)
            if poolRet != 0 {
                DispatchQueue.main.async {
                    self.logStore.log("Failed to allocate JIT pool (\(poolSizeMB)MB), code: \(poolRet)", level: .error)
                    self.logStore.uiPaused = false
                    self.isRunning = false
                    heartbeat.invalidate()
                    ws_log_quiet = 0
                }
                return
            }
            self.logStore.log("JIT pool allocated (\(poolSizeMB)MB)", level: .success)

            // Step 2: Execute Wine sequence
            let result = wine_run_full_sequence()

            // Step 3: Restore UI & unpause rendering
            DispatchQueue.main.async {
                self.logStore.log("Wine sequence completed with status \(result)", level: result == 0 ? .success : .error)
                self.logStore.uiPaused = false
                self.isRunning = false
                heartbeat.invalidate()
                ws_log_quiet = 0
            }
        }
    }
}
