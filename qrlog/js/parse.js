/**
 * Turn one spoken ramble into the fields of a logbook entry.
 *
 * A technician standing in front of a boiler will not dictate field by field.
 * They say one long thing: what they did, what they noticed, what they fitted,
 * when they want to come back. This module splits that into the form's fields.
 *
 * It is a rule-based German parser, not a language model — everything here runs
 * on the device with no network, which is the whole point of the app. It gets
 * plainly-spoken sentences right and unusual phrasing wrong, so the UI shows
 * what it proposes and the technician confirms before anything is filled in.
 *
 * Every export is a pure function so the rules can be unit tested.
 */

/* ---------- Vocabulary ---------- */

const NUMBER_WORDS = {
  null: 0, ein: 1, eine: 1, einem: 1, einen: 1, eins: 1, zwei: 2, drei: 3,
  vier: 4, fünf: 5, fuenf: 5, sechs: 6, sieben: 7, acht: 8, neun: 9, zehn: 10,
  elf: 11, zwölf: 12, zwoelf: 12, achtzehn: 18, vierundzwanzig: 24,
};

const MONTHS = {
  januar: 1, februar: 2, märz: 3, maerz: 3, april: 4, mai: 5, juni: 6,
  juli: 7, august: 8, september: 9, oktober: 10, november: 11, dezember: 12,
};

/** Weighted cues per entry kind — a spoken noun counts for more than a verb. */
const KIND_CUES = {
  'Störung': [['störung', 3], ['stoerung', 3], ['ausgefallen', 2], ['alarm', 2], ['notfall', 3], ['steht still', 2], ['läuft nicht', 2]],
  'Reparatur': [['reparatur', 3], ['repariert', 2], ['instandgesetzt', 2], ['ausgetauscht', 1], ['ausgewechselt', 1]],
  'Inbetriebnahme': [['inbetriebnahme', 3], ['in betrieb genommen', 3], ['erstinbetriebnahme', 3]],
  'Installation': [['installation', 3], ['installiert', 2], ['neu montiert', 2], ['neu eingebaut', 2]],
  'Kontrolle': [['kontrolle', 3], ['kontrolliert', 2], ['überprüft', 1], ['ueberprueft', 1], ['messung', 2], ['abnahme', 2]],
  'Wartung': [['wartung', 3], ['gewartet', 2], ['service', 2], ['jahreswartung', 3], ['unterhalt', 2]],
};

/** Cues that route a sentence to a field. */
const FIELD_CUES = {
  nextService: [
    'nächster service', 'naechster service', 'nächste wartung', 'naechste wartung',
    'nächster termin', 'naechster termin', 'wiedervorlage', 'nächstes mal komme',
    'wieder vorbei', 'wieder kommen', 'wiederkommen', 'nächster besuch',
  ],
  parts: [
    'verbaut', 'eingebaut habe', 'material', 'ersatzteil', 'ersatzteile',
    'verwendet', 'eingesetzt habe', 'mitgenommen', 'geliefert', 'bezogen',
    'stück', 'stueck', 'artikelnummer',
  ],
  findings: [
    'aufgefallen', 'befund', 'zustand', 'unruhig', 'defekt', 'undicht', 'leckt',
    'tropft', 'korrodiert', 'rost', 'verschmutzt', 'abgenutzt', 'abgetragen',
    'verschlissen', 'beobachten', 'im auge behalten', 'muss ersetzt',
    'muss getauscht', 'sollte ersetzt', 'sollte getauscht', 'auffällig',
    'auffaellig', 'problem', 'mangel', 'riss', 'verkalkt', 'zu wenig druck',
    'macht geräusche', 'macht geraeusche', 'läuft laut', 'im argen',
  ],
};

/** Discourse markers people use instead of full stops when speaking. */
const SPLIT_MARKERS = [
  'und dann', 'dann noch', 'danach', 'anschliessend', 'anschließend',
  'ausserdem', 'außerdem', 'zudem', 'zusätzlich', 'zusaetzlich', 'übrigens',
  'uebrigens', 'ach ja', 'weiter ist', 'was noch', 'dann',
];

