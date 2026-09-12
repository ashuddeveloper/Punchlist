-- ============================================================
-- Punchlist schema v1
--
-- Conventions:
--   * All ids are client-minted UUIDv7 TEXT. Offline creation means the device
--     must mint ids; v7 is time-sortable so inserts stay at the right edge of
--     the B-tree.
--   * All timestamps are INTEGER epoch milliseconds, UTC.
--   * Soft delete everywhere via deleted_at. A hard delete cannot be synced.
--   * Every mutable row carries an HLC for per-field last-writer-wins.
--   * Every enum column carries a CHECK. A bad enum arriving from sync should
--     fail at the write, not three weeks later inside the PDF renderer.
-- ============================================================

-- ============ IDENTITY & TENANCY ============

CREATE TABLE org (
  id            TEXT PRIMARY KEY,
  name          TEXT NOT NULL,
  logo_media_id TEXT,                    -- resolved in app code, not an FK:
                                         -- media.org_id already points back here
                                         -- and a mutual FK deadlocks inserts.
  license_no    TEXT,
  address       TEXT,
  phone         TEXT,
  email         TEXT,
  brand_color   TEXT NOT NULL DEFAULT '#1B4D3E',
  report_theme  TEXT NOT NULL DEFAULT 'standard'
                CHECK (report_theme IN ('standard','compact','narrative')),
  archive_originals INTEGER NOT NULL DEFAULT 0 CHECK (archive_originals IN (0,1)),
  hlc           TEXT NOT NULL,
  created_at    INTEGER NOT NULL,
  updated_at    INTEGER NOT NULL,
  deleted_at    INTEGER
);

CREATE TABLE inspector (
  id                 TEXT PRIMARY KEY,
  org_id             TEXT NOT NULL REFERENCES org(id),
  name               TEXT NOT NULL,
  email              TEXT,
  license_no         TEXT,
  signature_media_id TEXT,
  hlc                TEXT NOT NULL,
  created_at         INTEGER NOT NULL,
  updated_at         INTEGER NOT NULL,
  deleted_at         INTEGER
);

CREATE INDEX idx_inspector_org ON inspector(org_id) WHERE deleted_at IS NULL;

-- ============ TEMPLATES (authoring side) ============
-- These are the *editable* tables. A running inspection never reads them; it
-- reads its own frozen snapshot. Editing a template can therefore never change
-- a report that has already been performed.

CREATE TABLE template (
  id           TEXT PRIMARY KEY,
  org_id       TEXT NOT NULL REFERENCES org(id),
  name         TEXT NOT NULL,
  discipline   TEXT NOT NULL CHECK (discipline IN ('home','fire','commercial')),
  version      INTEGER NOT NULL DEFAULT 1,
  published_at INTEGER,
  hlc          TEXT NOT NULL,
  created_at   INTEGER NOT NULL,
  updated_at   INTEGER NOT NULL,
  deleted_at   INTEGER,
  UNIQUE (org_id, name, version)
);

CREATE TABLE template_section (
  id          TEXT PRIMARY KEY,
  template_id TEXT NOT NULL REFERENCES template(id) ON DELETE CASCADE,
  title       TEXT NOT NULL,
  sort_order  INTEGER NOT NULL,
  icon        TEXT,
  hlc         TEXT NOT NULL,             -- added: on-device template editing
  created_at  INTEGER NOT NULL,          -- (phase 3) has to be syncable (phase 4)
  updated_at  INTEGER NOT NULL,
  deleted_at  INTEGER
);

CREATE INDEX idx_section_template ON template_section(template_id, sort_order)
  WHERE deleted_at IS NULL;

CREATE TABLE template_item (
  id           TEXT PRIMARY KEY,
  section_id   TEXT NOT NULL REFERENCES template_section(id) ON DELETE CASCADE,
  label        TEXT NOT NULL,
  input_type   TEXT NOT NULL CHECK (input_type IN
                 ('rating','bool','select','multiselect','text','number',
                  'photo_only','signature')),
  options_json TEXT,
  required     INTEGER NOT NULL DEFAULT 0 CHECK (required IN (0,1)),
  sort_order   INTEGER NOT NULL,
  help_text    TEXT,
  unit         TEXT,                     -- added: "in", "ft", "°F", "amps"
  depends_on_item_id TEXT REFERENCES template_item(id),
  depends_on_value   TEXT,
  hlc          TEXT NOT NULL,
  created_at   INTEGER NOT NULL,
  updated_at   INTEGER NOT NULL,
  deleted_at   INTEGER
);

