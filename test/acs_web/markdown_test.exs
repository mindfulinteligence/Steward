defmodule AcsWeb.MarkdownTest do
  use ExUnit.Case, async: true

  alias AcsWeb.Markdown

  describe "render/1" do
    test "returns empty safe tuple for nil and blank" do
      assert Markdown.render(nil) == {:safe, ""}
      assert Markdown.render("") == {:safe, ""}
    end

    test "renders headings, emphasis, inline code, and lists" do
      {:safe, html} =
        Markdown.render("# Title\n\nSome **bold** and `code`.\n\n- one\n- two")

      assert html =~ "<h1>"
      assert html =~ "<strong>bold</strong>"
      assert html =~ "<code>code</code>"
      assert html =~ "<li>"
    end

    test "strips script tags and event handlers" do
      {:safe, html} =
        Markdown.render("<script>alert(1)</script>\n\n<img src=x onerror=\"alert(2)\">")

      refute html =~ "<script"
      refute html =~ "onerror"
    end
  end
end
