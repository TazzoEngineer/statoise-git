import Foundation

enum ExternalDiffLauncher {
    static func launch(tool: String, oldFile: String, newFile: String) {
        if tool.hasSuffix(".app") {
            let appName = ((tool as NSString).lastPathComponent as NSString).deletingPathExtension
            let executable = (tool as NSString).appendingPathComponent("Contents/MacOS/\(appName)")

            if FileManager.default.isExecutableFile(atPath: executable) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = [oldFile, newFile]
                try? process.run()
            } else {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                process.arguments = ["-a", tool, "--args", oldFile, newFile]
                try? process.run()
            }
        } else {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = [oldFile, newFile]
            try? process.run()
        }
    }
}
