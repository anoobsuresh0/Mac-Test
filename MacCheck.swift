// Mac Check — GUI for mac-check.sh. The script does the automatic checks; this runs it, draws the
// result, and hosts the hands-on tests (stress, ports, Bluetooth) that need a live window.
import SwiftUI
import AppKit
import CoreBluetooth

// MARK: - Script output model

struct Row: Identifiable {
    let id = UUID()
    let status: String?          // PASS / WARN / FAIL, nil for plain info lines
    let text: String
    var details: [String] = []   // 8-space indented lines under a result (e.g. list of services)
    var tip: String?             // plain-English advice for a result
}

struct Section: Identifiable {
    let id = UUID()
    let title: String
    var about: String?
    var rows: [Row] = []
}

// "== Title ==" section · "[ABOUT] x" explainer · "[PASS|WARN|FAIL] x" result ·
// "[TIP] x" advice for the previous result · 8-space lines = details of the previous result · else info.
func parse(_ out: String) -> [Section] {
    var sections: [Section] = []
    for line in out.components(separatedBy: .newlines) {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { continue }
        if t.hasPrefix("== "), t.hasSuffix(" ==") {
            sections.append(Section(title: String(t.dropFirst(3).dropLast(3))))
            continue
        }
        guard !sections.isEmpty, sections[sections.count - 1].title != "Summary" else { continue }
        let s = sections.count - 1, lastResult = sections[s].rows.lastIndex { $0.status != nil }
        if t.hasPrefix("[ABOUT] ") {
            sections[s].about = String(t.dropFirst(8))
        } else if t.hasPrefix("[TIP] "), let r = lastResult {
            sections[s].rows[r].tip = String(t.dropFirst(6))
        } else if let m = t.range(of: #"^\[(PASS|WARN|FAIL)\] "#, options: .regularExpression) {
            sections[s].rows.append(Row(status: String(t[m].dropFirst().prefix(4)), text: String(t[m.upperBound...])))
        } else if line.hasPrefix("        "), let r = lastResult, r == sections[s].rows.count - 1 {
            sections[s].rows[r].details.append(t)
        } else {
            sections[s].rows.append(Row(status: nil, text: t))
        }
    }
    return sections.filter { $0.title != "Summary" }
}

func shell(_ exe: String, _ args: [String]) -> (String, String, Int32) {
    let p = Process(), o = Pipe(), e = Pipe()
    p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
    p.standardOutput = o; p.standardError = e
    do { try p.run() } catch { return ("", error.localizedDescription, -1) }
    let out = o.fileHandleForReading.readDataToEndOfFile()   // read before wait, or a full pipe deadlocks
    let err = e.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self), p.terminationStatus)
}

func openURL(_ s: String) { if let u = URL(string: s) { NSWorkspace.shared.open(u) } }

// MARK: - Step 1: automatic checks

@MainActor final class Checker: ObservableObject {
    @Published var sections: [Section] = []
    @Published var raw = ""
    @Published var running = false
    @Published var admin = false
    @Published var error: String?

    let script = Bundle.main.path(forResource: "mac-check", ofType: "sh")!

    var count: (pass: Int, warn: Int, fail: Int) {
        let s = sections.flatMap(\.rows).compactMap(\.status)
        return (s.filter { $0 == "PASS" }.count, s.filter { $0 == "WARN" }.count, s.filter { $0 == "FAIL" }.count)
    }
    var serial: String? {
        sections.flatMap(\.rows).first { $0.text.hasPrefix("Serial Number") }?.text.components(separatedBy: ": ").last
    }

