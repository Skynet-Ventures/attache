# Handoff: Attaché — iOS remote for omp (direction "Signal")

## Overview
Attaché is a native iOS app for driving [omp](https://omp.sh) coding-agent sessions remotely: monitoring live turn streams, answering tool approvals (in-stream, in a queue, and from the lock screen), reviewing plans and diffs, steering subagents, and managing model roles/machines. It is a GUI wrapper — never a terminal — that preserves full omp data visibility (advisor commentary, subagent transcripts, context/cost, fallback chains).

## About the Design Files
The files in this bundle are **design references created in HTML** — prototypes showing intended look and behavior, not production code to copy. The task is to **recreate these designs in Swift/SwiftUI** (the intended target; no codebase exists yet) using platform patterns: `NavigationStack`, `ScrollView`, `ActivityKit`, `UserNotifications`. If a codebase appears later, follow its established patterns instead.

- `Attaché Prototype.dc.html` — the interactive prototype (canonical behavior spec). All screens, state machine, and interactions are implemented in the inline template + `Component` class at the bottom of the file; every color/size is an inline style you can read directly.
- `omp Mobile — Directions.dc.html` — static frames incl. two rejected art directions (1b, 1c) and the **system surfaces** frame (lock screen, Live Activity, Dynamic Island states) for direction 1a.
- `ios-frame.jsx` — device chrome only; ignore for implementation.

## Fidelity
**High-fidelity.** Colors, typography, spacing, radii, and copy are final for direction 1a ("Signal"). Recreate pixel-perfectly with system fonts (SF Pro / SF Mono). The app name "Attaché" and glyph "å" are placeholders — confirm before shipping.

## Design Tokens
Colors (dark-only theme):
- Background: `#060606`; raised surfaces `#101012`, `#0C0C0E`, `#141416`; composer bar `#0A0A0B`; code blocks `#000000`
- Text: primary `#F4F4F2`; secondary `rgba(244,244,242,0.55–0.8)`; tertiary `.45`; faint `.35`
- Accent (live/CTA): `#FF6A2B` (hover `#FF8551`); on-accent text: black
- Status: success `#30D158`, warning `#FFD60A`, danger `#FF453A`; diff green `#7CE59E` on `rgba(48,209,88,0.1)`, diff red `#FF9C93` on `rgba(255,69,58,0.09)`
- Hairlines: `rgba(255,255,255,0.05–0.10)`; accent borders `rgba(255,106,43,0.3–0.5)`

Typography (SF Pro = `.system`, SF Mono = `.monospaced`):
- Titles 15–17 semibold SF Pro; body/chat 13 regular (line-height 1.45–1.5)
- Data/labels: SF Mono 9–12; section headers 10 semibold, tracking +0.12em, uppercase, faint
- Code/diff: SF Mono 10.5–11, line-height 1.6–1.75

Spacing & shape: screen gutter 16–18; card padding 11–14; stream gap 10; radii — cards 10–14, chips 6–7, buttons 8–9, sheets 12 (20 top-only for bottom sheets); buttons 30–36pt tall (44pt min hit target via padding); toggles 40×24.

## Screens
Nav model: session-first. Home is root; everything else pushes onto the stack. Detailed layout/colors: read the matching `sc-if` block in the prototype source.

1. **Home** — header (glyph tile 34, app name, machine status line), quick chips (agents/approvals/machines/roles), search field (opens Resume), PINNED cards (running session with live status line + context bar + meta row; plan-waiting card reflecting plan state), then per-project session lists (status dot, title, age).
2. **Live turn stream** — header: back, title + `branch · turn N · elapsed` subtitle, ⑂ branch button (no model picker here — role/model selection lives only at the composer's @role chip); slim context meter (fill %, `132.4k/200k · $3.84 · compact@85%`). Stream: user bubbles (right, `#1E1E22`, 14/14/4/14 radius), agent text (plain), collapsible tool cards (search/edit), advisor block, inline approval card, appended messages, typing indicator. Composer: mode chip (CHAT→PLAN→GOAL→LOOP), @role chip, `/` palette, attach, mic-in-field, send; "■ stop turn" while active.
3. **Subagent hub** — 2-col live tiles (name, status dot/✓/○, last line 2-row clamp, `elapsed · tokens · calls`), focused-agent bottom sheet (transcript: tool rows + text + orange `»` steers) with steer input.
4. **Approvals queue** — header with count + policy note; cards: risk label (`HIGH · BASH` colored text, no stripes), source/age, command block or YAML mini-diff, reason, Deny / Allow once / Always; resolved cards drop to 62% opacity with verdict row; queue-clear state (green ✓).
5. **Plan review** — read-only-draft notice card, 6 steps (index, title, file mono, risk tag; ✓/●/· marks while executing), footer: Reject / Refine… / Accept & execute → executing banner with progress + pause. Accepting flips the Home plan card to EXECUTING.
6. **Full-screen diff** — mono file header with `+11 −3` and hashline chip `#a3f2`, full hunks with context lines, LSP/gofmt footer, Request changes / Looks good.
7. **Resume picker** — scope chips (`this folder` / `all projects ⇥`), deep search field, session rows (dot, title, sub, short id).
8. **Roles & settings** — 8 model-role rows (role, model, thinking-level chip that cycles minimal→low→medium→high→xhigh→max), fallback chain chips, approval-mode segmented (yolo / ask destr. / ask all), hindsight toggle, snapcompact, Rules/MCP/Skills rows.
9. **Machines / pairing** — `$ omp serve --pair` copy row, 4 code cells, QR button, paired machine rows (latency, versions, sessions; wake flow asleep→waking→online).
10. **Onboarding** — Welcome (glyph, 3 numbered value props, "Pair your first machine" / "Explore with demo data") → pairing → notifications permission screen.
11. **System surfaces** (static frames in the Directions file): lock-screen approval notification with Allow/Deny actions, Live Activity card (session, current tool, context bar, `ctx · $ · agents`), Dynamic Island compact (`å + dot + T14`), expanded (title, tool, progress, "1 approval waiting" chip), idle.

## Interactions & Behavior
- Tool cards tap-expand/collapse (omp's Ctrl+O equivalent); edit card also links "review ▸" → full diff.
- Inline approval: Allow once/Always → bash result card + agent continuation appended, context/cost tick up; Deny → agent adapts. Always also emits a "rule added" steer line.
- Advisor: distinct orange voice block; "Ask agent to address" forwards it as a steer (visible `»` line) and the agent responds; Dismiss hides.
- Goal mode: composer in GOAL + send → pinned sticky banner (objective, `turn N / budget 40`, pause/drop) that ticks each agent turn.
- Branch sheet: pick a prior turn → confirmation steer line; original session untouched.
- Offline: banner under status bar, machine chip flips red, sends become "queued" steer lines.
- Stream auto-scrolls to bottom on new content. Buttons: hover lightens accent, active scales ~0.96. Blink animation on live dots ≈1.6s ease pulses.
- Timers in prototype (reply latency ~1.1s, wake 1.6s, pair keystrokes 320ms) are simulation stand-ins for real omp events.

## State Management
Mirror the prototype's `Component.state`: `screen`, per-card expansion, `advisor: open|dismissed|addressed`, `inline: pending|allowed|denied`, `messages[]` (kinds: user/agent/tool/steer), `typing`, `mode`, `role`, sheet flags, `queue[]` with per-item status, `focused` agent + per-agent steers, `thinking{role}`, `approvalMode`, `hindsight`, `ctxPct/cost/turnNo/elapsed`, `plan: ready|refine|rejected|executing`, `goal{active,objective,turns}`, `obMode`, `offline`, `wakeState`, `pairStep`. In production these map to omp session events over the wire (session stream, approval RPCs, agent transcripts `agent://<id>`, roles config) — the app renders server state and sends user verdicts/steers back; treat every prototype timer as "await server event".

## Assets
None. Glyphs are text/SF-Symbols-replaceable (⑂ branch, ◆ advisor, ◎ goal, å placeholder logo). Use SF Symbols where natural (arrow.branch, checkmark, mic, plus).

## Files
- `Attaché Prototype.dc.html` — behavior + pixel spec (primary reference)
- `omp Mobile — Directions.dc.html` — static frames: system surfaces (07), rejected directions 1b/1c for context
- `ios-frame.jsx` — preview chrome only