CREATE INDEX idx_item_section ON template_item(section_id, sort_order)
  WHERE deleted_at IS NULL;

-- Reusable phrasing. The single biggest time-saver in the product: by
-- inspection 20 most narrative should be one tap.
CREATE TABLE canned_comment (
  id             TEXT PRIMARY KEY,
  org_id         TEXT NOT NULL REFERENCES org(id),
  item_id        TEXT,                   -- null = global. Not an FK: it refs an
                                         -- item that may live only in a snapshot.
  severity       TEXT NOT NULL CHECK (severity IN ('info','monitor','repair','safety')),
  body           TEXT NOT NULL,
  recommendation TEXT,
  use_count      INTEGER NOT NULL DEFAULT 0,
  last_used_at   INTEGER,
  hlc            TEXT NOT NULL,
  created_at     INTEGER NOT NULL,
  updated_at     INTEGER NOT NULL,
  deleted_at     INTEGER
);

-- Ranking index: suggestions for an item, most-used first. The report of this
-- query is what the inspector sees the instant they tag something "repair",
-- so it must never scan.
CREATE INDEX idx_canned_rank
  ON canned_comment(org_id, item_id, use_count DESC, last_used_at DESC)
  WHERE deleted_at IS NULL;

-- ============ THE INSPECTION (the hot path) ============

CREATE TABLE property (
  id          TEXT PRIMARY KEY,
  org_id      TEXT NOT NULL REFERENCES org(id),
  address_1   TEXT NOT NULL,
  address_2   TEXT,
  city        TEXT,
  region      TEXT,
  postal_code TEXT,
  lat         REAL,
  lon         REAL,
  year_built  INTEGER,
  sq_ft       INTEGER,
  hlc         TEXT NOT NULL,
  created_at  INTEGER NOT NULL,
  updated_at  INTEGER NOT NULL,
  deleted_at  INTEGER
);

CREATE INDEX idx_property_org ON property(org_id) WHERE deleted_at IS NULL;

CREATE TABLE inspection (
  id             TEXT PRIMARY KEY,
  org_id         TEXT NOT NULL REFERENCES org(id),
  property_id    TEXT NOT NULL REFERENCES property(id),
  inspector_id   TEXT NOT NULL REFERENCES inspector(id),
  template_id    TEXT NOT NULL,
  -- FROZEN snapshot of the whole template tree at creation. The report renders
  -- from this and never from the live tables. This is the only acceptable
  -- denormalisation in the schema; it is what buys immutable reports.
  template_snapshot_json TEXT NOT NULL,
  template_version INTEGER NOT NULL,
  -- Hash of the snapshot. Two inspections created from the same template
  -- version share it, which makes "did this template change?" a string compare
  -- instead of a JSON diff.
  template_snapshot_hash TEXT NOT NULL,
  status         TEXT NOT NULL DEFAULT 'draft'
                 CHECK (status IN ('draft','complete','delivered')),
  scheduled_at   INTEGER,
  started_at     INTEGER,
  completed_at   INTEGER,
  client_name    TEXT,
  client_email   TEXT,
  weather        TEXT,
  temperature_f  INTEGER,
  occupancy      TEXT,
  -- "Resume exactly" (§10.8). Durable, because a Zustand store dies with the
  -- process and the whole point is surviving a force-quit.
  resume_section_id TEXT,
  resume_offset     REAL NOT NULL DEFAULT 0,
  -- Search index is rebuilt lazily; per-keystroke FTS writes are not worth it.
  search_dirty   INTEGER NOT NULL DEFAULT 1 CHECK (search_dirty IN (0,1)),
  hlc            TEXT NOT NULL,
  created_at     INTEGER NOT NULL,
  updated_at     INTEGER NOT NULL,
  deleted_at     INTEGER
);

