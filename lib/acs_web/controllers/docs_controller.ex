defmodule AcsWeb.DocsController do
  use AcsWeb, :controller

  @pages [
    {"overview", "Start here"},
    {"install", "Connect"},
    {"configuration", "Configuration"},
    {"deployment", "Operate"},
    {"technical", "Architecture"}
  ]

  @documents %{
    "overview" => {
      "Start here",
      """
      # Steward

      Steward is a shared operating system for AI agents. It gives a team one place to connect agents, preserve decisions, coordinate work, and inspect what happened.

      ## Why teams use it

      - Keep organizational knowledge available across agents and projects.
      - Coordinate work without losing ownership or context.
      - Make agent activity auditable and easier to improve.

      ## How it fits

      Steward provides the service and data layer. Your coding or chat agent connects to it through the Model Context Protocol (MCP), while people use this site to understand the workspace and its status.
      """
    },
    "install" => {
      "Connect",
      """
      # Connect an agent

      Steward works with MCP-compatible agents. Add your Steward MCP endpoint to the agent you want to connect, then authenticate when prompted.

      ## Before you begin

      You need access to a Steward workspace and an MCP-compatible client. Ask your workspace administrator for the workspace URL and the appropriate access method.

      ## After connecting

      Your agent can use Steward to search shared knowledge, coordinate tasks, and record durable decisions. Start with a small request, then confirm that the agent can see the workspace resources you expect.
      """
    },
    "configuration" => {
      "Configuration",
      """
      # Configuration

      Steward workspaces can be configured for local development, a shared team environment, or a production deployment.

      ## Workspace access

      Access is scoped to the workspace and organization selected by your account. Keep production credentials in your deployment secret store and do not commit them to source control.

      ## Agent behavior

      Teams can decide which agents may read shared knowledge, create tasks, or update operational records. Use the narrowest access that supports the workflow.
      """
    },
    "deployment" => {
      "Operate",
      """
      # Operating Steward

      Steward is designed to run continuously for a team, with background maintenance and observability built into the service.

      ## Production changes

      Test changes before promoting them to production. Monitor deployment health, application errors, background work, and database activity after a release.

      ## Troubleshooting

      Start with the service health page and recent activity. Narrow the investigation to one organization, agent, or operation before inspecting database state. This keeps diagnosis fast and avoids waking an idle database unnecessarily.
      """
    },
    "technical" => {
      "Architecture",
      """
      # Architecture

      Steward is an Elixir and Phoenix application backed by PostgreSQL. Phoenix serves the web experience and MCP transport; background workers maintain knowledge, task, audit, and observability records.

      ## Data boundaries

      Organizations scope shared records. Agent operations are recorded with structured metadata so activity can be traced from a request to its resulting changes.

      ## Extensibility

      The service is organized around MCP tools, pluggable knowledge workflows, and structured events. This lets teams add capabilities without exposing internal operator procedures as public documentation.
      """
    }
  }

  def show(conn, %{"page" => page}) when is_map_key(@documents, page) do
    {title, markdown} = @documents[page]

    render(conn, :show,
      page_title: "#{title} · Steward Docs",
      title: title,
      active_page: page,
      pages: @pages,
      content: AcsWeb.Markdown.render(markdown)
    )
  end

  def show(conn, _params), do: redirect(conn, to: ~p"/docs/overview")
end
