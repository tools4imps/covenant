---
modules: [Covenant.Contract, Covenant.Contract.Component, Covenant.Contract.Obligation, Covenant.Contract.Record, Covenant.Contract.Condition, Covenant.Contract.Section, Covenant.Contract.Ceiling, Covenant.Contract.Validate, Covenant.Parser.Markdown, Covenant.Parser.Records, Covenant.Parser.Scope, Covenant.Error, Covenant.ContractError]
---
# covenant.contract

## Purpose

Reads a contracts directory into a `Covenant.Contract`: components from
intent and obligations files, decision records, scope ceilings, every
problem anchored to a file and line.

## Obligations

### covenant.contract.I1 — Files map to components by path
- **scope:** `Covenant.Contract.load/1`, `Covenant.Contract.component_id/2`
- **must:** read `<app>/<name>.intent.md` as the heavy-form component `<app>.<name>`, `<app>/<name>.obligations.md` as the light form, and also read `intent.md` or `obligations.md` inside a component-id directory as the same forms, with each nested directory adding an id segment (`billing.invoices/refunds/obligations.md` is `billing.invoices.refunds`); read `system/intent.md` as the component `system`; attach the matching named or directory-form `decisions.yml` to its component and keep records whose component has no file; expose obligations by id; allow both layout forms in one Contract and reject duplicate declarations across them. A file under the contracts directory that the loader does not read and whose basename looks like a Contract file (it contains `obligation`, `intent`, `decision`, `survivor` or `scope`, in any case and with any extension, `.markdown` included) is an error naming the file at line 1, never silently ignored: a nested named file `<app>/<sub>/x.obligations.md`, a misnamed `x.obligation.md`, an `x.obligations.markdown`; every other file (`NOTES.md`, `docs/overview.md`, an ADR) is prose and ignored; `README.md`, `*.survivors.yml`, `survivors.yml`, `system/scope.yml` and the files the loader reads are known
- **kind:** functional
- **status:** active

### covenant.contract.I2 — Obligation blocks are read in the convention's shape
- **scope:** `Covenant.Parser.Markdown`
- **must:** read `### <id> — <title>` (em dash, en dash or hyphen) followed by `- **field:** value` lines (`-`, `*` or `+` bullets), joining indented continuation lines, keeping unknown fields, stripping backticks from `record` and `target`, ignoring headings and fields inside fenced code (a fence closes only with the same character, at least the same length and an indent of at most three spaces more than its opening), ignoring a leading byte-order mark, in every form
- **kind:** functional
- **status:** active

### covenant.contract.I3 — Required fields and headings are enforced per form, at a precise line
- **scope:** `Covenant.Parser.Markdown`
- **must:** fail a block missing `scope`, `must`, `kind` or `status` (and `why` in heavy form), an empty field, an exception without `target`, a heading that is not the block shape; fail a heavy intent missing a required `##` section, with sections out of order or duplicated, without the revision log, or with an empty Purpose; fail a light file without Purpose; each error names the file and the line of the block, field or heading
- **kind:** functional
- **status:** active

### covenant.contract.I4 — Ids and enumerations are validated and unique
- **scope:** `Covenant.Parser.Markdown`, `Covenant.Parser.Records`, `Covenant.Contract.load/1`
- **must:** reject an obligation id outside `<component id>.I<n>`, an unknown `kind` or `status`, a duplicated obligation id, a component declared in both the named and directory forms, and a record id declared twice in one file or across files, pointing at the second declaration
- **kind:** functional
- **status:** active

### covenant.contract.I5 — Decision records are typed and anchored at their item line
- **scope:** `Covenant.Parser.Records`
- **must:** require `id` (kebab-case), `date` (`YYYY-MM-DD`), `decision`, `driver` and `approved_by`; type-check `kind`, `invariant`, `source`, `depends_on`, `superseded_by`, `alternatives` and `conditions` (plain strings or `text` with an optional `check` carrying a `kind`); anchor each error at the record's `- ` item line; treat an empty file as no records and a non-list as an error
- **kind:** persisted-format
- **status:** active

