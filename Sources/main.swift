import Foundation

enum MiniAppCLIError: LocalizedError {
    case invalidArguments(String)
    case fileNotFound(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let message):
            return message
        case .fileNotFound(let message):
            return message
        case .commandFailed(let message):
            return message
        }
    }
}

struct Logger {
    static func info(_ message: String) {
        FileHandle.standardError.write(Data(("[miniapp] " + message + "\n").utf8))
    }

    static func error(_ message: String) {
        FileHandle.standardError.write(Data(("[miniapp] ERROR: " + message + "\n").utf8))
    }
}

func printUsage() {
    let text = """
    miniapp

    Usage:
            miniapp host sdk install [--project <path/to/App.xcodeproj>] [--target <TargetName>] [--force]
            miniapp --version

    Notes:
      - This command injects a Run Script build phase into an iOS app target to generate miniapp-deps.json at build time.
      - The CLI is designed to be installed via Homebrew and available on PATH.
    """
    print(text)
}

func printVersion() {
        print("miniapp version \(miniAppCLIVersion)")
}

struct InstallOptions {
    var projectPath: String?
    var targetName: String?
    var force: Bool = false
}

func parseInstallOptions(_ args: ArraySlice<String>) throws -> InstallOptions {
    var options = InstallOptions()
    var iterator = args.makeIterator()

    while let arg = iterator.next() {
        switch arg {
        case "--project":
            guard let value = iterator.next() else { throw MiniAppCLIError.invalidArguments("Missing value for --project") }
            options.projectPath = value
        case "--target":
            guard let value = iterator.next() else { throw MiniAppCLIError.invalidArguments("Missing value for --target") }
            options.targetName = value
        case "--force":
            options.force = true
        case "-h", "--help":
            printUsage()
            exit(0)
        default:
            throw MiniAppCLIError.invalidArguments("Unknown argument: \(arg)")
        }
    }

    return options
}

func runProcess(_ launchPath: String, _ arguments: [String]) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = arguments

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    try process.run()
    process.waitUntilExit()

    let outData = stdout.fileHandleForReading.readDataToEndOfFile()
    let errData = stderr.fileHandleForReading.readDataToEndOfFile()

    guard process.terminationStatus == 0 else {
        let errText = String(data: errData, encoding: .utf8) ?? ""
        throw MiniAppCLIError.commandFailed("\(launchPath) \(arguments.joined(separator: " ")) failed: \(errText)")
    }

    return outData
}

func runProcessDiscardingStdout(_ launchPath: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = arguments

    // Some tools (e.g. plutil converting a large project.pbxproj to JSON)
    // can produce enough stdout to fill a pipe buffer and deadlock if the parent
    // only reads after the child exits. Prefer writing to a file or discarding stdout.
    process.standardOutput = FileHandle.nullDevice

    let stderr = Pipe()
    process.standardError = stderr

    try process.run()
    process.waitUntilExit()

    let errData = stderr.fileHandleForReading.readDataToEndOfFile()

    guard process.terminationStatus == 0 else {
        let errText = String(data: errData, encoding: .utf8) ?? ""
        throw MiniAppCLIError.commandFailed("\(launchPath) \(arguments.joined(separator: " ")) failed: \(errText)")
    }
}

func findXcodeprojs(in directory: URL) -> [URL] {
    guard let enumerator = FileManager.default.enumerator(
        at: directory,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) else {
        return []
    }

    var result: [URL] = []
    for case let url as URL in enumerator {
        if url.pathExtension == "xcodeproj" {
            result.append(url)
        }
    }
    return result
}

let generatorScriptName = "sdm-gen-deps.sh"

