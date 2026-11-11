import AgentPlugin

// The plugin's module and concrete type share a name; resolve its state type without
// introducing ambiguity with the source-compatible host model.
typealias SharedAgentRunState = AgentRunState
