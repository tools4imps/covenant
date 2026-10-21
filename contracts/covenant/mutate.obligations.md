---
modules: [Covenant.Mutate, Covenant.Mutate.Matrix, Covenant.Mutate.Modules, Covenant.Mutate.Mutant, Covenant.Mutate.Mutator, Covenant.Mutate.Operators, Covenant.Mutate.Survivors]
---
# covenant.mutate

## Purpose

Mutation testing against the Contract: `mix covenant.mutate <component>`
breaks the component's implementation one AST change at a time, runs its
contract tests against each break and credits every kill to the obligations
tagged on the tests that caught it, so a test that proves nothing is
visible. The modules listed above are the ones that can be mutated in the
VM that runs the suite; `Covenant.Mutate.Runner`, `Covenant.Mutate.Recompile`, `Covenant.Mutate.Workdir`, `Covenant.Mutate.Job`
and the Mix task run the worker itself and cannot be hot-swapped by their own
mutants, so their obligations are proved by the tests but not self-mutated.

## Obligations

### covenant.mutate.I31 — Resume only verified unchanged worker groups
- **scope:** `mix covenant.mutate`
- **must:** With opt-in checkpoints, retain a source, support, fixture, configuration, dependency source and BEAM, runtime, tool and option fingerprint. Seal a nonempty group only after a zero worker exit and its final original-suite verification. Ignore unsealed partial and watchdog results. On resume reject changed inputs, corrupt or overlapping groups, and a current baseline that differs from saved test metadata. Run a fresh original baseline even when every verdict is reused. Preserve exact or partial attribution and validate the complete selected result after merging. Do not import old raw results without a fingerprint and parent seal.
- **kind:** functional
- **status:** active

### covenant.mutate.I32 — Selective caller compilation keeps compile-time dependencies
- **scope:** `Covenant.Mutate.Recompile.prepare/3`, `Covenant.Mutate.Runner.run/1`, `mix covenant.mutate`
- **must:** Keep full caller compilation as the default. In opt-in selective mode, measure compile-time calls, retain transitive caller order, and recompile affected callers for both macro and ordinary runtime function mutations. Keep uncertain dependencies on the full compilation path. Preserve structs, generated modules, verification callbacks, original binaries, and test verdicts. Continue to run the complete selected test suite for survivors and exact attribution. Record the selected mode in reports and checkpoint fingerprints.
- **kind:** functional
- **status:** active

### covenant.mutate.I30 — Prior results schedule tests but never supply verdicts
- **scope:** `mix covenant.mutate`, `Covenant.Mutate.Runner.run/1`
- **must:** Allow --prioritize with --fail-fast to read a previous matrix or raw result for the same component. Match the exact mutation site and change, not its numbered ID alone. Try one known killing test first, using current baseline durations to choose a cheap test. Check the hinted test against original code on its own before mutation. If that control fails, discard the hint and require the full original suite to pass before continuing. A real non-timeout test failure is required for a kill, with partial credit. If that test passes or only times out, run the whole suite with the original filters. Ignore missing or excluded hint tests. Keep the full original baseline and final verification. Hints do not reuse verdicts, suppress invalid mutants or timeouts, or change survivor review. Full attribution remains available without fail-fast.
- **kind:** functional
- **status:** active

### covenant.mutate.I29 — Focused runs retain IDs and honest review scope
- **scope:** `mix covenant.mutate`, `Covenant.Mutate.Runner.run/1`
- **must:** Allow --only with explicit mutant IDs numbered before selection. Reject malformed and unknown IDs. Run each selected mutant once across worker slices and replacements. Keep normal baseline, isolation, final verification, timeout, invalid-mutant, and attribution rules. Mark focused reports and completion messages as limited to the selected sites. Resolve survivor declarations against the full selected module profile before filtering, so occurrence references stay stable. Defer annotations only when they match known excluded sites. Keep unknown annotations and selected stale entries visible. A focused result cannot claim full component verification.
- **kind:** functional
- **status:** active

