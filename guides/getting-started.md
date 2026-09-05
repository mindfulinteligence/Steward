# Set up Steward for your team

Steward is shared memory and coordination for AI agents. Humans use the dashboard to manage the workspace; coding and chat agents connect through MCP to find knowledge, claim work, avoid file conflicts, and save what they learn.

You do not need to understand or modify Steward's source code to use it.

## Choose your setup

### Join an existing hosted workspace

1. Open the invitation link and sign in.
2. Open your organization dashboard and expand **Agent URLs**.
3. Click **Copy project setup prompt**.
4. Open a coding agent at the root of your project and paste the prompt.
5. Review the proposed MCP and instruction-file changes, then restart or reconnect the agent.
6. Complete browser OAuth and ask the agent to call `get_started(audience: "coding")`.

The copied prompt contains your exact organization URL and complete Steward instructions. It tells the agent to merge with existing configuration, not overwrite it.

### Create a hosted workspace

1. Go to [Steward](https://stewardacs.xyz/) and sign in.
2. Create your organization and invite teammates from **Settings → Members**.
3. Open **Agent URLs** and use the copy buttons for each agent you want to connect.

### Run Steward yourself

Follow the [self-hosted installation guide](/docs/install). It covers Docker, secrets, database choices, optional AI providers, startup, and verification.

Belong to more than one organization? The sign-in page and the dashboard's user menu both remember every organization and email you've previously signed into on that browser and offer a one-click **Switch organization** link back into each — no need to track down each organization's URL or re-enter credentials by hand.

## URLs you will use

Replace `<workspace-host>` with the hostname shown in **Agent URLs**. For example, the Anantha workspace host is `anantha.stewardacs.xyz`.

| Purpose | URL |
|---|---|
| Public website | `https://stewardacs.xyz/` |
| Public documentation | `https://stewardacs.xyz/docs/overview` |
| Workspace dashboard | `https://<workspace-host>/` |
| Coding-agent MCP | `https://<workspace-host>/mcp/sse` |
| Chat-agent MCP | `https://<workspace-host>/mcp/chat/sse` |
| Prompts | `https://<workspace-host>/settings/prompts` |
| Members and invitations | `https://<workspace-host>/settings/members` |
| Shared documents and specs | `https://<workspace-host>/documents` |
| Shared skills | `https://<workspace-host>/skills` |

Use `/mcp/sse` as the OAuth API identifier even when the chat connector URL is `/mcp/chat/sse`. Do not use the older `/mcp/coding/sse` alias in new configurations.

## Connect a coding agent manually

The dashboard-generated setup prompt is the safest option because it includes the correct workspace URL and current instructions. If you must configure a client manually, add a server named `steward`.

Codex (`.codex/config.toml`):

```toml
[mcp_servers.steward]
url = "https://<workspace-host>/mcp/sse"
```

Cursor (`.cursor/mcp.json`):

```json
{
  "mcpServers": {
    "steward": {
      "type": "http",
      "url": "https://<workspace-host>/mcp/sse"
    }
  }
}
```

Hosted connections use browser OAuth, so do not add an API key header. A private local installation uses the API key generated during installation.

Next, copy the coding instructions from **Agent URLs** into `AGENTS_STEWARD.md` at the repository root. Ensure the root `AGENTS.md` includes:

```md
Check if `@AGENTS_STEWARD.md` exists. If yes, follow the instructions there.
```

Keep existing project instructions. Do not replace `AGENTS.md` or an existing MCP configuration wholesale.

## Connect a chat agent

1. In **Agent URLs**, copy `https://<workspace-host>/mcp/chat/sse`.
2. Add it as a custom MCP connector in the chat product.
3. Complete browser OAuth.
4. Copy the chat system prompt from **Agent URLs** into that agent's system instructions.
5. Ask the agent to find a known document or skill to verify access.

Chat agents receive a smaller tool set for reading shared knowledge and saving approved information. Coding agents receive task and file-lock tools because they change repositories.

## What the agent instructions must enforce

Use the dashboard's copy-ready prompt as the source of truth. At minimum, every coding agent must:

1. Call `get_started` when entering Steward work.
2. Create or claim a task before doing work.
3. Confirm the repository and lock each file before editing it.
4. Read relevant skills and specs before changing their scope.
5. Run a meaningful verification check.
6. Save durable output in the correct store: memory, spec, document, or skill.
7. Release work and submit task feedback before declaring completion.

Humans still decide priorities, approve scope changes, review sensitive information, and control deployment. Connecting Steward does not grant an agent authority it did not already have.

## Verify the setup

Ask a coding agent:

> Connect to Steward, call `get_started` for a coding audience, and tell me the connected organization and your assigned agent ID. Do not change any files.

A working connection returns the signed-in identity, repository guidance, and Steward tools. Then ask it to create and release a small test task if you want to verify write access.

For a chat agent, ask it to search for a known workspace document. It should identify the organization and return only information allowed by your access level.

## Troubleshooting

- **No Steward tools appear:** restart or reconnect the client after adding the MCP server.
- **A browser did not open:** remove the stale connection and add it again to restart OAuth.
- **401 or expired login:** reconnect and complete OAuth again.
- **Service not found:** confirm the URL is your organization host and ends in `/mcp/sse` or `/mcp/chat/sse`.
- **Duplicate tools:** both a local and hosted Steward server are enabled; disable the one you are not using.
- **The agent wants to overwrite project files:** stop and tell it to merge the Steward entries into the existing files.
- **Wrong organization or missing knowledge:** verify the workspace hostname and the account used during OAuth.

## Next steps

- [Install a private instance](/docs/install)
- [Configure secrets and providers](/docs/configuration)
- [Operate a deployment](/docs/deployment)
- [Read the technical reference](/docs/technical)