const FILLERS = /^(also|ähm|ahm|äh|ah|öhm|ohm|hm+|so|ja|gut|okay|ok|halt|eben|jetzt)\b[\s,]*/i;

/** Private marker for sentence boundaries — never appears in dictated text. */
const BREAK = '\u0001';

/* ---------- Text normalisation ---------- */

/**
 * Speech recognition writes numbers as words often enough that "eins komma
 * vier bar" would otherwise be unsearchable. Only decimals are rewritten;
 * plain counts are left as spoken, because "zwei Filter" reads fine.
 */
export function normalizeDecimals(text) {
  const word = Object.keys(NUMBER_WORDS).join('|');
  return text.replace(
    new RegExp(`\\b(\\d+|${word})\\s+komma\\s+(\\d+|${word})\\b`, 'gi'),
    (_, a, b) => `${toNumber(a)}.${toNumber(b)}`
  );
}

function toNumber(token) {
  if (/^\d+$/.test(token)) return Number(token);
  const value = NUMBER_WORDS[String(token).toLowerCase()];
  return value ?? token;
}

/* ---------- Dates ---------- */

function iso(date) {
  const tz = new Date(date.getTime() - date.getTimezoneOffset() * 60000);
  return tz.toISOString().slice(0, 10);
}

function shift(from, { months = 0, days = 0 }) {
  const date = new Date(from.getTime());
  date.setMonth(date.getMonth() + months);
  date.setDate(date.getDate() + days);
  return date;
}

/**
 * Find a date in one sentence, absolute ("16.9.2027", "16. September") or
 * relative to `today` ("in einem Jahr", "nächstes Jahr", "in 6 Monaten").
 * Returns an ISO date string or null.
 */
export function findDate(sentence, today = new Date()) {
  const text = sentence.toLowerCase();

  const isoMatch = text.match(/\b(\d{4})-(\d{2})-(\d{2})\b/);
  if (isoMatch) return isoMatch[0];

  const numeric = text.match(/\b(\d{1,2})\.\s*(\d{1,2})\.\s*(\d{2,4})?/);
  if (numeric) {
    const [, d, m, y] = numeric;
    const year = y
      ? (y.length === 2 ? 2000 + Number(y) : Number(y))
      : inferYear(today, Number(m), Number(d));
    return iso(new Date(year, Number(m) - 1, Number(d)));
  }

  const monthNames = Object.keys(MONTHS).join('|');
  const named = text.match(new RegExp(`\\b(?:(\\d{1,2})\\.?\\s*)?(${monthNames})\\b\\s*(\\d{4})?`, 'i'));
  if (named) {
    const [, d, name, y] = named;
    const month = MONTHS[name.toLowerCase()];
    const day = d ? Number(d) : 1;
    const year = y ? Number(y) : inferYear(today, month, day);
    return iso(new Date(year, month - 1, day));
  }

  if (/\bin\s+(einem\s+)?halben\s+jahr\b/.test(text)) return iso(shift(today, { months: 6 }));

  const words = Object.keys(NUMBER_WORDS).join('|');
  const relative = text.match(
    new RegExp(
      `\\bin\\s+(?:etwa\\s+|ca\\.?\\s+|circa\\s+|rund\\s+)?(\\d+|${words})\\s+(jahr(?:en?)?|monat(?:en?)?|woche(?:n)?|tag(?:en?)?)\\b`,
      'i'
    )
  );
  if (relative) {
    const n = Number(toNumber(relative[1]));
    const unit = relative[2].toLowerCase();
    if (!Number.isFinite(n)) return null;
    if (unit.startsWith('jahr')) return iso(shift(today, { months: n * 12 }));
    if (unit.startsWith('monat')) return iso(shift(today, { months: n }));
    if (unit.startsWith('woche')) return iso(shift(today, { days: n * 7 }));
    return iso(shift(today, { days: n }));
  }

  if (/\bnächstes jahr\b|\bnaechstes jahr\b/.test(text)) return iso(shift(today, { months: 12 }));
  if (/\bnächsten monat\b|\bnaechsten monat\b/.test(text)) return iso(shift(today, { months: 1 }));
  if (/\bnächste woche\b|\bnaechste woche\b/.test(text)) return iso(shift(today, { days: 7 }));
  return null;
}

