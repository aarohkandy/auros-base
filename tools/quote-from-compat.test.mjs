#!/usr/bin/env node --test
// ═══════════════════════════════════════════════════════════════════════════════════════════════════
// quote-from-compat — tested in BOTH directions, because a check that cannot fail is not a check.
//
//   node --test auros-base/tools/quote-from-compat.test.mjs
//
// The three properties this file exists to hold down, stated as the task that commissioned it did:
//
//   1. A `vm` ROW MUST NEVER REACH A QUOTE.
//   2. AN EMPTY COLUMN MUST NEVER BECOME A VERDICT.
//   3. A MODEL WITH NO ROW MUST PRODUCE "we have not tested this" — AND NOT SILENCE.
//
// Every one of them is a NEGATIVE property, and a negative property is exactly what a suite can
// satisfy by accident. `classify()` returning NEVER_SEEN for absolutely everything would satisfy 1,
// 2 and 3 completely and be worthless. So each rule here is proved as a PAIR: a control fixture that
// must come back TESTED · WORKS, and the same fixture with one defect introduced, which must not.
// The control is what makes the refusal mean something.
// ═══════════════════════════════════════════════════════════════════════════════════════════════════
import { test, describe } from 'node:test'
import assert from 'node:assert/strict'
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, readFileSync, existsSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { execFileSync } from 'node:child_process'

import {
  ANSWER, CAPABILITIES, PHYSICAL_ONLY, VERDICTS,
  loadRows, classify, quote, render, findTable, normalise,
} from './quote-from-compat.mjs'

const HERE = dirname(fileURLToPath(import.meta.url))
const TOOL = join(HERE, 'quote-from-compat.mjs')

// ── the schema comes from the REAL file, never from a copy ───────────────────────────────────────
// A fixture header copied into this file drifts from hardware/compat.tsv within a week, and then
// this suite is green about a table that no longer exists. Same rule as the shell harness's "never
// copy the code under test". If the two repos are not checked out side by side the suite ABORTS
// rather than inventing a header, because a suite testing an imaginary schema proves nothing.
const REAL_TSV = (() => {
  for (const c of [
    process.env.AUROS_COMPAT_TSV,
    join(HERE, '..', '..', 'hardware', 'compat.tsv'),   // meta repo, auros-base as a subdirectory
    join(HERE, '..', '..', '..', 'hardware', 'compat.tsv'), // siblings under a common parent
  ]) if (c && existsSync(c)) return resolve(c)
  return null
})()

if (!REAL_TSV) {
  throw new Error(
    'cannot find hardware/compat.tsv, so this suite would be testing an invented schema.\n' +
    'Set $AUROS_COMPAT_TSV. Looked beside auros-base and one level up from it.')
}

const HEADER = readFileSync(REAL_TSV, 'utf8').split('\n')[0]
const COLS = HEADER.split('\t')

const row = (fields = {}) => {
  for (const k of Object.keys(fields)) {
    if (!COLS.includes(k)) throw new Error(`fixture sets "${k}", which is not a column of ${REAL_TSV}. The columns are: ${COLS.join(', ')}`)
  }
  return COLS.map((c) => fields[c] ?? '').join('\t')
}
const file = (...rows) => `${HEADER}\n${rows.join('\n')}\n`

// ── THE CONTROL ──────────────────────────────────────────────────────────────────────────────────
// One real-shaped physical row with every capability observed working. Everything below is this
// fixture with exactly one thing changed, so every refusal is attributable to that one thing.
const MODEL = 'ThinkPad-T440s'
const WORKING = (over = {}) => row({
  model: MODEL, year: '2014', source: 'physical', cpu: 'Intel-Core-i5-4300U', ram_gb: '8',
  firmware: 'uefi-sb', ids: 'wifi=pci:8086:08b1;gpu=pci:8086:0a16;webcam=usb:04f2:b39a', tpm: '1.2',
  wifi: 'ok', trackpad: 'ok', suspend: 'ok', brightness: 'ok', gpu: 'ok', audio: 'ok', webcam: 'ok',
  verdict: 'supported', notes: '', tested_on: '2026-09-21', tester: 'aaroh', ...over,
})