    func run(admin: Bool) {
        guard !running else { return }
        running = true; error = nil
        let home = NSHomeDirectory(), script = script
        // Admin: macOS's own password dialog runs the whole script as root (sudo has no terminal in an app).
        let (exe, args): (String, [String]) = admin
            ? ("/usr/bin/osascript", ["-e", "on run argv",
               "-e", "do shell script \"HOME=\" & quoted form of item 1 of argv & \" /bin/bash \" & quoted form of item 2 of argv & \" --report-only\" with administrator privileges without altering line endings",
               "-e", "end run", home, script])
            : ("/bin/bash", [script, "--report-only"])
        DispatchQueue.global().async {
            let (out, err, code) = shell(exe, args)
            DispatchQueue.main.async {
                self.running = false
                if code != 0 { self.error = err.contains("-128") ? "Admin password cancelled." : (err.isEmpty ? out : err); return }
                self.raw = out
                self.sections = parse(out)
                self.admin = admin
            }
        }
    }

    func save() {
        let p = NSSavePanel()
        p.nameFieldStringValue = "mac-check-\(serial ?? "report").txt"
        if p.runModal() == .OK, let url = p.url { try? raw.write(to: url, atomically: true, encoding: .utf8) }
    }
}

// MARK: - Step 2: hands-on tests

final class StressTest: ObservableObject {
    @Published var running = false
    @Published var elapsed = 0
    @Published var speed: Int?           // % of the speed measured at the start
    @Published var heat = ProcessInfo.ThermalState.nominal
    @Published var result: [Row] = []

    var duration = 180
    private var threads: [Thread] = []
    private var counters: UnsafeMutablePointer<Int>?
    private var samples: [Int] = [], last = 0, maxHeat = ProcessInfo.ThermalState.nominal
    private var timer: Timer?, isAir = false

    func start() {
        guard !running else { return }
        isAir = shell("/usr/sbin/system_profiler", ["SPHardwareDataType"]).0.contains("MacBook Air")
        let n = ProcessInfo.processInfo.activeProcessorCount
        // ponytail: unsynchronised per-thread counters (padded 16 apart); torn reads only blur a 1 s sample
        let c = UnsafeMutablePointer<Int>.allocate(capacity: n * 16); c.initialize(repeating: 0, count: n * 16)
        counters = c; samples = []; last = 0; elapsed = 0; speed = nil; result = []; maxHeat = .nominal; running = true
        threads = (0..<n).map { i in
            let t = Thread {
                var x = 1.000001
                while !Thread.current.isCancelled {
                    for _ in 0..<200_000 { x = x * 1.0000001 + 0.0000001 }
                    c[i * 16] += 1
                }
                if x == 0 { print(x) }   // keeps the math from being optimised away
            }
            t.qualityOfService = .userInitiated
            t.start()
            return t
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick(n) }
    }

    private func tick(_ n: Int) {
        guard let c = counters else { return }
        let total = (0..<n).reduce(0) { $0 + c[$1 * 16] }
        samples.append(total - last); last = total; elapsed += 1
        heat = ProcessInfo.processInfo.thermalState
        if heat.rawValue > maxHeat.rawValue { maxHeat = heat }
        if samples.count > 15 { speed = Int(100 * avg(samples.suffix(5)) / baseline) }
        if elapsed >= duration { stop(finished: true) }
    }

    private var baseline: Double { max(1, avg(samples.dropFirst(3).prefix(12))) }   // seconds 4–15, before heat builds
    private func avg<C: Collection>(_ s: C) -> Double where C.Element == Int { s.isEmpty ? 0 : Double(s.reduce(0, +)) / Double(s.count) }