func generatorScriptContents() -> String {
    // Keep this script self-contained. It should never fail the build.
    return """
#!/bin/sh
set -e

OUTPUT_PATH=\"$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/miniapp-deps.json\"

# Resolve pbxproj path
PBXPROJ=\"\"
if [ -n \"$PROJECT_FILE_PATH\" ] && [ -f \"$PROJECT_FILE_PATH/project.pbxproj\" ]; then
  PBXPROJ=\"$PROJECT_FILE_PATH/project.pbxproj\"
elif [ -n \"$SRCROOT\" ]; then
  PBXPROJ=\"$(find \"$SRCROOT\" -maxdepth 4 -name project.pbxproj -path '*/.xcodeproj/*' -print -quit 2>/dev/null)\"
fi

if [ -z \"$PBXPROJ\" ] || [ ! -f \"$PBXPROJ\" ]; then
  echo \"[SDM] WARN: project.pbxproj not found; writing empty miniapp-deps.json\" >&2
  mkdir -p \"$(dirname \"$OUTPUT_PATH\")\"
  echo '[]' > \"$OUTPUT_PATH\"
  exit 0
fi

JSON=\"$(/usr/bin/plutil -convert json -o - \"$PBXPROJ\" 2>/dev/null || true)\"
if [ -z \"$JSON\" ]; then
  echo \"[SDM] WARN: failed to convert pbxproj to json; writing empty miniapp-deps.json\" >&2
  mkdir -p \"$(dirname \"$OUTPUT_PATH\")\"
  echo '[]' > \"$OUTPUT_PATH\"
  exit 0
fi

python3 - <<'PY' "$OUTPUT_PATH" "$JSON" || true
import json
import sys
import re

output_path = sys.argv[1]
pbx_json = sys.argv[2]

try:
    data = json.loads(pbx_json)
except Exception:
    with open(output_path, 'w', encoding='utf-8') as f:
        f.write('[]')
    sys.exit(0)

objects = data.get('objects', {}) or {}

# Map packageRefId -> {url, type, version}
packages = {}
for oid, obj in objects.items():
    if not isinstance(obj, dict):
        continue
    if obj.get('isa') == 'XCRemoteSwiftPackageReference':
        url = obj.get('repositoryURL') or ''
        req = obj.get('requirement') or {}
        kind = req.get('kind') or ''
        version = ''
        if kind in ('upToNextMajorVersion', 'upToNextMinorVersion'):
            version = req.get('minimumVersion') or ''
        elif kind in ('exactVersion'):
            version = req.get('version') or ''
        elif kind in ('revision'):
            version = req.get('revision') or ''
        elif kind in ('branch'):
            version = req.get('branch') or ''
        elif kind in ('versionRange'):
            min_v = req.get('minimumVersion') or ''
            max_v = req.get('maximumVersion') or ''
            version = f"{min_v}..{max_v}" if (min_v or max_v) else ''
        packages[oid] = { 'url': url, 'type': kind, 'version': version }

# Gather product dependencies and associate to package
records = []
seen = set()
for oid, obj in objects.items():
    if not isinstance(obj, dict):
        continue
    if obj.get('isa') == 'XCSwiftPackageProductDependency':
        pkg_ref = obj.get('package')
        if not pkg_ref or pkg_ref not in packages:
            continue
        pkg = packages[pkg_ref]
        url = pkg.get('url') or ''
        dep_type = pkg.get('type') or ''
        version = pkg.get('version') or ''

        name = obj.get('productName') or ''
        if not name and url:
            # Derive a stable package-ish name from URL
            m = re.search(r"/([^/]+?)(?:\\.git)?$", url)
            name = m.group(1) if m else url

        key = (url, dep_type, version)
        if key in seen:
            continue
        seen.add(key)
        records.append({ 'name': name, 'url': url, 'type': dep_type, 'version': version })

records.sort(key=lambda r: (r.get('name') or '', r.get('url') or ''))

with open(output_path, 'w', encoding='utf-8') as f:
    json.dump(records, f, ensure_ascii=False)
PY

exit 0
"""
}

func installGeneratorScript(into projectDir: URL, force: Bool) throws -> URL {
    let scriptsDir = projectDir.appendingPathComponent("Scripts", isDirectory: true)
    try FileManager.default.createDirectory(at: scriptsDir, withIntermediateDirectories: true)

    let scriptURL = scriptsDir.appendingPathComponent(generatorScriptName)

    if FileManager.default.fileExists(atPath: scriptURL.path), !force {
        return scriptURL
    }

    try generatorScriptContents().write(to: scriptURL, atomically: true, encoding: .utf8)

    // chmod +x
    _ = try? runProcess("/bin/chmod", ["+x", scriptURL.path])

    return scriptURL
}