### covenant.mutate.I28 — Worker VMs have bounded mutation lifetimes
- **scope:** `mix covenant.mutate`, `Covenant.Mutate.Runner.run/1`
- **must:** Limit each worker VM to 50 mutation verdicts by default, with a positive --max-mutants-per-worker override. Include invalid mutations in the limit. Verify the original suite before accepting a completed group and retiring the worker. Start a fresh VM for the remaining IDs only after the old worker exits. Keep the requested concurrent worker count, round-robin slices, deterministic IDs and exact test credit. Merge each verdict once. A failed verification or an ordinary incomplete checkpoint cannot request retirement or hide a failure. Keep one total deadline and cancellation scope across all worker replacements. Preserve partial results on failure and remove successful private copies and raw directories, except raw groups retained by opt-in verified checkpoints (I31).
- **kind:** functional
- **status:** active

### covenant.mutate.I27 — Mutation jobs are bounded and keep partial results
- **scope:** `mix covenant.mutate`
- **must:** Apply a total job deadline, including preparation and worker replacements. Allow a positive --max-runtime in milliseconds, with a one-hour default. Stop owned workers on deadline or cancellation. Save each completed verdict atomically before printing progress. Preserve partial raw results on worker failure and identify their directory. Partial results cannot pass as a complete mutation run. Remove successful raw-run directories.
- **kind:** functional
- **status:** active

### covenant.mutate.I26 — Protocol implementation sites belong to the implementation module
- **scope:** `Covenant.Mutate.Mutator.sites/2`, `mix covenant.mutate`
- **must:** Include runtime function bodies and opt-in macros in defimpl declarations with fully qualified literal protocol and type names. Built-in type names and the enclosing __MODULE__ reference are supported; lexical alias resolution is outside this scope. Use the generated implementation module as the mutation module, including an implicit enclosing module type and lists of types. A shared body has one mutation per source change, with all implementation module identities preserved in serialization, missing-site diagnostics, primitive ownership and survivor matching. Select a shared implementation body when any of its implementation modules is targeted, without assigning it to the protocol module or surrounding module. A protocol implementation in macro output stays in its enclosing provider's mutation scope. Keep traversal and replacement indices deterministic.
- **kind:** functional
- **status:** active

### covenant.mutate.I24 — Macro mutation is opt-in
- **scope:** `Covenant.Mutate.Mutator.sites/2`, `mix covenant.mutate`
- **must:** Keep ordinary runtime mutation sites unchanged when enabling macro mode. With macros: true or --macros, include public and private macro bodies and quoted code inside them. Report the enclosing provider macro as the function, including when its output defines another macro. Keep documentation attributes, types, compiler attributes, guard definitions, structural declarations, and quotes outside macros excluded. Pass the mode to every worker and use the same mode when counting and slicing mutants. Record macros: true and the requested recompile sources in the macro kill matrix; keep the default matrix fields unchanged.
- **kind:** functional
- **status:** active

### covenant.mutate.I25 — Macro callers are compiled for each mutant and restored
- **scope:** `Covenant.Mutate.Runner.run/1`, `mix covenant.mutate`
- **must:** In macro mode, compile the explicit --recompile source files in the supplied order, then the selected contract test files, against each loaded mutant. Expand source patterns in stable order and reject paths outside the project, missing sources, and target files that would overwrite the mutant, including symlink paths to those files. Check this compilation against the original before the baseline. Bound target and caller compilation by the worker budget. Classify a caller compilation failure as invalid without kill credit. Restore the target, caller and test modules after each completed mutant, using the caller and test binaries from their compiled baseline even when a disk BEAM differs. Remove new modules compiled in memory, including virtual source filenames, partial compilation failures and helpers that a test deletes while their old code remains. Apply cleanup to runtime and macro runs, including baseline and final verification; keep prior in-memory modules and newly loaded disk modules. Keep the final original suite green. Write no source or beam files. Caller coverage is explicit: users must list all compiled direct and transitive callers required by the selected tests.
- **kind:** functional
- **status:** active

