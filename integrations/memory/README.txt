dsh-memory: automatic capture, per-turn recall, and the panel mirror
====================================================================
The harness shipped a memory layer that was REGISTERED AND DEAD. Its capture
block read `event.text ?? event.message ?? event.content`; a session event is
`{ type, seq, time, data }` (dsh-session/lib/index.js), so none of those fields
exist, every turn/end produced an empty string, and the 60-character floor
dropped it. The store held 45 records, every one sourced 'migrated from previous
store', and not one episode had ever been captured. Per-turn recall had the same
kind of hole: its probe was only ever set by an explicit `memory_search` call, so
a session that never called that tool got no recall at all.

What the fixed plugin does
  - accumulates the turn from the message events, which is where the text is:
    `user/message` carries the message at `event.data`, `assistant/message` and
    `system/message` at `event.data.message`, and only `type: 'text'` blocks are
    text (see `messageText`);
  - flushes exactly one episode per `turn/end`, >= 60 chars, deduped;
  - primes per-turn recall with the turn's own user message, so recall fires on
    every turn instead of never;
  - mirrors each capture into the store the in-UI "Memory & learning" panel
    reads (`rsi/memory/memory.sqlite3` via the RSI front on 18803). Best effort:
    a panel that is not running must never cost a capture. Without this mirror
    the panel could only ever show what a person typed into it.

Why the mirror instead of one store: the panel's system of record is the RSI
store and the plugin's is `memory/memory.sqlite3`; they are different databases
with different schemas. The mirror makes harness activity visible where the user
looks without rewriting either store's schema.

Proof: `node memory/capture.test.mjs` — 15 checks, including that a turn/end
writes exactly one episode, that a sub-60-character turn does not, that recall
returns a snapshot carrying the captured episode with no memory_search call, and
that the mirror posts once with the panel bearer token and the turn text. It runs
against a throwaway store (`DSH_MEMORY_STORE`) and stubs fetch, so it touches
nothing live.