    func stop(finished: Bool = false) {
        guard running else { return }
        timer?.invalidate(); timer = nil
        threads.forEach { $0.cancel() }; threads = []
        running = false
        guard finished else { result = [Row(status: nil, text: "Stopped early — run the full 3 minutes for a real result.")]; return }
        let kept = Int(100 * avg(samples.suffix(20)) / baseline), limit = isAir ? 50 : 75
        var rows = [Row(status: "PASS", text: "Ran \(duration / 60) minutes at full power without crashing")]
        if maxHeat == .critical {
            rows.append(Row(status: "FAIL", text: "Reached a critical temperature",
                            tip: "The cooling isn't keeping up: a failing fan, blocked vents or dried-out thermal paste. Needs a repair."))
        }
        if kept < limit {
            rows.append(Row(status: "WARN", text: "Slowed to \(kept)% of its starting speed as it heated up",
                            tip: isAir ? "MacBook Air has no fan, so it slows down when hot, but dropping below half speed is more than normal. Check the bottom isn't unusually hot."
                                       : "A MacBook Pro has fans and should barely slow down. Listen for the fans during the test; silence or grinding means a fan problem."))
        } else {
            rows.append(Row(status: "PASS", text: "Kept \(kept)% of its speed while hot" + (isAir ? " (a fanless Air may slow down a bit; that's normal)" : "")))
        }
        result = rows
    }
}

final class PortTest: ObservableObject {
    @Published var running = false
    @Published var ports: [(now: Bool, seen: Bool)] = []
    private var timer: Timer?

    func start() {
        guard !running else { return }
        running = true; ports = []
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
    }

    func stop() { timer?.invalidate(); timer = nil; running = false }

    private func poll() {
        DispatchQueue.global().async {
            let now = PortTest.usbBuses()
            DispatchQueue.main.async {
                guard self.running else { return }
                if self.ports.count != now.count { self.ports = now.map { ($0, $0) } }
                else { self.ports = zip(self.ports, now).map { (now: $1, seen: $0.seen || $1) } }
            }
        }
    }

    // One built-in USB bus per USB-C port; a device on the port shows up as the bus's "_items".
    static func usbBuses() -> [Bool] {
        for type in ["SPUSBHostDataType", "SPUSBDataType"] {   // macOS 15+ name first, older name second
            let json = shell("/usr/sbin/system_profiler", ["-json", type]).0
            guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
                  let buses = obj[type] as? [[String: Any]], !buses.isEmpty else { continue }
            return buses
                .filter { ($0["USBKeyHardwareType"] as? String ?? "Built-in") == "Built-in" }
                .sorted { "\($0["USBKeyLocationID"] ?? $0["_name"] ?? "")" < "\($1["USBKeyLocationID"] ?? $1["_name"] ?? "")" }
                .map { !(($0["_items"] as? [Any]) ?? []).isEmpty }
        }
        return []
    }
}

final class BluetoothScan: NSObject, ObservableObject, CBCentralManagerDelegate {
    @Published var running = false
    @Published var found = 0
    @Published var result: Row?
    private var manager: CBCentralManager?
    private var seen = Set<UUID>()

    func start() {
        guard !running else { return }
        running = true; found = 0; seen = []; result = nil
        if let m = manager { centralManagerDidUpdateState(m) } else { manager = CBCentralManager(delegate: self, queue: .main) }
    }

