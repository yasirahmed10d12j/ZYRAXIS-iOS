import Foundation

/// Input to an agent tool: decoded by each tool from JSON.
public struct ToolInput: Equatable, Sendable {
    public var rawJSON: String
    public init(rawJSON: String = "{}") { self.rawJSON = rawJSON }
}

/// Output of an agent tool run.
public struct ToolOutput: Equatable, Sendable {
    public var text: String
    public init(text: String) { self.text = text }
}

/// Risk tier for a tool. Phase 2 ships metadata only — no dangerous tools.
/// The backend executes tools server-side; iOS never grants device control.
public enum ToolRiskLevel: String, Codable, CaseIterable, Sendable {
    case readOnly
    case reversible
    case destructive

    public var displayName: String {
        switch self {
        case .readOnly: return "Read-only"
        case .reversible: return "Reversible"
        case .destructive: return "Destructive"
        }
    }
}

/// Single executable capability the assistant can invoke
/// (task creation, memory write, backend calls, ...).
public protocol AgentTool: Sendable {
    var name: String { get }
    var description: String { get }
    /// JSON Schema describing parameters. Default: no parameters.
    var parametersJSONSchema: String { get }
    var riskLevel: ToolRiskLevel { get }
    /// Whether the user must confirm before each execution.
    var requiresConfirmation: Bool { get }
    func execute(input: ToolInput) async throws -> ToolOutput
}

public extension AgentTool {
    var parametersJSONSchema: String { "{}" }
    var riskLevel: ToolRiskLevel { .readOnly }
    var requiresConfirmation: Bool { false }
}

/// Advertised tool metadata sent to the backend as available-tools context.
public struct ToolDescriptor: Codable, Equatable, Sendable {
    public var name: String
    public var description: String
    public var parametersJSONSchema: String
    public var riskLevel: ToolRiskLevel
    public var requiresConfirmation: Bool

    public init(tool: any AgentTool) {
        self.name = tool.name
        self.description = tool.description
        self.parametersJSONSchema = tool.parametersJSONSchema
        self.riskLevel = tool.riskLevel
        self.requiresConfirmation = tool.requiresConfirmation
    }
}

/// Registry routing model-requested `ToolCall`s to implementations.
///
/// UI -> AIService (produces ToolCall) -> ToolRegistry (executes) -> backend.
public protocol ToolRegistry: Sendable {
    func register(_ tool: any AgentTool) async
    func tool(named name: String) async -> (any AgentTool)?
    func allTools() async -> [any AgentTool]
    func descriptors() async -> [ToolDescriptor]
    func execute(call: ToolCall) async throws -> ToolOutput
}

public enum ToolError: LocalizedError, Equatable {
    case unknownTool(String)
    case executionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unknownTool(let n): return "Unknown tool: \(n)"
        case .executionFailed(let m): return "Tool failed: \(m)"
        }
    }
}

/// Default in-memory registry. Ships with zero tools unless seeded —
/// `AppDependencies` seeds the safe read-only `AppInfoTool` for E2E.
/// Dangerous tools must never be registered on this client.
public actor DefaultToolRegistry: ToolRegistry {

    private var tools: [String: any AgentTool] = [:]

    public init() {}

    /// Synchronous seed (actor init is sync): avoids an async registration
    /// race at app launch.
    public init(seed: [any AgentTool]) {
        for tool in seed { tools[tool.name] = tool }
    }

    public func register(_ tool: any AgentTool) async {
        tools[tool.name] = tool
    }

    public func tool(named name: String) async -> (any AgentTool)? {
        tools[name]
    }

    public func allTools() async -> [any AgentTool] {
        Array(tools.values)
    }

    public func descriptors() async -> [ToolDescriptor] {
        tools.values.map(ToolDescriptor.init(tool:))
    }

    public func execute(call: ToolCall) async throws -> ToolOutput {
        guard let tool = tools[call.toolName] else {
            throw ToolError.unknownTool(call.toolName)
        }
        do {
            return try await tool.execute(input: ToolInput(rawJSON: call.argumentsJSON))
        } catch let e as ToolError {
            throw e
        } catch {
            throw ToolError.executionFailed(error.localizedDescription)
        }
    }
}