CREATE INDEX idx_inspection_recent
  ON inspection(org_id, status, scheduled_at DESC)
  WHERE deleted_at IS NULL;

CREATE INDEX idx_inspection_property ON inspection(property_id) WHERE deleted_at IS NULL;

CREATE INDEX idx_inspection_dirty ON inspection(search_dirty) WHERE search_dirty = 1;

-- One row per *answered* item: the value of the checklist input.
-- Sparse by design — an untouched checklist costs zero rows.
CREATE TABLE observation (
  id             TEXT PRIMARY KEY,
  inspection_id  TEXT NOT NULL REFERENCES inspection(id) ON DELETE CASCADE,
  item_id        TEXT NOT NULL,          -- refs the snapshot, not a live table
  section_id     TEXT NOT NULL,
  value_text     TEXT,
  value_number   REAL,
  value_bool     INTEGER CHECK (value_bool IN (0,1)),
  -- Rolled up from this observation's findings on every write, so the
  -- checklist can colour a row without a correlated subquery per cell.
  severity       TEXT CHECK (severity IN ('info','monitor','repair','safety')),
  location_note  TEXT,
  hlc            TEXT NOT NULL,
  created_at     INTEGER NOT NULL,
  updated_at     INTEGER NOT NULL,
  deleted_at     INTEGER
);

