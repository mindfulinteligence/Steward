defmodule AcsWeb.DocsController do
  use AcsWeb, :controller

  @pages [
    {"overview", "Start here"},
    {"install", "Connect"},
    {"configuration", "Configuration"},
    {"deployment", "Operate"},
    {"technical", "Architecture"}
  ]

  @external_resource Path.expand("../../../guides/getting-started.md", __DIR__)
  @external_resource Path.expand("../../../guides/steward-installer.md", __DIR__)
  @external_resource Path.expand("../../../guides/secrets.md", __DIR__)
  @external_resource Path.expand("../../../guides/deployment.md", __DIR__)
  @external_resource Path.expand("../../../README.md", __DIR__)

  @documents %{
    "overview" =>
      {"Start here", File.read!(Path.expand("../../../guides/getting-started.md", __DIR__))},
    "install" =>
      {"Connect", File.read!(Path.expand("../../../guides/steward-installer.md", __DIR__))},
    "configuration" =>
      {"Configuration", File.read!(Path.expand("../../../guides/secrets.md", __DIR__))},
    "deployment" =>
      {"Operate", File.read!(Path.expand("../../../guides/deployment.md", __DIR__))},
    "technical" => {"Architecture", File.read!(Path.expand("../../../README.md", __DIR__))}
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
