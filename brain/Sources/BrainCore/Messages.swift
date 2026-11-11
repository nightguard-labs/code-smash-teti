import Foundation

// BrainCore: the one shared language every organ and server speaks.
// Every message type is defined once, here, so all parts always agree on its shape.

public enum Role: String, Codable, Sendable { case system, user, assistant, tool }

public struct BrainMessage: Codable, Sendable, Equatable {
    public var role: Role
    public var content: String
    public init(role: Role, content: String) { self.role = role; self.content = content }
}

/// A request to think/generate. `project` ties it to a Si working-memory journal.
public struct GenerateRequest: Codable, Sendable {
    public var messages: [BrainMessage]
    public var maxTokens: Int
    public var temperature: Float
    public var think: Bool
    public var project: String?
    public init(messages: [BrainMessage], maxTokens: Int = 4096, temperature: Float = 0.3,
                think: Bool = false, project: String? = nil) {
        self.messages = messages; self.maxTokens = maxTokens; self.temperature = temperature
        self.think = think; self.project = project
    }
}

public struct GenerateStats: Codable, Sendable {
    public var promptTokens: Int
    public var generatedTokens: Int
    public var promptTokensPerSecond: Double
    public var tokensPerSecond: Double
    public var seconds: Double
    /// prompt tokens it didn't have to read again (remembered from an earlier request)
    public var reusedPromptTokens: Int = 0
    public init(promptTokens: Int, generatedTokens: Int, promptTokensPerSecond: Double,
                tokensPerSecond: Double, seconds: Double, reusedPromptTokens: Int = 0) {
        self.promptTokens = promptTokens; self.generatedTokens = generatedTokens
        self.promptTokensPerSecond = promptTokensPerSecond; self.tokensPerSecond = tokensPerSecond
        self.seconds = seconds; self.reusedPromptTokens = reusedPromptTokens
    }
    enum CodingKeys: String, CodingKey { case promptTokens, generatedTokens, promptTokensPerSecond, tokensPerSecond, seconds, reusedPromptTokens }
    /// Tolerant: older brain servers don't send newer fields.
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        promptTokens = try c.decodeIfPresent(Int.self, forKey: .promptTokens) ?? 0
        generatedTokens = try c.decodeIfPresent(Int.self, forKey: .generatedTokens) ?? 0
        promptTokensPerSecond = try c.decodeIfPresent(Double.self, forKey: .promptTokensPerSecond) ?? 0
        tokensPerSecond = try c.decodeIfPresent(Double.self, forKey: .tokensPerSecond) ?? 0
        seconds = try c.decodeIfPresent(Double.self, forKey: .seconds) ?? 0
        reusedPromptTokens = try c.decodeIfPresent(Int.self, forKey: .reusedPromptTokens) ?? 0
    }
}

/// What flows back out of the engine, token by token.
public enum BrainEvent: Codable, Sendable {
    case token(String)
    case done(GenerateStats)
    case failure(String)
}

/// Where everything lives. Internal SSD only (owner decision 11/05).
public enum BrainPaths {
    public static let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("local-ai/brain-lab")
    public static let models = root.appendingPathComponent("models")
    public static let memory = root.appendingPathComponent("memory")
    public static let run = root.appendingPathComponent("run")
    public static let logs = root.appendingPathComponent("logs")
    public static let socket = run.appendingPathComponent("brain.sock")
    public static let morals = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("local-ai/morals.md")
}

/// Ports. The edge speaks Ollama's API so chat apps and other tools can call the brain.
public enum BrainPorts {
    public static let edgeHTTP: UInt16 = 11450
}
