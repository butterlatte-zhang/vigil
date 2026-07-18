"""A minimal Vigil MCP server (stdio) — the probe for DOCTRINE §10 step1 ②.

Exposes ONE tool, `spawn`, standing in for Vigil's real structural tool. When
claude actually invokes it (the open question: does claude reliably CALL the tool
given a skill, vs just describe it in prose?), we log the structured call to a
file — un-fakeable proof the MCP transport carried a real function call, not a
scraped marker (unlike C2). It then BLOCKS for VIGIL_MCP_BLOCK seconds (the §10
②c question: can an MCP tool response be held for human-gate latency, like the
perm hook's 70s?), then returns a child node id the manager must use.

Run by claude as a stdio MCP subprocess (configured via --mcp-config).
"""
import os, json, time
from mcp.server.fastmcp import FastMCP

LOG = os.environ["VIGIL_MCP_LOG"]
BLOCK = float(os.environ.get("VIGIL_MCP_BLOCK", "0"))

mcp = FastMCP("vigil")


@mcp.tool()
def spawn(role: str, task: str) -> str:
    """Delegate a subtask to a new child worker node. You MUST call this tool to
    create a child; do not do the subtask yourself. Returns the new child node id."""
    with open(LOG, "a") as f:
        f.write(json.dumps({"phase": "received", "t": time.time(),
                            "role": role, "task": task}) + "\n")
    time.sleep(BLOCK)                      # simulate the human gate deciding
    with open(LOG, "a") as f:
        f.write(json.dumps({"phase": "returned", "t": time.time(),
                            "block": BLOCK, "child": "node-7"}) + "\n")
    return "node-7"


if __name__ == "__main__":
    mcp.run()   # stdio transport
