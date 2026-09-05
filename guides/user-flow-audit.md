# User-flow audit

## Objective

Make Steward's primary journey—sign in, establish a workspace, connect an agent, monitor work, and govern agent output—smooth, convenient, logical, and trustworthy.

This audit is based on a static review of the Phoenix router, authentication and tenant handoff, account landing, onboarding, invitations, shared layout, dashboard, and workspace LiveViews.

## Ideal journey

```text
Landing, deep link, or invitation
  → Context-aware sign-in (destination preserved)
  → Account resolution
      ├─ invitation → review boundary → accept
      ├─ no organization → create organization → provisioning
      └─ ready organization → secure tenant handoff
  → first-run dashboard
      → configure MCP → verify tools → start first task
  → active dashboard
      → monitor agents, tasks, and locks
  → review queues
      → inspect → approve/reject with appropriate authorization
  → recoverable error states
      → explanation → retry / return to workspace / sign out
```

## What already works well

- Account, tenant, and administrator routes are separated clearly.
- Return paths are validated and tenant sessions use a dedicated handoff.
- Onboarding has a useful three-step progress rail, derived identifiers, inline validation, and distinct pending, failed, and ready states.
- Invitations require an explicit decision and clearly show organization, email, role, and expiration.
- Organization administration uses labels, descriptions, confirmations, and understandable role guidance.
- The design system is cohesive, provides visible status language, and respects reduced-motion preferences.
- Workspace pages update through PubSub and consistently provide at least a basic empty state.

## Prioritized findings

### P0 — Protect trust and data

1. **Workspace reset was exposed as a prominent dashboard action to every member.** The server event did not check the user's role. A browser confirmation alone is not an authorization boundary.
   - **Implemented:** the control is now visible only to owners/admins, moved below operational content, given explicit scope/copy, and independently authorized in the event handler.
   - **Next:** move the action to a dedicated Settings danger zone, require typing the organization name, and write an audit event.

2. **Governance mutations need an explicit permission model.** Tool-request approvals, memory/spec/skill decisions, and error-trace mutations currently sit in the normal member route group. Bulk approval is especially consequential.
   - **Recommendation:** introduce reviewer/admin capabilities in both routing and event handlers; attribute decisions to the authenticated user; confirm bulk changes; collect reasons for rejection/deprecation/resolution.

### P1 — Remove flow breaks

3. **The first successful workspace visit was an activation cliff.** A new user saw three passive empty panels and the most prominent available action was destructive.
   - **Implemented:** the dashboard now establishes page purpose and presents a three-step first-run path: configure MCP, verify tools, and start work. Filtered task emptiness identifies the active filter and offers a one-click reset.
   - **Next:** provide a copyable tenant-specific MCP URL, connection health, and a link to exact client configuration instructions.

4. **Memory review filtering was misleading.** “All” and “Proposed” could resolve to the same data; the supposed all-view excluded lifecycle states; quarantine had a count but no discoverable filter; filter state was not reliably represented in the URL.
   - **Implemented:** Pending and All are distinct, All removes the status restriction, Quarantined is visible, supported query views map consistently, and filter changes update a shareable URL.

5. **Backend failures often masquerade as empty data.** Organization, invitation, spec, and member-loading errors can be normalized into `nil`, invalid, or an empty list, producing incorrect “create,” “invalid link,” or “no records” messages.
   - **Recommendation:** model `loading | loaded | empty | error` explicitly, retain last-known data, and provide contextual retry actions. Organization creation must remain blocked until account lookup succeeds.

6. **Invitation account mismatch is a dead end.** The page identifies the required email but does not provide a “sign out and continue as invited email” action that preserves the invitation URL.
   - **Partially implemented:** a general cross-organization account switcher shipped — the user menu and sign-in page now remember every org/email combination previously signed into on this browser (via a long-lived, `HttpOnly` cookie shared across tenant subdomains) and offer one-click links back into each. This gives most users a fast way to reach the account an invitation names.
   - **Next:** the invitation-mismatch page itself still does not surface this switcher or preserve the invitation URL through a sign-out/reauthentication round trip — wire the two together so mismatched invitations resolve without the user having to re-find the link.

7. **Wrong-workspace and stale-permission paths render raw 404/403 text.** These states provide no route back into the designed journey.
   - **Recommendation:** render privacy-safe branded recovery pages with “Open my workspace,” “Account desk,” and “Sign out.” Preserve the intended path when reauthentication could resolve it.

8. **Authentication destination context is under-explained.** The sign-in page is generic even when a protected deep link or invitation initiated the flow.
   - **Recommendation:** state why sign-in is required and where the user will return. Ensure account-only destinations such as onboarding are never replayed on a tenant host for existing members.

### P1 — Accessibility and responsive use

9. **Several core rows are clickable `<div>` elements.** Tool groups/rows and memory/spec/skill rows cannot be reliably reached or activated from a keyboard and do not expose expanded state.
   - **Recommendation:** use buttons or links with `aria-expanded`/`aria-controls`, Enter/Space behavior, and URL-backed selection where useful.

10. **Search fields depend on placeholders and suppress outlines.** Memory, specs, and skills search should have accessible names and visible focus.
    - **Recommendation:** add labels or `aria-label`, restore `:focus-visible`, and debounce search input.

11. **Fixed detail panes and flat top navigation do not scale down well.** Governance panes use fixed 420–480 px widths; mobile retains a hidden-scrollbar row of all destinations.
    - **Recommendation:** use full-width drawers/detail routes at narrow widths, group navigation into Operate / Review / Admin, and provide a clear overflow menu.

### P2 — Clarity and efficiency

12. **Navigation gives every module equal weight.** Only tool requests expose pending work; memory/spec/skill review and error queues remain invisible.
    - **Recommendation:** add aggregate review counts, use “Tool requests” rather than “Requests,” add page-specific titles and one `<h1>` per page, and group destinations by user intent.

13. **Selection and filters are often ephemeral.** Reloading, sharing, or using Back loses the selected record and active view on most modules.
    - **Recommendation:** make list filters and record selection URL-addressable.

14. **Tool health checks block initial rendering and collapse user context.** The tool page can wait several seconds for bridge checks and refreshes collapse groups.
    - **Recommendation:** render registry data first, run health asynchronously, show Checking/Healthy/Unreachable/Internal text, and preserve expansion state.

15. **Mutation feedback and filtered empty states are inconsistent.** Some operations have no success message; several errors expose raw backend reasons; empty states do not always distinguish first use from a filter with zero matches.
    - **Recommendation:** standardize loading/error/empty/filtered-empty components, translate technical errors into actionable copy, and include retry or clear-filter actions.

## Suggested delivery order

1. Finish authorization boundaries for every governance mutation.
2. Model loading and error states separately from empty states.
3. Complete first-run setup with a copyable endpoint and connection verification.
4. Repair invitation account switching and branded permission recovery.
5. Convert clickable rows to semantic, URL-backed interactions.
6. Group navigation and build responsive detail patterns.
7. Standardize feedback, page titles, and review counts.

## Success measures

- New workspace owners reach a connected first agent without external help.
- Existing users always return to their intended valid tenant destination after authentication.
- No destructive or governance mutation can be triggered by an unauthorized role, including crafted LiveView events.
- Loading failures are never reported as valid empty states.
- Every primary interaction is usable by keyboard and at a 320 px viewport.
- Filters and selected review records survive refresh and browser navigation.
