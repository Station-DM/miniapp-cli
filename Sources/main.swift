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

    Notes:
      - This command injects a Run Script build phase into an iOS app target to generate miniapp-deps.json at build time.
      - The CLI is designed to be installed via Homebrew and available on PATH.
    """
    print(text)
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

func findXcodeproj(in directory: URL) -> URL? {
    guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
        return nil
    }

    for case let url as URL in enumerator {
        if url.pathExtension == "xcodeproj" {
            return url
        }
    }

    return nil
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
    let jsonData = try runProcess("/usr/bin/plutil", ["-convert", "json", "-o", "-", pbxprojPath])
    let obj = try JSONSerialization.jsonObject(with: jsonData)
    guard let dict = obj as? [String: Any] else {
        throw MiniAppCLIError.commandFailed("pbxproj json is not a dictionary")
    }
    return dict
}

func writePBXProjJSON(_ json: [String: Any], to pbxprojPath: String) throws {
    let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    let tmpJSON = tmpDir.appendingPathComponent("miniapp-pbxproj.json")

    let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: tmpJSON)

    _ = try runProcess("/usr/bin/plutil", ["-convert", "openstep", "-o", pbxprojPath, tmpJSON.path])
}

func generateObjectID() -> String {
    let bytes = (0..<12).map { _ in UInt8.random(in: 0...255) }
    return bytes.map { String(format: "%02X", $0) }.joined()
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
    scriptPathRelativeToSRCROOT: String,
    force: Bool
) throws {
    var root = try loadPBXProjJSON(pbxprojPath: pbxprojPath)
    guard var objects = root["objects"] as? [String: Any] else {
        throw MiniAppCLIError.commandFailed("pbxproj missing objects")
    }

    // Idempotency: if already contains the phase name, skip unless force.
    let markerName = "[SDM] Generate Dependencies"
    if !force {
        for (_, value) in objects {
            guard let dict = value as? [String: Any] else { continue }
            if dict["isa"] as? String == "PBXShellScriptBuildPhase", dict["name"] as? String == markerName {
                Logger.info("Run Script build phase already present; skipping")
                return
            }
        }
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
        guard appTargets.count == 1 else {
            let available = appTargets.map { targetDisplayName($0.obj) }.joined(separator: ", ")
            throw MiniAppCLIError.invalidArguments("Multiple app targets found; pass --target. Available: [\(available)]")
        }
        selected = appTargets[0]
    }

    var targetObj = selected.obj
    guard var buildPhases = targetObj["buildPhases"] as? [Any] else {
        throw MiniAppCLIError.commandFailed("Target buildPhases missing")
    }

    let phaseID = generateObjectID()
    let shellScript = "\"$SRCROOT/\(scriptPathRelativeToSRCROOT)\"\n"

    let phaseObj: [String: Any] = [
        "isa": "PBXShellScriptBuildPhase",
        "buildActionMask": 2147483647,
        "files": [],
        "inputPaths": [],
        "outputPaths": [],
        "name": markerName,
        "runOnlyForDeploymentPostprocessing": 0,
        "shellPath": "/bin/sh",
        "shellScript": shellScript,
        "showEnvVarsInLog": 0
    ]

    objects[phaseID] = phaseObj
    buildPhases.append(phaseID)
    targetObj["buildPhases"] = buildPhases
    objects[selected.id] = targetObj
    root["objects"] = objects

    try writePBXProjJSON(root, to: pbxprojPath)
    Logger.info("Injected Run Script build phase into target: \(targetDisplayName(selected.obj))")
}

func handleInstall(_ options: InstallOptions) throws {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)

    let xcodeprojURL: URL
    if let projectPath = options.projectPath {
        xcodeprojURL = URL(fileURLWithPath: projectPath)
    } else if let found = findXcodeproj(in: cwd) {
        xcodeprojURL = found
    } else {
        throw MiniAppCLIError.fileNotFound("No .xcodeproj found. Pass --project <path/to/App.xcodeproj>.")
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

    try injectRunScriptBuildPhase(
        pbxprojPath: pbxprojURL.path,
        targetName: options.targetName,
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
