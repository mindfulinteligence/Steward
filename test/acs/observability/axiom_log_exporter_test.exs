defmodule Acs.Observability.AxiomLogExporterTest do
  use ExUnit.Case, async: false

  alias Acs.Observability.AxiomLogBackend
  alias Acs.Observability.AxiomLogExporter

  test "normalizes an allowlisted, trace-correlated Logger event" do
    event =
      AxiomLogBackend.to_event(
        :warning,
        ["slow ", "request"],
        {{2026, 7, 22}, {12, 34, 56, 789}},
        module: AcsWeb.Endpoint,
        agent_id: "agent-1",
        task_id: "task-1",
        trace_id: "0123456789abcdef0123456789abcdef",
        span_id: "0123456789abcdef",
        password: "must-not-ship"
      )

    assert event["message"] == "slow request"
    assert event["severity"] == "WARNING"
    assert event["level"] == "warning"
    assert event["module"] == "AcsWeb.Endpoint"
    assert event["agent_id"] == "agent-1"
    assert event["task_id"] == "task-1"
    assert event["trace_id"] == "0123456789abcdef0123456789abcdef"
    assert event["span_id"] == "0123456789abcdef"
    assert event["_time"] == "2026-07-22T12:34:56.789Z"
    refute Map.has_key?(event, "password")
  end

  test "redacts nested sensitive metadata and preserves valid UTF-8 when truncating" do
    long_message = String.duplicate("a", 16_382) <> "💥"

    event =
      AxiomLogBackend.to_event(:info, long_message, nil,
        module: Acs.Example,
        params: %{
          password: "secret",
          nested: %{api_key: "key", safe: "value"},
          deep: %{one: %{two: %{three: %{token: "deep-secret"}}}},
          struct: %URI{userinfo: "struct-secret"},
          tuple: {:token, "tuple-secret"}
        }
      )

    assert event["params"]["password"] == "[REDACTED]"
    assert event["params"]["nested"]["api_key"] == "[REDACTED]"
    assert event["params"]["nested"]["safe"] == "value"
    assert event["params"]["deep"]["one"]["two"]["three"] == "[TRUNCATED]"
    assert event["params"]["struct"] == "[STRUCT]"
    assert event["params"]["tuple"] == "[UNSUPPORTED]"

    encoded = Jason.encode!(event)
    refute encoded =~ "deep-secret"
    refute encoded =~ "struct-secret"
    refute encoded =~ "tuple-secret"
    assert String.valid?(event["message"])
    assert byte_size(event["message"]) <= 16_384
    assert {:ok, _json} = Jason.encode(event)
  end

  test "redacts URL query and database URL attributes before OTLP export" do
    attributes =
      :otel_attributes.new(
        %{
          :"url.query" => "api_key=secret",
          :"db.url" => "postgres://user:password@example.test/database",
          :"http.request.method" => "GET"
        },
        10,
        1_000
      )

    redacted =
      Acs.Observability.RedactingBatchSpanProcessor.redact_sensitive_attributes(attributes)
      |> :otel_attributes.map()

    assert redacted[:"url.query"] == "[REDACTED]"
    assert redacted[:"db.url"] == "[REDACTED]"
    assert redacted[:"http.request.method"] == "GET"
  end

  test "Logger backend forwards legacy Logger events without doing network I/O itself" do
    test_pid = self()

    start_supervised!(
      {AxiomLogExporter,
       token: "test-token",
       dataset: "steward-acs",
       domain: "https://api.axiom.co",
       batch_size: 1,
       flush_interval_ms: 60_000,
       request_fun: fn request ->
         send(test_pid, {:backend_request, request})
         {:ok, %{status: 200}}
       end,
       attach_backend: false}
    )

    event =
      {:info, self(),
       {Logger, "from Logger", {{2026, 7, 22}, {12, 0, 0, 0}},
        [module: Acs.Example, trace_id: "trace-1"]}}

    assert {:ok, %{}} = AxiomLogBackend.handle_event(event, %{})
    assert_receive {:backend_request, request}

    assert %{"message" => "from Logger", "trace_id" => "trace-1"} =
             request.body |> String.trim() |> Jason.decode!()
  end

  test "flushes a threshold batch as newline-delimited JSON" do
    test_pid = self()
    name = unique_name()

    request_fun = fn request ->
      send(test_pid, {:axiom_request, request})
      {:ok, %{status: 200}}
    end

    start_supervised!(
      {AxiomLogExporter,
       name: name,
       token: "test-token",
       dataset: "logs/prod",
       domain: "https://api.axiom.co/",
       batch_size: 2,
       flush_interval_ms: 60_000,
       request_fun: request_fun,
       attach_backend: false}
    )

    AxiomLogExporter.enqueue(%{"message" => "one"}, name)
    AxiomLogExporter.enqueue(%{"message" => "two"}, name)

    assert_receive {:axiom_request, request}
    assert request.url == "https://api.axiom.co/v1/ingest/logs%2Fprod"
    assert request.token == "test-token"
    assert String.ends_with?(request.body, "\n")

    assert request.body
           |> String.split("\n", trim: true)
           |> Enum.map(&Jason.decode!/1) == [
             %{"message" => "one"},
             %{"message" => "two"}
           ]
  end

  test "explicit flush drains multiple payload-sized batches" do
    test_pid = self()
    name = unique_name()

    start_supervised!(
      {AxiomLogExporter,
       name: name,
       token: "status-redaction-token",
       dataset: "steward-acs",
       domain: "https://api.axiom.co",
       batch_size: 10,
       max_batch_bytes: 35,
       flush_interval_ms: 60_000,
       request_fun: fn request ->
         send(test_pid, {:drain_request, request.body})
         {:ok, %{status: 200}}
       end,
       attach_backend: false}
    )

    for message <- ["first-event", "second-event", "third-event"] do
      assert :ok = AxiomLogExporter.enqueue(%{"message" => message}, name)
    end

    refute inspect(:sys.get_status(:global.whereis_name(elem(name, 1)))) =~
             "status-redaction-token"

    assert :ok = AxiomLogExporter.flush(name)
    assert_receive {:drain_request, _}
    assert_receive {:drain_request, _}
    assert_receive {:drain_request, _}
  end

  test "bounds admission while an HTTP request is stalled" do
    test_pid = self()
    name = unique_name()
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    request_fun = fn _request ->
      attempt = Agent.get_and_update(attempts, fn count -> {count + 1, count + 1} end)

      if attempt == 1 do
        send(test_pid, {:request_started, self()})

        receive do
          :release_request -> {:ok, %{status: 200}}
        end
      else
        {:ok, %{status: 200}}
      end
    end

    start_supervised!(
      {AxiomLogExporter,
       name: name,
       token: "test-token",
       dataset: "steward-acs",
       domain: "https://api.axiom.co",
       batch_size: 1,
       max_buffer: 3,
       flush_interval_ms: 60_000,
       request_fun: request_fun,
       attach_backend: false,
       log_failures: false}
    )

    assert :ok = AxiomLogExporter.enqueue(%{"message" => "first"}, name)
    assert_receive {:request_started, exporter_pid}

    results =
      for number <- 1..10 do
        AxiomLogExporter.enqueue(%{"message" => "queued-#{number}"}, name)
      end

    assert Enum.count(results, &(&1 == :ok)) == 2
    assert Enum.count(results, &(&1 == :dropped)) == 8
    send(exporter_pid, :release_request)
  end

  test "retains a failed batch and retries it on an explicit flush" do
    test_pid = self()
    name = unique_name()
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    request_fun = fn request ->
      attempt = Agent.get_and_update(attempts, fn count -> {count + 1, count + 1} end)
      send(test_pid, {:axiom_attempt, attempt, request.body})

      if attempt == 1,
        do: {:error, :timeout},
        else: {:ok, %{status: 202}}
    end

    start_supervised!(
      {AxiomLogExporter,
       name: name,
       token: "test-token",
       dataset: "steward-acs",
       domain: "https://api.axiom.co",
       batch_size: 1,
       flush_interval_ms: 60_000,
       request_fun: request_fun,
       attach_backend: false,
       log_failures: false}
    )

    AxiomLogExporter.enqueue(%{"message" => "retry me"}, name)
    assert_receive {:axiom_attempt, 1, first_body}

    assert :ok = AxiomLogExporter.flush(name)
    assert_receive {:axiom_attempt, 2, second_body}
    assert second_body == first_body
  end

  defp unique_name, do: {:global, {__MODULE__, make_ref()}}
end
