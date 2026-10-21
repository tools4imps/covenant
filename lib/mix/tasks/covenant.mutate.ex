defmodule Mix.Tasks.Covenant.Mutate do
  @shortdoc "Mutates a component and writes the kill matrix"

  @moduledoc """
  Mutates a component's implementation at the AST level, runs its contract
  tests against every mutant and credits each kill to the obligations tagged
  on the tests that caught it: every test has to prove it is worth keeping.

      mix covenant.mutate example.counter
      mix covenant.mutate example.counter --module Example.Counter --module Example.Counter.Log
      mix covenant.mutate example.counter --timeout 5000 --seed 42 --jobs 2
      mix covenant.mutate example.counter --fail-fast
      mix covenant.mutate example.counter --only m001,m007 --fail-fast
      mix covenant.mutate example.counter --out tmp/kill_matrix.json

  The modules under mutation are, in order of precedence, the `--module`
  flags, the `modules:` list in the front matter of the component's intent or
  obligations file, or the modules named in its `## Public surface` and in
  the `scope` of its obligations. The contract tests are the files declaring
  `use Covenant.Case, component: "<id>"` under the configured test paths.

  The suite runs in a worker process with `MIX_ENV=test` (one per `--jobs`),
  which boots the test environment once and hot-swaps each mutant in memory;
  no file is written by a mutant. The baseline must be green. A mutant whose
  only failures are test timeouts is a **survivor**, never a kill.

  Prints a progress line per mutant and, every 25 mutants, how many are done,
  the rate and the ETA (per worker, with `--jobs`); then the kill matrix (per
  obligation: mutants killed in total and uniquely), the survivors with their
  sort, and the mutation-blind tests (warn-only). Writes the matrix as JSON.

  Exit status 0 when the baseline is green and every survivor is annotated in
  `contracts/<app>/<component>.survivors.yml`, or in `survivors.yml` beside a
  component-directory Contract; 1 when the baseline is red, a survivor has no
  annotation, an annotation is stale, the Contract or the survivors file does
  not parse, or a worker fails.

  ## Options

  * `--checkpoint` — with `MIX_ENV=test`, retain parent-verified worker groups
    and input fingerprints. Only zero-exit groups with a passing final original
    suite are reusable. Partial and watchdog-stopped groups are not;
  * `--resume DIR` — implies checkpoint mode. Repeat the original semantic
    options. Reject changed inputs, corrupt groups, overlap, or changed baseline
    metadata. A fresh original baseline is required even for a fully cached
    selection. Jobs, group size, output, and total job budget may change;
  * `--selective-recompile` — with `--macros`, measure compile-time dependencies
    and compile affected caller files in their original order. Track ordinary
    functions executed by macros. Keep full compilation for macro files and
    uncertain dependencies. Off by default; test selection does not change;
  * `--only IDS` — run a comma-separated list of mutant IDs (repeatable).
    IDs are numbered from the whole selected module profile before filtering.
    Unknown IDs fail. The report records the selection and is a focused result,
    not a full component verification. Annotations for known excluded sites are
    deferred; unknown annotations and selected stale entries still fail. Keep
    source, modules, and macro mode fixed when reusing IDs; check the printed sites;
  * `--prioritize PATH` — with `--fail-fast`, use a previous matrix or raw result
    to try a known killing test first. Pick the cheapest known test from the
    current baseline. Match the site and mutation, not only the ID. If that
    test does not kill, run the whole suite. Missing or excluded tests are ignored.
    Every verdict is tested again. Omit fail-fast and this option for exact
    attribution at a stable checkpoint;
  * `--module MOD` — an implementation module (repeatable; overrides the Contract);
  * `--max-runtime MS` — total task deadline, including preparation and worker
    replacements (default 3600000, one hour). SIGTERM cancels the job. Owned
    worker ports are closed on cancellation; workers remove their copies and
    halt. Each completed verdict is saved atomically. A failed or cancelled
    job keeps its partial raw results and cannot pass as a complete matrix;
  * `--max-mutants-per-worker N` — verdicts per worker VM (default 50, positive).
    Invalid mutations also count. Each group must pass its final original suite
    before the worker retires. Once it exits, a fresh VM checks the remaining
    IDs. Renewal keeps the same concurrent worker count and total job deadline;
  * `--timeout MS` — per-test timeout for mutant runs. Without it the baseline is
    measured and the timeout is five times the slowest baseline test, never under
    1000 ms, so a mutant that loops forever is cut off quickly instead of holding
    each test for a flat ceiling (each worker measures its own baseline; a test or
    module with its own `@tag timeout:` keeps it);
  * `--fail-fast` — stop a mutant's run at its first failing test (ExUnit
    `max_failures: 1`). The verdict (killed or survived) is exact, so the
    survivors and the exit status are the same, but the credit is **partial**: a
    killed mutant is marked `credit: partial`, its `killed_by` names only the
    tests that failed before the stop, and the obligation and test totals count
    only mutants with exact credit (a survivor ran every test; a run that only
    timed out is run again in full). Unique kills and mutation-blind tests are
    not judged. A fail-fast matrix proves kills, not obligation credit: use it
    to sort survivors fast on a slow suite, and a full run to credit;
  * `--seed N` — ExUnit seed (default #{Covenant.Mutate.default_seed()}: definition order);
  * `--macros` — include macro bodies and their quoted code. Compile the
    selected contract test files again for every mutant. List compiled direct
    and transitive callers those tests need with `--recompile`; discovery is
    not automatic;
  * `--recompile PATH` — a project source file or glob to compile against each
    macro mutant (repeatable, requires `--macros`). Files are compiled in the
    supplied order, with sorted glob matches, before the contract test files.
    Put providers before callers. Sources must be inside the project and must
    not be mutation target files. A caller compile error makes the mutant
    `invalid`, with no test or obligation credit. Compilation uses the watchdog
    budget; original modules are restored after each mutant;
  * `--jobs N` — worker processes (default 1; mutants are split round-robin;
    never more than there are mutants, and a warning when N exceeds the schedulers
    online). Every worker, one included, runs the tests from a private copy of the
    project (`Covenant.Mutate.Workdir`), so a mutant's write or delete by a relative
    path never touches your project, ExUnit's `:tmp_dir` paths never collide and the
    kill credit is the same whatever N is. Whatever else the tests share between OS
    processes (a fixed path under the system temp directory, a database, a port) is
    still shared: keep `--jobs 1` for such a suite. A worker that a mutant makes
    loop for ever is stopped by a watchdog and its mutant is a `timeout`; the task
    starts a new worker for the mutants after it;
  * `--out PATH` — the kill matrix JSON (default `tmp/covenant/mutate/<component>/kill_matrix.json`).
    A temporary file unique to the run is renamed atomically to this path;
  * `--contracts DIR` — the contracts directory;
  * `--test-path PATH` — a contract test path or glob, relative to the current
    directory or absolute (repeatable). Without it, the configured `test_paths`
    are searched, relative to `Covenant.root/0` whichever directory the task runs in.

  `--raw PATH --slice I/N --skip m001,m002` are the worker's own flags; the task
  sets them.

  ## The survivors file

  A mutant no test kills is a survivor, and every survivor needs a judgment in
  `contracts/<app>/<component>.survivors.yml`, or in `survivors.yml` beside a
  component-directory Contract. The file is a YAML list with one entry per
  survivor. The task prints a skeleton for each unsorted survivor.

      - at: lib/example/counter.ex:29:17
        operator: element_removal
        mutation: "`value: 0` → `(removed)`"
        sort: equivalent
        reason: The struct default for value is already 0.

  `at` is `file:line:column`, `operator` the mutation operator, `mutation` the
  change as the task prints it and `reason` free text that says why this
  survivor may live. All of them are required: `at`, `operator` and `mutation`
  together name one mutant. `sort` is one of:

  * `equivalent` — the mutant behaves exactly like the original;
  * `log-only` — it changes only a message or a log line nobody pins;
  * `dead-code` — the mutated code is never reached, or its value never read;
  * `timeout` — the tests only timed out against it (a timeout is never a kill);
  * `evaluation-gap` — the behaviour matters but no test pins it yet;
  * `decision-hole` — the Contract leaves the behaviour deliberately undecided
    (a mutant inside the target of an active exception is sorted so for you);
  * `unpromised` — the behaviour does change and the Contract leaves it open
    (the sort of an `unpromised` declaration in the sibling layout).

  An entry matching no surviving mutant is stale and fails the task, like a
  stale `kind: exception` fails `mix covenant.check`.

  ## The sibling layout

  A primitive of the sibling layout (`mix covenant.mutate calc` for
  `contract/calc/`) is mutated in the code its `covers` block names: a
  module, a tree (`MyApp.Calc.*`) or a function, the most specific reference
  winning when primitives overlap. Its Contract tests are the `*_test.exs`
  files beside its README. Its survivors are declared in
  `contract/<primitive>/mutants.md`, as flinch reads them: under a heading
  that gives the reason, an `equivalent` or `unpromised` block of
  `Module.function/arity: from -> to` lines, the mutation as this task prints
  it. Each line names exactly one mutant: when several of the unit's mutants
  share the change, `#k` picks the k-th in source order (`Calc.f/1: 1 -> 2 #2`),
  and a line without one is ambiguous. `unpromised` also takes
  `Module.function/arity: *`, every survivor of the unit. A declaration that a
  test kills, that matches no mutant or that is ambiguous fails the task.
  """

  use Mix.Task

  alias Covenant.{Contract, Error}
  alias Covenant.Mutate

  alias Covenant.Mutate.{
    Checkpoint,
    Hints,
    Matrix,
    Modules,
    Mutant,
    Mutator,
    Runner,
    Selection,
    Survivors
  }

  @requirements ["app.config"]

  @timeout_status Runner.timeout_exit()

  @switches [
    module: :keep,
    only: :keep,
    prioritize: :string,
    checkpoint: :boolean,
    resume: :string,
    selective_recompile: :boolean,
    timeout: :integer,
    max_runtime: :integer,
    max_mutants_per_worker: :integer,
    fail_fast: :boolean,
    macros: :boolean,
    recompile: :keep,
    seed: :integer,
    jobs: :integer,
    out: :string,
    contracts: :string,
    test_path: :keep,
    raw: :string,
    slice: :string,
    skip: :string
  ]

  @impl true
  def run(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("invalid options: #{inspect(invalid)}; see `mix help covenant.mutate`")
    end

    component_id =
      case positional do
        [id] -> id
        _ -> Mix.raise("usage: mix covenant.mutate <component id> [options]")
      end

    # `--contracts` means a path from where it was typed; the workers resolve a relative
    # `contracts_dir` against the root, so hand them the absolute path
    opts =
      if opts[:contracts],
        do: Keyword.put(opts, :contracts, Path.expand(opts[:contracts])),
        else: opts

    # before the override below: `--contracts` redirects the Contract, not the root the
    # configured test paths resolve against
    test_paths = Covenant.test_paths(Keyword.get_values(opts, :test_path))

    if opts[:contracts], do: Application.put_env(:covenant, :contracts_dir, opts[:contracts])

    only =
      case Selection.ids(Keyword.get_values(opts, :only)) do
        {:ok, ids} -> ids
        {:error, reason} -> Mix.raise(reason)
      end

    settings = %{
      component: component_id,
      modules: Keyword.get_values(opts, :module),
      only: only,
      prioritize: opts[:prioritize] && Path.expand(opts[:prioritize]),
      checkpoint: opts[:checkpoint] || not is_nil(opts[:resume]),
      resume: opts[:resume] && Path.expand(opts[:resume]),
      selective_recompile: opts[:selective_recompile] || false,
      timeout: opts[:timeout],
      max_runtime: opts[:max_runtime] || 3_600_000,
      max_mutants_per_worker: opts[:max_mutants_per_worker] || 50,
      fail_fast: opts[:fail_fast] || false,
      macros: opts[:macros] || false,
      recompile: Keyword.get_values(opts, :recompile),
      seed: opts[:seed] || Mutate.default_seed(),
      jobs: max(opts[:jobs] || 1, 1),
      contracts: opts[:contracts] || Covenant.contracts_dir(),
      test_paths: test_paths,
      out: opts[:out] || Path.join(Mutate.default_dir(component_id), "kill_matrix.json")
    }

    if settings.max_runtime <= 0, do: Mix.raise("--max-runtime must be positive")

    if settings.max_mutants_per_worker <= 0,
      do: Mix.raise("--max-mutants-per-worker must be positive")

    if settings.recompile != [] and not settings.macros,
      do: Mix.raise("--recompile requires --macros")

    if settings.selective_recompile and not settings.macros,
      do: Mix.raise("--selective-recompile requires --macros")

    if settings.checkpoint and Mix.env() != :test,
      do: Mix.raise("--checkpoint and --resume require MIX_ENV=test")

    if settings.prioritize && not settings.fail_fast,
      do: Mix.raise("--prioritize requires --fail-fast; omit both for full test attribution")

    hints =
      case Hints.load(settings.prioritize, component_id) do
        {:ok, hints} -> hints
        {:error, reason} -> Mix.raise(reason)
      end

    settings = Map.put(settings, :hints, hints)

    case opts[:raw] do
      nil ->
        Covenant.Mutate.Job.run(settings.max_runtime, fn guard ->
          parent(Map.put(settings, :job_guard, guard))
        end)

      raw ->
        worker(settings, raw, opts[:slice] || "1/1", skip_ids(opts[:skip]))
    end
  end

  # -- parent: spawn workers, merge, report -----------------------------------

  defp parent(settings) do
    if settings.checkpoint, do: Mix.Task.run("compile", [])
    contract = load_contract(settings.contracts)

    plan =
      case Mutate.plan(contract, settings.component,
             modules: settings.modules,
             test_paths: settings.test_paths
           ) do
        {:ok, plan} -> plan
        {:error, reason} -> fail(reason)
      end

    # shown to the user: relative to where they ran the task, as they typed it
    survivors_path =
      settings.contracts |> Survivors.path(plan.component) |> Path.relative_to_cwd()

    check_survivors_document(survivors_path)

    annotations =
      case Survivors.load(survivors_path) do
        {:ok, annotations} -> annotations
        {:error, errors} -> fail_with(errors, "#{survivors_path} could not be parsed")
      end

    catalog =
      if settings.only == [] do
        []
      else
        case Modules.locate(plan.names, plan.source, File.cwd!()) do
          {:ok, modules, _} ->
            Selection.catalog(
              modules,
              File.cwd!(),
              settings.macros,
              keep(contract, plan, plan.source)
            )

          {:error, reason} ->
            fail(reason)
        end
      end

    selected =
      case Selection.choose(catalog, settings.only) do
        {:ok, selected} -> selected
        {:error, reason} -> fail(reason)
      end

    if settings.only != [] do
      Mix.shell().info(
        "covenant.mutate: focused run: #{length(selected)} of #{length(catalog)} mutants; full component verification is deferred"
      )
    end

    Mix.shell().info(
      "covenant.mutate: #{settings.component} — modules (#{plan.source}): #{Enum.join(plan.names, ", ")}"
    )

    Mix.shell().info("covenant.mutate: tests: #{Enum.join(plan.test_files, ", ")}")

    if settings.macros do
      callers =
        if settings.selective_recompile,
          do: "affected contract test files are recompiled last",
          else: "contract test files are recompiled last"

      Mix.shell().info(
        "covenant.mutate: macro mode; recompile callers: #{Enum.join(settings.recompile, ", ")}; #{callers}"
      )
    end

    if settings.fail_fast do
      Mix.shell().info(
        "covenant.mutate: --fail-fast: verdicts are exact, kills carry partial credit"
      )
    end

    settings = settings |> cap_jobs(plan, contract) |> Map.put(:run_id, run_id())

    # a directory of this run's own, so that two runs of a component do not share raw files
    run_dir =
      Path.expand(Path.join(Mutate.default_dir(settings.component), "run-#{settings.run_id}"))

    File.mkdir_p!(run_dir)

    Covenant.Mutate.Job.artifacts(settings.job_guard, run_dir)
    Mix.shell().info("covenant.mutate: raw results: #{run_dir}")

    {checkpoint, reused} =
      if settings.checkpoint do
        case Checkpoint.open(run_dir, Checkpoint.inputs(settings, plan), settings.resume) do
          {:ok, state, reused} -> {state, reused}
          {:error, reason} -> fail(reason)
        end
      else
        {nil, []}
      end

    reused_ids = for raw <- reused, mutant <- raw.mutants, do: mutant.id
    settings = Map.merge(settings, %{checkpoint_state: checkpoint, reused_ids: reused_ids})

    if settings.resume do
      Mix.shell().info(
        "covenant.mutate: reusing #{length(reused_ids)} verdict(s) from #{length(reused)} verified group(s); checking the current baseline"
      )
    end

    raws =
      1..settings.jobs
      |> Enum.map(fn i ->
        task = Task.async(fn -> run_worker(settings, plan, i, run_dir) end)
        Covenant.Mutate.Job.watch(settings.job_guard, task)
      end)
      |> await_workers()
      |> case do
        {:ok, raws} ->
          raws

        {:error, reason} ->
          Mix.shell().error("covenant.mutate: partial results: #{run_dir}")
          fail(reason)
      end

    if checkpoint do
      case Checkpoint.baselines(raws ++ reused) do
        :ok -> :ok
        {:error, reason} -> fail(reason)
      end
    end

    results =
      case Mutate.merge(raws ++ reused) do
        {:ok, results} ->
          results

        {:error, reason} ->
          Mix.shell().error("covenant.mutate: partial results: #{run_dir}")
          fail(reason)
      end

    Enum.each(results.ignored, fn {name, why} ->
      Mix.shell().info("covenant.mutate: ignoring derived module #{name}: #{why}")
    end)

    # Each mutants.md declaration names exactly one mutant of this run, or fails.
    {annotations, unresolved, deferred} =
      if settings.only == [] do
        {resolved, errors} = Survivors.resolve(annotations, results.mutants)
        {resolved, errors, 0}
      else
        Selection.annotations(annotations, catalog, results.mutants)
      end

    matrix =
      Matrix.build(results,
        component: plan.component,
        annotations: annotations,
        survivors_path: survivors_path,
        seed: settings.seed,
        timeout: results.timeout_ms,
        jobs: settings.jobs,
        fail_fast: settings.fail_fast
      )

    matrix = %{matrix | problems: Error.sort(unresolved ++ matrix.problems)}

    Mix.shell().info("")
    Mix.shell().info(Matrix.format(matrix))

    File.mkdir_p!(Path.dirname(settings.out))
    report = Matrix.to_map(matrix)

    report =
      if settings.selective_recompile,
        do: Map.put(report, "selective_recompile", true),
        else: report

    report =
      if checkpoint,
        do:
          Map.put(report, "checkpoint", %{
            "directory" => run_dir,
            "fingerprint" => checkpoint.fingerprint,
            "reused_groups" => length(reused),
            "reused_mutants" => length(reused_ids)
          }),
        else: report

    report =
      if settings.prioritize, do: Map.put(report, "prioritize", settings.prioritize), else: report

    report =
      if settings.only == [],
        do: report,
        else: Map.put(report, "selection", Selection.metadata(catalog, results.mutants, deferred))

    report =
      if settings.macros,
        do: Map.merge(report, %{"macros" => true, "recompile" => settings.recompile}),
        else: report

    temporary = settings.out <> "." <> settings.run_id <> ".tmp"
    File.write!(temporary, [Covenant.JSON.pretty(report), "\n"], [:sync])
    File.rename!(temporary, settings.out)
    unless checkpoint, do: File.rm_rf(run_dir)
    Mix.shell().info("\nwrote #{settings.out}")

    unsorted = for %{mutant: m, sort: nil} <- matrix.survivors, do: m

    cond do
      unsorted == [] ->
        :ok

      plan.component.form == :primitive ->
        Mix.shell().info(
          "\nTo declare the unsorted survivors, add to #{survivors_path}, under a heading that gives the reason:\n"
        )

        Mix.shell().info(
          "```unpromised\n" <>
            Enum.map_join(
              unsorted,
              "\n",
              &Survivors.template(&1, format: :md, mutants: results.mutants)
            ) <> "\n```"
        )

      true ->
        Mix.shell().info("\nTo annotate the unsorted survivors, add to #{survivors_path}:\n")
        Enum.each(unsorted, &Mix.shell().info(Survivors.template(&1)))
    end

    Mix.shell().info("")
    Enum.each(matrix.problems, &Mix.shell().error(Error.format(&1)))

    if Matrix.ok?(matrix) do
      message =
        if settings.only == [],
          do: "every mutant is caught or sorted",
          else:
            "selected mutants are caught or sorted; full component verification is deferred (#{deferred} annotation(s) deferred)"

      Mix.shell().info(IO.ANSI.format([:green, "covenant.mutate: " <> message]))

      :ok
    else
      fail("#{length(matrix.problems)} problem(s) in the kill matrix")
    end
  end

  @doc false
  # `Survivors` reads YAML with `YamlElixir.read_from_string/1`, which keeps one of
  # several documents and one of two equal keys: a `.yml` survivors file goes through
  # the strict reader first, and its errors (file:line) are the failure.
  @spec check_survivors_document(Path.t()) :: :ok | no_return()
  def check_survivors_document(path) do
    with ".yml" <- Path.extname(path),
         {:ok, text} <- File.read(path),
         {:error, errors} <- Covenant.Parser.Records.read_document(text, path) do
      fail_with(errors, "#{path} could not be parsed")
    else
      _ -> :ok
    end
  end

  defp run_id, do: :crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)

  # No more workers than mutants (the rest would only boot and idle), and a word of
  # warning when there are more than the VM has schedulers. The parent counts the
  # mutants itself; when it cannot, the number asked for stands.
  defp cap_jobs(%{jobs: 1} = settings, _plan, _contract), do: settings

  defp cap_jobs(settings, plan, contract) do
    count =
      if settings.only == [],
        do: count_mutants(plan, contract, settings.macros),
        else: length(settings.only)

    {jobs, messages} =
      jobs_for(
        settings.jobs,
        count,
        System.schedulers_online()
      )

    Enum.each(messages, &Mix.shell().info("covenant.mutate: warning: " <> &1))
    %{settings | jobs: jobs}
  end

  @doc false
  @spec jobs_for(pos_integer(), non_neg_integer() | nil, pos_integer()) ::
          {pos_integer(), [String.t()]}
  def jobs_for(requested, mutants, schedulers) do
    capped = if is_integer(mutants) and mutants > 0, do: min(requested, mutants), else: requested

    messages =
      cond do
        capped < requested ->
          ["--jobs #{requested}: only #{mutants} mutant(s), running #{capped} worker(s)"]

        capped > schedulers ->
          ["--jobs #{capped} exceeds the #{schedulers} schedulers online"]

        true ->
          []
      end

    {capped, messages}
  end

  defp count_mutants(plan, contract, macros) do
    source = plan.source
    root = File.cwd!()
    keep = keep(contract, plan, source)

    with {:ok, modules, _ignored} <- Modules.locate(plan.names, source, root) do
      modules
      |> Enum.group_by(fn {_, file} -> file end, fn {module, _} -> inspect(module) end)
      |> Enum.reduce(0, fn {file, targets}, count ->
        {:ok, ast} = Mutator.parse(File.read!(file), file)

        sites =
          ast
          |> Mutator.sites(file: Path.relative_to(file, root), modules: targets, macros: macros)
          |> Enum.filter(keep)

        count + length(sites)
      end)
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # The workers' results, or the first failure: the other workers are stopped then
  # (their ports close, which ends the workers' standard input and so the workers).
  @doc false
  def await_workers(tasks), do: await_workers(Map.new(tasks, &{&1.ref, &1}), [])

  defp await_workers(pending, raws) when map_size(pending) == 0, do: {:ok, raws}

  defp await_workers(pending, raws) do
    receive do
      {:DOWN, ref, :process, _pid, reason} when is_map_key(pending, ref) ->
        pending |> Map.delete(ref) |> Map.values() |> Enum.each(&Task.shutdown(&1, :brutal_kill))
        {:error, "worker task stopped: #{inspect(reason)}"}

      {ref, result} when is_map_key(pending, ref) ->
        Process.demonitor(ref, [:flush])

        case result do
          {:ok, more} ->
            await_workers(Map.delete(pending, ref), more ++ raws)

          {:error, reason} ->
            pending
            |> Map.delete(ref)
            |> Map.values()
            |> Enum.each(&Task.shutdown(&1, :brutal_kill))

            {:error, reason}
        end
    end
  end

  # Each slot starts workers in sequence. A verified retirement or a mutant
  # watchdog stop retains its verdicts and lets a new VM check the remaining IDs.
  defp run_worker(settings, plan, i, run_dir),
    do: run_worker(settings, plan, i, run_dir, 1, settings.reused_ids, [])

  defp run_worker(settings, plan, i, run_dir, attempt, skip, raws) do
    raw_path = Path.join(run_dir, "raw-#{i}-#{attempt}.json")
    worker = "worker #{i}/#{settings.jobs}"

    case spawn_worker(settings, plan, i, raw_path, skip) do
      0 ->
        with {:ok, raw} <- Mutate.decode_raw(raw_path),
             :ok <- Checkpoint.seal(settings.checkpoint_state, raw_path, raw) do
          cond do
            raw.complete ->
              {:ok, [raw | raws]}

            raw.retired and not raw.stopped ->
              replace_worker(settings, plan, i, run_dir, {attempt, skip, raws}, raw, :retired)

            true ->
              {:error, "#{worker} exited before final verification; results are incomplete"}
          end
        end

      @timeout_status ->
        # no results file: it was stopped while no mutant was running (an unmutated
        # re-run outran its budget). That is no mutant's verdict, and a new worker would
        # meet the same state, so it is an error; the worker named the last mutant on its output
        if match?({:ok, %{stopped: true}}, Mutate.decode_raw(raw_path)) do
          stopped(settings, plan, i, run_dir, {attempt, skip, raws}, raw_path)
        else
          {:error,
           "#{worker} was stopped by its watchdog outside a mutant: the unmutated suite did " <>
             "not finish after a mutant (see the output above for which); the results are unreliable"}
        end

      status ->
        {:error, "#{worker} exited with status #{status}"}
    end
  end

  defp stopped(settings, plan, i, run_dir, {attempt, skip, raws}, raw_path) do
    with {:ok, raw} <- Mutate.decode_raw(raw_path) do
      replace_worker(settings, plan, i, run_dir, {attempt, skip, raws}, raw, :watchdog)
    end
  end

  defp replace_worker(settings, plan, i, run_dir, {attempt, skip, raws}, raw, why) do
    worker = "worker #{i}/#{settings.jobs}"
    judged = Enum.map(raw.mutants, & &1.id)

    if judged == [] or Enum.any?(judged, &(&1 in skip)) do
      {:error, "#{worker} cannot restart without new, non-overlapping verdicts"}
    else
      if why == :retired do
        Mix.shell().info(
          "covenant.mutate: #{worker} retired after #{length(judged)} verified verdict(s); " <>
            "starting a new worker for the rest"
        )
      else
        for m <- raw.mutants, m.verdict == :timeout do
          Mix.shell().info(
            "covenant.mutate: #{worker}: #{m.id} #{Mutant.at(m)} was stopped by its watchdog (a timeout); " <>
              "starting a new worker for the rest"
          )
        end
      end

      run_worker(settings, plan, i, run_dir, attempt + 1, skip ++ judged, [raw | raws])
    end
  end

  defp spawn_worker(settings, plan, i, raw_path, skip) do
    mix = System.find_executable("mix") || Mix.raise("cannot find the `mix` executable on PATH")

    args =
      [
        "covenant.mutate",
        settings.component,
        "--raw",
        raw_path,
        "--slice",
        "#{i}/#{settings.jobs}"
      ] ++
        [
          "--seed",
          Integer.to_string(settings.seed),
          "--max-mutants-per-worker",
          Integer.to_string(settings.max_mutants_per_worker)
        ] ++
        if(settings.timeout, do: ["--timeout", Integer.to_string(settings.timeout)], else: []) ++
        if(settings.fail_fast, do: ["--fail-fast"], else: []) ++
        if(settings.macros, do: ["--macros"], else: []) ++
        if(settings.selective_recompile, do: ["--selective-recompile"], else: []) ++
        if(settings.only != [], do: ["--only", Enum.join(settings.only, ",")], else: []) ++
        if(settings.prioritize, do: ["--prioritize", settings.prioritize], else: []) ++
        Enum.flat_map(settings.recompile, &["--recompile", &1]) ++
        if(skip != [], do: ["--skip", Enum.join(skip, ",")], else: []) ++
        ["--contracts", settings.contracts] ++
        Enum.flat_map(plan.names, &["--module", &1]) ++
        Enum.flat_map(settings.test_paths, &["--test-path", &1])

    env = [{"MIX_ENV", "test"}, {"COVENANT_MUTATE_SOURCE", Atom.to_string(plan.source)}]

    {_, status} =
      System.cmd(mix, args, env: env, into: Covenant.Relay.new(), stderr_to_stdout: true)

    status
  end

  defp skip_ids(nil), do: []
  defp skip_ids(text), do: text |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

  # -- worker: boot the test env, run a slice, write raw results --------------

  defp worker(settings, raw_path, slice, skip) do
    stop_with_parent()
    started = System.monotonic_time(:millisecond)
    raw_path = Path.expand(raw_path)
    {i, n} = parse_slice(slice)
    prefix = if n > 1, do: "[#{i}/#{n}] ", else: ""

    Mix.Task.run("compile", [])
    Mix.Task.run("app.start", [])

    contract = load_contract(settings.contracts)

    plan =
      case Mutate.plan(contract, settings.component,
             modules: settings.modules,
             test_paths: settings.test_paths
           ) do
        {:ok, plan} -> plan
        {:error, reason} -> fail(reason)
      end

    source = source_from_env(plan.source)

    {modules, ignored} =
      case Modules.locate(plan.names, source, File.cwd!()) do
        {:ok, modules, ignored} -> {modules, ignored}
        {:error, reason} -> fail("cannot mutate `#{settings.component}`: #{reason}")
      end

    if n == 1 or i == 1 do
      Enum.each(modules, fn {module, file} ->
        Mix.shell().info(
          "#{prefix}covenant.mutate: #{inspect(module)} (#{Path.relative_to_cwd(file)})"
        )
      end)
    end

    runner_plan = %{
      component: settings.component,
      modules: modules,
      test_files: plan.test_files,
      root: File.cwd!(),
      seed: settings.seed,
      timeout: settings.timeout,
      fail_fast: settings.fail_fast,
      macros: settings.macros,
      recompile: settings.recompile,
      selective_recompile: settings.selective_recompile,
      on_recompile: fn mutant, selected, total ->
        if settings.selective_recompile do
          Mix.shell().info(
            "#{prefix}covenant.mutate: #{mutant.id} recompile #{selected}/#{total} caller file(s)"
          )
        end
      end,
      slice: {i, n},
      skip: skip,
      only: settings.only,
      prioritize: settings.hints,
      max_mutants: settings.max_mutants_per_worker,
      keep: keep(contract, plan, source),
      on_baseline: fn baseline ->
        Mix.shell().info(
          "#{prefix}covenant.mutate: baseline #{baseline.tests} test(s) green in #{baseline.ms} ms; #{baseline.total} mutant(s) pending in this slice"
        )
      end,
      on_checkpoint: fn result ->
        write_raw(raw_path, result, settings, slice, modules, ignored, complete: false)
      end,
      on_progress: fn mutant ->
        elapsed = System.monotonic_time(:millisecond) - started

        Mix.shell().info(
          prefix <> progress(mutant) <> " (elapsed #{Float.round(elapsed / 1000, 1)}s)"
        )
      end,
      on_eta: &Mix.shell().info(prefix <> eta(&1)),
      # runs in the worker's private copy, so the path is absolute; the runner halts
      on_timeout: fn result, _mutant ->
        write_raw(raw_path, result, settings, slice, modules, ignored,
          complete: false,
          stopped: true
        )
      end
    }

    case Runner.run(runner_plan) do
      {:ok, result} ->
        Mix.shell().info(
          "#{prefix}covenant.mutate: baseline #{length(result.tests)} test(s) green in #{result.baseline_ms} ms; " <>
            "#{length(result.mutants)} of #{result.all} mutant(s) run, per-test timeout #{result.timeout_ms} ms"
        )

        retiring = result.remaining > 0

        write_raw(
          raw_path,
          result,
          settings,
          slice,
          modules,
          ignored,
          complete: not retiring,
          retired: retiring
        )

        :ok

      {:error, reason} ->
        fail(reason)
    end
  end

  defp write_raw(
         raw_path,
         result,
         settings,
         slice,
         modules,
         ignored,
         state
       ) do
    File.mkdir_p!(Path.dirname(raw_path))

    temporary = raw_path <> ".tmp"

    File.write!(
      temporary,
      [
        Mutate.encode_raw(result,
          component: settings.component,
          only: settings.only,
          complete: Keyword.get(state, :complete, true),
          stopped: Keyword.get(state, :stopped, false),
          retired: Keyword.get(state, :retired, false),
          slice: slice,
          modules: Enum.map(modules, fn {m, _} -> inspect(m) end),
          ignored: ignored
        ),
        "\n"
      ],
      [:sync]
    )

    File.rename!(temporary, raw_path)
  end

  # The task that spawned this worker holds the other end of its standard input, and
  # closes it when it dies: a worker stuck in a mutant must not outlive it.
  defp stop_with_parent do
    spawn(fn -> drain_stdin() end)
    :ok
  end

  defp drain_stdin do
    case IO.binread(:stdio, :eof) do
      :eof -> orphaned()
      {:error, _} -> orphaned()
      _data -> drain_stdin()
    end
  end

  # The parent is gone: take the private copy of the project with us.
  defp orphaned do
    Covenant.Mutate.Runner.remove_workdir()
    System.halt(1)
  end

  # A primitive is mutated only in the code its covers own by the most specific reference.
  defp keep(contract, %{component: %{form: :primitive, id: id}}, :covers),
    do: &Mutate.covered_by?(contract, id, &1)

  defp keep(_contract, _plan, _source), do: fn _ -> true end

  defp progress(%Mutant{} = m) do
    verdict =
      case m.verdict do
        :killed -> "killed by #{length(m.killed_by)} test(s)"
        :survived -> "SURVIVED"
        :timeout -> "TIMEOUT (survivor)"
        :invalid -> "invalid: #{m.reason}"
      end

    "  #{m.id} #{Mutant.at(m)} #{m.operator} #{Mutant.mutation(m)}  #{verdict}"
  end

  defp eta(%{done: done, total: total, elapsed_ms: elapsed_ms}),
    do: Mutate.progress_line(done, total, elapsed_ms)

  defp parse_slice(slice) do
    with [i, n] <- String.split(slice, "/"),
         {i, ""} <- Integer.parse(i),
         {n, ""} <- Integer.parse(n),
         true <- i >= 1 and n >= 1 and i <= n do
      {i, n}
    else
      _ -> Mix.raise("--slice must be I/N with 1 <= I <= N, got #{inspect(slice)}")
    end
  end

  # The parent resolved the names and passes them as --module; the worker must
  # still know whether they were derived (lenient) or explicit (strict).
  defp source_from_env(default) do
    case System.get_env("COVENANT_MUTATE_SOURCE") do
      "derived" -> :derived
      "front_matter" -> :front_matter
      "covers" -> :covers
      "flag" -> :flag
      _ -> default
    end
  end

  # -- shared -----------------------------------------------------------------

  defp load_contract(dir) do
    case Contract.load(dir, sibling: sibling_relative()) do
      {:ok, contract} -> contract
      {:error, errors} -> fail_with(errors, "the Contract in #{dir} could not be parsed")
    end
  end

  @spec fail_with([Error.t()], String.t()) :: no_return()
  defp fail_with(errors, message) do
    Enum.each(Error.sort(errors), &Mix.shell().error(Error.format(&1)))
    fail(message)
  end

  @spec fail(String.t()) :: no_return()
  defp fail(message) do
    Mix.shell().error(
      IO.ANSI.format([:red, "covenant.mutate: ", message])
      |> IO.iodata_to_binary()
    )

    exit({:shutdown, 1})
  end

  defp sibling_relative do
    sibling = Covenant.sibling_dir()
    sibling && Path.relative_to_cwd(sibling)
  end
end