func loadPBXProjJSON(pbxprojPath: String) throws -> [String: Any] {
    let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    let tmpJSON = tmpDir.appendingPathComponent("miniapp-pbxproj-\(UUID().uuidString).json")

    // Avoid `-o -` (stdout) to prevent potential pipe-buffer deadlocks.
    try runProcessDiscardingStdout("/usr/bin/plutil", ["-convert", "json", "-o", tmpJSON.path, pbxprojPath])

    let jsonData = try Data(contentsOf: tmpJSON)
    let obj = try JSONSerialization.jsonObject(with: jsonData)
    guard let dict = obj as? [String: Any] else {
        throw MiniAppCLIError.commandFailed("pbxproj json is not a dictionary")
    }
    return dict
}

func generateObjectID() -> String {
    let bytes = (0..<12).map { _ in UInt8.random(in: 0...255) }
    return bytes.map { String(format: "%02X", $0) }.joined()
}

func removeExistingPhaseEntries(from content: String) -> String {
    var updated = content

    while let markerRange = updated.range(of: "/* [SDM] Generate Dependencies */ = {") {
        let blockStart = updated.lineRange(for: markerRange).lowerBound
        guard let blockEndRange = updated.range(of: "};", range: markerRange.upperBound..<updated.endIndex) else {
            break
        }
        let blockEnd = updated.index(after: blockEndRange.upperBound)
        updated.removeSubrange(blockStart..<blockEnd)
    }

    while let markerRange = updated.range(of: "/* [SDM] Generate Dependencies */") {
        let lineRange = updated.lineRange(for: markerRange)
        let line = updated[lineRange]
        if line.contains("= {") {
            updated.removeSubrange(lineRange)
            continue
        }
        updated.removeSubrange(lineRange)
    }

    return updated
}

func findInsertionIndexForNewBuildPhaseSection(in content: String) -> String.Index? {
    // Prefer inserting after the last existing BuildPhase section.
    var searchEnd = content.endIndex
    while let markerRange = content.range(of: "/* End PBX", options: .backwards, range: content.startIndex..<searchEnd) {
        let lineRange = content.lineRange(for: markerRange)
        if content[lineRange].contains("BuildPhase section */") {
            return lineRange.upperBound
        }
        searchEnd = markerRange.lowerBound
    }

    // Fallback: insert before targets if build phase sections are not found.
    if let nativeTargetBegin = content.range(of: "/* Begin PBXNativeTarget section */") {
        return nativeTargetBegin.lowerBound
    }
    if let projectBegin = content.range(of: "/* Begin PBXProject section */") {
        return projectBegin.lowerBound
    }
    return nil
}

func normalizePBXShellScriptBuildPhaseSectionWhitespace(_ content: String) -> String {
    let beginMarker = "/* Begin PBXShellScriptBuildPhase section */"
    let endMarker = "/* End PBXShellScriptBuildPhase section */"

    var updated = content

    // Collapse multiple blank lines immediately after the begin marker.
    while updated.contains("\(beginMarker)\n\n") {
        updated = updated.replacingOccurrences(of: "\(beginMarker)\n\n", with: "\(beginMarker)\n")
    }

    // Collapse multiple blank lines immediately before the end marker.
    while updated.contains("\n\n\(endMarker)") {
        updated = updated.replacingOccurrences(of: "\n\n\(endMarker)", with: "\n\(endMarker)")
    }

    return updated
}

func insertShellScriptPhaseBlock(_ content: String, phaseID: String, scriptPathRelativeToSRCROOT: String) throws -> String {
    let beginMarker = "/* Begin PBXShellScriptBuildPhase section */"
    let endMarker = "/* End PBXShellScriptBuildPhase section */"

    // IMPORTANT:
    // - `shellScript` must contain a literal "\n" escape in the pbxproj (not an actual newline).
    // - Quotes inside the pbxproj string must be written as `\"`.
    let block = """
            \(phaseID) /* [SDM] Generate Dependencies */ = {
                isa = PBXShellScriptBuildPhase;
                buildActionMask = 2147483647;
                files = (
                );
                inputPaths = (
                );
                name = "[SDM] Generate Dependencies";
                outputPaths = (
                );
                runOnlyForDeploymentPostprocessing = 0;
                shellPath = /bin/sh;
                shellScript = "\\\"$SRCROOT/\(scriptPathRelativeToSRCROOT)\\\"\\n";
                showEnvVarsInLog = 0;
            };
    """

    // Normalize to avoid introducing extra blank lines around the insertion point.
    // The Swift multiline literal typically includes a leading newline; trim and add exactly one trailing newline.
    let normalizedBlock = block.trimmingCharacters(in: .newlines) + "\n"

    var updated = content

    if let insertRange = updated.range(of: endMarker) {
        // Insert at the start of the end-marker line; `normalizedBlock` already ends with a newline.
        updated.insert(contentsOf: normalizedBlock, at: insertRange.lowerBound)
        return normalizePBXShellScriptBuildPhaseSectionWhitespace(updated)
    }

    // If the section does not exist (common when the project has never had a Run Script phase), create it.
    guard let sectionInsertIndex = findInsertionIndexForNewBuildPhaseSection(in: updated) else {
        throw MiniAppCLIError.commandFailed("Unable to insert PBXShellScriptBuildPhase section")
    }

    // `normalizedBlock` already ends with a newline, so the end marker will land on its own line.
    let section = "\n\(beginMarker)\n\(normalizedBlock)\(endMarker)\n"
    updated.insert(contentsOf: section, at: sectionInsertIndex)
    return normalizePBXShellScriptBuildPhaseSectionWhitespace(updated)
}

