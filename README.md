# Covenant

Covenant fails a build when an Elixir project's Contract stops being true. It is the Contract layer for [Impatient Programming](https://impatientprogramming.org) in Elixir, and the sibling of [flinch](https://github.com/tools4imps/flinch), [qualm](https://github.com/tools4imps/qualm) and [exhale](https://github.com/tools4imps/exhale-ruby).

A Contract, in Impatient Programming, is what a component promises, written down well enough that the component could be deleted and rebuilt from it alone: an intent, decision records that give the reason behind every value that looks arbitrary, and numbered obligations, each proved by a contract test. Covenant reads the Contract under `contracts/`, or in the [sibling layout](#the-sibling-layout) the other tools read, binds every contract test to the obligations it proves when the test compiles, publishes contract coverage, re-checks the premises of decisions, writes regeneration packs, and mutates a component to show which obligation's tests notice when its code breaks.

`mix covenant.mutate` is the Elixir counterpart of flinch's mutation gate. It breaks a component's code one change at a time, runs the component's contract tests against each broken copy, and credits every kill to the obligations tagged on the tests that caught it. A test that catches nothing is named. qualm judges a change in any language, so it runs beside Covenant as it is.

Covenant is a Mix library with one runtime dependency, `yaml_elixir`. It needs Elixir 1.18 or later.

## Install

```elixir
# mix.exs
def deps do
  [{:covenant, "~> 0.2", only: [:dev, :test], runtime: false}]
end
```

Or take it from GitHub:

```elixir
{:covenant, github: "tools4imps/covenant", only: [:dev, :test], runtime: false}
```

Then let every `mix test` record which obligations passed:

```elixir
# test/test_helper.exs
ExUnit.start(formatters: [ExUnit.CLIFormatter, Covenant.Formatter])
```

## Use

```bash
mix covenant.check                    # every active obligation has a passing test
mix covenant.check --static           # the same checks, with nothing compiled or run
mix covenant.conditions               # re-check the premises of the decision records
mix covenant.regen billing.invoices   # write a pack to rebuild a component from its Contract
mix covenant.mutate billing.invoices  # break the component and see which obligations notice
```

A real run on the example project in [`test/fixtures/example_project`](https://github.com/tools4imps/covenant/tree/main/test/fixtures/example_project), two components with seven active obligations:

```text
$ mix covenant.check
covenant.check: running mix test test/contract
Running ExUnit with seed: 848591, max_cases: 20

........
Finished in 0.04 seconds (0.04s async, 0.00s sync)
8 tests, 0 failures

Contract coverage (obligations with a passing test / active obligations)

  example.counter      6/6  100.0%
  example.greeter      1/1  100.0%
  system               0/0     n/a

  app example              7/7  100.0%
  app system               0/0     n/a

  total                    7/7  100.0%
covenant.check: warning: 1 component(s) declare no modules: example.greeter

wrote contracts/coverage.json
covenant.check: the Contract holds
```

`mix covenant.check` fails on a malformed obligation block, a dangling `record`, `invariant`, `superseded_by` or `depends_on` reference, an active obligation with no passing tagged test, a failing tagged test, an exception whose target no longer exists, and a scope ceiling exceeded. Coverage counts the active obligations that have at least one passing test; retired obligations and declared exceptions are reported but left out of the count. An obligation whose tagged tests were all skipped or excluded has no passing test: it fails, and the message names those tests. An obligation proven elsewhere takes a `kind: exception`. `contracts/coverage.json` is written without a timestamp, so it can be committed and diffed.

Each run writes its results to a private subdirectory of the results directory, so a `mix test` running in the background can't overwrite them mid-run. `--results-dir` (and the config key and `COVENANT_RESULTS_DIR`) only ever deletes Covenant's own result files. Paths resolve from the project root in every mode, so an umbrella app works.

`--static` compiles nothing, loads no config and runs no test. It reads the contract test files as source and applies every check that needs no compiled code, for a Contract written ahead of its implementation: it works on a project whose `lib/` doesn't compile yet. A tagged test counts, skipped or not. A test inside `for`, `Enum.each`, `if`, `case`, `cond` or `unless` is not credited, since it may never be defined; those are listed as needing compiled code. It writes `contracts/coverage.static.json` and never touches `coverage.json`:

```text
$ mix covenant.check --static
covenant.check --static: read 2 file(s), 2 contract test module(s), 8 tagged test(s) under test/contract; no test was compiled or run

Static contract coverage (obligations with a tagged test / active obligations)

  example.counter      6/6  100.0%
  example.greeter      1/1  100.0%
  system               0/0     n/a

  app example              7/7  100.0%
  app system               0/0     n/a

  total                    7/7  100.0%

skipped (need compiled code): 1 exception target(s), 1 module ceiling(s): counter-event-kinds, example.greeter.I2
covenant.check: warning: 1 component(s) declare no modules: example.greeter

wrote contracts/coverage.static.json
covenant.check: the Contract holds statically
```

## Exit codes

Every task exits 0 when the Contract holds and 1 when it doesn't. 1 also covers a run that couldn't finish: a Contract that doesn't parse, an unknown component, a red baseline before mutation.

| Task | Exits 1 when |
| --- | --- |
| `mix covenant.check` | any check above fails, or the contract suite fails |
| `mix covenant.conditions` | any decision record is suspect |
| `mix covenant.regen` | the component is unknown, the Contract doesn't parse, or `--out` is a non-empty directory that isn't a pack |
| `mix covenant.mutate` | the baseline is red, there is nothing to mutate, a survivor has no annotation, an annotation matches no survivor, or a worker or the VM breaks |

## The Contract

```text
contracts/
  README.md                        the project's convention
  system/
    intent.md                      the whole product's intent
    decisions.yml                  architecture decision records
    scope.yml                      scope-budget ceilings
  <app>/
    <component>.intent.md          heavy form: nine sections in a fixed order
    <component>.obligations.md     light form: a Purpose and obligation blocks
    <component>.decisions.yml      the component's decision records
    <component>.survivors.yml      sorted survivors of mix covenant.mutate
test/contract/<app>/<component>_contract_test.exs
```

The full convention, with the nine heavy-form sections and the rules for contract tests, is in [`docs/contract-convention.md`](docs/contract-convention.md). Copy it to your project as `contracts/README.md`: `mix covenant.regen` puts that file in every pack.

Component ids are `<app>.<component>`, and obligation ids are `<component id>.I<n>`. An obligation is a block:

```markdown
### example.counter.I1 — A counter never goes below zero
- **scope:** `Example.Counter.decrement/2`, every starting value
- **must:** stop at zero when `by` exceeds the value, instead of going negative or raising
- **why:** v1 raised on underflow and every caller rescued it, hiding real bugs (fixture incident #1)
- **kind:** functional
- **record:** clamp-at-zero
- **status:** active
```

`kind` is `functional`, `non-functional`, `persisted-format`, `ordering`, `security` or `exception`. A `kind: exception` block declares intentional duplication or a known gap, names the code with `target:` (`Module.function/arity`, `Module` or a file path relative to the project root), needs no test, and fails the check once its target is gone.

Parsing is strict. A malformed obligation block is an error at its line, never skipped silently:

- an obligation-shaped heading at the wrong level, indented, or written `### <id>: title` instead of `### <id> — <title>`
- an unclosed code fence
- a known field outside a block, or misspelled (`**Record:**`, `**record**:`)
- a repeated field
- a file under `contracts/` named like a Contract file (its name contains obligation, intent, decision, survivor or scope) that Covenant doesn't read, such as a misnamed `x.obligation.md`, an `x.obligations.markdown`, or one in a nested directory. Other files there, such as notes and ADRs, are prose and are ignored

`kind` and `status` take one value; nothing after them continues them. A YAML contract file, front matter included, is rejected for multiple documents, `<<` merge keys, repeated keys and fields of the wrong type. A leading BOM is fine, and so are bold-label bullets in prose.

### Contract tests

`Covenant.Case` wraps `ExUnit.Case`. Every test in a `Covenant.Case` module names the obligations it proves:

```elixir
defmodule Example.CounterContractTest do
  use Covenant.Case, component: "example.counter", async: true

  @tag obligation: "example.counter.I1"
  test "decrementing past zero stops at zero, never negative, never raising" do
    ...
  end
end
```

The tags are checked when the module compiles. An untagged test, an unknown or retired id, or an id from another component is a compile error at the test's line:

```text
** (CompileError) test/contract/example/zz_bad_contract_test.exs:5: test counts past the cap is tagged with unknown obligation `example.counter.I99`; `example.counter` declares: example.counter.I1, example.counter.I2, example.counter.I3, example.counter.I4, example.counter.I5, example.counter.I6, example.counter.I7
```

`@tag`, `@describetag` and `@moduletag` all work, and a tag can be a list of ids.

### Decision records

```yaml
- id: configurable-max
  date: "2026-10-09"
  decision: The cap is configurable per counter via new(max:) and defaults to 100.
  driver: Widgets of other widths appeared; the fixed cap had to be forked.
  alternatives:
    - option: A global application-env cap
      rejected: Two widgets on one page need two caps.
  approved_by: lead (fixture, 2026-10-09)
  depends_on: [fixed-max-100]
  conditions:
    - text: OTP 26 or later
      check: { kind: otp, version: ">= 26.0.0" }
    - text: The counter implementation lives in lib/example/counter.ex
      check: { kind: file, path: lib/example/counter.ex }
    - text: A counter built without options is capped at 100
      check: { kind: value, call: "Example.Counter.new/0", path: [max], equals: 100 }
  expires: When the cap moves to a persisted setting
```

`id`, `date`, `decision`, `driver` and `approved_by` are required. A condition with a `check` is one `mix covenant.conditions` can evaluate:

| `kind` | Fields | Holds when |
| --- | --- | --- |
| `dep` | `name`, optional `version` | the dependency is in `mix.lock`, at a matching version |
| `env` | `name` | the environment variable is set |
| `file` | `path` | the path exists under the project root |
| `otp` | `version` | the running OTP release matches |
| `elixir` | `version` | the running Elixir matches |
| `value` | `call`, `equals`, optional `path` | the function returns the value the record decided |

`contracts/` is trusted input, like `mix.exs`: a `value` check and a `module` counter run your project's functions. Covenant refuses to call into Elixir or OTP itself, so `System.halt/0` can't end the gate with a success status, but this is not a sandbox. A `file` path must stay under the project root. A `value` check lets the record that decides a value verify it. `call` names a zero-arity function of your project, as `"Module.fun/0"`, and is called in the project's own VM after it compiles. `path` walks keys through maps, trying the atom form of each key before the string form. Atoms compare as strings, lists element by element, numbers by value. A different value is suspect (`Example.Scope.event_kinds/0 is 3, the record says 4`), and so is a missing key or a call that raises. A module that isn't compiled in the VM leaves the condition unchecked, which is counted and never a failure.

```text
$ mix covenant.conditions --verbose
clamp-at-zero (contracts/example/counter.decisions.yml:1)
  ok Elixir is at least 1.18 — Elixir 1.19.6 matches `>= 1.18.0`
  - Callers treat the counter as a value, never as a process (not machine-checkable)
positive-steps (contracts/example/counter.decisions.yml:20)
  ok The contract tooling depends on yaml_elixir — dependency `yaml_elixir` 2.12.2 matches `~> 2.12`
fixed-max-100 (contracts/example/counter.decisions.yml:36)
configurable-max (contracts/example/counter.decisions.yml:46)
  ok OTP 26 or later — OTP 28.5 matches `>= 26.0.0`
  ok The counter implementation lives in lib/example/counter.ex — file `lib/example/counter.ex` exists
  ok A counter built without options is capped at 100 — Example.Counter.new/0 [max] is 100
one-example-app (contracts/system/decisions.yml:1)
  ok The PATH environment variable is set (mix is found through it) — env `PATH` is set
  ok The fixture keeps its own mix.lock — file `mix.lock` exists

covenant.conditions: 5 record(s), 7 machine-checkable condition(s), 0 suspect record(s)
```

A version requirement may leave out the minor and patch numbers after a comparison: `>= 28.0` reads as `>= 28.0.0`. One that doesn't parse is suspect, never skipped.

### Scope ceilings

`system/scope.yml` caps what can be counted, so the product stays small enough to regenerate. A `glob` counter counts files; a `module` counter calls a function of the project.

```yaml
- name: lib-files
  ceiling: 36
  counter: { kind: glob, pattern: "lib/**/*.ex" }
  why: A contract tool that cannot be read in an afternoon will not be trusted to gate merges.
  record: small-surface-after-mutate
```

A count over its ceiling fails `mix covenant.check`. A module counter that raises, such as a stub not written yet, leaves its ceiling unchecked with a warning.

## Regeneration packs

```text
$ mix covenant.regen example.counter
  CONTRACT_CONVENTION.md
  PROMPT.md
  REGENERATION_BRIEF.md
  contracts/example/counter.decisions.yml
  contracts/example/counter.intent.md
  contracts/system/decisions.yml
  contracts/system/intent.md
  stubs/lib/example/counter.ex
  test/contract/example/counter_contract_test.exs
covenant.regen: wrote 9 file(s) to tmp/covenant/regen/example.counter
```

`--out DIR` writes a `.covenant-pack` marker into every pack, listing the files Covenant wrote. A later run deletes only those files. It refuses a non-empty directory without a marker, and a pack that holds files Covenant didn't write (the rebuilding agent's `QUESTIONS.md`, say), and deletes nothing. Regen and mutate find the contract tests by reading `use Covenant.Case, component: ...` from the syntax tree, so the multi-line form `mix format` writes is found and a commented-out line isn't.

A pack holds everything an agent needs to rebuild one component and nothing of the old implementation: the intent or obligations file, the records, the system intent, the component's contract tests, and one stub module per module of the intent's `## Public surface`. Hand it to a fresh agent, rebuild, and run the contract tests. Every difference is a sentence the Contract was missing.

A Public surface mentions modules the component doesn't own, and a stub for one of those would shadow the real module. A `#### Modules` paragraph in the Public surface, or `modules:` in the file's front matter, says exactly what the component owns. Without one, Covenant decides from where each module lives and prints what it skipped; `mix covenant.check` warns about every component that declares no modules. The rules are in the docs for `Covenant.Regen.Ownership`.

## Mutation testing

```text
$ mix covenant.mutate example.counter
covenant.mutate: example.counter — modules (derived): Example.Counter
covenant.mutate: tests: test/contract/example/counter_contract_test.exs
covenant.mutate: Example.Counter (lib/example/counter.ex)
  m001 lib/example/counter.ex:11:16 integer_shift `100` → `101`  killed by 1 test(s)
  m002 lib/example/counter.ex:11:16 integer_shift `100` → `99`  killed by 2 test(s)
  m003 lib/example/counter.ex:29:5 return_nil `%__MODULE__{value: 0, max: max, events: []}` → `nil`  killed by 7 test(s)
  m005 lib/example/counter.ex:25:29 logical_swap `and` → `or`  SURVIVED
  ...
covenant.mutate: baseline 7 test(s) green in 82 ms; 59 of 59 mutant(s) run, per-test timeout 1000 ms

Kill matrix — example.counter (Example.Counter)
  59 mutants: 43 killed, 12 survived, 0 timed out, 4 invalid — score 78.2%
  7 tests, baseline 82 ms, seed 0, timeout 1000 ms

  obligation          killed  unique
  example.counter.I1      26       1
  example.counter.I2      17       7
  example.counter.I3      20       2
  example.counter.I4      22       0
  example.counter.I6      23       3
  example.counter.I7      15       1

Survivors (12; 0 unsorted)
  m005 lib/example/counter.ex:25:29 logical_swap `and` → `or`  evaluation-gap — new/1 rejecting a non-integer max is not an obligation yet; add one before callers rely on it.
  m010 lib/example/counter.ex:26:28 string_empty `"max must be a positive integer, got: #{inspect(max)}"` → `""`  log-only — The ArgumentError message is prose for humans; the Contract pins the exception, not its text.
  m017 lib/example/counter.ex:34:48 integer_shift `1` → `2`  decision-hole — The Contract lists increment/2 only; whether a default step exists is deliberately undecided.
  ...

Mutation-blind tests (warn): no mutant only this test catches
  test events are listed oldest first, one per successful call (Example.CounterContractTest) — 15 kill(s), 0 unique
  test the worked example: clamps record a clamped event in call order (Example.CounterContractTest) — 21 kill(s), 0 unique

wrote tmp/covenant/mutate/example.counter/kill_matrix.json

covenant.mutate: every mutant is caught or sorted
```

The modules to mutate come from `--module` flags, else the `modules:` front matter, else the Public surface and the obligations' `scope`. Each mutant is one AST change, compiled in memory: no file is written. The suite runs in a `MIX_ENV=test` worker that boots once and hot-swaps each mutant, and the unmutated baseline has to pass first. The set and order of mutants is a pure function of the source.

| Operator | Change |
| --- | --- |
| `boolean_flip` | `true` and `false` swap |
| `comparison_swap` | `==` and `!=` swap, `<` becomes `<=` or `>=`, and so on |
| `arithmetic_swap` | `+` and `-` swap, `*` and `/` swap |
| `logical_swap` | `and` and `or` swap, `&&` and `\|\|` swap |
| `condition_negate` | `if c` becomes `if !c`, `unless c` becomes `unless !c` |
| `statement_removal` | a call that isn't a block's last expression is dropped |
| `return_nil` | the last expression of a `def` or `defp` becomes `nil` |
| `integer_shift` | `n` becomes `n + 1` and `n - 1` |
| `string_empty` | a non-empty string becomes `""` |
| `guard_removal` | a clause's `when` guard is dropped |
| `clause_removal` | one clause of a `case`, `cond` or multi-clause `fn` is dropped |
| `element_removal` | one element of a list or one pair of a map is dropped |
| `ecto_where_removal` | a `\|> where(...)` stage or a `where:` key of `from` is dropped |

By default, docs, specs, types, `defmacro`, `defguard`, `defstruct` and `defexception` fields, `use`, `import`, `alias`, `require`, sigils and `quote` are not mutated. Struct literals in tests are expanded at compile time, so a mutant of a struct default could never be killed. A run that finds nothing to mutate is an error, and a module with no mutants is warned about.

Mutation jobs have a one-hour total deadline. Use `--max-runtime MS` to set
another positive limit. This includes preparation and worker replacements;
`--timeout` remains the per-test limit. SIGTERM cancels the job and closes its
worker ports. Completed verdicts are saved atomically before progress is printed.
An incomplete or cancelled job keeps its raw-result directory and names it in the
output. These partial files do not establish a complete mutation gate.

Each worker VM handles at most 50 mutation verdicts. Set a positive
`--max-mutants-per-worker N` to change this limit. The original tests must pass
after each group before its worker retires. A fresh VM then checks the remaining
IDs, with the same concurrent worker limit and whole-job deadline. This bounds
the accumulation of VM module indices and atoms from repeated compilation;
purging generated code alone cannot reclaim all of this VM bookkeeping.

With `MIX_ENV=test`, add `--checkpoint` to retain verified worker groups.
After cancellation, repeat the same source profile, seed, timeout, and test
options with `--resume DIR`, using the printed directory. Source, support,
fixture, configuration, dependency, BEAM, tool, and environment hashes must
match. Only groups sealed by the parent after a successful worker exit can be
reused. Incomplete and watchdog-stopped groups run again. A fresh passing
baseline is required even when all verdicts are cached. The report records
how many groups and verdicts were reused. Checkpoint directories remain after
success; normal runs still remove their raw directory.

Mutation cleanup uses independent VM trace sessions and needs Erlang/OTP 27 or
later. It tracks in-memory module loads in runtime and macro mode, including
helpers deleted by tests. Tracking records module names, never code binaries.
Baseline, mutant and final verification test runs all use this cleanup.

A `defimpl` body shared by several types has one mutation per source change.
Its JSON records all implementation modules in `modules`, while `module` keeps
the primary name for compatibility. Both module selection and primitive
ownership use all names. An exception for only one implementation does not
exempt the other implementations in the shared body.

To test a macro provider such as `__using__/1`, select macro mode and name the
compiled callers that the contract tests use:

```sh
mix covenant.mutate example.builder --macros \
  --recompile lib/example/consumer.ex \
  --recompile lib/example/derived.ex
```

Macro mode includes `defmacro`, `defmacrop`, and quoted code inside them. It
also keeps the normal runtime mutation sites. For each mutant, Covenant
compiles the listed caller sources in order, then the contract test files.
This makes generated functions, macro expansions, and compile-time test values
observe the current mutant. Caller and test modules are restored from their
compiled baseline afterward; new modules compiled in memory are removed,
including those with virtual source filenames. No source or beam file is written.

List all direct and transitive compiled callers that the selected tests need,
with providers before their callers. Caller paths must stay inside the project
and cannot name a mutation target, including through a symlink. Caller discovery
is not automatic.
Repeat `--recompile` for more files, or use a quoted glob whose matches compile
in filename order. Calls that the tests compile themselves need no extra entry.
A caller compilation failure makes the mutant invalid and gives no kill credit;
an assertion failure during a test gives normal obligation credit. Macro mode
still skips guards, structural declarations, compiler attributes, docs and
types, and quotes outside macro definitions.

Add `--selective-recompile` with `--macros` to compile only affected caller and
contract files. Covenant measures ordinary function calls made during macro
expansion, as well as compiler references. It keeps transitive caller order.
Macro files and uncertain dependencies keep full compilation. The default
still compiles every caller. This option changes compilation work; it keeps
the same test selection and original-code checks. See the
[development guide](docs/development-mutation.md) for both optimizations.

A mutant is killed when a test fails for any reason but a timeout, survives when every test passes, and is invalid when it doesn't compile; a mutant the tests only time out against is a survivor. A kill is credited to the obligations tagged on every test that failed. An obligation's unique kills are the mutants only its tests caught. A test with no unique kill is mutation-blind and is listed as a warning; `@tag mutation_blind: "reason"` keeps the reason beside the warning.

There's no score threshold. The score is printed for information. Every survivor is either killed by a new test or sorted in `contracts/<app>/<component>.survivors.yml`, under a reason a reviewer can check. `at`, `operator` and `mutation` are all required, so an entry names one mutant:

```yaml
- at: lib/example/counter.ex:69:60
  operator: return_nil
  mutation: "`:ok` → `nil`"
  sort: dead-code
  reason: check_step!/1's return value is never read; only its raise is observable.
```

| Sort | The survivor is |
| --- | --- |
| `equivalent` | a mutant that behaves exactly like the original |
| `log-only` | a change to a message or a log line nobody pins |
| `dead-code` | in code that is never reached, or whose value is never read |
| `timeout` | a mutant the tests only timed out against |
| `evaluation-gap` | a behaviour that matters and no test pins yet |
| `decision-hole` | a behaviour the Contract leaves undecided on purpose |
| `unpromised` | a behaviour that changes and that the Contract leaves open, as the sibling layout declares it |

A mutant inside the target of an active `kind: exception` obligation is sorted `decision-hole` without an entry. An entry that matches no survivor fails the run, so the file stays true.

Without `--timeout`, each test's timeout is five times the slowest baseline test, and never under a second. `--fail-fast` stops each mutant's run at its first failing test: the verdicts are the same as a full run's, but the kill credit is partial, so use it to sort survivors on a slow suite and a full run to credit obligations. `mix help covenant.mutate` has the rest.

### Development loop

Use `--only m005,m017` to check selected IDs from the same source and module
profile. Add `--fail-fast` for partial test attribution. A previous result can
also schedule a known killing test first:

```sh
mix covenant.mutate example.counter --only m005,m017 --fail-fast \
  --prioritize tmp/covenant/mutate/example.counter/kill_matrix.json \
  --max-runtime 60000 --out tmp/counter-dev.json
```

Every verdict is measured again. A hint that passes or only times out falls
back to the whole suite. Focused results identify their selected sites and
defer annotations for known excluded sites. Selected stale entries and unknown
annotations still fail. Keep the full module profile to preserve IDs; check the
printed sites after source changes. For full verification and exact obligation
credit, omit `--only`, `--fail-fast`, and `--prioritize`.

See [the measured Jido development workflow](docs/development-mutation.md) for
commands, timings, and the limits of focused runs and saved hints.

### Workers and the project

Every worker, `--jobs 1` included, runs the tests from a private copy of the project under the system temp directory. `_build` and `deps` beside a `mix.exs`, and `node_modules`, are linked rather than copied. `cover`, `doc`, `.elixir_ls`, `.lexical`, `.expert`, `erl_crash.dump` and `priv/plts` are left out, and so is `.git`, so a test that shells out to git doesn't see the project's repository. A system temp directory inside the project (outside its `tmp/`) is refused. A mutant's write or delete by a relative path lands in the copy. Absolute paths, paths through the `_build` and `deps` links, and paths derived from the project's location (`__DIR__`, `Application.app_dir/1`) are not protected. Mutate a project whose tests you would run anyway, from a clean working tree. A suite that shares anything else between OS processes, such as a database or a fixed port, needs `--jobs 1`.

- `--jobs N` splits the mutants over N workers. It is capped at the number of mutants and warns above the schedulers online.
- After each mutant the worker checks that the applications the baseline started are still running. If one is not, it restarts them and runs the unmutated suite once. At the end it runs the unmutated suite again. A broken VM ends the run with an error naming the mutant, instead of recording false kills.
- A test's measured time includes its teardown (`on_exit`, supervised shutdown), and the unmutated re-runs use the baseline's timeout, not a mutant's. A red re-run is retried once. Before every run, the copy's `tmp/` is made writable again, so a test that leaves a read-only directory there doesn't break the next run.
- A watchdog stops a mutant when no test finishes for ten times the baseline, plus five seconds, plus the per-test timeout. The mutant is a `timeout`, a survivor, unless a test had already failed against it, which makes it a kill with partial credit. The task starts a new worker for the rest.
- A worker dies with its parent and removes its copy first. Whenever it removes a copy that the suite's processes may still be writing to, it steps out of the copy beforehand, so nothing they write by a relative path can keep it alive.
- Concurrent runs of one component don't clobber each other.

The final matrix uses a temporary file unique to its run and replaces the
output atomically. When two runs use the same output path, the file contains
one complete matrix from the last writer. Their temporary files stay separate.

Runtime functions and opt-in macros in handwritten `defimpl` blocks belong to
the generated protocol implementation module. Fully qualified literal protocol and type
names, built-in types, lists of types, and an omitted `for:` inside a module
are supported. Lexical aliases, including aliases from nested declarations,
are not resolved. The `for:` declaration is not a
mutation site. A shared body retains all implementation identities, including
macros declared in that body. A `defimpl` emitted by a macro remains in the
provider macro's scope.

## The sibling layout

flinch, qualm and exhale read a smaller Contract: a directory per primitive, numbered obligations in its README, and the Contract tests beside it. Covenant reads that layout too, so a team running them beside Covenant keeps one Contract. A project can use it, the `contracts/` layout, or both.

```text
contract/
  calc/
    README.md         obligations and a covers block
    calc_test.exs     the calc Contract tests
    mutants.md        declared survivors, optional
  test_helper.exs     empty: Mix wants a helper in every test path
```

The calc example from flinch's README, in Elixir. The README lists the obligations and names the code it covers:

````markdown
# calc

Small sums.

## Obligations

- **A1** Add returns the sum of its arguments.
- **A2** Clamp returns n when it sits between lo and hi, and the nearer bound otherwise.

```covers
Calc
```
````

A `covers` line is a module (`Calc`), a tree (`Calc.*`: the module and every module under it) or a function (`Calc.add/2`). When primitives overlap, the most specific reference wins.

The Contract tests name the obligations they prove in a comment directly above each test:

```elixir
defmodule Calc.ContractTest do
  use Covenant.Case, async: true

  # Contract: calc/A1
  test "add sums its arguments" do
    assert Calc.add(2, 3) == 5
  end

  # Contract: calc/A2
  test "clamp returns the nearer bound outside them" do
    assert Calc.clamp(-3, 1, 10) == 1
  end
end
```

`Covenant.Case` takes the primitive from the file's directory and reads the comments when the module compiles, so `# Contract: calc/A1` counts exactly as `@tag obligation: "calc/A1"` does, and that works too. Several ids go on one line, separated by commas. A test that names nothing, an unknown id and another primitive's id are compile errors, and so is a `# Contract:` comment that doesn't sit directly above a test. Bold words in a primitive's README prose are prose; only a list item that opens with a bold id is an obligation.

For `mix test` to run them, add the directory to the test paths and give it an empty `contract/test_helper.exs`; `test/test_helper.exs` still starts ExUnit. The default `test_pattern`, `*_test.exs`, already matches.

```elixir
# mix.exs
def project do
  [
    # ...
    test_paths: ["test", "contract"]
  ]
end
```

`mix covenant.check` runs `contract/` whether or not it's in `test_paths`. A real run on [`test/fixtures/sibling_project`](https://github.com/tools4imps/covenant/tree/main/test/fixtures/sibling_project):

```text
$ mix covenant.check
covenant.check: running mix test contract
Running ExUnit with seed: 844304, max_cases: 20

...
Finished in 0.01 seconds (0.01s async, 0.00s sync)
3 tests, 0 failures

Contract coverage (obligations with a passing test / active obligations)

  calc          2/2  100.0%

  app contract      2/2  100.0%

  total             2/2  100.0%

wrote contract/coverage.json
covenant.check: the Contract holds
```

It checks what `flinch contract` checks: every obligation is named by a Contract test, every Contract test names an obligation of its own primitive, no test outside `contract/` carries a Contract comment or tag, and every `covers` line names code that loads (`--static` lists those as skipped). Two primitives covering the same code fail it too. Coverage goes to `contract/coverage.json` when the project has no `contracts/`.

`mix covenant.mutate calc` mutates the code the covers name, keeping only what the primitive owns by the most specific reference, and runs the tests beside the README:

```text
$ mix covenant.mutate calc
covenant.mutate: calc — modules (covers): Calc
covenant.mutate: tests: contract/calc/calc_test.exs
covenant.mutate: Calc (lib/calc.ex)
  m001 lib/calc.ex:6:24 return_nil `a + b` → `nil`  killed by 1 test(s)
  ...
  m007 lib/calc.ex:12:9 comparison_swap `<` → `<=`  SURVIVED
  ...
Kill matrix — calc (Calc)
  11 mutants: 9 killed, 2 survived, 0 timed out, 0 invalid — score 81.8%
  3 tests, baseline 10 ms, seed 0, timeout 1000 ms

  obligation  killed  unique
  calc/A1          2       2
  calc/A2          7       7

Survivors (2; 0 unsorted)
  m007 lib/calc.ex:12:9 comparison_swap `<` → `<=`  equivalent — At a bound, the bound is n: When `n` equals `lo`, the first clause returns `lo`, which is `n`, so `<` and `<=` agree. The same holds for `hi`.
  m009 lib/calc.ex:13:9 comparison_swap `>` → `>=`  equivalent — At a bound, the bound is n: When `n` equals `lo`, the first clause returns `lo`, which is `n`, so `<` and `<=` agree. The same holds for `hi`.

covenant.mutate: every mutant is caught or sorted
```

Survivors are declared in the primitive's `mutants.md`, under a heading that gives the reason:

````markdown
## At a bound, the bound is n

When `n` equals `lo`, the first clause returns `lo`, which is `n`, so `<` and
`<=` agree. The same holds for `hi`.

```equivalent
Calc.clamp/3: < -> <=
Calc.clamp/3: > -> >=
```
````

A line is a unit and the mutation as the run prints it, `Module.function/arity: from -> to`, and it names exactly one mutant. When several of the unit's mutants share the change, `#k` picks the k-th in source order, killed ones included, so the number doesn't move as tests change: `Calc.clamp/3: < -> <= #2`. A line they share without `#k` is ambiguous and fails the run. An `equivalent` block claims no program can tell the mutant from the original; an `unpromised` block says the behaviour changes and the Contract leaves it open, and only there does `Module.function/arity: *` declare every survivor of the unit. A declaration that a test contradicts, or that names no surviving mutant, fails the run, line by line. An unsorted survivor is printed as a block ready to paste, with `#k` where it needs one.

`mix covenant.regen calc` writes the README, the Contract tests (subdirectories included), `contract/test_helper.exs`, the convention and a stub of every public function the primitive covers. `mutants.md` stays out, since it describes the old implementation.

## Configuration

```elixir
config :covenant,
  contracts_dir: "contracts",              # default
  sibling_dir: "contract",                 # default; the sibling layout; false turns it off
  test_paths: ["test/contract"],           # default; globs allowed
  results_dir: "_build/covenant/results",  # default
  case_modules: []                         # your wrappers around Covenant.Case, for --static and regen
```

Covenant resolves paths from the project root, never from the directory `mix` runs in. The root is the Mix project's directory, or the umbrella's for an app of one. It is never an ancestor of the project, and neither `--contracts docs/contracts` nor `contracts_dir` (relative or absolute) moves it: `contracts_dir` only says where the Contract is, relative to the root. When `contracts/` lives above the Mix project (a poncho layout, or a Mix project below the repository root), set `contracts_dir: "../contracts"` (the root stays the project, so ceilings still count its files), or set the root with `COVENANT_ROOT` or `config :covenant, root: ...`. In an umbrella, set `contracts_dir: Path.expand("../contracts", __DIR__)` in `config/config.exs` and `test_paths: ["apps/*/test/contract"]`. Run from inside an app, `mix covenant.check` runs the tests from the umbrella root, so each app's tests run in that app's own VM; each app's results are written separately and merged. [`test/fixtures/umbrella_project`](https://github.com/tools4imps/covenant/tree/main/test/fixtures/umbrella_project) runs the tasks from inside an app.

`--static` and regen read `use Covenant.Case, component: "..."` literally. If your contract tests `use MyApp.ContractCase` instead, list it in `case_modules`; otherwise `--static` reports the module as one it can't read. Both follow the project's `test_pattern`.

## In CI

```yaml
- uses: actions/checkout@v4
- uses: erlef/setup-beam@v1
  with:
    otp-version: "28"
    elixir-version: "1.19"
- run: mix deps.get
- run: mix covenant.check
```

`mix covenant.check` runs the contract suite itself, so it can replace the `mix test` step for `test/contract`. Mutation runs per component and takes longer; run it on the components a change touches.

## Why

Agents write more code than anyone reads. What a team can still read is the Contract: what each component promises, why, and the tests that prove it. Covenant keeps that layer load-bearing. A test that proves no obligation doesn't compile, an obligation with no passing test fails the build, a decision whose premise stopped holding is listed, and a test that catches no broken code is named.

The test of a Contract is regeneration. If a component can be deleted and rebuilt from its pack alone, the Contract is complete, and every difference after a rebuild is a sentence it was missing.

## How Covenant holds itself to account

Covenant has its own Contract in [`contracts/`](https://github.com/tools4imps/covenant/tree/main/contracts): 101 obligations across ten light-form components, a system intent and the decision records behind its policies. Every test in `test/contract/` is a `Covenant.Case` test that names its obligations. CI runs the suite and `mix covenant.check` on every push, on Elixir 1.18 and 1.19.

Two components are mutated with Covenant itself. `covenant.conditions` makes 242 mutants: 211 killed, 29 invalid, and 2 survivors. `covenant.mutate`, run against its own unit tests, makes 1541: 1325 killed, 150 invalid, 2 timeouts, and 64 survivors. Every survivor is sorted, with its reason, in `contracts/covenant/*.survivors.yml`.

```bash
mix deps.get
mix test               # Elixir 1.18: mix test test/contract
mix covenant.check     # Covenant against its own Contract
```

## Known limits in 0.2

- An exception's `target` can name a public function, a module or a file, not a private function.
- `--static` reads only literal component names and literal tags, and doesn't credit tests generated in a loop or a conditional.
- A `value` check calls only zero-arity functions.
- Mutation runs one component at a time. There is no mode that mutates only what a branch changed.
- The private copy protects relative paths only. A mutant can still write through an absolute path or a link to `_build` or `deps`.
- Run as root, a mutant that times out while several of its processes keep creating files can leave a small `covenant-parked-*` directory in the system temp directory. The worker reports it on standard error.
- The modules that run the mutation worker can't be mutated by their own run.
- Struct fields given by a module attribute (`defstruct @fields`, `defexception @fields`) are still mutated, and the mutants that result can't be killed. Sort them as `equivalent`.
- In the sibling layout, a `covers` function must be public: the check finds it with `__info__/1`.
- A `mutants.md` declaration names Covenant's printed mutation, so declarations don't carry over between flinch and Covenant.

## License

MIT
