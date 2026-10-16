# Changelog

## 0.2.0 (2026-10-16)

Macro and protocol mutation, bounded workers and faster repeat runs, from
Mike Hostetler's first community contribution (#1).

- `mix covenant.mutate --macros` mutates public and private macro bodies and
  their quoted output. Callers named with `--recompile` are compiled in the
  order given, before the contract tests; list every direct and transitive
  caller, providers first, since discovery isn't automatic. A caller that
  fails to compile makes the mutant `invalid`, with no kill credit. A
  `--recompile` path can't name a mutation target, even through a symlink.
- Literal `defimpl` bodies are mutated. Shared implementation and macro owners
  are kept for ownership and survivor matching.
- Caller and test binaries are restored exactly, and generated and in-memory
  modules are cleaned after the baseline, each mutant and the final check.
- `--max-runtime MS` bounds the whole job (default one hour), and SIGTERM
  cancels it. Each verdict is saved atomically, so a failed or cancelled job
  keeps its partial results, and never passes as a complete matrix.
  `--max-mutants-per-worker N` retires a worker after N verdicts (default 50),
  once the original suite passes on it, and a fresh VM takes the rest.
- `--only` runs chosen mutation IDs without renumbering them or claiming full
  coverage. `--fail-fast` keeps partial credit for kills. `--prioritize PATH`,
  which requires `--fail-fast`, tries a test that killed the same mutant in an
  earlier matrix first.
- `--checkpoint` and `--resume DIR` (`MIX_ENV=test` only) keep only verified,
  completed worker groups, fingerprinted against source, fixtures, config,
  dependencies, BEAMs and options. A resumed run always takes a fresh baseline.
- `--selective-recompile`, with `--macros`, measures compile-time dependencies
  and recompiles only the affected callers.
- Progress shows the baseline and elapsed worker time. Final reports use
  run-specific temporary files, so concurrent runs don't remove each other's.
- Cleanup and selective dependency tracing need OTP 27 or later.

## 0.1.0 (2026-10-11)

The first release: the Contract layer for Impatient Programming in Elixir.

- `Covenant.Contract` reads a `contracts/` directory: heavy-form intents with
  their nine sections, light-form obligations files, decision records, the
  system intent and scope ceilings. Every problem carries its file and line.
  Parsing is strict: a malformed obligation block (a heading at the wrong
  level, an unclosed fence, a misspelled or repeated field) is an error at its
  line, and a YAML file with several documents, merge keys or repeated keys is
  rejected. `contracts/` is trusted input, like `mix.exs`; Covenant refuses to
  call into Elixir or OTP, and `file` conditions and exception targets must stay
  under the project root.
- `Covenant.Case` binds contract tests to obligations when they compile. An
  untagged test, an unknown or retired obligation, or another component's
  obligation is a compile error at the test's line.
- `Covenant.Formatter` records which obligations passed, one results file per
  Mix app, so an umbrella's apps don't overwrite each other.
- `mix covenant.check` runs the contract suite and fails on malformed blocks,
  dangling references, an obligation with no passing test, a stale exception
  or a scope ceiling exceeded. An obligation whose tagged tests were all
  skipped or excluded has no passing test. It prints contract coverage and
  writes `contracts/coverage.json`. Each run writes its results to a private
  subdirectory, and `--results-dir` deletes only Covenant's own files.
  `--static` applies the same checks with nothing compiled, loaded or run, and
  writes `contracts/coverage.static.json`; it credits no test inside `for`,
  `Enum.each`, `if`, `case`, `cond` or `unless`.
- `mix covenant.conditions` re-checks the premises of decision records: `dep`,
  `env`, `file`, `otp`, `elixir`, and `value`, which calls a function of the
  project and compares the result with the value the record decided.
- `mix covenant.regen <component>` writes a regeneration pack: the intent,
  records, contract tests and public-surface stubs, with the implementation
  left out. Stubs are written only for modules the component owns. `--out`
  clears only a directory that holds the `.covenant-pack` marker and refuses
  any other non-empty one. Tests are found by reading `use Covenant.Case`
  from the syntax tree.
- `mix covenant.mutate <component>` mutates the component's modules in memory
  with thirteen operators, runs its contract tests against each mutant and
  writes a kill matrix that credits every kill to the obligations whose tests
  caught it. Survivors are sorted in `<component>.survivors.yml`; an unsorted
  survivor or a stale entry fails the run. An entry's `at`, `operator` and
  `mutation` are all required, so it names one mutant. `--fail-fast` trades exact credit
  for speed, `--jobs N` runs several workers, and the per-test timeout is
  measured from the baseline. Every worker runs the tests from a private copy
  of the project, so a mutant's relative-path writes never reach it. A
  watchdog turns a hung mutant into a `timeout`, workers die with their
  parent, and a health check after each mutant ends the run with an error if
  the VM is broken. `defstruct` and `defexception` fields are not mutated, and
  a run with nothing to mutate is an error.
- The sibling layout that flinch, qualm and exhale read: `contract/<primitive>/`
  with `- **A1**` obligations and a `covers` block in its README, Contract tests
  beside it that name their obligations in `# Contract: calc/A1` comments, and
  an optional `mutants.md` of `equivalent` and `unpromised` declarations.
  `Covenant.Case` reads the comments at compile time; `mix covenant.check`
  applies the rules of `flinch contract`; `mix covenant.mutate` and
  `mix covenant.regen` take a primitive by name. A project can use either
  layout or both. The survivor sorts gain `unpromised`. Each `mutants.md`
  line names exactly one mutant: `#k` picks one when several of a unit's
  mutants share a change, and a line they share without it is ambiguous.
- Covenant governs itself: 96 obligations across ten components, each proved
  by a `Covenant.Case` test.
- Hardened before release by adversarial review (Claude and GPT): false greens
  from skipped tests, parameterized failures, malformed or unread Contract
  files and a project root moved by `--contracts`; destructive `--out` and
  `--results-dir`; mutants writing into the real project; and hangs, false
  "unreliable" verdicts from slow teardowns, and orphaned workers.