### covenant.mutate.I1 — Thirteen operators, one change each
- **scope:** `Covenant.Mutate.Operators.variants/1`
- **must:** produce at a node every replacement the operators allow, each replacing that one node and carrying its operator and a one-line `from` and `to`: `boolean_flip` (`true` and `false` swap), `comparison_swap` (`==` and `!=`, `===` and `!==` swap; `<` becomes `<=` and `>=`, `<=` becomes `<` and `>`, `>` becomes `>=` and `<=`, `>=` becomes `>` and `<`), `arithmetic_swap` (`+` and `-`, `*` and `/`), `logical_swap` (`and` and `or`, `&&` and `||`), `condition_negate` (`if`/`unless` take the negated condition), `statement_removal` (a non-final call of a block of several expressions goes), `return_nil` (the last expression of a `def`/`defp` body becomes `nil`, unless it is `nil`), `integer_shift` (a written integer becomes one more and one less), `string_empty` (a non-empty string or interpolation becomes `""`), `guard_removal` (a `when` guard goes), `clause_removal` (one clause of a `case`, `cond` or multi-clause `fn` goes, when there are several), `element_removal` (one element of a bracketed list or one pair of a map goes, never where a `|` is involved) and `ecto_where_removal` (a `|> where(...)` stage or a `where:` key of `from` goes)
- **kind:** functional
- **status:** active

