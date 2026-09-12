#!/usr/bin/env node
/**
 * Acceptance test 8, runnable anywhere Node is: every hot-path query uses an
 * index and does not scan a table.
 *
 * This exists as a Node script rather than a Swift test for one reason: it can
 * run on any CI machine in under a second, so a query regression is caught on
 * every push rather than only on the macOS runner. The schema it checks is the
 * same `001_init.sql` the app ships — one source of truth, no transcription.
 *
 * It also guards against drift: each query must appear verbatim in the Swift
 * file that claims to own it, so nobody can tune a query in Swift and leave
 * this file asserting a plan that no longer exists.
 *
 *   node tools/schema-check/check.mjs
 */
import { DatabaseSync } from 'node:sqlite';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const repo = join(here, '..', '..');

const schema = readFileSync(
  join(repo, 'Sources/PunchlistCore/Resources/Migrations/001_init.sql'), 'utf8');
const manifest = JSON.parse(readFileSync(join(here, 'queries.json'), 'utf8'));

const normalise = (s) => s.replace(/\s+/g, ' ').trim();

const db = new DatabaseSync(':memory:');
db.exec('PRAGMA foreign_keys = ON');
db.exec(schema);

// Representative data. The planner picks plans partly from table statistics, so
// an empty database would happily "prove" that every query uses an index. These
// volumes are roughly a working inspector's first year.
seed(db);
db.exec('ANALYZE');

let failures = 0;
let checked = 0;

console.log('Hot-path query plans\n');

for (const q of manifest.queries) {
  checked++;
  const plan = db.prepare('EXPLAIN QUERY PLAN ' + q.sql).all(...q.params);
  const detail = plan.map((r) => r.detail).join(' | ');

  const problems = [];
  const scans = plan.filter(
    (r) => /\bSCAN\b/.test(r.detail) && !/USING (COVERING )?INDEX/.test(r.detail));
  if (scans.length && !q.allowScan) {
    problems.push('table scan: ' + scans.map((s) => s.detail).join('; '));
  }
  if (q.forbidSort && /USE TEMP B-TREE FOR ORDER BY/.test(detail)) {
    problems.push('sorts instead of reading the order from an index');
  }

  // Drift guard: the query must actually exist in the Swift file that owns it.
  if (q.source) {
    const src = normalise(readFileSync(join(repo, q.source), 'utf8'));
    if (!src.includes(normalise(q.sql))) {
      problems.push(`not found verbatim in ${q.source} — the manifest has drifted`);
    }
  }

  if (problems.length) {
    failures++;
    console.log(`  FAIL  ${q.name}`);
    for (const p of problems) console.log(`        ${p}`);
    console.log(`        plan: ${detail}`);
  } else {
    const note = q.allowScan ? ' (scan allowed: ' + (q.note ?? '') + ')' : '';
    console.log(`  ok    ${q.name}${note}`);
  }
}

console.log(`\n${checked - failures}/${checked} hot-path queries indexed.`);
if (failures) {
  console.error(`\n${failures} quer${failures === 1 ? 'y' : 'ies'} would scan. ` +
    'Add an index or change the query — do not relax this check.');
  process.exit(1);
}

