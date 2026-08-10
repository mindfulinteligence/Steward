defmodule Acs.Specs.Entry do
  @moduledoc """
  A specs entry — shareable knowledge stored for agents and humans.

  Two modes:

  1. **Module spec** (`document_type` nil or `"spec"`) — structured documentation
     about code: purpose, invariants, workflows, failure modes, constraints.

  2. **Document** (`document_type` set) — any long-form artifact the user or agent
     produced and wants to share: knowledge files, project documents, marketing copy
     (text + image references in markdown), deliverables, policies, guides.

  Use `content` for the full markdown body on documents. Use `source` for origin
  (file path, URL, asset folder).

  Status lifecycle:
    proposed → approved → deprecated
         ↓
      rejected

  Audit-only states such as under_review, contradicted, runtime_divergent, and
  historical may describe a document without being primary governance stages.

  Verification status per-spec confidence:
    confirmed | inferred | proposed | contested | unknown
  """

  defstruct [
    # string — app name (e.g., "my_app") — per-app isolation
    :app,
    # string — authenticated repository provenance
    :repo,
    # string — authenticated writer origin (coding_agent/chat_agent/system)
    :origin,
    # string — "engine/orchestrator" (unique within app scope)
    :id,
    # string — see status lifecycle above
    :status,
    # string — human-readable label
    :title,
    # string — why this module exists
    :purpose,
    # list(string) — truths that must always hold
    :invariants,
    # list(string) — expected call sequences/protocols
    :workflows,
    # list(string) — known failure scenarios
    :failure_modes,
    # map or nil — formal state definitions
    :state_machine,
    # list(string) — non-goals, tradeoffs, limits
    :constraints,
    # string — expected input to the module
    :input,
    # string — expected output from the module
    :output,
    # string — what transformation happens
    :expected_transformation,
    # list(string) — categorization
    :tags,
    # list(map) — semantic graph edges, each with type, target, description
    :references,
    # string — confidence level (see above)
    :verification_status,
    # integer — semantic version starting at 1
    :version,
    # integer — previous version for lineage
    :parent_version,
    # string — SHA-256 of canonical content excluding metadata
    :spec_hash,
    # string — agent name
    :proposed_by,
    # string — user name
    :approved_by,
    # string — ISO 8601
    :created_at,
    # string — ISO 8601
    :updated_at,
    # string — "policy"|"process"|"guideline"|"reference"|"spec" (nil = legacy spec)
    :document_type,
    # string — markdown body for document-type entries
    :content,
    # string — team scope (ABAC)
    :team,
    # string — project scope (ABAC)
    :project,
    # string — "team"|"project"|"org" (ABAC, default "org")
    :visibility,
    # integer — data authority clearance stamped from the writer (1 = highest);
    # nil = ungated. Read: item_order >= viewer_order. Edit: item_order > viewer_order.
    :authority_sort_order,
    # string — origin of the document (file path, URL, etc.)
    :source,
    # string — agent currently editing (presence signal, not a lock)
    :editing_by,
    # string — ISO 8601 when editing started
    :editing_since,
    # string — SHA-256 of content for last-write-wins conflict detection
    :content_hash,
    # string — LLM audit recommendation: approve | reject | human_review
    :audit_verdict,
    # string — ISO 8601 when LLM audit ran
    :audited_at,
    # string — brief LLM audit reasoning
    :audit_reasoning,
    # integer — LLM quality score 1-5
    :quality_score
  ]

  @type t :: %__MODULE__{
          app: String.t() | nil,
          repo: String.t() | nil,
          origin: String.t() | nil,
          id: String.t() | nil,
          status: String.t() | nil,
          title: String.t() | nil,
          purpose: String.t() | nil,
          invariants: [String.t()] | nil,
          workflows: [String.t()] | nil,
          failure_modes: [String.t()] | nil,
          state_machine: map() | nil,
          constraints: [String.t()] | nil,
          input: String.t() | nil,
          output: String.t() | nil,
          expected_transformation: String.t() | nil,
          tags: [String.t()] | nil,
          references: [map()] | nil,
          verification_status: String.t() | nil,
          version: integer() | nil,
          parent_version: integer() | nil,
          spec_hash: String.t() | nil,
          proposed_by: String.t() | nil,
          approved_by: String.t() | nil,
          created_at: String.t() | nil,
          updated_at: String.t() | nil,
          document_type: String.t() | nil,
          content: String.t() | nil,
          team: String.t() | nil,
          project: String.t() | nil,
          visibility: String.t() | nil,
          authority_sort_order: integer() | nil,
          source: String.t() | nil,
          editing_by: String.t() | nil,
          editing_since: String.t() | nil,
          content_hash: String.t() | nil,
          audit_verdict: String.t() | nil,
          audited_at: String.t() | nil,
          audit_reasoning: String.t() | nil,
          quality_score: integer() | nil
        }

  @valid_statuses Acs.Governance.Status.primary_statuses() ++
                    ~w(under_review contradicted runtime_divergent historical)
  @valid_verification_statuses ~w(confirmed inferred proposed contested unknown)

  @doc """
  Create a new Entry from a map. Sets defaults for nil fields.
  - status defaults to "proposed"
  - version defaults to 1
  - parent_version defaults to 0
  - Lists default to []
  """
  def from_map(map) when is_map(map) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    struct(__MODULE__, %{
      app: map["app"],
      repo: map["repo"],
      origin: map["origin"],
      id: map["id"],
      status: map["status"] || "proposed",
      title: map["title"],
      purpose: map["purpose"],
      invariants: map["invariants"] || [],
      workflows: map["workflows"] || [],
      failure_modes: map["failure_modes"] || [],
      state_machine: map["state_machine"],
      constraints: map["constraints"] || [],
      input: map["input"],
      output: map["output"],
      expected_transformation: map["expected_transformation"],
      tags: map["tags"] || [],
      references: map["references"] || [],
      verification_status: map["verification_status"],
      version: map["version"] || 1,
      parent_version: map["parent_version"] || 0,
      spec_hash: map["spec_hash"],
      proposed_by: map["proposed_by"],
      approved_by: map["approved_by"],
      created_at: map["created_at"] || now,
      updated_at: now,
      document_type: map["document_type"],
      content: map["content"],
      team: map["team"],
      project: map["project"],
      visibility: map["visibility"] || "org",
      authority_sort_order: map["authority_sort_order"],
      source: map["source"],
      editing_by: map["editing_by"],
      editing_since: map["editing_since"],
      content_hash: map["content_hash"],
      audit_verdict: map["audit_verdict"],
      audited_at: map["audited_at"],
      audit_reasoning: map["audit_reasoning"],
      quality_score: map["quality_score"]
    })
  end

  @doc """
  Convert to a plain map for YAML serialization.
  Excludes nil fields and empty lists.
  """
  def to_map(%__MODULE__{} = entry) do
    %{
      "app" => entry.app,
      "repo" => entry.repo,
      "origin" => entry.origin,
      "id" => entry.id,
      "status" => entry.status,
      "title" => entry.title,
      "purpose" => entry.purpose,
      "invariants" => entry.invariants,
      "workflows" => entry.workflows,
      "failure_modes" => entry.failure_modes,
      "state_machine" => entry.state_machine,
      "constraints" => entry.constraints,
      "input" => entry.input,
      "output" => entry.output,
      "expected_transformation" => entry.expected_transformation,
      "tags" => entry.tags,
      "references" => entry.references,
      "verification_status" => entry.verification_status,
      "version" => entry.version,
      "parent_version" => entry.parent_version,
      "spec_hash" => entry.spec_hash,
      "proposed_by" => entry.proposed_by,
      "approved_by" => entry.approved_by,
      "created_at" => entry.created_at,
      "updated_at" => entry.updated_at,
      "document_type" => entry.document_type,
      "content" => entry.content,
      "team" => entry.team,
      "project" => entry.project,
      "visibility" => entry.visibility,
      "authority_sort_order" => entry.authority_sort_order,
      "source" => entry.source,
      "editing_by" => entry.editing_by,
      "editing_since" => entry.editing_since,
      "content_hash" => entry.content_hash,
      "audit_verdict" => entry.audit_verdict,
      "audited_at" => entry.audited_at,
      "audit_reasoning" => entry.audit_reasoning,
      "quality_score" => entry.quality_score
    }
    |> remove_nils()
    |> remove_empty_lists()
  end

  @valid_document_types ~w(
    spec knowledge project marketing deliverable
    policy process guideline reference
  )

  def valid_document_types, do: @valid_document_types

  @doc """
  Validate an Entry struct.
  Returns :ok or {:error, [reason_strings]}.

  Dual-mode validation:
  - Module spec mode (document_type nil): requires purpose, invariants, workflows, failure_modes
  - Document mode (document_type present): requires document_type, title, content (any length)
  """
  def validate(%__MODULE__{} = entry) do
    if entry.document_type do
      validate_document(entry)
    else
      validate_spec(entry)
    end
  end

  defp validate_document(entry) do
    errors = []

    errors =
      if is_nil(entry.app) or entry.app == "", do: ["app is required"] ++ errors, else: errors

    errors = if is_nil(entry.id) or entry.id == "", do: ["id is required"] ++ errors, else: errors

    errors =
      if is_nil(entry.title) or entry.title == "",
        do: ["title is required"] ++ errors,
        else: errors

    errors =
      if entry.document_type not in @valid_document_types do
        [
          "invalid document_type: #{entry.document_type}. Must be one of: #{Enum.join(@valid_document_types, ", ")}"
        ] ++ errors
      else
        errors
      end

    errors =
      if is_nil(entry.content) or entry.content == "" do
        ["content is required for documents"] ++ errors
      else
        errors
      end

    if errors == [], do: :ok, else: {:error, Enum.reverse(errors)}
  end

  defp validate_spec(entry) do
    errors = []

    errors =
      if is_nil(entry.app) or entry.app == "", do: ["app is required"] ++ errors, else: errors

    errors = if is_nil(entry.id) or entry.id == "", do: ["id is required"] ++ errors, else: errors

    errors =
      if entry.status && entry.status not in @valid_statuses do
        ["invalid status: #{entry.status}. Must be one of: #{Enum.join(@valid_statuses, ", ")}"] ++
          errors
      else
        errors
      end

    errors =
      if entry.verification_status &&
           entry.verification_status not in @valid_verification_statuses do
        [
          "invalid verification_status: #{entry.verification_status}. Must be one of: #{Enum.join(@valid_verification_statuses, ", ")}"
        ] ++ errors
      else
        errors
      end

    errors =
      if entry.references do
        ref_errors =
          entry.references
          |> Enum.with_index()
          |> Enum.reduce([], fn {ref, i}, acc ->
            ref_errors = []

            ref_errors =
              if is_nil(ref["type"]),
                do: ["references[#{i}]: missing type"] ++ ref_errors,
                else: ref_errors

            ref_errors =
              if is_nil(ref["target"]),
                do: ["references[#{i}]: missing target"] ++ ref_errors,
                else: ref_errors

            ref_errors ++ acc
          end)

        errors ++ ref_errors
      else
        errors
      end

    errors =
      if is_integer(entry.version) and entry.version < 1 do
        ["version must be >= 1, got: #{entry.version}"] ++ errors
      else
        errors
      end

    # Presence checks
    errors =
      if is_nil(entry.title) or entry.title == "",
        do: ["title is required"] ++ errors,
        else: errors

    errors =
      if is_nil(entry.purpose) or entry.purpose == "",
        do: ["purpose is required"] ++ errors,
        else: errors

    errors =
      if is_nil(entry.invariants) or entry.invariants == [],
        do: ["invariants must have at least one entry"] ++ errors,
        else: errors

    errors =
      if is_nil(entry.workflows) or entry.workflows == [],
        do: ["workflows must have at least one entry"] ++ errors,
        else: errors

    errors =
      if is_nil(entry.failure_modes) or entry.failure_modes == [],
        do: ["failure_modes must have at least one entry"] ++ errors,
        else: errors

    # Quality checks
    errors =
      if entry.title && String.length(entry.title) < 10 do
        ["title must be at least 10 characters, got: #{String.length(entry.title)}"] ++ errors
      else
        errors
      end

    errors =
      if entry.title && generic_title?(entry.title) do
        ["title must be meaningful (not just 'X module' or generic description)"] ++ errors
      else
        errors
      end

    errors =
      if entry.purpose && String.length(entry.purpose) < 20 do
        ["purpose must be at least 20 characters, got: #{String.length(entry.purpose)}"] ++ errors
      else
        errors
      end

    errors =
      if entry.purpose && generic_purpose?(entry.purpose) do
        ["purpose must describe WHY the module exists (not just 'Module for X')"] ++ errors
      else
        errors
      end

    errors =
      if entry.invariants do
        inv_errors =
          entry.invariants
          |> Enum.with_index()
          |> Enum.reduce([], fn {inv, i}, acc ->
            inv_errors = []

            inv_errors =
              if not is_binary(inv) do
                ["invariants[#{i}] must be a string, got: #{inspect(inv)}"]
              else
                inv_errors =
                  if String.length(inv) < 15,
                    do:
                      [
                        "invariants[#{i}] must be at least 15 characters, got: #{String.length(inv)}"
                      ] ++ inv_errors,
                    else: inv_errors

                inv_errors =
                  if generic_invariant?(inv),
                    do:
                      ["invariants[#{i}] must be meaningful (not generic like 'module exists')"] ++
                        inv_errors,
                    else: inv_errors

                inv_errors
              end

            inv_errors ++ acc
          end)

        errors ++ inv_errors
      else
        errors
      end

    errors =
      if entry.workflows do
        wf_errors =
          entry.workflows
          |> Enum.with_index()
          |> Enum.reduce([], fn {wf, i}, acc ->
            wf_errors = []

            wf_errors =
              if not is_binary(wf) do
                ["workflows[#{i}] must be a string, got: #{inspect(wf)}"]
              else
                wf_errors =
                  if String.length(wf) < 20,
                    do:
                      [
                        "workflows[#{i}] must be at least 20 characters, got: #{String.length(wf)}"
                      ] ++ wf_errors,
                    else: wf_errors

                wf_errors
              end

            wf_errors ++ acc
          end)

        errors ++ wf_errors
      else
        errors
      end

    errors =
      if entry.failure_modes do
        fm_errors =
          entry.failure_modes
          |> Enum.with_index()
          |> Enum.reduce([], fn {fm, i}, acc ->
            fm_errors = []

            fm_errors =
              if not is_binary(fm) do
                ["failure_modes[#{i}] must be a string, got: #{inspect(fm)}"]
              else
                fm_errors =
                  if String.length(fm) < 20,
                    do:
                      [
                        "failure_modes[#{i}] must be at least 20 characters, got: #{String.length(fm)}"
                      ] ++ fm_errors,
                    else: fm_errors

                fm_errors =
                  if generic_failure_mode?(fm),
                    do:
                      [
                        "failure_modes[#{i}] must describe a real failure scenario (not generic like 'may fail')"
                      ] ++ fm_errors,
                    else: fm_errors

                fm_errors
              end

            fm_errors ++ acc
          end)

        errors ++ fm_errors
      else
        errors
      end

    if errors == [], do: :ok, else: {:error, Enum.reverse(errors)}
  end

  # Quality validation helpers

  defp generic_title?(title) do
    String.length(title) < 20 and
      (Regex.match?(~r/^[\w\s]+ module$/i, title) or
         Regex.match?(~r/^module for /i, title) or
         Regex.match?(~r/^[\w\s]+ component$/i, title))
  end

  defp generic_purpose?(purpose) do
    String.length(purpose) < 30 and
      (Regex.match?(~r/^module for /i, purpose) or
         Regex.match?(~r/^[\w\s]+ module$/i, purpose) or
         (Regex.match?(~r/^provides? /i, purpose) and String.length(purpose) < 40))
  end

  defp generic_invariant?(invariant) when is_binary(invariant) do
    String.length(invariant) < 25 and
      (Regex.match?(~r/^module (exists|loaded|initialized)$/i, invariant) or
         Regex.match?(~r/^[\w\s]+ exists$/i, invariant) or
         Regex.match?(~r/^[\w\s]+ is (loaded|initialized|valid)$/i, invariant))
  end

  defp generic_invariant?(_), do: false

  defp generic_failure_mode?(failure_mode) when is_binary(failure_mode) do
    String.length(failure_mode) < 30 and
      (Regex.match?(~r/^may fail$/i, failure_mode) or
         Regex.match?(~r/^(can|could) fail$/i, failure_mode) or
         (Regex.match?(~r/^[\w\s]+ (fails|failure|error)$/i, failure_mode) and
            String.length(failure_mode) < 40))
  end

  defp generic_failure_mode?(_), do: false

  @doc """
  Compute SHA-256 hash of canonical content (excludes metadata fields).
  Canonical content includes: purpose, invariants, workflows, failure_modes, 
  state_machine, constraints, tags, references (sorted).
  """
  def compute_spec_hash(%__MODULE__{} = entry) do
    canonical =
      %{
        purpose: entry.purpose || "",
        invariants: (entry.invariants || []) |> Enum.sort(),
        workflows: (entry.workflows || []) |> Enum.sort(),
        failure_modes: (entry.failure_modes || []) |> Enum.sort(),
        state_machine: entry.state_machine || %{},
        constraints: (entry.constraints || []) |> Enum.sort(),
        input: entry.input || "",
        output: entry.output || "",
        expected_transformation: entry.expected_transformation || "",
        tags: (entry.tags || []) |> Enum.sort(),
        references: (entry.references || []) |> Enum.sort_by(& &1["target"])
      }
      |> :erlang.term_to_binary()

    :crypto.hash(:sha256, canonical) |> Base.encode16(case: :lower)
  end

  @doc """
  Generate a file path for a spec given app and module path.
  e.g., app="my_app", path="engine/orchestrator" → "my_app/engine/orchestrator.yaml".
  The app name is arbitrary and serves as a namespace for per-app configuration isolation.
  """
  def spec_filename(app, path) do
    Path.join([app, "#{path}.yaml"])
  end

  defp remove_nils(map) do
    Enum.reject(map, fn {_k, v} -> is_nil(v) end) |> Map.new()
  end

  defp remove_empty_lists(map) do
    Enum.reject(map, fn {_k, v} -> is_list(v) and v == [] end) |> Map.new()
  end
end