/** A bare "16.9." means the next one that has not gone past yet. */
function inferYear(today, month, day) {
  const thisYear = new Date(today.getFullYear(), month - 1, day);
  return thisYear < today ? today.getFullYear() + 1 : today.getFullYear();
}

/** "gestern" / "vorgestern" move the entry's own date. */
export function findEntryDate(text, today = new Date()) {
  const lower = text.toLowerCase();
  if (/\bvorgestern\b/.test(lower)) return iso(shift(today, { days: -2 }));
  if (/\bgestern\b/.test(lower)) return iso(shift(today, { days: -1 }));
  return null;
}

/* ---------- Sentence splitting and routing ---------- */

export function splitSentences(text) {
  // One pass with the markers sorted longest first: JS alternation is
  // leftmost-first, so "und dann" has to be offered before "dann" or the
  // sentence gets broken twice at the same place.
  const alternation = [...SPLIT_MARKERS]
    .sort((a, b) => b.length - a.length)
    .join('|');
  const marked = text
    .replace(/([.!?;:])\s+/g, `$1${BREAK}`)
    .replace(new RegExp(`(?:^|[,.;\\s])(?:${alternation})\\b`, 'gi'), `${BREAK}$&`);
  return marked
    .split(BREAK)
    .map((s) => s.replace(/^[\s,.;:]+/, '').replace(FILLERS, '').trim())
    .filter((s) => s.length > 2);
}

function cueScore(sentence, cues) {
  const lower = sentence.toLowerCase();
  return cues.reduce((score, cue) => (lower.includes(cue) ? score + cue.length : score), 0);
}

/**
 * Which field a sentence belongs in. `nextService` only wins when the sentence
 * actually names a time — "beim nächsten Service schauen wir die Anode an" is
 * a note to the next technician, not a date.
 */
export function classify(sentence, today = new Date()) {
  const scores = {
    nextService: cueScore(sentence, FIELD_CUES.nextService),
    parts: cueScore(sentence, FIELD_CUES.parts),
    findings: cueScore(sentence, FIELD_CUES.findings),
  };
  if (scores.nextService > 0 && findDate(sentence, today)) return 'nextService';
  if (scores.parts > 0 && scores.parts >= scores.findings) return 'parts';
  if (scores.findings > 0) return 'findings';
  return 'work';
}

export function detectKind(text) {
  const lower = text.toLowerCase();
  let best = null;
  let bestScore = 0;
  for (const [kind, cues] of Object.entries(KIND_CUES)) {
    const score = cues.reduce((sum, [cue, weight]) => (lower.includes(cue) ? sum + weight : sum), 0);
    if (score > bestScore) {
      bestScore = score;
      best = kind;
    }
  }
  return best;
}

/* ---------- The whole thing ---------- */

/**
 * Parse a transcript into proposed field values.
 *
 * Returns the fields plus the sentence-by-sentence routing, so the UI can show
 * its work instead of asking the user to trust it.
 */
export function parseDictation(transcript, { today = new Date() } = {}) {
  const text = normalizeDecimals(String(transcript || '').trim());
  const sentences = splitSentences(text);

  const buckets = { work: [], findings: [], parts: [] };
  const routed = [];
  let nextService = null;

  for (const sentence of sentences) {
    const field = classify(sentence, today);
    routed.push({ text: sentence, field });
    if (field === 'nextService') nextService ??= findDate(sentence, today);
    else buckets[field].push(sentence);
  }

  // A date said anywhere counts, as long as the speaker framed it as the next
  // visit — people often trail off with "und dann in einem Jahr wieder".
  if (!nextService) {
    for (const { text: sentence } of routed) {
      if (!/wieder|nächst|naechst|erneut|turnus/i.test(sentence)) continue;
      nextService = findDate(sentence, today);
      if (nextService) break;
    }
  }

  return {
    work: joinSentences(buckets.work),
    findings: joinSentences(buckets.findings),
    parts: joinSentences(buckets.parts),
    kind: detectKind(text),
    date: findEntryDate(text, today),
    nextService,
    sentences: routed,
  };
}