function seed(db) {
  const now = Date.now();
  const hlc = (n) => String(n).padStart(15, '0') + ':00000:aaaaaaaaaaaa';
  const ins = (sql) => db.prepare(sql);

  db.exec('BEGIN');
  ins(`INSERT INTO org (id,name,hlc,created_at,updated_at) VALUES ('org','Acme',?,?,?)`)
    .run(hlc(now), now, now);
  ins(`INSERT INTO inspector (id,org_id,name,hlc,created_at,updated_at) VALUES ('insp','org','A',?,?,?)`)
    .run(hlc(now), now, now);
  ins(`INSERT INTO template (id,org_id,name,discipline,version,hlc,created_at,updated_at)
       VALUES ('t1','org','Residential','home',1,?,?,?)`).run(hlc(now), now, now);

  const sectionStmt = ins(`INSERT INTO template_section (id,template_id,title,sort_order,hlc,created_at,updated_at)
       VALUES (?,?,?,?,?,?,?)`);
  const itemStmt = ins(`INSERT INTO template_item (id,section_id,label,input_type,required,sort_order,hlc,created_at,updated_at)
       VALUES (?,?,?,?,0,?,?,?,?)`);
  for (let s = 0; s < 8; s++) {
    const sid = s === 0 ? 's1' : `s${s + 1}`;
    sectionStmt.run(sid, 't1', `Section ${s}`, s, hlc(now), now, now);
    for (let i = 0; i < 9; i++) {
      itemStmt.run(`item${s}_${i}`, sid, `Item ${i}`, 'rating', i, hlc(now), now, now);
    }
  }
  db.prepare(`UPDATE template_item SET id='item1' WHERE id='item0_0'`).run();

  // 100 completed inspections plus the one under test — the DB-size budget in
  // §8 is quoted at 100 inspections, so that is what the planner should see.
  const propStmt = ins(`INSERT INTO property (id,org_id,address_1,hlc,created_at,updated_at) VALUES (?,?,?,?,?,?)`);
  const inspStmt = ins(`INSERT INTO inspection
      (id,org_id,property_id,inspector_id,template_id,template_snapshot_json,
       template_version,template_snapshot_hash,status,scheduled_at,resume_offset,search_dirty,hlc,created_at,updated_at)
      VALUES (?,?,?,?,?,'{}',1,'h',?,?,0,0,?,?,?)`);
  for (let n = 0; n < 101; n++) {
    const id = n === 0 ? 'i1' : `i${n + 1}`;
    propStmt.run(`p${n}`, 'org', `${n} Main St`, hlc(now), now, now);
    inspStmt.run(id, 'org', `p${n}`, 'insp', 't1', n === 0 ? 'draft' : 'complete',
                 now - n * 86400000, hlc(now), now, now);
  }

  const obsStmt = ins(`INSERT INTO observation
      (id,inspection_id,item_id,section_id,severity,hlc,created_at,updated_at) VALUES (?,?,?,?,?,?,?,?)`);
  const findStmt = ins(`INSERT INTO finding
      (id,inspection_id,observation_id,severity,narrative,sort_order,hlc,created_at,updated_at)
      VALUES (?,?,?,?,'x',?,?,?,?)`);
  const mediaStmt = ins(`INSERT INTO media
      (id,org_id,inspection_id,observation_id,kind,local_path,upload_state,captured_at,sort_order,sha256,hlc,created_at,updated_at)
      VALUES (?,?,?,?,'photo',?, 'pending',?,?,?,?,?,?)`);

  // The inspection under test: 60 answers, 30 findings, 250 photos.
  const obsId = (k) => (k === 0 ? 'o1' : `o1_${k}`);
  for (let n = 0; n < 60; n++) {
    const oid = obsId(n);
    obsStmt.run(oid, 'i1', `item${n % 8}_${n % 9}`, `s${(n % 8) + 1}`,
                n % 4 === 0 ? 'repair' : null, hlc(now), now, now);
    if (n % 2 === 0) {
      findStmt.run(`f1_${n}`, 'i1', oid, ['info','monitor','repair','safety'][n % 4], n, hlc(now), now, now);
    }
  }
  // Observations across the whole corpus, not just the inspection under test.
  // Without this the planner sees a 60-row observation table, decides a scan is
  // cheaper than any index, and the check "passes" for the wrong reason. The
  // cardinality the planner sees has to resemble a working inspector's year.
  for (let i = 1; i < 101; i++) {
    for (let n = 0; n < 60; n++) {
      obsStmt.run(`o${i + 1}_${n}`, `i${i + 1}`, `item${n % 8}_${n % 9}`, `s${(n % 8) + 1}`,
                  n % 4 === 0 ? 'repair' : null, hlc(now), now, now);
    }
  }

  for (let n = 0; n < 250; n++) {
    mediaStmt.run(`m${n}`, 'org', 'i1', n < 200 ? obsId(n % 60) : null,
                  `photos/${n}.jpg`, now - n * 1000, n, n < 240 ? `sha${n}` : null,
                  hlc(now), now, now);
  }

  // Canned comments, weighted so the ranking index has something to order.
  const canned = ins(`INSERT INTO canned_comment
      (id,org_id,item_id,severity,body,use_count,last_used_at,hlc,created_at,updated_at)
      VALUES (?,?,?,?,'body',?,?,?,?,?)`);
  for (let n = 0; n < 400; n++) {
    canned.run(`c${n}`, 'org', n % 3 === 0 ? null : `item${n % 8}_${n % 9}`,
               ['info','monitor','repair','safety'][n % 4], n % 50, now - n * 1000,
               hlc(now), now, now);
  }
  db.exec('COMMIT');
}
