defmodule Acs.Observability.RedactingBatchSpanProcessor do
  @moduledoc false

  require Record

  @behaviour :otel_span_processor

  Record.defrecordp(
    :span,
    Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")
  )

  def start_link(config), do: :otel_batch_processor.start_link(config)

  @impl true
  def on_start(context, span_record, config) do
    :otel_batch_processor.on_start(context, span_record, config)
  end

  @impl true
  def on_end(span_record, config) do
    attributes = span(span_record, :attributes)
    sanitized_span = span(span_record, attributes: redact_sensitive_attributes(attributes))
    :otel_batch_processor.on_end(sanitized_span, config)
  end

  @impl true
  def force_flush(config), do: :otel_batch_processor.force_flush(config)

  @doc false
  def redact_sensitive_attributes(attributes) do
    attribute_map = :otel_attributes.map(attributes)

    Enum.reduce([:"url.query", "url.query", :"db.url", "db.url"], attributes, fn key, acc ->
      if Map.has_key?(attribute_map, key) do
        :otel_attributes.set(key, "[REDACTED]", acc)
      else
        acc
      end
    end)
  end
end