func insertPhaseReference(_ content: String, phaseID: String, targetID: String) throws -> String {
    guard let targetRange = content.range(of: "\(targetID) /*") else {
        throw MiniAppCLIError.commandFailed("Target block not found in pbxproj")
    }
    guard let buildPhasesRange = content.range(of: "buildPhases = (", range: targetRange.lowerBound..<content.endIndex) else {
        throw MiniAppCLIError.commandFailed("buildPhases list missing for target")
    }
    guard let closingRange = content.range(of: ");", range: buildPhasesRange.upperBound..<content.endIndex) else {
        throw MiniAppCLIError.commandFailed("buildPhases list malformed")
    }

    var updated = content

    // Insert *before the closing line*, not before the `);` token.
    // Otherwise the indentation that precedes `);` stays on the previous line
    // and the closing line becomes unindented / messy.
    let closingLineRange = content.lineRange(for: closingRange)

    // Match indentation used by the existing `buildPhases` list.
    // Conventionally entries are indented one level deeper than the `buildPhases = (` line.
    let buildPhasesLineRange = content.lineRange(for: buildPhasesRange)
    let buildPhasesLine = content[buildPhasesLineRange]
    let baseIndent = String(buildPhasesLine.prefix { $0 == "\t" || $0 == " " })
    let entryIndent = baseIndent + "\t"

    // If a previous run inserted at the `);` token, the closing line may have lost indentation
    // and now starts at column 0. Detect and repair that by prefixing `baseIndent`.
    let closingLine = String(content[closingLineRange])
    let needsClosingIndentFix = closingLine.hasPrefix(");")
    let closingIndentPrefix = needsClosingIndentFix ? baseIndent : ""

        let entry = "\(entryIndent)\(phaseID) /* [SDM] Generate Dependencies */,\n\(closingIndentPrefix)"
    updated.insert(contentsOf: entry, at: closingLineRange.lowerBound)
    return updated
}

func findAppTargets(objects: [String: Any]) -> [(id: String, obj: [String: Any])] {
    var result: [(String, [String: Any])] = []
    for (key, value) in objects {
        guard let dict = value as? [String: Any] else { continue }
        guard dict["isa"] as? String == "PBXNativeTarget" else { continue }
        let productType = dict["productType"] as? String
        if productType == "com.apple.product-type.application" {
            result.append((key, dict))
        }
    }
    return result
}

func targetDisplayName(_ target: [String: Any]) -> String {
    if let name = target["name"] as? String, !name.isEmpty { return name }
    if let name = target["productName"] as? String, !name.isEmpty { return name }
    return "(unknown)"
}