    func centralManagerDidUpdateState(_ m: CBCentralManager) {
        guard running else { return }
        switch m.state {
        case .poweredOn:
            m.scanForPeripherals(withServices: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { self.finish() }
        case .poweredOff:
            done(Row(status: "WARN", text: "Bluetooth is turned off", tip: "Turn it on from the menu bar or Control Centre, then scan again."))
        case .unauthorized:
            done(Row(status: "WARN", text: "Mac Check isn't allowed to use Bluetooth",
                     tip: "Open System Settings › Privacy & Security › Bluetooth, switch Mac Check on, then scan again."))
        case .unsupported:
            done(Row(status: "FAIL", text: "No working Bluetooth hardware", tip: "The Bluetooth chip isn't responding. That's a logic board fault."))
        default: break   // .resetting / .unknown: a real state update follows
        }
    }

    func centralManager(_ m: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        seen.insert(p.identifier); found = seen.count
    }

    private func finish() {
        guard running else { return }
        manager?.stopScan()
        done(found > 0 ? Row(status: "PASS", text: "Found \(found) Bluetooth device\(found == 1 ? "" : "s") nearby")
                       : Row(status: "WARN", text: "No Bluetooth devices found",
                             tip: "Put your phone (with Bluetooth on) or AirPods case next to the Mac and scan again. Still nothing means a weak antenna."))
    }

    private func done(_ r: Row) { result = r; running = false }
}

// MARK: - Views

struct StatusIcon: View {
    let status: String?
    var body: some View {
        switch status {
        case "PASS": Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
        case "WARN": Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
        case "FAIL": Image(systemName: "xmark.octagon.fill").foregroundColor(.red)
        default:     Image(systemName: "info.circle").foregroundColor(.secondary)
        }
    }
}

struct RowView: View {
    let row: Row
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                StatusIcon(status: row.status).frame(width: 16)
                if row.status == nil, let i = row.text.range(of: ": ") {
                    // "Key: value" info line → two columns
                    Text(row.text[..<i.lowerBound]).foregroundColor(.secondary).frame(width: 170, alignment: .leading)
                    Text(row.text[i.upperBound...]).textSelection(.enabled)
                } else {
                    Text(row.text).foregroundColor(row.status == nil ? .secondary : .primary).textSelection(.enabled)
                }
                Spacer(minLength: 0)
            }
            if let tip = row.tip, row.status != "PASS" {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "lightbulb").foregroundColor(.yellow)
                    Text(tip).font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 24)
            }
            if !row.details.isEmpty {
                DisclosureGroup("Show \(row.details.count) item\(row.details.count == 1 ? "" : "s")") {
                    Text(row.details.joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.callout)
                .padding(.leading, 24)
            }
        }
    }
}

struct Card<Content: View>: View {
    var title: String? = nil
    var about: String? = nil
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { Text(title).font(.headline) }
            if let about { Text(about).font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true) }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.2)))
        .cornerRadius(10)
    }
}

struct StepHeader: View {
    let number: Int, title: String, subtitle: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)").font(.headline).foregroundColor(.white)
                .frame(width: 26, height: 26).background(Circle().fill(Color.accentColor))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title3.bold())
                Text(subtitle).foregroundColor(.secondary)
            }
        }
        .padding(.top, 10)
    }
}

struct Verdict: View {
    let c: (pass: Int, warn: Int, fail: Int)
    let admin: Bool
    var body: some View {
        let (icon, color, title): (String, Color, String) =
            c.fail > 0 ? ("xmark.octagon.fill", .red, "Don't buy yet — \(c.fail) problem\(c.fail == 1 ? "" : "s") to resolve")
          : c.warn > 0 ? ("exclamationmark.triangle.fill", .orange, "Mostly good — \(c.warn) thing\(c.warn == 1 ? "" : "s") to look at")
          : ("checkmark.seal.fill", .green, "All automatic checks passed")
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 30)).foregroundColor(color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.title3.bold())
                    Text("\(c.pass) passed · \(c.warn) warning\(c.warn == 1 ? "" : "s") · \(c.fail) failed"
                         + (admin ? "" : " · admin checks not run"))
                        .font(.callout).foregroundColor(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 16) {
                legend("PASS", "Good")
                legend("WARN", "Ask the seller or use it to negotiate")
                legend("FAIL", "Don't buy until it's fixed")
            }
            .font(.caption)
        }
        .padding(14)
        .background(color.opacity(0.12))
        .cornerRadius(10)
    }

    func legend(_ s: String, _ text: String) -> some View {
        HStack(spacing: 4) { StatusIcon(status: s); Text(text).foregroundColor(.secondary) }
    }
}

