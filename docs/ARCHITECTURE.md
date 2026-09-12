# Punchlist — architecture contract

Read this before adding code. It is the shared context for everyone working in
this repo.

## What this product is

A field inspection tool for a solo inspector or a 2–15 person firm. They walk a
property, capture structured observations and photos, and produce a branded PDF
**on site**. The sale is: finish the report before you leave the driveway.

The user is in a crawlspace, in gloves, in bad light, with no signal, while a
client waits. Every decision is subordinate to: *does this get them a finished
report before they leave?*

## Non-negotiable constraints

1. **Every core flow works in airplane mode.** Create, fill, capture,
   annotate, generate PDF, share. Network is for sync only and the user never
   waits on it.
2. **Data loss is a product-ending bug.** Every keystroke and capture is
   committed to disk immediately. There is no Save button anywhere.
3. **A report renders identically forever.** Templates are versioned and
   snapshotted; a 2026 inspection still produces the same report in 2027.
4. **Photos are first-class.** 80–250 per inspection. 60fps, < 250MB RSS.
5. **No account required to start.**

## Stack

- **SwiftUI + GRDB.swift**, iOS 17+. AVFoundation for capture, PDFKit for the
  report, Core Image for the photo pipeline.
- `PunchlistCore` (SwiftPM) holds everything that decides what is true: schema,
  migrations, ids, clocks, repositories, the report's layout model. It imports
  **no** Apple UI framework, so it builds and tests on Linux CI with no
  simulator.
- `App/Punchlist` is the only place SwiftUI / AVFoundation / PDFKit appear.

## Data layer rules

- **Ids are client-minted UUIDv7** (`UUIDv7.generate()`). Never `UUID()`.
- **Timestamps are `Int64` epoch milliseconds, UTC.** Never `Date` in a column.
- **Soft delete only** (`deleted_at`). A hard delete cannot be synced.
- **All writes go through `AppDatabase.write { ctx in ... }`** and use
  `ctx.insert / ctx.update / ctx.softDelete`. Never `record.save(db)` — it would
  skip the HLC stamp and the outbox append, both of which must happen in the
  same transaction as the data.
- **Reads use `AppDatabase.read`**, or `observe` for anything the UI displays.
  `ValueObservation` is how the UI stays live; there is no separate store, and
  no view model caches durable state.
- **Never query the live `template*` tables from an inspection.** Use
  `inspection.snapshot()`. This is the mechanism behind constraint 3.

## Key model shapes

- `Inspection` — has `templateSnapshotJson` (frozen `TemplateSnapshot`),
  `templateSnapshotHash`, `status`, and `resumeSectionId` / `resumeOffset` for
  "reopen exactly where they left off".
- `Observation` — one row per *answered* checklist item, holding the input's
  value. Sparse: an untouched checklist costs zero rows. Carries a `severity`
  rolled up from its findings so a list row can be coloured without a subquery.
- `Finding` — a single defect under an observation. **One item routinely has
  several**: cracked shingles at the NE valley (repair), moss on the north slope
  (monitor), a missing vent boot (safety). Severity, narrative, location and
  photos all hang off the finding, not the observation.
- `MediaItem` — three artifacts per photo: `originalPath` (kept only if the org
  opts in), `localPath` (2048px long edge, q=0.8 — what the report embeds),
  `thumbPath` (256px — what every list renders). `isUnfiled` is the photo tray.

## Design direction

The default SaaS card kit is wrong here and will read as generic. The visual
language comes from field instruments and survey documents: high contrast,
unambiguous state, no decoration that isn't load-bearing.

```
ink        #14181A   primary text
slate      #5A6570   secondary text, metadata
paper      #FBFAF7   app background
field      #EDEEEA   input wells, resting surfaces
line       #D2D5CE   hairlines
--- severity: the ONLY saturated colour in the product ---
info       #3E6B8A
monitor    #B07A12
repair     #C4541F
safety     #A31D1D
```

If a screen has colour on it, that colour means something.

- **Type:** one family, wide weight range, tabular figures for measurements.
  Hierarchy from weight and size — not colour, not tracked-out all-caps labels.
  Body text 17pt minimum.
- **Touch targets: 56pt minimum, 64pt for anything used repeatedly.** Gloves.
- **Severity is never colour alone** — always colour *and* shape
  (`Severity.glyph`). Read in direct sun, by people who are not all 25, some of
  whom are colour-blind.
- **Layout:** the checklist is one scrolling column, section-anchored, with a
  persistent progress affordance. Not a wizard — inspectors do the roof when
  they're on the roof, not when a wizard says so.
- **Motion:** only in response to a user action, and only to show what changed.
  A photo animating into the tray it was filed under is useful. Fade-and-slide
  entrances on every section are decoration; cut them.
- **Empty and error states carry direction.** Say what happened and what to do.
  Never "Something went wrong."
- Support Dynamic Type and VoiceOver. This is a professional tool used all day.

## Performance budgets (these are tests, not aspirations)

| Metric | Budget |
|---|---|
| Cold start to usable inspection list | < 1.2s |
| Tap "new inspection" to first checklist item | < 400ms |
| Checklist scroll, 200 items | 60fps, zero blank cells |
| Shutter tap to ready-for-next-shot | < 350ms |
| Photo grid scroll, 250 photos | 60fps |
| PDF, 40pp / 150 photos | < 15s |
| Memory, large inspection open | < 250MB |
| DB size, 100 completed inspections | < 120MB excl. media |

## Out of scope — do not build

Web app. Real-time collaboration. A conflict-resolution UI. Offline maps. An
integrations marketplace. AI-generated narrative. A custom PDF layout designer.

## Build order

1. **Local core** — schema, checklist, photo capture. All local. *(current)*
2. **The report** — PDF engine, branding, severity summary, share sheet.
3. **Template editing + polish** — on-device builder, canned comments, voice
   notes, photo tray, annotation.
4. **Accounts + sync** — only now does a server exist.
5. **Team features.**
