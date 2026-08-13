---
description: "Pick skill_save vs specs/documents vs save_memory at end of ACS work"
name: "choose-knowledge-store"
proposed_by: "unknown"
scope_paths: ["lib/acs/memory", "priv/prompts", "lib/acs/mcp"]
status: "approved"
tags: ["skills", "documents", "memory", "specs", "guidance"]
when_to_use: "Before release_work when deciding whether to skill_save, specs_propose a document/spec, or save_memory"
audit_reasoning: "The skill is exceptionally well-structured and actionable. It provides a clear, numbered decision tree for a coding agent to choose the correct knowledge store. Prerequisites, verification, and failure recovery are all present. The description is distinct and informative. Tool references (skill_save, specs_propose, documents_propose, save_memory) and their parameters are concrete and appropriate for a coding audience. The scope_path is correctly implied by the tool calls. It is not a duplicate of existing skills, which handle ingestion, not the routing decision."
audit_score: 10
audit_status: "ok"
audited_at: "2026-07-31T07:46:00.199888Z"
approved_at: "2026-07-31T07:46:00.228320Z"
approved_by: "llm"
reviewed_at: "2026-07-31T07:46:00.228320Z"
reviewed_by: "llm"
---

## When to use
At the end of any coding or chat ACS task, before `release_work`, decide which knowledge store to write.

## Prerequisites
- Claimed ACS task
- Audience known (coding → `specs_propose` for docs; chat → `documents_propose`)

## Steps
1. Ask: did I follow a **repeatable multi-step procedure** another agent should re-run?
   - Yes → `skill_save` with numbered steps, prerequisites, verification, failure recovery.
   - Examples: deploy, secrets, MCP sequences, debug playbooks, ingest, review, support flows.
2. Else: did I produce or ingest a **long shareable artifact** (policy, brief, research, marketing, knowledge write-up)?
   - Coding → `specs_propose(app, path: "documents/<type>/<slug>", document_type:, title:, content:)`
   - Chat → `documents_propose(...)` (same fields). Prefer `skill_get(name: "ingest-document")` first.
3. Else: did a **code module's intent** change?
   - → `specs_propose` with purpose / invariants / workflows (or `document_type: "spec"`).
4. Else: is it a **short eternal truth**?
   - → `save_memory(kind, title, content, scope_path)` — read memory_protocol first.
5. Else: does a memory with the **same title/scope already exist** (from `ask`/`query_memories`), or did `save_memory` reject the save as a duplicate?
   - → `update_memory` — resolve by `memory_id`, or by `title` + `scope_path`; replace only the provided fields; ledger keeps provenance. No create fallback — new truths go through `save_memory`.
6. Pick **one** primary store. Do not dump the same content into all four.
7. Then: unlock → `release_work` → `submit_task_feedback` last.

## Verification
- Saved entry is findable via `skill_get` / `query_specs` / `ask` / `query_memories` as appropriate.
- Claim packets show complete `instructions_claim.md` text (no mid-sentence cut).

## Failure recovery
- If intake returns `needs_input`: fix content (add steps / remove secrets) and retry once.
- If unsure between skill and document: skill needs ordered steps an agent follows; document is prose to keep/share.
