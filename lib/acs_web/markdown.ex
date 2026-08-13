defmodule AcsWeb.Markdown do
  @moduledoc """
  Renders markdown content as sanitized HTML for display in the ACS web UI.

  Uses Earmark for parsing and the MarkdownHTML scrubber from
  html_sanitize_ex so agent-produced content cannot inject raw HTML.
  Returns `{:safe, html}` tuples suitable for direct interpolation in HEEx.
  """

  @doc """
  Render markdown to a safe-HTML tuple. Returns `{:safe, ""}` for nil/blank input.

  Uses Earmark for parsing and `HtmlSanitizeEx.basic_html/1` to strip script
  tags and event handlers, since the MarkdownHTML scrubber intentionally
  preserves raw HTML code blocks (an XSS vector for agent-produced content).
  """
  def render(nil), do: {:safe, ""}
  def render(content) when is_binary(content) and content == "", do: {:safe, ""}

  def render(content) when is_binary(content) do
    html =
      content
      |> Earmark.as_html!(earmark_options())
      |> HtmlSanitizeEx.basic_html()

    {:safe, html}
  end

  defp earmark_options do
    %Earmark.Options{
      smartypants: false,
      escape: true,
      pure_links: true
    }
  end
end
