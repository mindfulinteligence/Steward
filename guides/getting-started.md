# Steward: a shared operating system for AI agents

Steward helps people coordinate AI agents that work on the same projects.

Without coordination, two agents can edit the same file, repeat the same investigation, or make decisions without telling the rest of the team. Steward gives them one shared place to declare work, avoid collisions, and preserve what they learn.

Steward does **not** replace your coding agent, chat assistant, repository, or project tracker. It connects to agents through MCP and adds a coordination layer around the tools you already use.

## What Steward does

| Need | Steward capability | Result |
|---|---|---|
| Know who is doing what | Tasks and agent presence | People and agents can see active work before starting something new. |
| Prevent conflicting edits | File locks | Agents avoid changing the same file at the same time. |
| Stop rediscovering decisions | Memories | Durable decisions, warnings, and patterns follow the team. |
| Keep code intent understandable | Specs | Agents see a module's purpose and invariants before changing it. |
| Reuse proven procedures | Skills | Installation, deployment, debugging, and support workflows become repeatable. |
| Keep long-form knowledge available | Documents | Plans, policies, briefs, and reference material remain searchable. |

## Who it is for

- A developer using more than one coding agent or editor.
- A team whose agents work across the same repositories.
- An organization that wants agent decisions and procedures to survive beyond one chat session.
- Operators who need to see active work, review shared knowledge, and control access by organization and role.

For one short, isolated agent task, Steward may be unnecessary. It becomes useful when work overlaps, repeats, or needs to be handed between people and agents.

## Set up Steward

Choose one of these paths:

1. **Use a hosted organization:** create or join an organization from the Steward sign-in page. Your organization gets an isolated workspace and MCP endpoint.
2. **Run Steward yourself:** follow the [installation guide](/docs/install). The default local setup uses Docker, SQLite, and no LLM provider.

Belong to more than one organization? The sign-in page and the dashboard's user menu both remember every organization and email you've previously signed into on that browser and offer a one-click **Switch organization** link back into each — no need to track down each organization's URL or re-enter credentials by hand.

After setup, open the Steward dashboard. It shows the MCP endpoint and copy-ready instructions for connecting chat and coding agents.

## Connect a coding agent

The exact settings screen differs by agent, but the flow is the same:

For an invited user, the shortest path is to accept the invitation, open the organization workspace, expand **Agent URLs**, and choose **Copy project setup prompt**. Paste it into a coding agent opened at the project root. The agent merges the organization MCP URL and Steward instructions into the project's existing configuration, then tells the user how to reconnect and complete OAuth.

1. In the Steward dashboard, copy the **coding MCP endpoint** and coding-agent instructions.
2. Add the endpoint as an MCP server in Codex, Cursor, Claude Code, OpenCode, or another MCP-compatible client.
3. Complete the browser sign-in when using a hosted organization. A local installation uses its configured API key instead.
4. Paste the coding-agent instructions into the repository's `AGENTS.md` or equivalent rules file.
5. Restart or reconnect the agent so it discovers the Steward tools.
6. Ask the agent to check Steward. A successful connection returns its identity, repository context, and current work guidance.

Example remote configuration:

```toml
[mcp_servers.steward]
url = "https://YOUR-STEWARD-HOST/mcp/sse"
```

Keep the generated repository instructions in version control when they contain no secrets. Keep API keys and local environment files out of version control.

## Connect a chat agent

Use the dashboard's **chat MCP endpoint** and chat instructions when connecting a conversational assistant such as Claude or ChatGPT.

Chat agents get a smaller, safer tool surface for finding knowledge, reading skills and documents, checking work status, and saving approved information. Coding agents additionally receive task and file-locking tools because they modify repositories.

## The normal agent workflow

Once connected, agents should follow this loop:

1. **Check context:** identify the repository and load relevant memories, specs, and skills.
2. **Claim work:** create or claim a task before making changes.
3. **Lock files:** reserve the files that will be edited.
4. **Do and verify the work:** change the project and run the smallest meaningful checks.
5. **Save reusable knowledge:** update a spec, skill, document, or memory when the work produced something future agents need.
6. **Release and report:** release the task and submit feedback so the next person or agent sees a clean state.

The human remains responsible for priorities, approvals, and decisions that change scope. Steward makes the agent's work visible; it does not grant agents authority they did not already have.

## How this helps a team

### Fewer collisions

Before editing, an agent can see that another agent already owns a task or file. The team spends less time resolving duplicate work and conflicting patches.

### Better handoffs

A task records the current unit of work. Specs explain why code exists. Memories preserve decisions and warnings. A different person or agent can continue without reconstructing the full history from chat transcripts.

### Consistent procedures

When a deployment, installation, or support workflow works, save it as a skill. Future agents retrieve the same verified steps instead of improvising a new procedure.

### Shared knowledge with boundaries

Organizations, teams, projects, roles, and authority levels control who can see or change shared information. Local ACS instances remain test-only; team knowledge belongs in the shared Steward organization.

### Human oversight

The dashboard shows active agents, tasks, memories, documents, skills, tool requests, and errors. Humans can review the operating context instead of relying on each agent to summarize itself accurately.

## A practical team rollout

1. Start with one repository and two or three people.
2. Add the Steward MCP connection and repository instructions to every agent used on that repository.
3. Require task claiming and file locking for all code changes.
4. Save only durable knowledge: decisions, invariants, warnings, and repeatable procedures.
5. Review memories, specs, and skills regularly; archive or correct anything stale.
6. Expand to more repositories after the workflow feels routine.

The goal is not to store every conversation. The goal is to keep the small amount of context that prevents the team from repeating mistakes.

## Next steps

- [Install Steward](/docs/install)
- [Review configuration and secrets](/docs/configuration)
- [Understand remote versus local development](/docs/development)
- [Deploy Steward](/docs/deployment)
- [Read the technical reference](/docs/technical)
