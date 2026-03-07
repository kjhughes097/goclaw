package mcp

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	mcpgo "github.com/mark3labs/mcp-go/mcp"
	"github.com/nextlevelbuilder/goclaw/internal/tools"
)

// ToolNames returns all registered MCP tool names.
func (m *Manager) ToolNames() []string {
	m.mu.RLock()
	defer m.mu.RUnlock()

	var names []string
	for _, ss := range m.servers {
		names = append(names, ss.toolNames...)
	}
	return names
}

// ServerToolNames returns tool names for a specific server.
func (m *Manager) ServerToolNames(serverName string) []string {
	m.mu.RLock()
	defer m.mu.RUnlock()

	if ss, ok := m.servers[serverName]; ok {
		return append([]string(nil), ss.toolNames...)
	}
	return nil
}

// updateMCPGroup rebuilds the "mcp" group with all MCP tool names across servers.
// Must be called with m.mu NOT held (it acquires RLock).
func (m *Manager) updateMCPGroup() {
	allNames := m.ToolNames()
	if len(allNames) > 0 {
		tools.RegisterToolGroup("mcp", allNames)
	} else {
		tools.UnregisterToolGroup("mcp")
	}
}

// unregisterAllTools removes all MCP tools from the registry.
func (m *Manager) unregisterAllTools() {
	m.mu.Lock()
	defer m.mu.Unlock()

	for name, ss := range m.servers {
		if ss.cancel != nil {
			ss.cancel()
		}
		if ss.client != nil {
			_ = ss.client.Close()
		}
		for _, toolName := range ss.toolNames {
			m.registry.Unregister(toolName)
		}
		tools.UnregisterToolGroup("mcp:" + name)
		slog.Debug("mcp.server.unregistered", "server", name, "tools", len(ss.toolNames))
	}
	m.servers = make(map[string]*serverState)
	tools.UnregisterToolGroup("mcp")
}

// ToolInfo holds a tool's name and description for API responses.
type ToolInfo struct {
	Name        string `json:"name"`
	Description string `json:"description,omitempty"`
}

// DiscoverTools connects temporarily to an MCP server, lists its tools, and disconnects.
// Used for on-demand discovery when no persistent Manager connection exists (DB-backed servers).
func DiscoverTools(ctx context.Context, transportType, command string, args []string, env map[string]string, url string, headers map[string]string) ([]ToolInfo, error) {
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()

	client, err := createClient(transportType, command, args, env, url, headers)
	if err != nil {
		return nil, fmt.Errorf("create client: %w", err)
	}
	defer client.Close()

	if transportType != "stdio" {
		if err := client.Start(ctx); err != nil {
			return nil, fmt.Errorf("start transport: %w", err)
		}
	}

	initReq := mcpgo.InitializeRequest{}
	initReq.Params.ProtocolVersion = mcpgo.LATEST_PROTOCOL_VERSION
	initReq.Params.ClientInfo = mcpgo.Implementation{Name: "goclaw-discovery", Version: "1.0.0"}
	if _, err := client.Initialize(ctx, initReq); err != nil {
		return nil, fmt.Errorf("initialize: %w", err)
	}

	toolsResult, err := client.ListTools(ctx, mcpgo.ListToolsRequest{})
	if err != nil {
		return nil, fmt.Errorf("list tools: %w", err)
	}

	result := make([]ToolInfo, 0, len(toolsResult.Tools))
	for _, t := range toolsResult.Tools {
		result = append(result, ToolInfo{Name: t.Name, Description: t.Description})
	}
	return result, nil
}

// filterTools removes tools from the registry that don't match the allow/deny lists.
func (m *Manager) filterTools(serverName string, allow, deny []string) {
	m.mu.Lock()
	defer m.mu.Unlock()

	ss, ok := m.servers[serverName]
	if !ok {
		return
	}

	allowSet := toSet(allow)
	denySet := toSet(deny)

	var kept []string
	for _, toolName := range ss.toolNames {
		bt, ok := m.registry.Get(toolName)
		if !ok {
			continue
		}
		bridge, ok := bt.(*BridgeTool)
		if !ok {
			kept = append(kept, toolName)
			continue
		}
		origName := bridge.OriginalName()

		// Deny takes priority
		if _, denied := denySet[origName]; denied {
			m.registry.Unregister(toolName)
			continue
		}

		// If allow list is set, only keep tools in the allow list
		if len(allowSet) > 0 {
			if _, allowed := allowSet[origName]; !allowed {
				m.registry.Unregister(toolName)
				continue
			}
		}

		kept = append(kept, toolName)
	}
	ss.toolNames = kept
}