function joinSentences(sentences) {
  return sentences
    .map((s) => {
      const trimmed = s.replace(/\s+/g, ' ').trim();
      const cased = trimmed.charAt(0).toUpperCase() + trimmed.slice(1);
      return /[.!?]$/.test(cased) ? cased : `${cased}.`;
    })
    .join(' ');
}

export const FIELD_LABELS = {
  work: 'Ausgeführte Arbeiten',
  findings: 'Befund / Zustand',
  parts: 'Verbautes Material',
  nextService: 'Nächster Service',
};

/* ---------- Anlage master data ---------- */

/** Things a Gebäudetechnik technician stands in front of. */
const ASSET_TYPES = [
  'sole/wasser-wärmepumpe', 'luft/wasser-wärmepumpe', 'wärmepumpe', 'gasheizung',
  'ölheizung', 'pelletheizung', 'holzheizung', 'fernwärme', 'heizkessel', 'kessel',
  'brenner', 'boiler', 'wassererwärmer', 'wärmespeicher', 'lüftungsanlage', 'lüftung',
  'komfortlüftung', 'klimaanlage', 'kältemaschine', 'rückkühler', 'solaranlage',
  'photovoltaik', 'pv-anlage', 'umwälzpumpe', 'unterverteilung', 'notstromaggregat',
  'hebeanlage', 'enthärtungsanlage', 'druckerhöhungsanlage', 'brandmeldeanlage',
];

/** Cue words that introduce a value, longest first so "typenbezeichnung" beats "typ". */
const LABELLED_FIELDS = {
  manufacturer: ['hersteller', 'fabrikat', 'marke'],
  model: ['typenbezeichnung', 'modellbezeichnung', 'baureihe', 'modell', 'typ'],
  serial: ['fabrikationsnummer', 'seriennummer', 'gerätenummer', 'geraetenummer', 'serial'],
  location: ['standort', 'befindet sich im', 'befindet sich in', 'steht im', 'steht in', 'montiert im'],
};

/** Words that end a dictated value — "Hersteller Viessmann Modell Vitocal". */
const VALUE_STOPPERS = [
  ...Object.values(LABELLED_FIELDS).flat(),
  'baujahr', 'in betrieb', 'serviceintervall', 'wartungsintervall', 'alle',
];

/**
 * Pull the value that follows a cue word, up to the next cue word or clause end.
 * "Hersteller ist Viessmann, Modell Vitocal 200" -> "Viessmann".
 */
function valueAfter(text, cues) {
  const lower = text.toLowerCase();
  for (const cue of cues) {
    const at = lower.indexOf(cue);
    if (at === -1) continue;
    let rest = text.slice(at + cue.length);
    rest = rest.replace(/^[\s:,-]*(?:ist|sind|wäre|waere)?\s*(?:der|die|das|ein|eine)?\s*/i, '');
    const cut = rest.split(/[,.;]/)[0];
    const stop = VALUE_STOPPERS.map((s) => cut.toLowerCase().indexOf(s)).filter((i) => i > 0);
    const value = (stop.length ? cut.slice(0, Math.min(...stop)) : cut)
      .replace(FILLERS, '')
      .trim();
    // "Hersteller, ähm, weiss ich nicht" must leave the field empty rather than
    // filling it with a hesitation.
    if (value && !FILLERS.test(`${value} `)) return value;
  }
  return '';
}

/** How often the thing wants seeing: "alle zwei Jahre", "jährlich", "alle 6 Monate". */
export function findInterval(text) {
  const lower = text.toLowerCase();
  if (/\bhalbjährlich\b|\bhalbjaehrlich\b/.test(lower)) return 6;
  if (/\bvierteljährlich\b|\bvierteljaehrlich\b|\bquartal\b/.test(lower)) return 3;
  if (/\bjährlich\b|\bjaehrlich\b|\bjedes jahr\b/.test(lower)) return 12;
  if (/\bmonatlich\b/.test(lower)) return 1;

  const words = Object.keys(NUMBER_WORDS).join('|');
  const every = lower.match(
    new RegExp(`\\ball[e]?\\s+(\\d+|${words})\\s+(jahr(?:en?)?|monat(?:en?)?)\\b`, 'i')
  );
  if (every) {
    const n = Number(toNumber(every[1]));
    if (!Number.isFinite(n)) return null;
    return every[2].startsWith('jahr') ? n * 12 : n;
  }

  const named = lower.match(
    new RegExp(`(?:service|wartungs)intervall\\D{0,12}(\\d+|${words})\\s*(jahr(?:en?)?|monat(?:en?)?)?`, 'i')
  );
  if (named) {
    const n = Number(toNumber(named[1]));
    if (!Number.isFinite(n)) return null;
    return named[2] && named[2].startsWith('jahr') ? n * 12 : n;
  }
  return null;
}

