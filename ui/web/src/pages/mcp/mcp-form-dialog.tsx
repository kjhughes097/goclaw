import { useState, useEffect } from "react";
import { Loader2, CheckCircle2, XCircle } from "lucide-react";
import {
  Dialog,
  DialogContent,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Switch } from "@/components/ui/switch";
import { KeyValueEditor } from "@/components/shared/key-value-editor";
import type { MCPServerData, MCPServerInput } from "./hooks/use-mcp";
import { slugify, isValidSlug } from "@/lib/slug";

interface MCPFormDialogProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  server?: MCPServerData | null;
  onSubmit: (data: MCPServerInput) => Promise<unknown>;
  onTest: (data: { transport: string; command?: string; args?: string[]; url?: string; headers?: Record<string, string>; env?: Record<string, string> }) => Promise<{ success: boolean; tool_count?: number; error?: string }>;
}

const TRANSPORTS = [
  { value: "stdio", label: "stdio" },
  { value: "sse", label: "SSE" },
  { value: "streamable-http", label: "Streamable HTTP" },
];

export function MCPFormDialog({ open, onOpenChange, server, onSubmit, onTest }: MCPFormDialogProps) {
  const [name, setName] = useState("");
  const [displayName, setDisplayName] = useState("");
  const [transport, setTransport] = useState("stdio");
  const [command, setCommand] = useState("");
  const [args, setArgs] = useState("");
  const [url, setUrl] = useState("");
  const [headers, setHeaders] = useState<Record<string, string>>({});
  const [env, setEnv] = useState<Record<string, string>>({});
  const [toolPrefix, setToolPrefix] = useState("");
  const [timeout, setTimeout] = useState(60);
  const [enabled, setEnabled] = useState(true);
  const [loading, setLoading] = useState(false);
  const [testing, setTesting] = useState(false);
  const [testResult, setTestResult] = useState<{ success: boolean; tool_count?: number; error?: string } | null>(null);
  const [error, setError] = useState("");

  useEffect(() => {
    if (open) {
      setName(server?.name ?? "");
      setDisplayName(server?.display_name ?? "");
      setTransport(server?.transport ?? "stdio");
      setCommand(server?.command ?? "");
      setArgs(Array.isArray(server?.args) ? server.args.join(", ") : "");
      setUrl(server?.url ?? "");
      setHeaders(server?.headers ?? {});
      setEnv(server?.env ?? {});
      setToolPrefix((server?.tool_prefix ?? "").replace(/^mcp_/, ""));
      setTimeout(server?.timeout_sec ?? 60);
      setEnabled(server?.enabled ?? true);
      setError("");
      setTestResult(null);
    }
  }, [open, server]);

  const isStdio = transport === "stdio";

  const buildConnectionData = () => {
    const parsedArgs = isStdio && args.trim()
      ? args.split(",").map((a) => a.trim()).filter(Boolean)
      : undefined;
    const parsedHeaders = !isStdio && Object.keys(headers).length > 0 ? headers : undefined;
    const parsedEnv = Object.keys(env).length > 0 ? env : undefined;
    return {
      transport,
      command: isStdio ? command.trim() : undefined,
      args: parsedArgs,
      url: !isStdio ? url.trim() : undefined,
      headers: parsedHeaders,
      env: parsedEnv,
    };
  };

  const handleTest = async () => {
    if (isStdio && !command.trim()) {
      setError("Command is required for stdio transport");
      return;
    }
    if (!isStdio && !url.trim()) {
      setError("URL is required for SSE/HTTP transport");
      return;
    }

    setTesting(true);
    setError("");
    setTestResult(null);
    try {
      const result = await onTest(buildConnectionData());
      setTestResult(result);
    } catch (err: unknown) {
      setTestResult({ success: false, error: err instanceof Error ? err.message : "Connection failed" });
    } finally {
      setTesting(false);
    }
  };

  const handleSubmit = async () => {
    if (!name.trim() || !transport) {
      setError("Name and transport are required");
      return;
    }
    if (!isValidSlug(name.trim())) {
      setError("Name must be a valid slug (lowercase letters, numbers, hyphens only)");
      return;
    }
    if (isStdio && !command.trim()) {
      setError("Command is required for stdio transport");
      return;
    }
    if (!isStdio && !url.trim()) {
      setError("URL is required for SSE/HTTP transport");
      return;
    }

    setLoading(true);
    setError("");
    try {
      const conn = buildConnectionData();
      await onSubmit({
        name: name.trim(),
        display_name: displayName.trim() || undefined,
        ...conn,
        tool_prefix: toolPrefix.trim() || undefined,
        timeout_sec: timeout,
        enabled,
      });
      onOpenChange(false);
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : "Failed to save");
    } finally {
      setLoading(false);
    }
  };

  return (
    <Dialog open={open} onOpenChange={(v) => !loading && onOpenChange(v)}>
      <DialogContent className="max-h-[85vh] flex flex-col sm:max-w-xl">
        <DialogHeader>
          <DialogTitle>{server ? "Edit MCP Server" : "Add MCP Server"}</DialogTitle>
        </DialogHeader>

        <div className="grid gap-4 py-2 px-0.5 -mx-0.5 overflow-y-auto min-h-0">
          <div className="grid gap-1.5">
            <Label htmlFor="mcp-name">Name *</Label>
            <Input id="mcp-name" value={name} onChange={(e) => setName(slugify(e.target.value))} placeholder="my-mcp-server" />
            <p className="text-xs text-muted-foreground">Lowercase letters, numbers, and hyphens only</p>
          </div>

          <div className="grid gap-1.5">
            <Label htmlFor="mcp-display">Display Name</Label>
            <Input id="mcp-display" value={displayName} onChange={(e) => setDisplayName(e.target.value)} placeholder="My MCP Server" />
          </div>

          <div className="grid gap-1.5">
            <Label>Transport *</Label>
            <div className="flex gap-2">
              {TRANSPORTS.map((t) => (
                <Button
                  key={t.value}
                  type="button"
                  variant={transport === t.value ? "default" : "outline"}
                  size="sm"
                  onClick={() => setTransport(t.value)}
                >
                  {t.label}
                </Button>
              ))}
            </div>
          </div>

          {isStdio ? (
            <>
              <div className="grid gap-1.5">
                <Label htmlFor="mcp-cmd">Command *</Label>
                <Input id="mcp-cmd" value={command} onChange={(e) => setCommand(e.target.value)} placeholder="npx -y @modelcontextprotocol/server-everything" className="font-mono text-sm" />
              </div>
              <div className="grid gap-1.5">
                <Label htmlFor="mcp-args">Args (comma-separated)</Label>
                <Input id="mcp-args" value={args} onChange={(e) => setArgs(e.target.value)} placeholder="--flag1, --flag2" className="font-mono text-sm" />
              </div>
            </>
          ) : (
            <>
              <div className="grid gap-1.5">
                <Label htmlFor="mcp-url">URL *</Label>
                <Input id="mcp-url" value={url} onChange={(e) => setUrl(e.target.value)} placeholder="http://localhost:3001/sse" className="font-mono text-sm" />
              </div>
              <div className="grid gap-1.5">
                <Label>Headers</Label>
                <KeyValueEditor
                  value={headers}
                  onChange={setHeaders}
                  keyPlaceholder="Header name"
                  valuePlaceholder="Header value"
                  addLabel="Add Header"
                />
              </div>
            </>
          )}

          <div className="grid gap-1.5">
            <Label>Environment Variables</Label>
            <KeyValueEditor
              value={env}
              onChange={setEnv}
              keyPlaceholder="Variable name"
              valuePlaceholder="Value"
              addLabel="Add Variable"
            />
          </div>

          <div className="grid gap-1.5">
            <Label htmlFor="mcp-prefix">Tool Prefix</Label>
            <div className="flex">
              <span className="inline-flex items-center px-2.5 rounded-l-md border border-r-0 border-input bg-muted text-muted-foreground text-sm font-mono">mcp_</span>
              <Input id="mcp-prefix" value={toolPrefix} onChange={(e) => setToolPrefix(e.target.value.replace(/[^a-z0-9_]/g, ""))} placeholder={name.replace(/-/g, "_") || "auto"} className="rounded-l-none font-mono text-sm" />
            </div>
            <p className="text-xs text-muted-foreground">Auto-derived from name if empty. Tools: <code className="text-[10px]">mcp_&#123;prefix&#125;__&#123;tool&#125;</code></p>
          </div>

          <div className="grid gap-1.5">
            <Label htmlFor="mcp-timeout">Timeout (seconds)</Label>
            <Input id="mcp-timeout" type="number" value={timeout} onChange={(e) => setTimeout(Number(e.target.value))} min={1} />
          </div>

          <div className="flex items-center gap-2">
            <Switch id="mcp-enabled" checked={enabled} onCheckedChange={setEnabled} />
            <Label htmlFor="mcp-enabled">Enabled</Label>
          </div>
          {error && <p className="text-sm text-destructive">{error}</p>}
        </div>

        <DialogFooter className="flex-col sm:flex-row gap-2">
          <div className="flex items-center gap-2 mr-auto">
            <Button type="button" variant="secondary" size="sm" onClick={handleTest} disabled={loading || testing}>
              {testing ? <><Loader2 className="h-3.5 w-3.5 animate-spin mr-1" /> Testing...</> : "Test Connection"}
            </Button>
            {testResult && (
              <span className={`flex items-center gap-1 text-xs ${testResult.success ? "text-emerald-600 dark:text-emerald-400" : "text-destructive"}`}>
                {testResult.success ? (
                  <><CheckCircle2 className="h-3.5 w-3.5" /> {testResult.tool_count} tools found</>
                ) : (
                  <><XCircle className="h-3.5 w-3.5" /> {testResult.error}</>
                )}
              </span>
            )}
          </div>
          <div className="flex gap-2">
            <Button variant="outline" onClick={() => onOpenChange(false)} disabled={loading}>Cancel</Button>
            <Button onClick={handleSubmit} disabled={loading}>
              {loading ? "Saving..." : server ? "Update" : "Create"}
            </Button>
          </div>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
