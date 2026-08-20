defmodule AcsWeb.DocsController do
  use AcsWeb, :controller

  @pages [
    {"overview", "Start here", "guides/getting-started.md"},
    {"install", "Install", "priv/skills/steward-installer.md"},
    {"configuration", "Configuration", "guides/secrets.md"},
    {"development", "Development", "guides/development-workflow.md"},
    {"deployment", "Deployment", "guides/deployment.md"},
    {"testing", "Testing", "guides/deployment-testing.md"},
    {"technical", "Technical reference", "README.md"}
  ]

  @root Path.expand("../../..", __DIR__)
  for {_, _, path} <- @pages do
    @external_resource Path.join(@root, path)
  end

  @documents Map.new(@pages, fn {slug, title, path} ->
               {slug, {title, File.read!(Path.join(@root, path))}}
             end)

  def show(conn, %{"page" => page}) when is_map_key(@documents, page) do
    {title, markdown} = @documents[page]

    render(conn, :show,
      page_title: "#{title} · Steward Docs",
      title: title,
      active_page: page,
      pages: @pages,
      content: markdown |> rewrite_links() |> AcsWeb.Markdown.render()
    )
  end

  def show(conn, _params), do: redirect(conn, to: ~p"/docs/overview")

  defp rewrite_links(markdown) do
    Regex.replace(~r{\]\((?:\.\./)?guides/([^)]+)\.md\)}, markdown, "](/docs/\\1)")
  end
end