const ask = (text, model = MODEL) => classify(model, loadRows(text, 'fixture.tsv'))
const refuses = (text, why) => {
  let threw = null
  try { loadRows(text, 'fixture.tsv') } catch (e) { threw = e }
  assert.ok(threw, `expected a REFUSAL (${why}) but the file loaded cleanly`)
  return threw
}

// ─────────────────────────────────────────────────────────────────────────────────────────────────
describe('the control — without it, a tool that always says "never seen" passes every test below', () => {
  test('a complete physical row with every capability ok is TESTED · WORKS', () => {
    const r = ask(file(WORKING()))
    assert.equal(r.answer, ANSWER.WORKS, `the control must be quotable, or nothing below means anything:\n${JSON.stringify(r, null, 2)}`)
    assert.equal(r.quotable, true)
    assert.equal(r.untested.length, 0)
    assert.match(r.say, /every one of/i)
  })

  test('the control names its evidence — line, date and tester', () => {
    const r = ask(file(WORKING()))
    assert.equal(r.rows.length, 1)
    assert.equal(r.rows[0].line, 2)
    const text = render([r], 'fixture.tsv')
    assert.match(text, /fixture\.tsv:2/, 'a quote with no citation is an opinion')
    assert.match(text, /2026-09-21/)
    assert.match(text, /aaroh/)
  })
})

// ─────────────────────────────────────────────────────────────────────────────────────────────────
describe('RULE 1 — a vm row must never reach a quote', () => {
  test('the SAME row, with source flipped to vm, stops being quotable', () => {
    // The single-variable version of the rule. Nothing about this row changes except the word "vm".
    const asPhysical = ask(file(WORKING()))
    assert.equal(asPhysical.answer, ANSWER.WORKS, 'control')

    const asVm = ask(file(WORKING({
      source: 'vm',
      // the physical-only columns must be blank on a vm row or the FILE is refused; that is the
      // next test. Here the row is otherwise honest and must STILL not produce a quote.
      wifi: '', trackpad: '', suspend: '', brightness: '', webcam: '',
    })))
    assert.equal(asVm.answer, ANSWER.NEVER_SEEN)
    assert.equal(asVm.quotable, false)
    assert.deepEqual(asVm.vmRowsIgnored, [2], 'the ignored vm row must be named, not silently dropped')
    assert.match(asVm.say, /virtual machine/i, 'the customer-facing sentence must say WHY we cannot answer')
  })

  test('a vm row whose gpu and audio ARE filled still produces no quote', () => {
    // gpu and audio are not in hardware/README.md's physical-only set, so the lint lets a vm row
    // carry them — a QEMU profile really does have a virtio GPU. This is the gap a filter written
    // as "drop rows with physical-only claims" instead of "drop vm rows" would fall straight into.
    const r = ask(file(WORKING({ source: 'vm', wifi: '', trackpad: '', suspend: '', brightness: '', webcam: '', gpu: 'ok', audio: 'ok' })))
    assert.equal(r.answer, ANSWER.NEVER_SEEN)
    assert.equal(r.rows.length, 0)
  })

  for (const col of PHYSICAL_ONLY) {
    test(`a vm row claiming ${col} makes the WHOLE FILE unquotable`, () => {
      // Not "that row is skipped". If one row is inventing observations, no row in the file has been
      // written by someone applying the rule, so the tool refuses the file and says so.
      const honestVm = WORKING({ source: 'vm', wifi: '', trackpad: '', suspend: '', brightness: '', webcam: '' })
      assert.doesNotThrow(() => loadRows(file(honestVm), 'fixture.tsv'), 'control: an honest vm row loads')

      const cells = honestVm.split('\t'); cells[COLS.indexOf(col)] = 'ok'
      const e = refuses(file(cells.join('\t')), `a vm row claiming ${col}`)
      assert.match(e.message, new RegExp(`vm row claiming ${col}`))
      assert.match(e.message, /Refusing to quote from this file/)
    })
  }

  test('a vm row and a physical row for the same model: only the physical one is quoted', () => {
    const vm = WORKING({ source: 'vm', wifi: '', trackpad: '', suspend: '', brightness: '', webcam: '' })
    const r = ask(file(vm, WORKING()))
    assert.equal(r.answer, ANSWER.WORKS)
    assert.equal(r.rows.length, 1, 'the vm row must not be counted as a second machine')
    assert.equal(r.rows[0].line, 3, 'the evidence must cite the PHYSICAL row (line 3), not the vm row (line 2)')
  })

  test('a vm row cannot drag a good physical row DOWN either', () => {
    // The mirror image, and the one a naive "worst case wins" implementation gets wrong: a vm row
    // is not evidence in either direction.
    const vm = WORKING({ source: 'vm', gpu: 'fail', audio: 'fail', wifi: '', trackpad: '', suspend: '', brightness: '', webcam: '' })
    const r = ask(file(vm, WORKING()))
    assert.equal(r.answer, ANSWER.WORKS)
  })
})

