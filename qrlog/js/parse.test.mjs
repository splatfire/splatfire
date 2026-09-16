/**
 * Unit tests for the dictation parser.
 *
 *   node --test qrlog/js/parse.test.mjs
 *
 * The cases are written the way a technician actually speaks: one long take,
 * no punctuation, filler words, spoken numbers.
 */

import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  parseDictation, normalizeDecimals, findDate, findEntryDate,
  splitSentences, classify, detectKind,
} from './parse.js';

const TODAY = new Date(2026, 8, 16); // 16 September 2026

test('spoken decimals become numbers', () => {
  assert.equal(normalizeDecimals('Soledruck war eins komma vier bar'), 'Soledruck war 1.4 bar');
  assert.equal(normalizeDecimals('Vordruck 1 komma 8 bar'), 'Vordruck 1.8 bar');
  assert.equal(normalizeDecimals('zwei Filter getauscht'), 'zwei Filter getauscht');
});

test('absolute dates', () => {
  assert.equal(findDate('nächster Service am 14.03.2027', TODAY), '2027-03-14');
  assert.equal(findDate('am 1.4.27 wieder', TODAY), '2027-04-01');
  assert.equal(findDate('am 16. September 2027', TODAY), '2027-09-16');
  // A bare day/month rolls to next year once it is past.
  assert.equal(findDate('am 1.3. wieder vorbei', TODAY), '2027-03-01');
  assert.equal(findDate('am 1.12. wieder vorbei', TODAY), '2026-12-01');
});

test('relative dates', () => {
  assert.equal(findDate('in einem Jahr wieder', TODAY), '2027-09-16');
  assert.equal(findDate('in sechs Monaten', TODAY), '2027-03-16');
  assert.equal(findDate('in 2 Jahren', TODAY), '2028-09-16');
  assert.equal(findDate('in einem halben Jahr', TODAY), '2027-03-16');
  assert.equal(findDate('nächstes Jahr wieder', TODAY), '2027-09-16');
  assert.equal(findDate('in zwei Wochen', TODAY), '2026-09-30');
  assert.equal(findDate('irgendwann mal', TODAY), null);
});

test('gestern moves the entry date', () => {
  assert.equal(findEntryDate('war gestern dort', TODAY), '2026-09-15');
  assert.equal(findEntryDate('war vorgestern dort', TODAY), '2026-09-14');
  assert.equal(findEntryDate('heute war ich dort', TODAY), null);
});

test('sentences split on spoken connectors, not on every und', () => {
  const parts = splitSentences('Filter gewechselt und gereinigt und dann den Druck geprüft');
  assert.equal(parts.length, 2);
  assert.equal(parts[0], 'Filter gewechselt und gereinigt');
});

test('kind is detected from the strongest cue', () => {
  assert.equal(detectKind('Jahreswartung gemacht, dabei den Filter ausgetauscht'), 'Wartung');
  assert.equal(detectKind('Störung behoben, Anlage stand still'), 'Störung');
  assert.equal(detectKind('nur kurz kontrolliert'), 'Kontrolle');
  assert.equal(detectKind('Kaffee getrunken'), null);
});

test('sentences route to the right field', () => {
  assert.equal(classify('Filter gewechselt', TODAY), 'work');
  assert.equal(classify('Umwälzpumpe läuft unruhig', TODAY), 'findings');
  assert.equal(classify('verbaut habe ich einen Solefilter', TODAY), 'parts');
  assert.equal(classify('nächster Service in einem Jahr', TODAY), 'nextService');
  // Mentions the next service but names no date — that is a note, not a date.
  assert.equal(classify('beim nächsten Service die Anode anschauen', TODAY), 'work');
});

test('a full ramble fills the form', () => {
  const transcript =
    'Also heute Jahreswartung an der Wärmepumpe gemacht, Filter gewechselt und den ' +
    'Soledruck kontrolliert, war bei eins komma vier bar. Dann ist mir aufgefallen dass ' +
    'die Umwälzpumpe unruhig läuft, das müssen wir beobachten. Verbaut habe ich einen ' +
    'Solefilter-Einsatz. Nächster Service in einem Jahr.';

  const result = parseDictation(transcript, { today: TODAY });

  assert.equal(result.kind, 'Wartung');
  assert.equal(result.nextService, '2027-09-16');
  assert.match(result.work, /Filter gewechselt/);
  assert.match(result.work, /1\.4 bar/);
  assert.match(result.findings, /unruhig/);
  assert.match(result.parts, /Solefilter-Einsatz/);
  // Each part of the ramble lands in exactly one field.
  assert.doesNotMatch(result.work, /unruhig/);
  assert.doesNotMatch(result.findings, /Filter gewechselt/);
});

test('a fault call reads as a fault call', () => {
  const result = parseDictation(
    'Störung, die Anlage stand still. Sicherung war raus, wieder eingeschaltet und ' +
      'Fehlerspeicher gelöscht. Der Schütz ist verschmort, muss ersetzt werden. ' +
      'Ich komme nächste Woche wieder.',
    { today: TODAY }
  );
  assert.equal(result.kind, 'Störung');
  assert.equal(result.nextService, '2026-09-23');
  assert.match(result.findings, /muss ersetzt werden/);
  assert.match(result.work, /Fehlerspeicher/);
});

test('an empty or useless transcript proposes nothing', () => {
  const result = parseDictation('', { today: TODAY });
  assert.equal(result.work, '');
  assert.equal(result.findings, '');
  assert.equal(result.parts, '');
  assert.equal(result.kind, null);
  assert.equal(result.nextService, null);
  assert.deepEqual(result.sentences, []);
});

test('unclassifiable speech all lands in work rather than being dropped', () => {
  const result = parseDictation('Bin kurz vorbeigefahren und habe nach dem Rechten gesehen.', {
    today: TODAY,
  });
  assert.match(result.work, /vorbeigefahren/);
  assert.match(result.work, /nach dem Rechten/);
  assert.equal(result.findings, '');
});