### covenant.mutate.I2 — Mutants are enumerated deterministically at reported locations
- **scope:** `Covenant.Mutate.Mutator.sites/2`, `Covenant.Mutate.Mutator.numbered/1`
- **must:** list the mutants of an AST in one walk, inside the target modules (every module when none is named), each with the file, line and column of the node it changes and the module and function it sits in, a nested module by its expanded name (`__MODULE__.Inner` is the enclosing module's name followed by `.Inner`; an absolute `Elixir.Standalone` is `Standalone`); by default skip documentation attributes, specs and types, compiler attributes, `defstruct` and `defexception`, macro and guard definitions, `use`/`import`/`alias`/`require`, `quote` and sigils; number them `m001`, `m002`, ... in walk order (wider than three digits past `m999`); the same source always yields the same mutants in the same order with the same ids
- **why:** a struct literal in a test file is expanded when the test compiles, before any mutant is loaded, so a mutated `defstruct` default can never be killed and would be reported as a survivor although a test asserts it
- **kind:** functional
- **status:** active

### covenant.mutate.I3 — A mutant is one change, compiled in memory
- **scope:** `Covenant.Mutate.Mutator.parse/2`, `Covenant.Mutate.Mutator.apply/2`, `Covenant.Mutate.Mutator.compile/2`
- **must:** apply a mutant by replacing exactly the node at its index and no other; compile an AST into loaded modules without writing a file, replacing the loaded version, and answer a mutant that does not compile with an error message that names the line and column when the compiler gives them; answer a source that does not parse with an error that names the file and line
- **kind:** functional
- **status:** active

### covenant.mutate.I4 — An invalid mutant is neither a kill nor a survivor
- **scope:** `mix covenant.mutate`
- **must:** give a mutant that does not compile the verdict `invalid` with the compiler's reason; run no test against it, credit it to no obligation, list it among no survivors and leave it out of the score's denominator
- **kind:** functional
- **status:** active

### covenant.mutate.I5 — Verdicts follow the tests' outcomes
- **scope:** `Covenant.Mutate.Runner.verdict/2`, `Covenant.Mutate.Runner.entry/2`
- **must:** judge a mutant `killed` when any test failed or was invalid for a reason other than a timeout, `killed_by` naming exactly those tests; `timeout` when the only failures were test timeouts, which makes it a survivor and never a kill; `survived` when every test passed; report a finished test as `passed`, `failed`, `timeout` (every failure an `ExUnit.TimeoutError`), `invalid`, `skipped` or `excluded`, with its obligation tags, its `mutation_blind` reason and its file relative to the project root
- **kind:** functional
- **status:** active

### covenant.mutate.I6 — The baseline must be green
- **scope:** `mix covenant.mutate`
- **must:** run the contract tests unmutated first and mutate nothing when one fails, exiting 1 and naming the failing tests; exit 1 likewise when no contract test declares the component or the contract test modules define no test
- **kind:** functional
- **status:** active

### covenant.mutate.I7 — Kills are credited to obligations, uniquely and in total
- **scope:** `Covenant.Mutate.Matrix.build/2`
- **must:** credit a killed mutant to the obligations tagged on every test that failed against it; count per testable obligation the mutants killed and the mutants only that obligation's tests killed (its unique kills), listing an obligation with no kill too, and count the same per test, counting only the mutants whose credit is exact (a mutant a `--fail-fast` run killed has partial credit, I17); list a passing test with no unique kill as mutation-blind, with its declared reason when it has one, as a warning and never a failure; score `killed / (killed + survived + timed out)` with invalid mutants excluded, and no score for no mutants
- **kind:** functional
- **status:** active

### covenant.mutate.I8 — The survivors file is read strictly
- **scope:** `Covenant.Mutate.Survivors.parse/2`, `Covenant.Mutate.Survivors.load/1`, `Covenant.Mutate.Survivors.path/2`, `Covenant.Parser.Primitive.declarations/2`
- **must:** read a YAML list of mappings with `at` (`file:line:column`), `operator` (one of the thirteen), `sort` (one of the seven: `equivalent`, `log-only`, `dead-code`, `timeout`, `evaluation-gap`, `decision-hole` or `unpromised`) `mutation` (the change as the run prints it) and `reason`, all required; report every bad entry as `file:line: message` (a missing or empty key, a key of the wrong type, an unknown operator or sort, a malformed `at`, an entry that is not a mapping, a document that is not a list, invalid YAML); read a missing or empty file as no annotations; keep the file at `<contracts>/<app>/<component>.survivors.yml`, or beside a component-directory intent or obligations file as `survivors.yml` (`<contracts>/system/survivors.yml` for the system component); keep a sibling-layout primitive's survivors in the `mutants.md` beside its README, read by its extension: each line of an `equivalent` or `unpromised` block is `Module.function/arity: from -> to`, optionally `#k`, sorted as its block says, or, in an `unpromised` block only, `Module.function/arity: *`, and a wildcard in an `equivalent` block is an error
- **kind:** functional
- **status:** active

### covenant.mutate.I9 — Every survivor is sorted and every key names one mutant
- **scope:** `Covenant.Mutate.Survivors.find/2`, `Covenant.Mutate.Survivors.matches?/2`, `Covenant.Mutate.Survivors.resolve/2`, `Covenant.Mutate.Survivors.unit/1`, `Covenant.Mutate.Survivors.template/2`, `Covenant.Mutate.Matrix.build/2`
- **must:** match a survivors-file entry to the one survivor with its `at`, `operator` and `mutation`; pin each `mutants.md` declaration with a change to the one mutant of its unit (`Module.function/arity`, or the module for code outside a function) with that change, `#k` picking the k-th in source order among all of them, killed or not, and report a line that several share without `#k`, or whose `#k` is past the last, as an error (`ambiguous: N mutants in Unit share from -> to`) that sorts nothing; let a wildcard sort every survivor of its unit; sort an unannotated survivor inside the target of an active exception `decision-hole`; report every other unannotated survivor or timeout as a problem naming the mutant; judge staleness per line: an entry or declaration that names no surviving mutant is moved or unmatched, one that names only a killed mutant is stale or contradicted, one that names only an invalid mutant is stale (it does not compile), and a wildcard needs at least one survivor in its unit; print an unsorted primitive survivor as a `mutants.md` line, with `#k` when its unit has others with the same change; fail on nothing else
- **kind:** functional
- **status:** active

### covenant.mutate.I10 — The modules to mutate come from the flags, the front matter or the Contract
- **scope:** `Covenant.Mutate.Modules.resolve/2`, `Covenant.Mutate.Modules.derive/1`, `Covenant.Mutate.Modules.references/1`, `Covenant.Mutate.Modules.locate/3`
- **must:** take the `--module` flags first, then the front matter's `modules:` (for a sibling-layout primitive, the modules its `covers` name, a tree as `Module.*`), then the module names in the inline code spans of the Public surface and of the obligation scopes (fenced blocks ignored), sorted and unique; expand a `Module.*` name to the project's modules under it; find each module's source file, skipping a derived module that is not loaded or whose source lies outside the project root and listing it with the reason, and refusing an explicit one
- **kind:** functional
- **status:** active

### covenant.mutate.I11 — The plan and the worker results
- **scope:** `Covenant.Mutate.plan/3`, `Covenant.Mutate.covered_by?/3`, `Covenant.Mutate.Mutant.decode/1`, `Covenant.Mutate.encode_raw/2`, `Covenant.Mutate.decode_raw/1`, `Covenant.Mutate.merge/1`
- **must:** resolve a component to its module names and its contract test files (a primitive's are the `*_test.exs` files beside its README), or fail naming the problem (an unknown component, with the known ones; no module, or covers naming no code; no contract test file); tell whether a primitive owns a mutant by the most specific covers reference; carry a worker's results, the per-test timeout it used (`timeout_ms`) and each mutant's credit through JSON and back unchanged, answering a mutant of an unknown operator with an error naming it rather than guessing one (`Covenant.Mutate.Mutant.decode/1`), and `decode_raw/1` answering a results file with such a mutant `{:error, "<path>: <message>"}` for the first one, not raising; merge the workers' results by concatenating their mutants sorted by id and keeping the largest `timeout_ms`, refusing results that overlap or leave a mutant without a verdict
- **kind:** functional
- **status:** active

### covenant.mutate.I12 — The kill matrix is JSON of a fixed shape
- **scope:** `Covenant.Mutate.Matrix.to_map/1`, `mix covenant.mutate`
- **must:** write to `--out` a JSON object with the covenant version, `component`, `modules`, `files`, `seed`, `timeout_ms`, `jobs`, `fail_fast`, `baseline` (`tests`, `ms`), `summary` (`mutants`, `killed`, `survived`, `timeouts`, `invalid`, `partial`, `score`, `annotated`, `unsorted`), `mutants` (each with `id`, `at`, `file`, `line`, `column`, `operator`, `from`, `to`, `module`, `function`, `verdict`, `killed_by`, `timeouts`, `reason`, `credit`, `obligations`), `obligations` (`killed`, `unique`, `mutants`, `unique_mutants`), `tests` (`kills`, `unique_kills`, `mutants`, `unique_mutants`, `mutation_blind`, with the test's identity and tags), `survivors` (`id`, `at`, `operator`, `mutation`, `verdict`, `sort`, `reason`) and `problems`; print the table of the same numbers
- **kind:** functional
- **status:** active

### covenant.mutate.I13 — The exit status says whether the sort is complete
- **scope:** `mix covenant.mutate`
- **must:** exit 0 when the baseline is green and every survivor is annotated; exit 1 for a red baseline, an unannotated survivor, a stale or unmatched annotation, or a Contract or survivors file that does not parse, printing each problem as `file:line: message` and a ready-to-fill skeleton for every unannotated survivor
- **kind:** functional
- **status:** active

### covenant.mutate.I14 — The same sources and seed give the same matrix
- **scope:** `mix covenant.mutate`
- **must:** give two runs over unchanged sources with the same seed the same mutants, ids, verdicts and `killed_by` lists (with `--fail-fast` the same mutants, ids and verdicts: which test fails first is not pinned)
- **kind:** functional
- **status:** active

### covenant.mutate.I15 — A worker runs in a private copy of the project
- **scope:** `Covenant.Mutate.Workdir.build/4`, `Covenant.Mutate.Workdir.remove/1`, `Covenant.Mutate.Workdir.within/2`
- **must:** build, under the given base directory (the system temp directory by default), a directory named `covenant-mutate-<OS pid>-<random suffix>`, created with an exclusive `mkdir` (one that exists already is an error and is never touched) and readable by its owner only (mode 0700), that holds a real copy of the project root's files and directories (ignored and untracked files included), in which a directory named `node_modules` at any depth, and a directory named `_build` or `deps` whose parent holds a `mix.exs`, is a symlink to the original (a `deps` or `_build` elsewhere, of plain data, is copied), `.git` and `.elixir_ls` (directory or file) at any depth are left out (so a test that shells out to `git` doesn't see the project's repository, and its baseline says so; git looks in the parent directories too, so a system temp directory inside another repository shows that one), and at the top level only `cover`, `doc`, `.lexical`, `.expert`, `erl_crash.dump` and `priv/plts` (dialyzer PLTs, which no test reads) are left out as well, when asked to (`register?`) register the directory (`Workdir.register/1`, `registered/0`, `unregister/0`, `remove_registered/0`: the one key the task's stdin watcher reads) immediately after the exclusive `mkdir` and before anything is copied, and forget it when the build fails, so that a parent that dies during the copy leaves no partial copy; a symlink is copied as a symlink and never followed (an absolute one whose target lies under the project root is rewritten to the same place under the copy; a relative one that resolves outside the root becomes an absolute link to the original target; a relative one that stays inside is copied as it is), an entry that cannot be read (`:eacces`) is left out with a warning on the standard error stream naming it, any other failure while building removes the half-built directory and raises, and the top-level `tmp` is a real empty directory; refuse a base directory that lies under the project root (the copy would copy itself without end) with an `ArgumentError` naming it, except one under the top-level `tmp/`, which is not copied; so a write or delete by a cwd-relative path in a test or a mutant lands in the copy and never in the project; remove it without ever following a symlink, so the links go and never what they point at, and when the path itself has been replaced by a symlink (to another directory, whose own links must survive) unlink just that link, after making its directories writable, the top directory included, so that one a mutant left unreadable (mode 000) is removed too (a test may leave a read-only one), without raising (what is left is warned about on the standard error stream), and remove one that is gone already without error; run a function with it as the working directory and restore the previous one even when the function raises; do not protect absolute paths, paths reached through the `_build` and `deps` links, or paths derived from the project's location (`__DIR__`, `Application.app_dir/1`), because the tool runs the project's own code against broken copies of it, and say so in the moduledoc
- **why:** a `string_empty` mutant turned `@dir "tmp/cache"` into `""` and the project's own `clear!/0` then ran `File.rm_rf!(Path.expand(""))` in the project root, deleting the whole project, `.git` included
- **kind:** functional
- **status:** active

### covenant.mutate.I16 — The per-test timeout of a mutant run is measured from the baseline
- **scope:** `Covenant.Mutate.default_timeout/1`, `mix covenant.mutate`
- **must:** without `--timeout` give the mutants' tests a timeout of five times the slowest baseline test, in milliseconds, and never under 1000 (`default_timeout/1`; a baseline of no test measures 1000), each worker measuring its own baseline and the matrix recording the largest as `timeout_ms`, and run the baseline itself, and the sanity re-runs between mutants, under `--timeout` when given, else under the ExUnit timeout the project set (read from `ExUnit.configuration()` after its `test_helper.exs` has run, before the run sets its own), else the ExUnit default of 60 seconds; with `--timeout MS` give them exactly MS; leave a test that sets its own `@tag timeout:` with it
- **why:** a flat ceiling holds every test a mutant that loops forever reaches for the whole ceiling, so a database-backed suite spent about a minute per mutant (half a day for a module of 700), and it is too short for a suite whose tests are slow
- **kind:** functional
- **status:** active

### covenant.mutate.I17 — --fail-fast stops a run at its first failure and says the credit is partial
- **scope:** `mix covenant.mutate`, `Covenant.Mutate.Matrix.build/2`
- **must:** with `--fail-fast` stop each mutant's run at its first failing test (ExUnit `max_failures: 1`) and give every mutant the verdict a full run gives; mark a mutant such a run killed `credit: partial` (its `killed_by` names only the tests that failed before the stop) and every other mutant `exact` (a survivor ran every test, an invalid mutant none); run a mutant again in full when its fail-fast run failed on timeouts alone, since a timeout is a failure to ExUnit and ends the run before a test that would kill the mutant; count in an obligation's `killed` and `unique` and a test's `kills` and `unique_kills` the mutants with exact credit only; judge no test mutation-blind (`mutation_blind` is null unless the test declares a reason); write `fail_fast` and the number of partial kills (`summary.partial`) to the JSON and say in the table's header that the credit is partial; document in `mix help covenant.mutate` that a fail-fast matrix proves kills, not obligation credit
- **why:** the verdict of a kill does not depend on which test caught it, but its credit does: a unique kill cannot be told from a test that merely ran first, so a fast run that credited it would reward the order of the tests
- **kind:** functional
- **status:** active

### covenant.mutate.I18 — Progress reports its pace and its ETA
- **scope:** `Covenant.Mutate.progress_due?/2`, `Covenant.Mutate.progress_line/3`, `mix covenant.mutate`
- **must:** after every 25th mutant of a worker's slice, but not after its last, print `progress: <done>/<total> mutants (<percent>%), <rate> mutants/min, ETA <time>`, the rate being the mutants done over the time since the first of them started and the time left the mutants remaining at that rate, written as hours and minutes from an hour, minutes and seconds from a minute and seconds below; with `--jobs N` each worker prints its own, prefixed `[i/N]`
- **kind:** functional
- **status:** active

### covenant.mutate.I19 — A run ends rather than count what a broken VM reports as kills
- **scope:** `Covenant.Mutate.Runner.run/1`, `Covenant.Mutate.Runner.restore/1`
- **must:** after the baseline, record the applications that are started; after each mutant's restore, when one of them is no longer started, start it again and run the unmutated suite once more, ending the run with an error that names the mutant (its id, location and operator) when an application will not start or that suite is red, and recording no verdict after that point; ending it likewise when a mutant has deleted the worker's working directory; keep the verdict that the mutant's own tests gave; after the last mutant of a worker, run the unmutated suite once more and end the run with an error naming the last mutant, as unreliable, when it is red; run each of those unmutated suites (this one and the one after a restart) under the timeout the baseline ran with (the plan's, else 60 seconds), not the mutants' shorter one, restoring the mutants' timeout after, and when one is red run it once more after a pause of 200 ms before ending the run (a leftover process of an earlier mutant may still be writing where a test of this run cleans up); before every run of the suite in a worker (baseline, mutant, unmutated re-runs) make every directory under the copy's `tmp/` owner-writable without following a symlink (`Workdir.unlock/1`), so that ExUnit can clear the `:tmp_dir` of a test that an earlier run left a read-only directory in; measure each test's duration as the larger of ExUnit's `time` and the wall time from its start to its finish, so that an `on_exit` callback or a supervised process's shutdown, which ExUnit's per-test timeout bounds but its `time` leaves out, counts in the baseline and in the timeout measured from it; answer a module that will not load back (a NIF `on_load` that fails the second time) with an error naming the module, after loading back every other original, rather than crash
- **why:** a mutant in a module with a supervised receive loop made `:code.purge` kill the process, the supervisor gave up, the application stopped, and every later mutant counted as killed: the score read 90.5%
- **kind:** functional
- **status:** active

### covenant.mutate.I20 — A mutant that never ends is stopped by a wall-clock budget
- **scope:** `Covenant.Mutate.Runner.run/1`, `Covenant.Mutate.Runner.budget_ms/2`, `Covenant.Mutate.Runner.timeout_exit/0`, `Covenant.Mutate.Workdir.leave/1`
- **must:** bound each run of the suite against a mutant by a progress budget: the longest it may go without finishing a test is ten times the baseline's duration, plus five seconds, plus the per-test timeout, in milliseconds (`budget_ms/2`), the timer starting over at every finished test, because a loop in `setup_all` and a test tagged `timeout: :infinity` finish nothing and are not bounded by ExUnit's per-test timeout, while many tests that each hit that timeout are finished tests and are no hang; when a mutant outruns it, run no further mutant, call the `:on_timeout` callback of the plan, from inside the private copy of the project (the working directory is the copy: the callback writes to an absolute path), with the results so far and that mutant as the last (verdict `timeout`, unless a test of its run finished before the watchdog fired and failed or was invalid for a reason other than a timeout: then `killed`, with credit `partial` and `killed_by` naming those tests, since the tests that finished count), reporting a callback that raises or throws on the standard error stream and going on as if it had returned; then take the working directory out of the copy before removing it (`Workdir.leave/1`: into a new, empty, read-only directory next to the copy, not named like a copy and removed at once, so the working directory no longer exists and a relative write fails with `:enoent` from then on; it never raises), remove the copy without raising and never restore the working directory to the project (the mutant's processes may still run and write by a relative path, and must not put back what the removal takes away), halt the VM with the status `timeout_exit/0` (3), leaving no directory behind, and, when nothing halts, leave the working directory in a new empty read-only directory and return an error naming the mutant; apply the same budget to compiling a mutant (a mutant whose compilation never ends, `@x if true, do: :ok, else: receive(...)` with its `true` turned false, is a timeout like any other: its verdict is `timeout`, and the original modules are restored), and take the same abandon-and-halt path, never restoring the working directory to the project, when an unmutated re-run (after the last mutant, or after the restart of an application) outruns its budget, since the processes of the suite may still run: the copy is removed, the error naming the mutant is written to the standard error stream, the VM halts with exit 3, and `:on_timeout` is not called (no mutant is the verdict to persist)
- **why:** a mutant looping inside `setup_all` hung the run forever; the first watchdog, a budget for the whole run, called eight tests that each hit the per-test timeout a hang; killing the task that ran the suite left the mutant's own processes writing into the real project after the working directory had been restored; and a process that went on rewriting a file under `tmp/` while its copy was being removed left the whole copy behind, one run in a hundred with one such process and every run with four
- **kind:** functional
- **status:** active

### covenant.mutate.I21 — An empty run is visible
- **scope:** `Covenant.Mutate.Runner.run/1`
- **must:** warn on the standard error stream, naming the module and its file, of every module to mutate in which no mutant was found, and end the run with an error when no mutant was found in any of them, instead of reporting a matrix of nothing
- **kind:** functional
- **status:** active

### covenant.mutate.I22 — The task runs every worker in a private copy and carries on past a stopped one
- **scope:** `mix covenant.mutate`
- **must:** run every worker in a private copy of the project, `--jobs 1` included, so that a mutant's write or delete by a relative path never touches the project; give each run its own subdirectory (`run-<random id>`) of the component's `tmp/covenant/mutate/` directory for the workers' results, written to absolute paths, and remove it after merging unless opt-in verified checkpoints retain it (I31), so that two runs of one component at once do not clobber each other; when a worker exits with the status `Covenant.Mutate.Runner.timeout_exit/0` (3), which is not an error, read its results file, take the mutants it judged (the timed-out one last, with the verdict `timeout`, a survivor and never a kill, unless the runner found a finished test that killed it, with credit `partial`), start a worker for the rest (`--skip m001,m002` passes the ids to the worker as `:skip`) writing to a file of its own, and repeat until a worker exits 0, then merge every file; report any other exit status as an error, and report as an error naming the worker, with no new worker, a worker that exits 3 and left no results file (it was stopped in an unmutated re-run, not by a mutant); before using a component's `*.survivors.yml`, read it with the strict reader (`Covenant.Parser.Records.read_document/2`) and fail with its errors, file and line, when the file holds more than one YAML document, a merge key or a duplicate key, since the lenient reader of the survivors would drop entries silently
- **why:** a mutant deleted a whole project, `.git` included, under `--jobs 1`, where the worker ran in the real project; and a mutant that looped in `setup_all` stopped its worker, and with it the whole run
- **kind:** functional
- **status:** active

### covenant.mutate.I23 — The task's workers live and die with it
- **scope:** `mix covenant.mutate`
- **must:** start no more workers than there are mutants and warn on the standard output when `--jobs` exceeds the schedulers online; stop the other workers as soon as one fails instead of waiting for them; make a worker halt (status 1) when its standard input reaches the end, which is what happens when the task that spawned it dies, so that a worker stuck in a mutant does not run on for ever, after removing its private copy of the project (`Runner.remove_workdir/0`, which takes the working directory out of the copy first, as I20 does, since the suite may be in the middle of a run), so that a dead parent leaves no copy behind, one it was still copying included (the copy is registered as soon as it exists)
- **why:** a worker stuck in a mutant was found running at 98% CPU as a child of init after its parent had died
- **kind:** functional
- **status:** active