// ─────────────────────────────────────────────────────────────────────────────────────────────────
describe('RULE 2 — an empty column must never become a verdict', () => {
  for (const col of CAPABILITIES) {
    test(`blanking ${col} alone turns WORKS into CAVEAT and names ${col} as untested`, () => {
      assert.equal(ask(file(WORKING())).answer, ANSWER.WORKS, 'control')

      const r = ask(file(WORKING({ [col]: '' })))
      assert.equal(r.answer, ANSWER.CAVEAT, `${col} empty was quoted as working`)
      assert.equal(r.quotable, false)
      assert.ok(r.untested.includes(col), `${col} must be reported as untested, got ${JSON.stringify(r.untested)}`)
      assert.match(r.say, new RegExp(col), 'the sentence must name the column nobody tested')
      assert.match(r.say, /never tested|do not know/i)
    })
  }

  test('all seven empty, with verdict=supported, is still not a quote', () => {
    // The dangerous shape: somebody writes the verdict from memory after the machine goes back in
    // the cupboard. A verdict is a human's summary; it is not evidence, and it cannot manufacture
    // observations that were never made.
    const blank = Object.fromEntries(CAPABILITIES.map((c) => [c, '']))
    const r = ask(file(WORKING({ ...blank, verdict: 'supported' })))
    assert.equal(r.answer, ANSWER.CAVEAT)
    assert.deepEqual(r.untested.sort(), [...CAPABILITIES].sort())
  })

  test('verdict=untested on an otherwise perfect row is not a quote either', () => {
    const r = ask(file(WORKING({ verdict: 'untested' })))
    assert.equal(r.answer, ANSWER.CAVEAT)
    assert.match(r.say, /verdict/i)
  })

  test('verdict=supported-with-caveat is honoured even when every column says ok', () => {
    // The human saw something the seven columns do not have a slot for — thermals, battery, a
    // firmware quirk. The tool does not get to overrule them with its own arithmetic.
    const r = ask(file(WORKING({ verdict: 'supported-with-caveat', notes: 'throttles hard after 20 minutes' })))
    assert.equal(r.answer, ANSWER.CAVEAT)
    assert.match(r.say, /throttles hard/)
  })

  test('fail and partial are reported as what they are, not merged into one mush', () => {
    const r = ask(file(WORKING({ webcam: 'fail', wifi: 'partial', notes: 'associates on 2.4 GHz only' })))
    assert.equal(r.answer, ANSWER.CAVEAT)
    assert.deepEqual(r.failing, ['webcam'])
    assert.deepEqual(r.partial, ['wifi'])
    assert.match(r.say, /webcam did not work/)
    assert.match(r.say, /wifi only partly worked/)
    assert.match(r.say, /2\.4 GHz only/)
  })

  test('two machines of the same model that disagree are reported as disagreeing', () => {
    // Averaging them would invent a machine neither tester saw. The disagreement IS the finding —
    // it usually means two different wifi cards behind one marketing name, which is the exact thing
    // the ids column exists to catch.
    const r = ask(file(WORKING(), WORKING({ wifi: 'fail', ids: 'wifi=pci:14e4:4727' })))
    assert.equal(r.answer, ANSWER.CAVEAT)
    assert.ok(r.disagreements.includes('wifi'))
    assert.match(r.say, /disagreed about wifi/)
  })
})