/**
 * Parse a spoken description of an installation into the Anlage sheet.
 *
 * Unlike a logbook entry this is mostly labelled values — "Hersteller Viessmann,
 * Seriennummer 2024-88213, Baujahr 2019" — so it reads cue words rather than
 * routing whole sentences, and anything it cannot place is kept as notes.
 */
export function parseAsset(transcript, { today = new Date() } = {}) {
  const text = String(transcript || '').trim();
  const lower = text.toLowerCase();

  const manufacturer = valueAfter(text, LABELLED_FIELDS.manufacturer);
  const model = valueAfter(text, LABELLED_FIELDS.model);
  const serial = valueAfter(text, LABELLED_FIELDS.serial).replace(/\s+/g, '');
  let location = valueAfter(text, LABELLED_FIELDS.location);

  // Rooms are often named without any cue: "die Wärmepumpe im Technikraum UG".
  if (!location) {
    const room = text.match(
      /\b(?:im|in der|in den)\s+((?:unter|ober|dach)?geschoss|technikraum|heizraum|keller\w*|estrich|dachstock|maschinenraum|garage|waschküche|waschkueche)\b[^,.;]*/i
    );
    if (room) location = room[0].replace(/^\s*(?:im|in der|in den)\s+/i, '').trim();
  }

  const type = ASSET_TYPES.find((candidate) => lower.includes(candidate)) ?? '';
  const titleCase = (s) => s.replace(/(^|[\s/-])(\p{Ll})/gu, (_, sep, ch) => sep + ch.toUpperCase());

  const year = lower.match(/\b(?:baujahr|jahrgang)\D{0,6}(\d{4})\b/);
  const installedOn = year
    ? `${year[1]}-01-01`
    : (/\bin betrieb\b|\binstalliert\b|\bmontiert\b/.test(lower) ? findDate(text, today) : null);

  const found = { manufacturer, model, serial, location, type, installedOn };
  const notes = splitSentences(text)
    .filter((sentence) => !describesOnly(sentence, found))
    .join(' ');

  return {
    name: type ? titleCase([type, location].filter(Boolean).join(' ')) : '',
    type: type ? titleCase(type) : '',
    location,
    manufacturer,
    model,
    serial,
    installedOn: installedOn ?? '',
    intervalMonths: findInterval(text),
    notes,
  };
}

/**
 * True when a sentence carried nothing but values already extracted, so it
 * would only repeat itself in the notes.
 */
function describesOnly(sentence, found) {
  let rest = sentence;
  for (const value of Object.values(found)) {
    if (value) rest = rest.replace(new RegExp(escapeRegex(String(value)), 'gi'), ' ');
  }
  for (const cue of [...VALUE_STOPPERS, 'ist', 'sind', 'der', 'die', 'das', 'ein', 'eine', 'im', 'in', 'und']) {
    rest = rest.replace(new RegExp(`\\b${escapeRegex(cue)}\\b`, 'gi'), ' ');
  }
  return rest.replace(/[\s\d.,;:/-]/g, '').length < 4;
}

function escapeRegex(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

export const ASSET_FIELD_LABELS = {
  name: 'Bezeichnung',
  type: 'Anlagetyp',
  location: 'Standort',
  manufacturer: 'Hersteller',
  model: 'Modell',
  serial: 'Seriennummer',
  installedOn: 'In Betrieb seit',
  intervalMonths: 'Serviceintervall (Monate)',
  notes: 'Notizen',
};
