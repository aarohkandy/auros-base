#!/usr/bin/env node
// ═══════════════════════════════════════════════════════════════════════════════════════════════════
// auros-base/tools/quote-from-compat.mjs — what we can honestly say about a customer's fleet.
//
// SPEC §8: hardware/compat.tsv is "how we quote without guessing". This is the tool that does the
// not-guessing. Given a list of models — the list a school reads off their asset register — it
// returns, per model, exactly one of FOUR answers and the evidence behind it:
//
//   TESTED · WORKS      a physical row, every capability observed ok, verdict supported.
//   TESTED · CAVEAT     a physical row with something partial, something failing, something
//                       untested, or a human verdict of supported-with-caveat.
//   NEVER SEEN          no physical row exists. THIS IS THE COMMON ANSWER TODAY and it is the one
//                       the tool is built to protect, because it is the one there is pressure to
//                       dress up as the first.
//   UNSUPPORTED         a human has declared this model unsupported (spec §9). Never inferred here.
//
// ── THE TWO REFUSALS ─────────────────────────────────────────────────────────────────────────────
//
// 1. A `source=vm` ROW MAY NEVER REACH A QUOTE. hardware/README.md: "No customer quote is ever
//    generated from a vm row." A QEMU profile has no wifi chipset, no trackpad, no backlight and no
//    webcam, so a vm row is evidence about our build pipeline, not about anybody's laptops. vm rows
//    are dropped in the loader, and classify() throws if one reaches it — belt and braces, because
//    the filter is one `.filter()` away from being deleted by someone tidying up.
//
// 2. AN EMPTY COLUMN MAY NEVER BECOME A VERDICT. Empty means "nobody tried this". It is not a
//    quiet yes. `wifi` empty cannot contribute to WORKS; it forces CAVEAT and is named in the
//    output as untested. The whole table is worthless the first time an empty cell reads as a pass.
//
// Both are asserted in both directions by tools/quote-from-compat.test.mjs — a vm row must never
// reach a quote, an empty column must never become a verdict, and a model with no row must produce
// "we have not tested this" rather than silence.
//
// ── USAGE ────────────────────────────────────────────────────────────────────────────────────────
//   quote-from-compat.mjs "ThinkPad T440s" "Latitude E6430"
//   quote-from-compat.mjs --models-file fleet.txt --json
//   --file PATH            the compat.tsv to read (default: search, see findTable)
//   --require-quotable     exit 3 unless EVERY model came back TESTED · WORKS
//
// EXIT: 0 report produced · 2 refused to read the table (fail closed) · 3 --require-quotable unmet
// ═══════════════════════════════════════════════════════════════════════════════════════════════════
import { readFileSync, existsSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

export const CAPABILITIES = ['wifi', 'trackpad', 'suspend', 'brightness', 'gpu', 'audio', 'webcam']
/** hardware/README.md's physical-only set. A vm row claiming one of these makes the FILE dishonest. */
export const PHYSICAL_ONLY = ['wifi', 'trackpad', 'suspend', 'brightness', 'webcam']
export const CAPABILITY_VALUES = ['ok', 'partial', 'fail']
export const VERDICTS = ['supported', 'supported-with-caveat', 'unsupported', 'untested']
export const SOURCES = ['vm', 'physical']

export const ANSWER = {
  WORKS: 'tested-works',
  CAVEAT: 'tested-caveat',
  NEVER_SEEN: 'never-seen',
  UNSUPPORTED: 'unsupported',
}

class Refusal extends Error {}

// ── locating the table ───────────────────────────────────────────────────────────────────────────
// NEVER GUESS A PATH. compat.tsv lives in the meta repo (aarohkandy/auros) and this tool lives in
// auros-base, so the relative path between them depends on how the two were checked out. Every
// candidate is listed on failure, with whether it existed, because a tool that says "not found" and
// not "I looked here" is how four build cycles went on remembered layouts.
// `selfDir` is a parameter, not a constant, for one reason: with it hard-coded there is no way to
// test the "found nothing anywhere" branch from inside this repository — the search would always
// walk up out of auros-base and find the real table. A refusal path that cannot be reached in a test
// is a refusal path nobody has ever seen work (D34).
export function findTable (explicit, {
  cwd = process.cwd(),
  env = process.env,
  selfDir = dirname(fileURLToPath(import.meta.url)),
} = {}) {
  const tried = []
  const take = (p, why) => {
    const abs = resolve(p)
    const hit = existsSync(abs)
    tried.push(`${hit ? 'found  ' : 'absent '} ${abs}   (${why})`)
    return hit ? abs : null
  }
  if (explicit) {
    const hit = take(explicit, '--file')
    if (hit) return hit
    throw new Refusal(`--file names a path that does not exist.\n  ${tried.join('\n  ')}`)
  }
  if (env.AUROS_COMPAT_TSV) {
    const hit = take(env.AUROS_COMPAT_TSV, '$AUROS_COMPAT_TSV')
    if (hit) return hit
  }
  // Upwards from the working directory, then upwards from this file: the first covers "run it from
  // anywhere in the meta repo", the second covers "run it from a sibling checkout of auros-base".
  for (const [start, why] of [[cwd, 'up from cwd'], [selfDir, 'up from this script']]) {
    let d = resolve(start)
    for (let i = 0; i < 8; i++) {
      const hit = take(join(d, 'hardware', 'compat.tsv'), why)
      if (hit) return hit
      const up = dirname(d)
      if (up === d) break
      d = up
    }
  }
  throw new Refusal(
    'cannot find hardware/compat.tsv. Pass --file, or set $AUROS_COMPAT_TSV.\n' +
    '  Searched, in order:\n  ' + tried.join('\n  '))
}

// ── loading, with every honesty rule re-derived here rather than assumed ─────────────────────────
// This does not trust tools/compat-lint.mjs to have run. The publish gate recomputes its verdict
// instead of trusting the harness's `verdict` field (D32) for the same reason: a checker that can be
// skipped is not a guarantee, and this is the tool that talks to customers.
export function loadRows (text, path = 'compat.tsv') {
  const lines = text.split('\n').filter((l) => l.trim() !== '')
  if (lines.length === 0) throw new Refusal(`${path} is empty — not even a header. Refusing to quote from nothing.`)
  const header = lines[0].split('\t').map((h) => h.trim())
  const required = ['model', 'source', 'verdict', ...CAPABILITIES]
  const missing = required.filter((c) => !header.includes(c))
  if (missing.length) {
    throw new Refusal(
      `${path} header is missing required column(s): ${missing.join(', ')}.\n` +
      `  The header IS: ${header.join(' | ')}`)
  }
  const idx = Object.fromEntries(header.map((h, i) => [h, i]))
  const at = (cells, col) => (cells[idx[col]] ?? '').trim()

  const rows = []
  lines.slice(1).forEach((raw, n) => {
    const lineNo = n + 2
    const cells = raw.split('\t')
    const where = `${path}:${lineNo}`
    const source = at(cells, 'source')
    if (!SOURCES.includes(source)) {
      throw new Refusal(`${where} source is "${source}" — must be exactly ${SOURCES.join(' or ')}. ` +
        'An unlabelled row cannot be filtered, so the whole file stops being quotable. Fix the row.')
    }
    const model = at(cells, 'model')
    if (model === '') throw new Refusal(`${where} has no model. A row we cannot match is not evidence.`)

    // The enums are enforced on PHYSICAL rows only, and deliberately: those are the rows a quote is
    // built from, so a value here that this tool would have to interpret is exactly the guess the
    // table exists to remove. A vm row records what a QEMU profile is (`gpu=virtio`, `verdict=boots`)
    // and is never read for a capability — being strict there would be strictness about a fiction.
    // The one rule that DOES apply to vm rows is the physical-only one below, because a vm row
    // claiming wifi is not a vocabulary problem, it is an invented observation.
    const verdict = at(cells, 'verdict')
    if (source === 'physical' && verdict !== '' && !VERDICTS.includes(verdict)) {
      throw new Refusal(`${where} is a physical row with verdict "${verdict}" — must be one of ` +
        `${VERDICTS.join(', ')} or empty. This is a row we would quote from.`)
    }

    const caps = {}
    for (const c of CAPABILITIES) {
      const v = at(cells, c)
      if (source === 'physical' && v !== '' && !CAPABILITY_VALUES.includes(v)) {
        throw new Refusal(`${where} ${c}="${v}" — must be ${CAPABILITY_VALUES.join('/')} or EMPTY. ` +
          'Empty means "nobody tried this". Anything else is a value this tool would have to interpret, ' +
          'and interpreting it is the guess the table exists to remove.')
      }
      if (source === 'vm' && v !== '' && PHYSICAL_ONLY.includes(c)) {
        throw new Refusal(`${where} is a vm row claiming ${c}="${v}". A QEMU profile cannot observe ${c}. ` +
          'Refusing to quote from this file at all until that row is fixed: if one row is inventing ' +
          'observations, no row in it can be trusted. Run tools/compat-lint.mjs.')
      }
      caps[c] = v
    }
    rows.push({
      line: lineNo, source, model, verdict, caps,
      year: at(cells, 'year'), notes: at(cells, 'notes'),
      tested_on: at(cells, 'tested_on'), tester: at(cells, 'tester'),
      ids: at(cells, 'ids'), tpm: at(cells, 'tpm'), firmware: at(cells, 'firmware'),
    })
  })
  return rows
}

/** Matching is exact, then exact-after-normalisation. It is never fuzzy: two ThinkPads one letter
 *  apart are two different laptops, and a near-match quoted as a match is the worst output here. */
export const normalise = (s) => String(s).toLowerCase().replace(/[^a-z0-9]+/g, '')

// ── classification ───────────────────────────────────────────────────────────────────────────────
export function classify (model, allRows) {
  const vmRows = allRows.filter((r) => r.source === 'vm')
  const physical = allRows.filter((r) => r.source === 'physical')

  // The belt-and-braces assertion. If this ever throws, somebody removed the filter above.
  for (const r of physical) {
    if (r.source !== 'physical') throw new Error(`internal: a ${r.source} row reached classify() at line ${r.line}`)
  }

  const want = normalise(model)
  const mine = physical.filter((r) => r.model === model || normalise(r.model) === want)
  const vmOnly = vmRows.filter((r) => r.model === model || normalise(r.model) === want)

  if (mine.length === 0) {
    return {
      model,
      answer: ANSWER.NEVER_SEEN,
      rows: [],
      // Named explicitly so the report can say WHY there is no answer, instead of going quiet.
      vmRowsIgnored: vmOnly.map((r) => r.line),
      say: vmOnly.length
        ? 'We have not tested this model. We have only run it in a virtual machine, which cannot tell ' +
          'you anything about its wifi, trackpad, suspend, brightness or webcam, so we will not quote from it.'
        : 'We have not tested this model. We do not know, and we are not going to guess.',
      untested: [...CAPABILITIES],
      quotable: false,
    }
  }

  // A human verdict of unsupported is the strongest statement in the file and is §9-reserved.
  // It outranks everything else and is never softened into a caveat.
  const unsupported = mine.filter((r) => r.verdict === 'unsupported')
  if (unsupported.length) {
    return {
      model, answer: ANSWER.UNSUPPORTED, rows: unsupported, quotable: false,
      untested: [], failing: [], partial: [],
      say: 'We do not support this model. A person looked at the evidence and decided that, and we are not going to sell you something we have already decided does not work.',
    }
  }

  // Worst case across every physical row for this model. If two rows disagree, the disagreement IS
  // the finding — it is reported, never averaged away.
  const untested = [], failing = [], partial = []
  for (const c of CAPABILITIES) {
    const vals = mine.map((r) => r.caps[c])
    if (vals.some((v) => v === '')) untested.push(c)     // EMPTY IS NEVER A PASS.
    if (vals.some((v) => v === 'fail')) failing.push(c)
    if (vals.some((v) => v === 'partial')) partial.push(c)
  }
  const disagreements = CAPABILITIES.filter((c) => new Set(mine.map((r) => r.caps[c])).size > 1)
  const caveatVerdict = mine.some((r) => r.verdict === 'supported-with-caveat')
  const noVerdict = mine.some((r) => r.verdict === 'untested' || r.verdict === '')

  const clean = untested.length === 0 && failing.length === 0 && partial.length === 0 &&
                !caveatVerdict && !noVerdict && disagreements.length === 0

  if (clean) {
    return {
      model, answer: ANSWER.WORKS, rows: mine, quotable: true,
      untested: [], failing: [], partial: [], disagreements: [],
      say: `We have imaged this model and every one of ${CAPABILITIES.join(', ')} worked.`,
    }
  }

  const bits = []
  if (failing.length) bits.push(`${failing.join(', ')} did not work`)
  if (partial.length) bits.push(`${partial.join(', ')} only partly worked`)
  if (untested.length) bits.push(`${untested.join(', ')} ${untested.length === 1 ? 'was' : 'were'} never tested, so we do not know`)
  if (disagreements.length) bits.push(`two machines of this model disagreed about ${disagreements.join(', ')}`)
  if (!bits.length && noVerdict) bits.push('nobody has written a verdict for it yet')
  if (!bits.length && caveatVerdict) bits.push('a person recorded a caveat against it')

  return {
    model, answer: ANSWER.CAVEAT, rows: mine, quotable: false,
    untested, failing, partial, disagreements,
    say: `We have imaged this model, with caveats: ${bits.join('; ')}.` +
         (mine.map((r) => r.notes).filter(Boolean).length
           ? ` Recorded: ${mine.map((r) => r.notes).filter(Boolean).join(' / ')}`
           : ''),
  }
}

export function quote (models, rows) {
  return models.map((m) => classify(m, rows))
}

// ── CLI ──────────────────────────────────────────────────────────────────────────────────────────
const LABEL = {
  [ANSWER.WORKS]: 'TESTED · WORKS',
  [ANSWER.CAVEAT]: 'TESTED · CAVEAT',
  [ANSWER.NEVER_SEEN]: 'NEVER SEEN',
  [ANSWER.UNSUPPORTED]: 'UNSUPPORTED (human decision)',
}

export function render (results, tablePath) {
  const out = []
  out.push(`source: ${tablePath}`)
  for (const r of results) {
    out.push('')
    out.push(`  ${r.model}`)
    out.push(`    ${LABEL[r.answer]}`)
    out.push(`    ${r.say}`)
    if (r.rows?.length) {
      for (const row of r.rows) {
        out.push(`    evidence: ${tablePath}:${row.line} — tested ${row.tested_on || '(no date)'} by ${row.tester || '(no tester)'}` +
                 (row.ids ? `, ${row.ids}` : ''))
      }
    }
    if (r.vmRowsIgnored?.length) {
      out.push(`    ignored: ${r.vmRowsIgnored.length} vm row(s) at line(s) ${r.vmRowsIgnored.join(', ')} — a vm row never supports a quote.`)
    }
  }
  const n = (a) => results.filter((r) => r.answer === a).length
  out.push('')
  out.push(`  ${results.length} model(s): ${n(ANSWER.WORKS)} tested and working, ${n(ANSWER.CAVEAT)} tested with caveats, ` +
           `${n(ANSWER.NEVER_SEEN)} never seen, ${n(ANSWER.UNSUPPORTED)} unsupported.`)
  if (n(ANSWER.NEVER_SEEN) === results.length && results.length > 0) {
    out.push('')
    out.push('  Every model on this list is one we have never had in our hands. The honest quote is a')
    out.push('  pilot: take three of their machines, image them, and fill in the table. Anything else is')
    out.push('  a promise about hardware nobody here has touched.')
  }
  return out.join('\n')
}

function main (argv) {
  const models = []
  let file = null, json = false, requireQuotable = false, modelsFile = null
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]
    if (a === '--file') file = argv[++i]
    else if (a === '--models-file') modelsFile = argv[++i]
    else if (a === '--json') json = true
    else if (a === '--require-quotable') requireQuotable = true
    else if (a === '-h' || a === '--help') { process.stdout.write(HELP); return 0 }
    else if (a.startsWith('--')) throw new Refusal(`unknown option ${a}`)
    else models.push(a)
  }
  if (modelsFile) {
    let t
    try { t = readFileSync(modelsFile, 'utf8') } catch (e) { throw new Refusal(`--models-file: ${e.message}`) }
    for (const l of t.split('\n')) { const s = l.trim(); if (s && !s.startsWith('#')) models.push(s) }
  }
  if (models.length === 0) throw new Refusal(`no models given.\n${HELP}`)

  const path = findTable(file)
  let text
  try { text = readFileSync(path, 'utf8') } catch (e) { throw new Refusal(`cannot read ${path}: ${e.message}`) }
  const rows = loadRows(text, path)
  const results = quote(models, rows)

  if (json) process.stdout.write(JSON.stringify({ table: path, results }, null, 2) + '\n')
  else process.stdout.write(render(results, path) + '\n')

  if (requireQuotable && results.some((r) => !r.quotable)) {
    const bad = results.filter((r) => !r.quotable).map((r) => r.model)
    process.stderr.write(`\nquote-from-compat: --require-quotable, but ${bad.length} model(s) are not: ${bad.join(', ')}\n`)
    return 3
  }
  return 0
}

const HELP = `
quote-from-compat.mjs <model>...            what we can honestly say about these models
  --models-file FILE    one model per line, # comments allowed
  --file PATH           the compat.tsv to read
  --json                machine-readable
  --require-quotable    exit 3 unless every model is TESTED · WORKS
`

if (process.argv[1] && resolve(process.argv[1]) === resolve(fileURLToPath(import.meta.url))) {
  try {
    process.exit(main(process.argv.slice(2)))
  } catch (e) {
    if (e instanceof Refusal) { process.stderr.write(`quote-from-compat: ${e.message}\n`); process.exit(2) }
    throw e
  }
}