### covenant.contract.I6 — Scope ceilings parse with their counters
- **scope:** `Covenant.Parser.Scope`
- **must:** read `name`, a non-negative integer `ceiling`, a `glob` counter with `pattern` or a `module` counter with `module` and `function`, optional `why` and `record`, anchored at the item line; reject anything else precisely
- **kind:** persisted-format
- **status:** active

### covenant.contract.I7 — Every problem is reported; none hides another
- **scope:** `Covenant.Contract.load/1`, every parser
- **must:** collect every problem across every file, including unreadable files, and return them together instead of stopping at the first
- **kind:** functional
- **status:** active

### covenant.contract.I8 — An empty directory is a valid Contract; a missing one is not
- **scope:** `Covenant.Contract.load/1`
- **must:** return an empty Contract for a directory with no contract files, and an error naming the path for a directory that does not exist, with a hint for a `contracts/` that lives above the Mix project (`config :covenant, contracts_dir: "../contracts"`, `COVENANT_ROOT`, `config :covenant, root: ...`)
- **kind:** functional
- **status:** active

### covenant.contract.I9 — Dangling references are found
- **scope:** `Covenant.Contract.Validate.dangling/1`
- **must:** report an obligation whose `record`, a record whose `invariant`, `superseded_by` or `depends_on`, and a ceiling whose `record` names something that does not exist, each at its own line, and report nothing for a consistent Contract
- **kind:** functional
- **record:** references-checked-at-check-time
- **status:** active

### covenant.contract.I10 — A malformed obligation block is rejected, never skipped
- **scope:** `Covenant.Parser.Markdown`
- **must:** fail, at the offending line, an obligation-shaped heading (`<id>.I<n> — <title>`) at any level but `###`, an obligation heading indented by one to three spaces, a code fence never closed, a field line outside an obligation block (only a known obligation field — `scope`, `must`, `why`, `kind`, `status`, `record`, `target`; other bold-label bullets are prose), a field repeated within one block, and a known field written as `- **Record:**` (wrong case) or `- **record**:` (colon outside the bold), naming the right spelling, so that a block of such fields never vanishes; a heading is flagged as misplaced only when its id is a full `<component>.I<n>` (`## I1 - Overview` is not). Not covered, by design: fields inside a 4-space indented code block are read as fields, a `~~~` line in prose opens a fence, and an obligation inside a blockquote or an HTML comment is not recognised or is read as live; an obligation must not vanish or change because of how its neighbours are written. A `###` heading whose first word is an obligation id but which is not written `<id> — <title>` (such as `### a.b.I9: title`) is an error at its line, even when no field follows it. A fence opener is indented at most three spaces (CommonMark), so a four-space-indented fence opens nothing. `kind` and `status` are single values: the line after one, a nested bullet included, never continues it, so `- **status:** active` with a sub-bullet beneath it reads `active`
- **kind:** functional
- **status:** active

### covenant.contract.I11 — A YAML Contract file is read whole or rejected
- **scope:** `Covenant.Parser.Records`, `Covenant.Parser.Scope`
- **must:** fail, at the offending line and without raising, a file holding more than one YAML document, a `<<` merge key, a mapping key repeated within one mapping (keys are the same only with the same type and value: `1` and `"1"` differ), and a field whose value is a mapping or list where text is expected (`decision`, `driver`, `approved_by`, `evidence`, `expires`, `notes`, an alternative's `rejected`, a ceiling's `why` and `record`); a ceiling or record must not vanish or change because the YAML reader would drop, ignore or pick between values; front matter is read the same way, so duplicate keys and several documents in it are errors, and a YAML error with no line (an error is anchored at line 1) is reported as an error, never a crash
- **kind:** functional
- **status:** active