struct HandsOnTests: View {
    @ObservedObject var stress: StressTest
    @ObservedObject var ports: PortTest
    @ObservedObject var bt: BluetoothScan

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 360), spacing: 14, alignment: .top)], spacing: 14) {
            Card(title: "Screen, keyboard, speakers & trackpad",
                 about: "Opens a test page in Safari: full-screen colours to spot dead pixels, a keyboard map that lights up each key you press, left/right speaker tones, and a Force Touch meter.") {
                Button("Open Tests in Safari") {
                    if let p = Bundle.main.path(forResource: "test-page", ofType: "html") { _ = shell("/usr/bin/open", ["-a", "Safari", p]) }
                }
            }

            Card(title: "Stress test (3 minutes)",
                 about: "Runs every processor core at full power to heat the Mac up. Faulty cooling or a weak logic board shows up as overheating, heavy slowdown or a crash. Plug in the charger first. If the Mac freezes, restarts or shuts down, don't buy it.") {
                HStack {
                    if stress.running { Button("Stop") { stress.stop() } } else { Button("Start Stress Test") { stress.start() } }
                    if stress.running { ProgressView(value: Double(stress.elapsed), total: Double(stress.duration)).frame(maxWidth: 160) }
                }
                if stress.running {
                    Text("\(stress.duration - stress.elapsed)s left · Speed: \(stress.speed.map { "\($0)%" } ?? "measuring…") · Heat: \(heatLabel(stress.heat))")
                        .font(.callout).foregroundColor(.secondary)
                }
                ForEach(stress.result) { RowView(row: $0) }
            }

            Card(title: "USB-C ports",
                 about: "Plug a USB device (a USB stick, a phone cable or a mouse; not just a charger) into each USB-C port, one at a time. Each port goes green once the Mac detects something in it.") {
                HStack {
                    if ports.running { Button("Stop") { ports.stop() } } else { Button("Start Port Test") { ports.start() } }
                    if ports.running && ports.ports.isEmpty { ProgressView().scaleEffect(0.6) }
                }
                if !ports.ports.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(Array(ports.ports.enumerated()), id: \.offset) { i, p in
                            Label("Port \(i + 1)", systemImage: p.seen ? "checkmark.circle.fill" : "circle.dashed")
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background((p.seen ? Color.green : Color.secondary).opacity(p.now ? 0.35 : 0.15))
                                .cornerRadius(6)
                        }
                    }
                    let n = ports.ports.filter(\.seen).count
                    RowView(row: n == ports.ports.count
                        ? Row(status: "PASS", text: "All \(n) USB-C ports work")
                        : Row(status: nil, text: "\(n) of \(ports.ports.count) ports detected a device so far"))
                }
                Text("Also plug the charger into every USB-C port and MagSafe; the battery icon should show charging each time. HDMI and the SD slot need a display or card to test.")
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            Card(title: "Bluetooth scan",
                 about: "Listens for 10 seconds for nearby Bluetooth devices (phones, headphones, watches) to prove the Bluetooth antenna works. macOS will ask permission the first time.") {
                HStack {
                    Button("Scan for Devices") { bt.start() }.disabled(bt.running)
                    if bt.running { ProgressView().scaleEffect(0.6); Text("\(bt.found) found…").foregroundColor(.secondary) }
                }
                if let r = bt.result { RowView(row: r) }
            }
        }
    }

    func heatLabel(_ s: ProcessInfo.ThermalState) -> String {
        switch s {
        case .nominal: return "Normal"
        case .fair: return "Warm"
        case .serious: return "Hot (slowing down)"
        case .critical: return "Too hot!"
        @unknown default: return "Unknown"
        }
    }
}

