# AGENTS.md

Source of truth for engineering conventions in this repository.

## UI

### No explanation copy in the UI

Never add explanatory subtitles, helper text, footnotes, or instructional copy beneath
controls. A label or title stands alone. The toggle / segmented pill / row is self-describing
by what it controls; if it is not, the fix is to change the control, not to add a sentence
under it explaining what it does.

What this excludes:
- `Text(...)` underneath a `Toggle`, `Picker`, `SegmentedPills`, or any row that already has
  a label
- "Allow in System Settings…" hints below a switch
- "The tracker opens automatically…" restatements of the toggle's own effect
- `help(...)` tooltips on controls that are not requesting them

Why: the AppKit surfaces in this app render the same explanation copy every time the user
opens them, which turns one sentence into dozens over a session. The user knows what a
"Launch at login" toggle does. Trust the control.

If the explanation is genuinely required (e.g. an error state from a failed API call), the
explanation belongs in `AGENTS.md`, the codebase comments, or a doc — not in the UI.

The existing `PageHeader` already encodes this rule at the page-title level: "A title
stands alone — no explanatory subtitle underneath it." Apply it to every other surface too.