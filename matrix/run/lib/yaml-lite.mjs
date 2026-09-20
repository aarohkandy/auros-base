// yaml-lite — a deliberately small YAML reader.
//
// WHY THIS EXISTS AND WHY IT IS NOT `js-yaml`:
// The harness must run on a bare runner with no `npm install` step. A missing dependency at gate time
// must never be able to turn a FAIL into a "could not evaluate", so the harness carries zero runtime
// dependencies (see run/README.md, "No dependency may stand between a failure and a red result").
//
// WHAT IT SUPPORTS — exactly what checks.yaml and profiles.yaml use, and nothing more:
//   block mappings, block sequences (of scalars or of mappings), nesting by indentation,
//   `>` / `>-` folded and `|` / `|-` literal block scalars, `#` comments, single/double quoted scalars,
//   and the scalar coercions true/false/null/integer.
//
// WHAT IT DOES NOT SUPPORT: flow collections ({}, []), anchors, aliases, tags, multi-document streams,
// complex keys. It THROWS on flow collections and anchors rather than guessing, because a parser that
// silently mis-reads the gate definition is worse than one that refuses.

const FLOW_RE = /^[^#]*:\s*[[{]/;

export function parseYaml(src) {
  const lines = String(src).split(/\r?\n/);
  const rows = [];
  for (let i = 0; i < lines.length; i++) {
    const raw = lines[i];
    if (/^\s*$/.test(raw)) { rows.push({ n: i + 1, blank: true, indent: -1, text: '', raw }); continue; }
    if (/^\s*#/.test(raw)) continue;
    const indent = raw.length - raw.replace(/^\s+/, '').length;
    rows.push({ n: i + 1, blank: false, indent, text: raw.slice(indent), raw });
  }
  const live = rows.filter((r) => !r.blank);
  for (const r of live) {
    if (/(^|\s)[&*][A-Za-z0-9_]/.test(r.text)) throw new Error(`yaml-lite: anchors/aliases unsupported (line ${r.n})`);
    if (FLOW_RE.test(r.text)) throw new Error(`yaml-lite: flow collections unsupported (line ${r.n})`);
  }
  const { value } = parseBlock(rows, 0, live.length ? live[0].indent : 0);
  return value;
}

// Parse the run of rows at `indent` starting at index `i`. Returns { value, i }.
function parseBlock(rows, i, indent) {
  // skip leading blanks
  while (i < rows.length && rows[i].blank) i++;
  if (i >= rows.length) return { value: null, i };
  if (rows[i].text.startsWith('- ') || rows[i].text === '-') return parseSeq(rows, i, indent);
  return parseMap(rows, i, indent);
}

function parseMap(rows, i, indent) {
  const out = {};
  while (i < rows.length) {
    const r = rows[i];
    if (r.blank) { i++; continue; }
    if (r.indent < indent) break;
    if (r.indent > indent) throw new Error(`yaml-lite: unexpected indent (line ${r.n}): ${r.raw}`);
    const m = /^([^:#]+):(?:\s+(.*))?$/.exec(r.text);
    if (!m) throw new Error(`yaml-lite: not a mapping entry (line ${r.n}): ${r.raw}`);
    const key = m[1].trim();
    const inline = (m[2] ?? '').trim();
    i++;
    if (inline === '' || inline === '>' || inline === '>-' || inline === '|' || inline === '|-' ||
        inline === '>+' || inline === '|+') {
      if (inline !== '') {
        const blk = readBlockScalar(rows, i, indent, inline);
        out[key] = blk.value; i = blk.i; continue;
      }
      // Nested block, or an explicitly empty value.
      let j = i; while (j < rows.length && rows[j].blank) j++;
      if (j >= rows.length || rows[j].indent <= indent) { out[key] = null; continue; }
      const sub = parseBlock(rows, j, rows[j].indent);
      out[key] = sub.value; i = sub.i; continue;
    }
    out[key] = scalar(stripComment(inline));
  }
  return { value: out, i };
}

function parseSeq(rows, i, indent) {
  const out = [];
  while (i < rows.length) {
    const r = rows[i];
    if (r.blank) { i++; continue; }
    if (r.indent < indent) break;
    if (r.indent > indent) throw new Error(`yaml-lite: unexpected indent in sequence (line ${r.n}): ${r.raw}`);
    if (!(r.text.startsWith('- ') || r.text === '-')) break;
    const rest = r.text === '-' ? '' : r.text.slice(2);
    if (rest === '') {
      i++;
      let j = i; while (j < rows.length && rows[j].blank) j++;
      if (j < rows.length && rows[j].indent > indent) { const sub = parseBlock(rows, j, rows[j].indent); out.push(sub.value); i = sub.i; }
      else out.push(null);
      continue;
    }
    // `- key: value` starts a mapping whose indent is indent+2; rewrite the row and re-parse in place.
    if (/^([^:#]+):(\s|$)/.test(rest)) {
      const childIndent = indent + 2;
      const synth = rows.slice();
      synth[i] = { ...r, indent: childIndent, text: rest };
      const sub = parseMap(synth, i, childIndent);
      out.push(sub.value); i = sub.i; continue;
    }
    out.push(scalar(stripComment(rest))); i++;
  }
  return { value: out, i };
}

function readBlockScalar(rows, i, parentIndent, marker) {
  const literal = marker.startsWith('|');
  const chomp = marker.includes('-') ? 'strip' : marker.includes('+') ? 'keep' : 'clip';
  const body = [];
  let bodyIndent = null;
  while (i < rows.length) {
    const r = rows[i];
    if (r.blank) { body.push(''); i++; continue; }
    if (r.indent <= parentIndent) break;
    if (bodyIndent === null) bodyIndent = r.indent;
    body.push(' '.repeat(Math.max(0, r.indent - bodyIndent)) + r.text);
    i++;
  }
  while (body.length && body[body.length - 1] === '') body.pop();
  let value;
  if (literal) value = body.join('\n');
  else {
    const parts = [];
    let cur = [];
    for (const line of body) {
      if (line === '') { parts.push(cur.join(' ')); cur = []; }
      else cur.push(line.trim());
    }
    parts.push(cur.join(' '));
    value = parts.join('\n');
  }
  if (chomp === 'clip') value += '\n';
  else if (chomp === 'keep') value += '\n';
  return { value, i };
}

function stripComment(s) {
  if (s.startsWith('"') || s.startsWith("'")) return s;
  const idx = s.search(/\s#/);
  return idx === -1 ? s : s.slice(0, idx).trim();
}

function scalar(s) {
  if (s === '') return null;
  if ((s.startsWith('"') && s.endsWith('"')) || (s.startsWith("'") && s.endsWith("'"))) return s.slice(1, -1);
  if (s === 'true') return true;
  if (s === 'false') return false;
  if (s === 'null' || s === '~') return null;
  if (/^-?\d+$/.test(s)) return Number(s);
  if (/^-?\d+\.\d+$/.test(s)) return Number(s);
  return s;
}