struct ManualChecks: View {
    let serial: String?
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                item("Replaced parts: System Settings › General › About › Parts & Service. Only shown if the Mac has been repaired; non-genuine parts are listed there.",
                     "Open About", "x-apple.systempreferences:com.apple.SystemProfiler.AboutExtension")
                // Apple's page needs a CAPTCHA and has no public API, so this is the most we can automate
                item("Warranty & genuine serial\(serial.map { " (\($0))" } ?? ""): the button copies the serial; paste it with ⌘V. The model Apple shows must match this Mac.",
                     "Copy Serial & Check Coverage", "https://checkcoverage.apple.com", copy: serial)
                item("Camera and microphone: check the picture is clear and your voice is recorded.", "Open Photo Booth", "file:///System/Applications/Photo%20Booth.app")
                item("Apple's own hardware test: shut down, hold the power button until “Loading startup options” appears, then press ⌘D. Takes about 5 minutes.", nil, nil)
                item("Body: dents, bent corners, a wobbly or loose hinge, swollen battery (the case bulges or doesn't sit flat), stains or sticky keys (signs of liquid).", nil, nil)
            }
        }
    }

    func item(_ text: String, _ button: String?, _ url: String?, copy: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: "hand.point.right").foregroundColor(.accentColor).frame(width: 16)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer()
            if let button, let url {
                Button(button) {
                    if let copy {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(copy, forType: .string)
                    }
                    openURL(url)
                }
            }
        }
    }
}

struct BeforeYouPay: View {
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array([
                    "Ask the seller to choose System Settings › General › Transfer or Reset › Erase All Content and Settings, and enter their own password.",
                    "Watch the Mac restart and show the “Hello” setup screen.",
                    "Start the setup. It must NOT ask for the seller's Apple Account (that means Activation Lock is still on) and must NOT show a “Remote Management” screen.",
                    "Only then hand over the money.",
                ].enumerated()), id: \.offset) { i, s in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(i + 1).").bold().frame(width: 18, alignment: .trailing)
                        Text(s).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

struct ContentView: View {
    @StateObject var c = Checker()
    @StateObject var stress = StressTest()
    @StateObject var ports = PortTest()
    @StateObject var bt = BluetoothScan()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Mac Check").font(.largeTitle.bold())
                        Text("Inspect a used Apple Silicon Mac before you pay for it. Work through the four steps below on the Mac you're buying.")
                            .foregroundColor(.secondary)
                    }
                }

                StepHeader(number: 1, title: "Automatic checks", subtitle: "About 10 seconds. Checks locks, security, crash history, battery, SSD, wireless and parts.")
                HStack {
                    Button("Run Checks") { c.run(admin: false) }.buttonStyle(.borderedProminent).disabled(c.running)
                    Button("Run with Admin Checks…") { c.run(admin: true) }.disabled(c.running)
                    Button("Save Report…") { c.save() }.disabled(c.raw.isEmpty)
                    if c.running { ProgressView().scaleEffect(0.6); Text("Checking…").foregroundColor(.secondary) }
                }
                Text("Admin checks add 3 more checks (Apple's ownership records, all profiles, startup security). They need this Mac's login password, so ask the seller to type it in.")
                    .font(.caption).foregroundColor(.secondary)
                if let e = c.error { Text(e).foregroundColor(.red).textSelection(.enabled) }
                if !c.sections.isEmpty {
                    Verdict(c: c.count, admin: c.admin)
                    ForEach(c.sections) { s in
                        Card(title: s.title, about: s.about) {
                            VStack(alignment: .leading, spacing: 8) { ForEach(s.rows) { RowView(row: $0) } }
                        }
                    }
                }

                StepHeader(number: 2, title: "Hands-on tests", subtitle: "Things only you can see, hear or feel. Each takes a minute or two.")
                HandsOnTests(stress: stress, ports: ports, bt: bt)

                StepHeader(number: 3, title: "Manual checks", subtitle: "Quick things no software can check for you.")
                ManualChecks(serial: c.serial)

                StepHeader(number: 4, title: "Before you pay", subtitle: "The final proof that the Mac is really free to use.")
                BeforeYouPay()
            }
            .padding(20)
        }
        .frame(minWidth: 820, minHeight: 700)
        .onDisappear { stress.stop(); ports.stop() }
    }
}

@main struct MacCheckApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
