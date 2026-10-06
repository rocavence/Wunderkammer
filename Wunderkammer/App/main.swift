import AppKit

// Started by an AI assistant: speak MCP on stdio and pass calls to the app.
if CommandLine.arguments.contains("--mcp") { MCPServer.run() }

let app = NSApplication.shared
// Unit tests load the app as their host; don't open windows or the library then.
if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
} else {
    app.run()
}
