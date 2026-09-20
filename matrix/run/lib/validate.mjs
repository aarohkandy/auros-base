// validate.mjs — a small JSON Schema (draft 2020-12 subset) validator.
//
// Same reason as yaml-lite: zero dependencies. `ajv` would be better in every way except the one that
// matters here — if `npm install` fails on a runner, an ajv-based harness reports "could not validate",
// and the schema itself says an unvalidatable result is a FAIL, never an unknown. A validator that is
// always present is worth more than a validator that is occasionally better.
//
// Supported keywords: type, enum, const, pattern, minimum, maximum, minItems, maxItems, minLength,
// required, properties, additionalProperties, items, format (date-time only, and only loosely).
// UNSUPPORTED keywords are a hard error, not a silent pass — see assertSupported(). That is the whole
// safety property: this validator can never approve a schema it does not fully understand.

const SUPPORTED = new Set([
  '$schema', '$id', 'title', 'description', 'type', 'enum', 'const', 'pattern', 'minimum', 'maximum',
  'minItems', 'maxItems', 'minLength', 'maxLength', 'required', 'properties', 'additionalProperties',
  'items', 'format',
]);

export function assertSupported(schema, path = '#') {
  if (schema === true || schema === false) return;
  if (typeof schema !== 'object' || schema === null) throw new Error(`validate: schema at ${path} is not an object`);
  for (const k of Object.keys(schema)) {
    if (!SUPPORTED.has(k)) throw new Error(`validate: unsupported schema keyword "${k}" at ${path} — refusing to validate against a schema this validator does not fully implement`);
  }
  if (schema.properties) for (const [k, v] of Object.entries(schema.properties)) assertSupported(v, `${path}/properties/${k}`);
  if (schema.items) assertSupported(schema.items, `${path}/items`);
  if (schema.additionalProperties && typeof schema.additionalProperties === 'object') assertSupported(schema.additionalProperties, `${path}/additionalProperties`);
}

export function validate(schema, data) {
  assertSupported(schema);
  const errors = [];
  walk(schema, data, '', errors);
  return errors;
}

function typeOf(v) {
  if (v === null) return 'null';
  if (Array.isArray(v)) return 'array';
  if (Number.isInteger(v)) return 'integer';
  return typeof v === 'number' ? 'number' : typeof v;
}

function typeMatches(want, v) {
  const t = typeOf(v);
  if (want === 'number') return t === 'number' || t === 'integer';
  if (want === 'object') return t === 'object';
  return want === t;
}

function walk(schema, data, path, errors) {
  const at = path || '(root)';
  if (schema === true) return;
  if (schema === false) { errors.push(`${at}: schema forbids any value`); return; }

  if (schema.type !== undefined) {
    const wants = Array.isArray(schema.type) ? schema.type : [schema.type];
    if (!wants.some((w) => typeMatches(w, data))) {
      errors.push(`${at}: expected type ${wants.join('|')}, got ${typeOf(data)}`);
      return; // further keywords would only produce noise
    }
  }
  if (schema.enum !== undefined && !schema.enum.some((e) => JSON.stringify(e) === JSON.stringify(data))) {
    errors.push(`${at}: ${JSON.stringify(data)} is not one of ${JSON.stringify(schema.enum)}`);
  }
  if (schema.const !== undefined && JSON.stringify(schema.const) !== JSON.stringify(data)) {
    errors.push(`${at}: expected const ${JSON.stringify(schema.const)}`);
  }
  if (typeof data === 'string') {
    if (schema.pattern !== undefined && !new RegExp(schema.pattern).test(data)) {
      errors.push(`${at}: ${JSON.stringify(data)} does not match /${schema.pattern}/`);
    }
    if (schema.minLength !== undefined && data.length < schema.minLength) errors.push(`${at}: shorter than minLength ${schema.minLength}`);
    if (schema.maxLength !== undefined && data.length > schema.maxLength) errors.push(`${at}: longer than maxLength ${schema.maxLength}`);
    if (schema.format === 'date-time' && !isDateTime(data)) errors.push(`${at}: ${JSON.stringify(data)} is not an RFC3339 date-time`);
  }
  if (typeof data === 'number') {
    if (schema.minimum !== undefined && data < schema.minimum) errors.push(`${at}: ${data} < minimum ${schema.minimum}`);
    if (schema.maximum !== undefined && data > schema.maximum) errors.push(`${at}: ${data} > maximum ${schema.maximum}`);
  }
  if (Array.isArray(data)) {
    if (schema.minItems !== undefined && data.length < schema.minItems) errors.push(`${at}: ${data.length} items < minItems ${schema.minItems}`);
    if (schema.maxItems !== undefined && data.length > schema.maxItems) errors.push(`${at}: ${data.length} items > maxItems ${schema.maxItems}`);
    if (schema.items !== undefined) data.forEach((v, i) => walk(schema.items, v, `${path}[${i}]`, errors));
  }
  if (data && typeof data === 'object' && !Array.isArray(data)) {
    for (const req of schema.required ?? []) {
      if (!Object.prototype.hasOwnProperty.call(data, req)) errors.push(`${at}: missing required property "${req}"`);
    }
    const props = schema.properties ?? {};
    for (const [k, v] of Object.entries(data)) {
      if (Object.prototype.hasOwnProperty.call(props, k)) walk(props[k], v, `${path}/${k}`, errors);
      else if (schema.additionalProperties === false) errors.push(`${at}: additional property "${k}" is not permitted`);
      else if (schema.additionalProperties && typeof schema.additionalProperties === 'object') walk(schema.additionalProperties, v, `${path}/${k}`, errors);
    }
  }
}

function isDateTime(s) {
  if (!/^\d{4}-\d{2}-\d{2}[Tt]\d{2}:\d{2}:\d{2}(\.\d+)?([Zz]|[+-]\d{2}:\d{2})$/.test(s)) return false;
  return !Number.isNaN(Date.parse(s));
}