CREATE UNIQUE INDEX idx_observation_unique
  ON observation(inspection_id, item_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_observation_severity
  ON observation(inspection_id, severity) WHERE deleted_at IS NULL;
CREATE INDEX idx_observation_section
  ON observation(inspection_id, section_id) WHERE deleted_at IS NULL;

-- CHANGED FROM BRIEF: findings are their own table.
--
-- One checklist item routinely carries several independent defects: cracked
-- shingles at the NE valley (repair), moss on the north slope (monitor), a
-- missing vent boot (safety). Three severities, three locations, three photo
-- sets, one item. A single observation row per item cannot express that, and
-- the workaround — cramming them into one narrative — destroys the severity
-- summary page, which is the page clients actually read.
--
-- It also gives §7's "numbered findings that cross-reference" a real identity.
CREATE TABLE finding (
  id             TEXT PRIMARY KEY,
  inspection_id  TEXT NOT NULL REFERENCES inspection(id) ON DELETE CASCADE,
  observation_id TEXT NOT NULL REFERENCES observation(id) ON DELETE CASCADE,
  severity       TEXT NOT NULL CHECK (severity IN ('info','monitor','repair','safety')),
  narrative      TEXT NOT NULL DEFAULT '',
  recommendation TEXT,
  location_note  TEXT,
  canned_comment_id TEXT,                -- provenance, for use_count ranking
  sort_order     INTEGER NOT NULL DEFAULT 0,
  hlc            TEXT NOT NULL,
  created_at     INTEGER NOT NULL,
  updated_at     INTEGER NOT NULL,
  deleted_at     INTEGER
);

-- Drives the severity summary page: all safety items in an inspection, ordered.
CREATE INDEX idx_finding_severity
  ON finding(inspection_id, severity, sort_order) WHERE deleted_at IS NULL;
CREATE INDEX idx_finding_observation
  ON finding(observation_id, sort_order) WHERE deleted_at IS NULL;

-- ============ MEDIA ============

CREATE TABLE media (
  id             TEXT PRIMARY KEY,
  -- org_id added: logos and signatures belong to an org, not an inspection.
  -- The brief's org.logo_blob_id -> media.id forced a fake inspection row.
  org_id         TEXT NOT NULL REFERENCES org(id),
  -- Nullable: a logo has no inspection. Also null for tray photos before
  -- filing? No — tray photos DO belong to an inspection, just not to an
  -- observation yet. That is the whole point of the tray.
  inspection_id  TEXT REFERENCES inspection(id) ON DELETE CASCADE,
  observation_id TEXT REFERENCES observation(id) ON DELETE SET NULL,
  finding_id     TEXT REFERENCES finding(id) ON DELETE SET NULL,
  kind           TEXT NOT NULL
                 CHECK (kind IN ('photo','video','audio','signature','logo')),
  -- Three artifacts, not two (§6): the 2048px display JPEG is what the report
  -- embeds, the 256px thumb is what every list renders, and the original is
  -- kept only when the org opts into archiving.
  local_path     TEXT NOT NULL,          -- display variant, sandbox-relative
  thumb_path     TEXT,
  original_path  TEXT,
  remote_key     TEXT,
  upload_state   TEXT NOT NULL DEFAULT 'pending'
                 CHECK (upload_state IN ('pending','uploading','done','failed')),
  upload_attempts INTEGER NOT NULL DEFAULT 0,
  bytes          INTEGER,
  width          INTEGER,
  height         INTEGER,
  duration_ms    INTEGER,                -- voice notes and video
  transcript     TEXT,                   -- on-device transcription, phase 3
  captured_at    INTEGER NOT NULL,
  lat            REAL,
  lon            REAL,
  -- Non-destructive annotation: arrows and circles are re-renderable vector
  -- data, so an annotation made three weeks ago is still undoable and the
  -- original pixels are never touched.
  annotation_json TEXT,
  caption        TEXT,
  sort_order     INTEGER NOT NULL DEFAULT 0,
  sha256         TEXT,                   -- dedupe + integrity; computed at idle
  hlc            TEXT NOT NULL,
  created_at     INTEGER NOT NULL,
  updated_at     INTEGER NOT NULL,
  deleted_at     INTEGER
);

CREATE INDEX idx_media_upload_queue
  ON media(upload_state, upload_attempts) WHERE deleted_at IS NULL;
CREATE INDEX idx_media_by_obs
  ON media(observation_id, sort_order) WHERE deleted_at IS NULL;
CREATE INDEX idx_media_by_finding
  ON media(finding_id, sort_order) WHERE deleted_at IS NULL;
-- The photo grid and the unfiled tray. Both scroll 250 rows at 60fps, so both
-- get an index that satisfies the ORDER BY without a sort step.
CREATE INDEX idx_media_by_inspection
  ON media(inspection_id, captured_at DESC) WHERE deleted_at IS NULL;
CREATE INDEX idx_media_tray
  ON media(inspection_id, captured_at DESC)
  WHERE deleted_at IS NULL AND observation_id IS NULL AND finding_id IS NULL;
CREATE INDEX idx_media_sha ON media(sha256) WHERE sha256 IS NOT NULL AND deleted_at IS NULL;

-- ============ SYNC ============

-- Outbox. Every local mutation writes here inside the *same* transaction as
-- the data write.
--
-- CHANGED FROM BRIEF: payload_json holds only the fields this mutation
-- actually changed, not the whole row. §5.3 asks for last-writer-wins
-- per field; a whole-row payload cannot do that — replaying it would clobber
-- fields this device never touched, silently discarding the other inspector's
-- work. The server keeps a per-field HLC map and applies these partial
-- payloads against it.
CREATE TABLE outbox (
  seq          INTEGER PRIMARY KEY AUTOINCREMENT,
  table_name   TEXT NOT NULL,
  row_id       TEXT NOT NULL,
  op           TEXT NOT NULL CHECK (op IN ('upsert','delete')),
  payload_json TEXT NOT NULL,            -- changed fields only
  hlc          TEXT NOT NULL,            -- stamp for every field in the payload
  created_at   INTEGER NOT NULL,
  attempts     INTEGER NOT NULL DEFAULT 0,
  last_error   TEXT
);

-- Compaction: collapse superseded entries for the same row.
CREATE INDEX idx_outbox_row ON outbox(table_name, row_id, seq);

CREATE TABLE sync_state (
  key   TEXT PRIMARY KEY,                -- 'cursor' | 'device_id' | 'last_hlc'
  value TEXT NOT NULL
);

-- ============ SEARCH ============
-- Maintained lazily from inspection.search_dirty rather than by trigger:
-- the narrative blob is an aggregate over findings, which a row trigger cannot
-- compute cheaply, and nobody searches mid-keystroke.

CREATE VIRTUAL TABLE inspection_fts USING fts5(
  inspection_id UNINDEXED,
  address,
  client_name,
  narrative_blob,
  tokenize = 'porter unicode61 remove_diacritics 2'
);

-- (schema_migration is owned by the migration runner, not by a migration.)