// ─────────────────────────────────────────────────────────────────────────────────────────────────
describe('RULE 3 — a model with no row says so out loud, and is not silence', () => {
  test('an unknown model returns NEVER SEEN with a sentence, not an empty result', () => {
    const r = ask(file(WORKING()), 'Latitude-E6430')
    assert.equal(r.answer, ANSWER.NEVER_SEEN)
    assert.ok(r.say.length > 20, 'silence is the failure mode here; there must be something to say')
    assert.match(r.say, /not tested/i)
    assert.match(r.say, /not going to guess/i)
  })

  test('the RENDERED report names every unknown model — it never drops one', () => {
    const models = ['Latitude-E6430', 'MacBookPro11,1', 'Chromebook-C720']
    const text = render(quote(models, loadRows(file(WORKING()), 'f.tsv')), 'f.tsv')
    for (const m of models) assert.match(text, new RegExp(m.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')), `${m} vanished from the report`)
    assert.match(text, /3 never seen/)
  })

  test('an EMPTY table answers every model rather than erroring', () => {
    // This is the repository's actual state today (BLOCKED.md B5). The common answer must be a
    // first-class outcome of the tool, not an edge case that throws — a tool that falls over when
    // it has no data is a tool people stop running, and then they quote from memory.
    const results = quote(['anything', 'at-all'], loadRows(`${HEADER}\n`, 'empty.tsv'))
    assert.equal(results.length, 2)
    for (const r of results) assert.equal(r.answer, ANSWER.NEVER_SEEN)
    const text = render(results, 'empty.tsv')
    assert.match(text, /never had in our hands/, 'an all-unknown list must say what to do instead: a pilot')
  })

  test('a near-miss model name is NEVER SEEN, not a match', () => {
    // "ThinkPad T440" and "ThinkPad T440s" are different laptops with different wifi cards. A fuzzy
    // match here is worse than no answer, because it produces a confident wrong one.
    assert.equal(ask(file(WORKING()), 'ThinkPad-T440').answer, ANSWER.NEVER_SEEN)
    assert.equal(ask(file(WORKING()), 'ThinkPad-T450s').answer, ANSWER.NEVER_SEEN)
    assert.equal(ask(file(WORKING()), 'T440s').answer, ANSWER.NEVER_SEEN)
  })

  test('spacing, case and punctuation do NOT make a different laptop', () => {
    // The control for the test above: the match must be exact about the MODEL and forgiving about
    // how somebody typed it, or every row a human writes misses the row a script wrote.
    for (const spelling of ['ThinkPad T440s', 'thinkpad-t440s', 'ThinkPad_T440s', '  ThinkPad T440s  '.trim()]) {
      assert.equal(ask(file(WORKING()), spelling).answer, ANSWER.WORKS, `"${spelling}" did not match "${MODEL}"`)
    }
    assert.equal(normalise('ThinkPad T440s'), normalise('thinkpad-t440s'))
  })
})

// ─────────────────────────────────────────────────────────────────────────────────────────────────
describe('unsupported is a human decision and is never dressed up as anything else', () => {
  test('a physical row with verdict=unsupported returns UNSUPPORTED, not CAVEAT', () => {
    const r = ask(file(WORKING({ verdict: 'unsupported', notes: '32 GB eMMC, below the floor (D26)' })))
    assert.equal(r.answer, ANSWER.UNSUPPORTED)
    assert.equal(r.quotable, false)
    assert.match(r.say, /do not support/i)
  })

  test('unsupported outranks a row that otherwise looks perfect', () => {
    const r = ask(file(WORKING({ verdict: 'unsupported' })))
    assert.notEqual(r.answer, ANSWER.WORKS)
  })

  test('nothing in this tool INFERS unsupported — the worst it produces on its own is CAVEAT', () => {
    // §9: declaring a model unsupported decides what we refuse to sell. A tool that reached that
    // conclusion from seven failing columns would be making a business decision from a spreadsheet.
    const allFail = Object.fromEntries(CAPABILITIES.map((c) => [c, 'fail']))
    const r = ask(file(WORKING({ ...allFail, verdict: 'supported-with-caveat' })))
    assert.equal(r.answer, ANSWER.CAVEAT, 'the tool proposed unsupported by itself')
  })
})

// ─────────────────────────────────────────────────────────────────────────────────────────────────
describe('a file it cannot trust is refused, never partly believed', () => {
  test('REFUSES an unlabelled source', () => {
    for (const bad of ['', 'VM', 'Physical', 'real', 'hardware']) {
      const e = refuses(file(WORKING({ source: bad })), `source="${bad}"`)
      assert.match(e.message, /must be exactly/)
    }
    assert.doesNotThrow(() => loadRows(file(WORKING()), 'f'), 'control: source=physical loads')
  })

  test('REFUSES a capability value it would have to interpret, and names the line', () => {
    for (const bad of ['yes', 'works', 'OK', 'good', '?', '-', 'n/a']) {
      const e = refuses(file(WORKING({ wifi: bad })), `wifi="${bad}"`)
      assert.match(e.message, /fixture\.tsv:2/, 'the refusal must name the line to fix')
      assert.match(e.message, /ok\/partial\/fail or EMPTY/)
    }
  })

  test('REFUSES a physical verdict outside the vocabulary, and ACCEPTS every one inside it', () => {
    for (const v of VERDICTS) assert.doesNotThrow(() => loadRows(file(WORKING({ verdict: v })), 'f'), `verdict=${v}`)
    for (const bad of ['boots', 'fine', 'good', 'yes']) refuses(file(WORKING({ verdict: bad })), `verdict="${bad}"`)
  })

  test('a vm row may carry the vocabulary of a QEMU profile — that is the control for the rule above', () => {
    // compat.tsv's vm rows record what the profile IS (gpu=virtio, verdict=boots). Being strict
    // there would be strictness about a fiction, and it would make the file unloadable for reasons
    // that have nothing to do with quoting anybody.
    const vm = row({ model: 'qemu-uefi-modern', source: 'vm', gpu: 'virtio', audio: 'none', verdict: 'boots' })
    assert.doesNotThrow(() => loadRows(file(vm), 'f'))
    assert.equal(classify('qemu-uefi-modern', loadRows(file(vm), 'f')).answer, ANSWER.NEVER_SEEN)
  })

  test('REFUSES a header missing a column, and prints the header it DID find', () => {
    for (const drop of ['model', 'source', 'verdict', ...CAPABILITIES]) {
      const kept = COLS.filter((c) => c !== drop)
      const e = refuses(`${kept.join('\t')}\n`, `header without ${drop}`)
      assert.match(e.message, new RegExp(drop))
      assert.match(e.message, /The header IS:/, 'a refusal that does not print what IS there sends the reader guessing')
    }
  })

  test('REFUSES an empty file and a row with no model', () => {
    refuses('', 'a completely empty file')
    refuses('   \n\n', 'whitespace only')
    refuses(file(WORKING({ model: '' })), 'a row with no model')
  })
})

// ─────────────────────────────────────────────────────────────────────────────────────────────────
describe('finding the table — it says where it looked', () => {
  let ROOT
  const root = () => (ROOT ??= mkdtempSync(join(tmpdir(), 'auros-quote-')))

  test('--file that does not exist is a refusal naming the absolute path tried', () => {
    let e = null
    try { findTable(join(root(), 'nope', 'compat.tsv')) } catch (err) { e = err }
    assert.ok(e, 'a missing --file must not fall through to a search')
    assert.match(e.message, /absent/)
    assert.match(e.message, /nope/)
  })

  test('with nothing to find, it lists every directory it searched', () => {
    // Both search origins have to be inside the barren tree. With only `cwd` moved, the search
    // walks up from the SCRIPT and finds the repository's real table — which is correct behaviour
    // and is why the refusal branch was unreachable until `selfDir` became a parameter.
    const empty = join(root(), 'barren', 'a', 'b'); mkdirSync(empty, { recursive: true })
    let e = null
    try { findTable(null, { cwd: empty, env: {}, selfDir: empty }) } catch (err) { e = err }
    assert.ok(e, 'a search that finds nothing must refuse, not return undefined')
    assert.match(e.message, /Searched, in order/)
    assert.match(e.message, /absent/)
  })

  test('$AUROS_COMPAT_TSV is honoured, and the control is that it finds a real file', () => {
    const d = join(root(), 'env'); mkdirSync(join(d, 'hardware'), { recursive: true })
    const p = join(d, 'hardware', 'compat.tsv'); writeFileSync(p, `${HEADER}\n`)
    assert.equal(findTable(null, { cwd: root(), env: { AUROS_COMPAT_TSV: p }, selfDir: root() }), resolve(p))
    // and the control: with the variable unset, that same barren cwd finds nothing.
    assert.throws(() => findTable(null, { cwd: root(), env: {}, selfDir: root() }))
  })

  test.after(() => { if (ROOT) rmSync(ROOT, { recursive: true, force: true }) })
})

// ─────────────────────────────────────────────────────────────────────────────────────────────────
// ─────────────────────────────────────────────────────────────────────────────────────────────────
// PROVENANCE, and the ids rule, RE-DERIVED here — this tool's header says it does not trust
// compat-lint to have run, and both of these were absent from it.
//
// The attack: a physical row for ThinkPad-T440s, seven `ok`s, verdict supported, valid ids, and
// `tester` and `tested_on` both EMPTY. It came back TESTED · WORKS, --require-quotable exited 0, and
// the evidence line read "tested (no date) by (no tester)". The strongest sentence this tool can
// say required nobody's name and no date. And a physical row with an EMPTY ids column quoted
// TESTED · WORKS too, because the ids rule lived only in compat-lint.
describe('RULE 4 — the WORKS answer needs a person and a date on the row', () => {
  test('the attack exactly as it was run: no tester, no date → CAVEAT, never WORKS', () => {
    const r = ask(file(WORKING({ tester: '', tested_on: '' })))
    assert.notEqual(r.answer, ANSWER.WORKS, `an unsigned, undated row quoted as WORKS:\n${r.say}`)
    assert.equal(r.answer, ANSWER.CAVEAT)
    assert.equal(r.quotable, false)
    assert.match(r.say, /nobody's name and no date/, `the caveat did not say what is missing:\n${r.say}`)
  })

  test('each half on its own is still a caveat, and says which half', () => {
    const noName = ask(file(WORKING({ tester: '' })))
    assert.equal(noName.answer, ANSWER.CAVEAT)
    assert.match(noName.say, /nobody's name/)
    assert.doesNotMatch(noName.say, /no date/, 'a dated row was said to have no date')

    const noDate = ask(file(WORKING({ tested_on: '' })))
    assert.equal(noDate.answer, ANSWER.CAVEAT)
    assert.match(noDate.say, /no date/)
    assert.doesNotMatch(noDate.say, /nobody's name/, 'a signed row was said to have no name')
  })

  test('one unsigned row among two signed ones still blocks WORKS', () => {
    // Worst case across every row, as for the capabilities: a clean majority does not launder an
    // unsigned observation into the quote.
    const r = ask(file(WORKING(), WORKING({ tester: '' }), WORKING()))
    assert.equal(r.answer, ANSWER.CAVEAT)
    assert.deepEqual(r.unsigned, [3], 'the unsigned row must be named by line')
  })

  test('the control still holds: signed and dated is WORKS', () => {
    assert.equal(ask(file(WORKING())).answer, ANSWER.WORKS)
  })
})

describe('RULE 5 — a physical row with no ids cannot be quoted from', () => {
  test('an empty ids column on a physical row refuses the file', () => {
    const e = refuses(file(WORKING({ ids: '' })), 'a physical row with no ids')
    assert.match(e.message, /empty ids column/, `the refusal did not name the column:\n${e.message}`)
    assert.match(e.message, /fixture\.tsv:2/, 'the refusal did not name the line')
  })

  test('the control: the same row WITH ids loads and quotes', () => {
    assert.equal(ask(file(WORKING())).answer, ANSWER.WORKS)
  })

  test('a vm row needs no ids — it has no hardware to identify', () => {
    assert.doesNotThrow(() => loadRows(file(WORKING({
      source: 'vm', ids: '', wifi: '', trackpad: '', suspend: '', brightness: '', webcam: '',
    })), 'fixture.tsv'))
  })

  test('a table whose header has no provenance or ids columns is refused as a schema error', () => {
    // Not quietly caveating every row for a reason that is really "the column is missing".
    for (const col of ['ids', 'tester', 'tested_on']) {
      const header = COLS.filter((c) => c !== col)
      const body = WORKING().split('\t').filter((_, i) => COLS[i] !== col).join('\t')
      const e = refuses(`${header.join('\t')}\n${body}\n`, `a header with no ${col}`)
      assert.match(e.message, new RegExp(`missing required column\\(s\\): ${col}`), e.message)
    }
  })
})

describe('the CLI, as a real process, with real exit codes', () => {
  let ROOT
  const root = () => (ROOT ??= mkdtempSync(join(tmpdir(), 'auros-quote-cli-')))
  let seq = 0
  const write = (text) => {
    const p = join(root(), `t-${seq++}.tsv`); writeFileSync(p, text); return p
  }
  const run = (args) => {
    try {
      return { exit: 0, out: execFileSync(process.execPath, [TOOL, ...args], { encoding: 'utf8', stdio: 'pipe', cwd: root() }) }
    } catch (e) {
      return { exit: e.status ?? -1, out: String(e.stdout ?? '') + String(e.stderr ?? '') }
    }
  }

  test('exit 0 and a readable report for a quotable model', () => {
    const r = run(['--file', write(file(WORKING())), MODEL])
    assert.equal(r.exit, 0, r.out)
    assert.match(r.out, /TESTED · WORKS/)
  })

  test('the attack end to end: an unsigned, undated row fails --require-quotable', () => {
    const path = write(file(WORKING({ tester: '', tested_on: '' })))
    const r = run(['--file', path, '--require-quotable', MODEL])
    assert.equal(r.exit, 3, `--require-quotable accepted an unsigned, undated row:\n${r.out}`)
    assert.doesNotMatch(r.out, /TESTED · WORKS/)
    assert.match(r.out, /TESTED · CAVEAT/)
  })

  test('a physical row with no ids exits 2 — refused, not quoted', () => {
    const r = run(['--file', write(file(WORKING({ ids: '' }))), MODEL])
    assert.equal(r.exit, 2, r.out)
    assert.match(r.out, /empty ids column/)
  })

  test('exit 0 — but NEVER SEEN — for a model with no row', () => {
    const r = run(['--file', write(file(WORKING())), 'Latitude-E6430'])
    assert.equal(r.exit, 0, 'not knowing is a normal answer, not an error')
    assert.match(r.out, /NEVER SEEN/)
  })

  test('--require-quotable exits 3 on a vm-only model and 0 on the physical control', () => {
    const vmOnly = write(file(WORKING({ source: 'vm', wifi: '', trackpad: '', suspend: '', brightness: '', webcam: '' })))
    assert.equal(run(['--file', vmOnly, '--require-quotable', MODEL]).exit, 3)
    assert.equal(run(['--file', write(file(WORKING())), '--require-quotable', MODEL]).exit, 0)
  })

  test('--require-quotable exits 3 when one column is empty — the whole point of rule 2', () => {
    const p = write(file(WORKING({ webcam: '' })))
    const r = run(['--file', p, '--require-quotable', MODEL])
    assert.equal(r.exit, 3)
    assert.match(r.out, /webcam/)
  })

  test('a dishonest file exits 2, and never 0 with a partial answer', () => {
    const bad = write(file(WORKING({ source: 'vm' })))   // a vm row claiming all five
    const r = run(['--file', bad, MODEL])
    assert.equal(r.exit, 2, r.out)
    assert.match(r.out, /vm row claiming/)
  })

  test('a missing table exits 2 and says where it looked', () => {
    const r = run(['--file', join(root(), 'gone.tsv'), MODEL])
    assert.equal(r.exit, 2)
    assert.match(r.out, /absent/)
  })

  test('no models at all is a usage refusal, not an empty success', () => {
    assert.equal(run(['--file', write(file(WORKING()))]).exit, 2)
  })

  test('--json carries the same answer as the text, machine-readably', () => {
    const r = run(['--file', write(file(WORKING({ webcam: '' }))), '--json', MODEL])
    assert.equal(r.exit, 0, r.out)
    const j = JSON.parse(r.out)
    assert.equal(j.results[0].answer, ANSWER.CAVEAT)
    assert.deepEqual(j.results[0].untested, ['webcam'])
    assert.equal(j.results[0].quotable, false)
  })

  test('--models-file reads a fleet list, skipping comments and blanks', () => {
    const list = join(root(), 'fleet.txt')
    writeFileSync(list, `# the school's asset register\n${MODEL}\n\nLatitude-E6430\n`)
    const r = run(['--file', write(file(WORKING())), '--models-file', list])
    assert.equal(r.exit, 0, r.out)
    assert.match(r.out, /2 model\(s\)/)
    assert.match(r.out, /1 tested and working/)
    assert.match(r.out, /1 never seen/)
  })

  test.after(() => { if (ROOT) rmSync(ROOT, { recursive: true, force: true }) })
})

// ─────────────────────────────────────────────────────────────────────────────────────────────────
describe('this tool and the real repository agree', () => {
  test('every column this tool reads exists in the real hardware/compat.tsv', () => {
    for (const c of ['model', 'source', 'verdict', 'ids', 'tpm', ...CAPABILITIES]) {
      assert.ok(COLS.includes(c), `${REAL_TSV} has no "${c}" column. Its header is: ${COLS.join(' | ')}`)
    }
  })

  test('the real compat.tsv loads, and every model in it is answerable', () => {
    const text = readFileSync(REAL_TSV, 'utf8')
    const rows = loadRows(text, REAL_TSV)
    for (const r of rows) assert.ok(classify(r.model, rows).say.length > 0)
  })

  test('the real compat.tsv has no physical row yet, so nothing is quotable from it', () => {
    // BLOCKED.md B5. If this goes red without a Gate 5 run behind it, a row was written from a VM
    // or from imagination and the one asset in this company that compounds has been poisoned at
    // row one. Delete this test when the first real laptop is imaged — and only then.
    const rows = loadRows(readFileSync(REAL_TSV, 'utf8'), REAL_TSV)
    assert.equal(rows.filter((r) => r.source === 'physical').length, 0)
  })
})