func injectRunScriptBuildPhase(
    pbxprojPath: String,
    targetName: String?,
    preferredTargetName: String?,
    scriptPathRelativeToSRCROOT: String,
    force: Bool
) throws {
    let root = try loadPBXProjJSON(pbxprojPath: pbxprojPath)
    guard let objects = root["objects"] as? [String: Any] else {
        throw MiniAppCLIError.commandFailed("pbxproj missing objects")
    }

    let appTargets = findAppTargets(objects: objects)
    let selected: (id: String, obj: [String: Any])

    if let targetName {
        guard let match = appTargets.first(where: { targetDisplayName($0.obj) == targetName }) else {
            let available = appTargets.map { targetDisplayName($0.obj) }.joined(separator: ", ")
            throw MiniAppCLIError.invalidArguments("Target not found: \(targetName). Available app targets: [\(available)]")
        }
        selected = match
    } else {
        if appTargets.count == 1 {
            selected = appTargets[0]
        } else if let preferredTargetName,
                  let match = appTargets.first(where: { targetDisplayName($0.obj) == preferredTargetName }) {
            selected = match
        } else {
            let available = appTargets.map { targetDisplayName($0.obj) }.joined(separator: ", ")
            if let preferredTargetName {
                throw MiniAppCLIError.invalidArguments("Multiple app targets found; couldn't auto-select target named '\(preferredTargetName)'. Pass --target. Available: [\(available)]")
            }
            throw MiniAppCLIError.invalidArguments("Multiple app targets found; pass --target. Available: [\(available)]")
        }
    }

    var content = try String(contentsOfFile: pbxprojPath, encoding: .utf8)
    let markerName = "[SDM] Generate Dependencies"
    if content.contains(markerName) {
        if !force {
            Logger.info("Run Script build phase already present; skipping")
            return
        }
        content = removeExistingPhaseEntries(from: content)
    }

    let phaseID = generateObjectID()
    content = try insertShellScriptPhaseBlock(content, phaseID: phaseID, scriptPathRelativeToSRCROOT: scriptPathRelativeToSRCROOT)
    content = try insertPhaseReference(content, phaseID: phaseID, targetID: selected.id)

    try content.write(to: URL(fileURLWithPath: pbxprojPath), atomically: true, encoding: .utf8)
    Logger.info("Injected Run Script build phase into target: \(targetDisplayName(selected.obj))")
}

func handleInstall(_ options: InstallOptions) throws {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)

    let xcodeprojURL: URL
    if let projectPath = options.projectPath {
        xcodeprojURL = URL(fileURLWithPath: projectPath)
    } else {
        let found = findXcodeprojs(in: cwd)
        let filtered = found.filter { $0.lastPathComponent.lowercased() != "pods.xcodeproj" }
        let candidates = filtered.isEmpty ? found : filtered

        if candidates.isEmpty {
            throw MiniAppCLIError.fileNotFound("No .xcodeproj found. Pass --project <path/to/App.xcodeproj>.")
        }

        if candidates.count == 1 {
            xcodeprojURL = candidates[0]
        } else {
            let listed = candidates
                .map { $0.path }
                .sorted()
                .joined(separator: ", ")
            throw MiniAppCLIError.invalidArguments("Multiple .xcodeproj found; pass --project. Candidates: [\(listed)]")
        }
    }

    guard xcodeprojURL.pathExtension == "xcodeproj" else {
        throw MiniAppCLIError.invalidArguments("--project must point to a .xcodeproj")
    }

    let projectDir = xcodeprojURL.deletingLastPathComponent()
    let pbxprojURL = xcodeprojURL.appendingPathComponent("project.pbxproj")

    guard FileManager.default.fileExists(atPath: pbxprojURL.path) else {
        throw MiniAppCLIError.fileNotFound("project.pbxproj not found at \(pbxprojURL.path)")
    }

    let scriptURL = try installGeneratorScript(into: projectDir, force: options.force)
    let relScriptPath = "Scripts/\(scriptURL.lastPathComponent)"

    let inferredTargetName = xcodeprojURL.deletingPathExtension().lastPathComponent

    try injectRunScriptBuildPhase(
        pbxprojPath: pbxprojURL.path,
        targetName: options.targetName,
        preferredTargetName: inferredTargetName,
        scriptPathRelativeToSRCROOT: relScriptPath,
        force: options.force
    )

    Logger.info("Install completed")
}

func main() throws {
    let args = CommandLine.arguments

    if args.count <= 1 {
        printUsage()
        return
    }

    if args.contains("-h") || args.contains("--help") {
        printUsage()
        return
    }

    if args.count == 2 && args[1] == "--version" {
        printVersion()
        return
    }

    // Expected: miniapp host sdk install ...
    guard args.count >= 4 else {
        throw MiniAppCLIError.invalidArguments("Invalid command. See --help.")
    }

    if args[1] == "host", args[2] == "sdk", args[3] == "install" {
        let options = try parseInstallOptions(args.dropFirst(4))
        try handleInstall(options)
        return
    }

    throw MiniAppCLIError.invalidArguments("Unknown command. See --help.")
}

do {
    try main()
} catch {
    Logger.error(error.localizedDescription)
    exit(1)
}
