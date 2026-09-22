/**
 * dsh-memory — persistent agent memory for DeepSeek Harness.
 *
 * Unlike a dynamic Cordis Plugin, this loads from the profile composition on every DSH start.
 * That is the entire point: memory must be present in every session, not only while a session
 * that defined it happens to be running.
 *
 * What it registers:
 *   memory_search  — hybrid recall (FTS5 + CJK n-gram + local embeddings), active records only
 *   memory_write   — store a fact; same subject supersedes atomically
 *
 * Failure policy: if the store cannot be opened, this plugin logs and registers nothing.
 * A broken memory layer must never prevent the harness from starting.
 *
 * @module dsh-memory
 */
import { defineTool } from '@deepseek-ai/dsh-tools'
import { existsSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { DatabaseSync } from 'node:sqlite'
import { fileURLToPath } from 'node:url'

/** Cordis plugin name, used by loader diagnostics. */
export const name = 'dsh-memory'

/** The tool registry is the one hard dependency. */
export const inject = ['tools']

const HERE = dirname(fileURLToPath(import.meta.url))

/**
 * Locate the one memory store.
 *
 * This package is installed as a plain COPY in two places — the workspace
 * (`memory/plugin`) and the profile (`profiles/tauri/node_modules/dsh-memory`).
 * Those two locations sit at different depths, so a fixed '..' chain cannot serve
 * both: from the profile copy it would resolve inside the profile and open a
 * second, empty database. Walking upward and refusing any candidate that lands
 * inside a `node_modules` tree finds the single real store from either copy.
 */
function resolveStorePath() {
  const override = process.env.DSH_MEMORY_STORE
  if (typeof override === 'string' && override.trim() !== '') return resolve(override)

  const candidates = []
  let directory = HERE
  for (let depth = 0; depth < 12; depth += 1) {
    if (!directory.toLowerCase().includes('node_modules')) {
      candidates.push(join(directory, 'memory', 'memory.sqlite3'))
    }
    const parent = dirname(directory)
    if (parent === directory) break
    directory = parent
  }

  // A copy installed outside the harness tree (for example under the desktop
  // app's own home on C:) has no workspace above it, so the walk cannot reach
  // the store. Fall back to this harness's store explicitly.
  candidates.push('D:\\KEEP OUT\\DSH Kawaii\\DSH Kawaii creator\\memory\\memory.sqlite3')

  // Membership in the store is what proves a candidate: a stray empty database
  // left behind by an earlier layout must never be mistaken for the real one.
  const isRealStore = (candidate) => {
    if (!existsSync(candidate)) return false
    let probe
    try {
      probe = new DatabaseSync(candidate, { readOnly: true })
      const row = probe.prepare(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='memories'",
      ).get()
      return row !== undefined
    } catch {
      return false
    } finally {
      try { probe?.close() } catch { /* already closed */ }
    }
  }

  const found = candidates.find(isRealStore)
  return found ?? candidates[0]
}

const STORE_PATH = resolveStorePath()

// The ported module reads its database path from MEMORY_DATABASE at import time, so
// bind it to the single resolved store before importing. Both copies of this package
// (workspace and profile) therefore open the SAME database.
process.env.MEMORY_DATABASE = STORE_PATH

const { remember, retrieve, context: memoryContext, statistics, DATABASE } =
  await import('./core/memory-store.mjs')

/** Render a plain string result into a text tool card. */
const textOutput = (label) => ({
  schema: { type: 'string' },
  render(_args, value) {
    return [{ type: 'text', text: label + '\n' + String(value) }]
  },
})

/**
 * Per-turn recall probe: the text of the turn's own user message.
 *
 * The reference module retrieves by query text and has no "most recent" path, so
 * something has to supply a query. This is fed by the `user/message` events
 * below, which means recall runs on every turn. It used to be fed only by an
 * explicit `memory_search` call, so a session that never called that tool got no
 * recall at all — the probe stayed empty and `context()` returned ''.
 */
let LAST_QUERY = ''

/**
 * Extract plain text from a session message.
 *
 * Session events are `{ type, seq, time, data }`. Only the message events carry
 * text, and they do not agree on where: `user/message` puts the message at
 * `event.data` itself, while `assistant/message` and `system/message` put it at
 * `event.data.message` (see `deriveEventMessage` in dsh-session/lib/index.js).
 * Content is a block list, and only `type: 'text'` blocks are text.
 *
 * @param message - a message object, a content block list, or a plain string.
 * @returns the concatenated text, trimmed; '' when there is none.
 */
function messageText(message) {
  if (typeof message === 'string') return message.trim()
  if (message === null || typeof message !== 'object') return ''
  const blocks = Array.isArray(message.content) ? message.content : []
  return blocks
    .map((block) => {
      if (typeof block === 'string') return block
      if (block !== null && typeof block === 'object' && block.type === 'text' && typeof block.text === 'string') return block.text
      return ''
    })
    .filter(Boolean)
    .join('\n')
    .trim()
}

/** Format hits as one line each, id first so a follow-up call can act on it. */
function formatHits(hits) {
  if (hits.length === 0) return 'No matching memory records.'
  return hits
    .map((h, i) => `${i + 1}. [${h.kind ?? 'memory'}] ${h.body ?? h.content}  (id ${String(h.memory_id ?? h.id).slice(0, 8)})`)
    .join('\n')
}

/**
 * Mirror one captured turn into the store the in-UI panel reads.
 *
 * The "Memory & learning" panel is served by this harness's own RSI front
 * (`rsi/service.py`, `/rsi/ui` -> `rsi/memory/memory.sqlite3`) and that is a
 * DIFFERENT database from this plugin's. Before this mirror existed the panel
 * could only ever show what a person typed into it: every automatic capture went
 * to a store the panel never opens, which is why the panel looked uninvolved
 * with the harness.
 *
 * Best effort and non-fatal by construction: the front may not be running, and a
 * panel that is down must never cost a capture. The bearer token is the one the
 * launcher exports for the panel's own proxy, and the front rejects any request
 * carrying an Origin header, which a server-side fetch never sends.
 *
 * @param text - the captured turn text.
 */
function mirrorToPanel(text) {
  const base = process.env.RSI_PANEL_URL
  const key = process.env.LOCAL_MODEL_API_KEY
  if (typeof base !== 'string' || base === '' || typeof key !== 'string' || key === '') return
  try {
    const request = fetch(`${base}/rsi/memory/store`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${key}` },
      body: JSON.stringify({
        title: text.slice(0, 80),
        body: text.slice(0, 800),
        kind: 'episode',
        source: 'dsh-memory automatic capture (turn/end)',
        scope: 'user',
      }),
    })
    // Swallow both network failure and any later rejection: capture must not
    // depend on the panel being up.
    Promise.resolve(request).catch(() => {})
  } catch {
    // A malformed RSI_PANEL_URL is not worth failing a turn over.
  }
}

/**
 * Register the memory tools.
 * @param ctx - registrant context carrying the tool registry.
 */
export function apply(ctx) {
  try {
    // Opening once here proves the store is reachable and applies the schema/upgrades
    // before any tool runs, so a broken store fails loudly at load rather than at use.
    statistics()
  } catch (error) {
    console.error(
      '[dsh-memory] could not open the memory store; memory tools are unavailable this run:',
      error instanceof Error ? error.message : String(error),
    )
    return
  }

  console.log(`[dsh-memory] store ready at ${DATABASE}`)

  // ── per-turn recall ────────────────────────────────────────────────────────
  // `systemPrompt.context()` renders as a "sourced user-role snapshot" that is
  // explicitly SEPARATE from the system-prompt sections, so recall injected here
  // cannot invalidate the prompt-cache prefix the way a per-turn system-prompt
  // mutation would.
  //
  // Deliberately conservative, because the evidence says so: memory injection
  // HURTS agents when it is large or presented as authoritative. Long-context
  // baselines beat every dedicated memory system, memory scaffolds hurt
  // long-horizon performance across 10 models in 23,392 episodes, and 61-62% of
  // memory errors happen AFTER the correct memory was retrieved — so the failure
  // is in the model's handling of what it is given. What does work is a small,
  // precisely-chosen slice, hence the hard cap below.
  //
  // `text` is a function, so it is re-evaluated for every assembly; it returns ''
  // when there is nothing worth saying, and the harness drops an empty context
  // rather than injecting noise.
  const systemPrompt = ctx.get?.('systemPrompt')
  if (systemPrompt?.context) {
    try {
      systemPrompt.context({
        name: 'dsh-memory.recall',
        order: 500,
        text: () => {
          try {
            // The reference module supplies recall as one bounded block with its own
            // non-authoritative warning and a scope/expiry-filtered graph traversal.
            // It returns '' when nothing qualifies, which the harness drops.
            return memoryContext(LAST_QUERY, 'user')
          } catch {
            // Recall must never break a turn.
            return ''
          }
        },
      })
      console.log('[dsh-memory] per-turn recall registered as a user-role context snapshot')
    } catch (error) {
      console.warn('[dsh-memory] per-turn recall unavailable:', error instanceof Error ? error.message : String(error))
    }
  } else {
    console.warn('[dsh-memory] systemPrompt service not present; per-turn recall disabled (tools still work)')
  }

  // ── automatic capture ─────────────────────────────────────────────────────
  // Memory must fill itself, or it only ever holds what someone chose to save.
  //
  // THIS BLOCK WAS DEAD CODE UNTIL 2026-09-22. It read `event.text ?? event.message
  // ?? event.content`; a session event has none of those fields — its payload is
  // `event.data` — so every turn/end produced an empty string, fell through the
  // 60-character floor and returned. The store held 45 records, every one of them
  // sourced 'migrated from previous store', and not a single episode had ever
  // been captured. The turn is now accumulated from the message events, which is
  // where the text actually is, and flushed once on turn/end.
  //
  // Deterministic and bounded, deliberately. The evidence forbids the obvious
  // shortcut: write-path LLM extraction is on the do-not-build list, and
  // automatic write is a security boundary (planted memories survive at 87.5%
  // with >90% defence miss rates; poisoning 1.2% of a corpus drops LongMemEval
  // from 0.850 to 0.300). So this summarises NOTHING with a model — it records
  // what actually happened, truncated.
  //
  // Bounded on four axes so it can never flood the store or hog the recall slot:
  //   - one capture per turn (turn/end), not per token or per step;
  //   - a 60-character floor, so tool chatter and acknowledgements are ignored;
  //   - identical content is skipped here as well as deduped by the store;
  //   - importance 0.1, so captures sort BELOW every deliberate fact in the
  //     recall snapshot and cannot crowd out what is worth surfacing.
  let turnParts = []
  let lastCaptured = ''
  try {
    ctx.on('session/event', (subject, event) => {
      try {
        const type = event?.type
        const data = event?.data

        if (type === 'user/message') {
          const text = messageText(data)
          // The turn's own prompt is the only query this seam can offer recall.
          if (text !== '') LAST_QUERY = text.slice(0, 400)
          if (text !== '') turnParts.push(text)
          return
        }

        if (type === 'assistant/message' || type === 'system/message') {
          const text = messageText(data?.message)
          if (text !== '') turnParts.push(text)
          return
        }

        if (type !== 'turn/end') return

        const text = turnParts.join('\n\n').trim()
        turnParts = []
        if (text.length < 60) return
        if (text === lastCaptured) return
        lastCaptured = text

        remember(
          text.slice(0, 80),
          text.slice(0, 800),
          'episode',
          'automatic capture (turn/end)',
          null,
          'user',
        )

        // ...and into the store the Memory & learning panel actually opens.
        mirrorToPanel(text)
      } catch {
        // Capture must never break a turn.
      }
    })
    console.log('[dsh-memory] automatic capture registered on session/event (turn/end)')
  } catch (error) {
    console.warn('[dsh-memory] automatic capture unavailable:', error instanceof Error ? error.message : String(error))
  }

  ctx.tools.register(defineTool({
    name: 'memory_search',
    description:
      'Search long-term memory for facts, preferences, decisions, and lessons stored in earlier sessions. '
      + 'Use this before re-deriving or re-researching anything that may already be known. '
      + 'Returns active records only: superseded and revoked records are never returned.',
    parameters: {
      q: {
        type: 'string',
        required: true,
        description: 'What to search for. An empty string returns the most recent records.',
      },
      scope: {
        type: 'string',
        description: 'Memory scope: user (personal, default) or a project scope.',
      },
      limit: {
        type: 'number',
        description: 'Maximum results, 1-50. Default 10.',
      },
    },
    output: textOutput('Memory search results'),
    async execute(args) {
      const query = typeof args.q === 'string' ? args.q : ''
      const scope = typeof args.scope === 'string' && args.scope !== '' ? args.scope : 'user'
      const limit = typeof args.limit === 'number' ? Math.min(50, Math.max(1, args.limit)) : 10

      if (query.trim() !== '') LAST_QUERY = query
      const result = retrieve(query, limit, scope)
      return `${result.memories.length} hit(s) — ${result.ranking}\n` + formatHits(result.memories)
    },
    presentCall: (args) => ({
      card: 'generic',
      title: 'Search memory',
      kind: 'other',
      rawInput: args.q,
    }),
  }))

  ctx.tools.register(defineTool({
    name: 'memory_write',
    description:
      'Store a durable fact, preference, decision, or lesson in long-term memory so future sessions do not '
      + 'have to rediscover it. Re-using the same subject supersedes the previous record atomically, so the '
      + 'newest value always wins and the old one stops being retrievable.',
    parameters: {
      content: {
        type: 'string',
        required: true,
        description: 'The fact to remember, as one self-contained sentence.',
      },
      subject: {
        type: 'string',
        description: 'Stable key for the thing described, e.g. "deploy.target". Re-using a subject supersedes the prior record. Omit for append-only notes.',
      },
      kind: {
        type: 'string',
        description: 'One of: fact, preference, decision, episode, skill. Default fact.',
      },
      scope: {
        type: 'string',
        description: 'user (default) or a project scope.',
      },
    },
    output: textOutput('Memory write result'),
    async execute(args) {
      const content = typeof args.content === 'string' ? args.content : ''
      if (content.trim() === '') return 'memory_write requires non-empty content.'
      const scope = typeof args.scope === 'string' && args.scope !== '' ? args.scope : 'user'
      const kind = typeof args.kind === 'string' && args.kind !== '' ? args.kind : 'fact'
      // The reference store keys a record by (title, body, kind, source); the tool's
      // `subject` becomes the title, so re-using a subject updates the same record.
      const title = typeof args.subject === 'string' && args.subject.trim() !== ''
        ? args.subject.trim()
        : content.trim().slice(0, 80)
      const result = remember(title, content, kind, 'memory_write tool', null, scope)
      return `Stored. id ${String(result.id).slice(0, 8)} active=${result.active} scope=${result.scope}`
        + `${result.expires_at === null ? '' : ' expires=' + result.expires_at}`
    },
    presentCall: (args) => ({
      card: 'generic',
      title: 'Write memory',
      kind: 'other',
      rawInput: args.content,
    }),
  }))
}
