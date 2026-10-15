# Warm up

The control center's **Warm Up** page holds one timetable for Claude Code, Codex and GLM 5.3.
A schedule is a wall-clock time, the weekdays it repeats on, and the clients it warms. The
background tracker owns all execution. An enabled schedule is all an automatic run needs, and
switching one off is how you stop it; `Warm up now` works with no schedule at all. There are no
schedules to begin with. Quota resets no longer trigger anything.

## Responsibilities

- `LLMUsagePreferences/WarmUp.swift`: schedules, per-client transport settings, run records
  and IPC. The control center writes configuration; the tracker alone writes runtime state.
- `LLMUsagePreferences/WarmUpTimetable.swift`: pure calendar math, shared so the control
  center can show the next run without asking the tracker.
- `WarmUpCoordinator`: one timer, one execution slot per client, cancellation, the persisted
  handled-occurrence watermark and restart recovery. It re-evaluates on configuration
  changes, timer expiry, system wake, time-zone changes and clock changes.
- `WarmUpExecutor`: the per-client extension point. Each client's transport builds its own
  isolated request and decides what counts as a completed turn. Executors never schedule
  themselves or write shared preferences.

To change how a client is warmed, change its executor. To change when, edit the timetable —
no code involved.

## Scheduling rules

Schedules follow the machine's current time zone and re-evaluate when it changes. Each
client runs at most once per occurrence, and the occurrence it last handled is persisted, so
a restart never repeats it. Recovery and timetable-edit state changes are saved immediately,
even when no occurrence is due. When several schedules select the same client at the same time,
one run covers them all, and an occurrence arriving while that client is still running is
absorbed rather than queued.

A fixed clock time is not enough on its own: whoever touches a client first opens its window,
so an occurrence can land inside a window the user opened. Open windows are handled below.

Nothing runs while the Mac sleeps, and a missed occurrence is not made up. Only a timer firing
within a minute of its occurrence still counts as on time; anything later is recorded as
`Missed` and dropped, never replayed as a backlog. A time that daylight saving skips is skipped;
a repeated hour resolves to its first instant and still runs once. A new or edited schedule
never fires for occurrences from before the edit. Failures are recorded and not retried; `Warm
up now` is the retry, and it leaves the timetable untouched.

## Open session windows

A client's 5-hour session window opens at the first request after the previous one closed, and
its reset is fixed from that instant. A request sent while a window is already open opens
nothing: it is ordinary usage that spends the current window's budget and the weekly quota. So
warm up only does work in the gap between one window closing and the next real request.

A run therefore begins by fetching the client's quota and reading the `Session` line's usage
and reset. The window is open only when the provider reports non-zero usage and a future reset.
Codex also publishes a moving, future reset for an idle zero-percent window; that candidate
boundary does not suppress warm up. The check happens at the firing instant rather than using
the published snapshot, which can be a whole refresh interval old. An occurrence landing in an
open window is recorded as `Warm until <time>` and spent there — nothing is sent, and nothing is
deferred to when the window closes. A schedule runs at its own time or not at all, so continuous
use all day simply means no warm up ever runs. `Warm up now` behaves the same way.

A client whose fetch fails or reports no `Session` reset is never skipped this way: GLM's
Coding plan reports no session window, so it always runs at its scheduled time.

## Execution and credentials

Every run sends a fixed request to reply with `OK` without tools or file access. CLI runs use
a temporary directory, empty stdin and no session persistence or resume. Codex uses a
read-only sandbox and ignores user config; Claude uses safe mode with tools and MCP disabled.
Both keep the CLI's own authentication, accept an explicit executable and model, and fall
back to the user's login shell when the executable path is blank. The installed CLIs must
support these flags.

GLM keys are saved in Keychain. The shared credential loader also recognizes the existing
`.config/openusage/zai.json` source, then `ZAI_API_KEY` / `GLM_API_KEY` from the process
environment. Removing the Keychain override restores this lookup order. Quota monitoring uses
the same loader. No key is stored in defaults.

The GLM endpoint selector distinguishes Coding Plan and Standard API. Requests use `glm-5.3`,
low reasoning effort and a 64-token output limit. GLM 5.3 requires reasoning; see the
[official model guide](https://docs.z.ai/guides/llm/glm-5.3) and
[completion parameters](https://docs.z.ai/api-reference/llm/chat-completion). Warm up means
making a small authenticated model request; it does not guarantee a provider cache duration
or a new quota window. Requests can consume quota or API credit.

CLI execution times out after 120 seconds, including shell startup. API requests use a
120-second request timeout and reject redirects.

## What a run records

A run counts as successful only with evidence that a model finished a turn: Claude's result
object with non-empty text, a Codex `agent_message` followed by `turn.completed`, or a GLM
choice carrying non-empty answer content with `finish_reason: stop`. Reasoning-only output,
output cut short by a token limit, and unfinished CLI turns do not count as success.
An exit code of 0 alone is `No completion`.

Each record keeps the scheduled occurrence, the actual start and finish, the client, the
answering model when the response names one, the HTTP status or CLI exit code, and token
usage when reported. It never keeps raw CLI output, response bodies or credentials. The
sixty most recent runs are retained and shown on the page, newest first.

## Validation

`swift test` covers occurrence selection across weekdays, daylight-saving gaps and repeats,
time-zone changes, late and missed occurrences, restart recovery, manual-request
deduplication, client concurrency, cancellation, history bounds, fake CLI execution and mock
HTTP responses. Tests do not run installed agent CLIs or use real API keys.
