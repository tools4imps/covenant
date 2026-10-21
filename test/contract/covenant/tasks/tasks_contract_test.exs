defmodule Covenant.TasksContractTest do
  @moduledoc """
  Runs the mix tasks as subprocesses inside the fixture project, the way a
  user would. Slow on the first run (the fixture compiles its own `_build`).
  """

  use Covenant.Case, component: "covenant.tasks", async: false

  alias Covenant.ContractBuilder

  @moduletag :e2e
  @moduletag timeout: 300_000

  @project ContractBuilder.fixture_project()

  defp mix(args, opts \\ []) do
    mix = System.find_executable("mix") || raise "mix not on PATH"
    env = [{"MIX_ENV", "dev"}, {"COVENANT_RESULTS_DIR", nil}] ++ Keyword.get(opts, :env, [])
    {output, status} = System.cmd(mix, args, cd: @project, env: env, stderr_to_stdout: true)
    if opts[:print], do: IO.puts(output)
    {output, status}
  end

  setup_all do
    File.rm_rf!(Path.join(@project, "_build/covenant"))
    File.rm_rf!(Path.join(@project, "tmp"))
    :ok
  end

  @tag obligation: "covenant.tasks.I1"
  test "mix covenant.check runs the contract suite, prints coverage, writes coverage.json and exits 0" do
    {output, status} = mix(["covenant.check"])
    assert status == 0, output
    assert output =~ "covenant.check: running mix test test/contract"
    assert output =~ ~r/(8 tests, 0 failures|Result: 8 passed)/
    assert output =~ ~r/example\.counter\s+6\/6\s+100\.0%/
    assert output =~ ~r/example\.greeter\s+1\/1\s+100\.0%/
    assert output =~ ~r/total\s+7\/7\s+100\.0%/
    assert output =~ "covenant.check: warning: 1 component(s) declare no modules: example.greeter"
    assert output =~ "the Contract holds"

    coverage = Path.join(@project, "contracts/coverage.json") |> File.read!() |> JSON.decode!()
    assert coverage["totals"] == %{"active" => 7, "covered" => 7, "coverage" => 1.0}

    assert coverage["components"]["example.counter"]["obligations"]["example.counter.I5"][
             "status"
           ] == "retired"

    assert File.exists?(Path.join(@project, "_build/covenant/results/example.json"))
  end

  @tag obligation: "covenant.tasks.I1"
  test "mix covenant.check accepts records and tests in one component directory" do
    contracts = Path.join(@project, "tmp/component-contract")
    component = Path.join(contracts, "example.greeter")
    File.rm_rf!(contracts)
    File.mkdir_p!(component)
    on_exit(fn -> File.rm_rf!(contracts) end)

    File.write!(Path.join(component, "obligations.md"), """
    ---
    modules: [Example.Greeter]
    ---
    # example.greeter

    ## Purpose

    Greets people.

    ### example.greeter.I1 — Greets a person by name
    - **scope:** `Example.Greeter.greet/1`
    - **must:** return a greeting that includes the name
    - **kind:** functional
    - **status:** active
    """)

    File.write!(Path.join(component, "decisions.yml"), "[]\n")
    File.write!(Path.join(component, "survivors.yml"), "[]\n")

    File.write!(Path.join(component, "greeter_contract_test.exs"), """
    defmodule Example.ComponentDirectoryContractTest do
      use Covenant.Case, component: "example.greeter", async: true

      @tag obligation: "example.greeter.I1"
      test "greets by name" do
        assert Example.Greeter.greet("Ada") == "Hello, Ada!"
      end
    end
    """)

    {output, status} =
      mix([
        "covenant.check",
        "--contracts",
        "tmp/component-contract",
        "--test-path",
        "tmp/component-contract"
      ])

    assert status == 0, output
    assert output =~ "covenant.check: running mix test tmp/component-contract"
    assert output =~ ~r/example\.greeter\s+1\/1\s+100\.0%/
    assert output =~ "covenant.check: the Contract holds"
    assert File.exists?(Path.join(contracts, "coverage.json"))
  end

  @tag obligation: "covenant.tasks.I2"
  test "mix covenant.check --no-run on a corrupted copy of the Contract fails with precise messages" do
    {_, 0} = mix(["covenant.check"])

    corrupt = Path.join(@project, "tmp/corrupt-contracts")
    ContractBuilder.copy_fixture_contracts(corrupt)

    intent = Path.join(corrupt, "example/counter.intent.md")

    File.write!(
      intent,
      File.read!(intent)
      |> String.replace(
        "- **must:** stop at zero when `by` exceeds the value, instead of going negative or raising\n",
        ""
      )
    )

    {output, status} = mix(["covenant.check", "--no-run", "--contracts", "tmp/corrupt-contracts"])
    assert status == 1

    assert output =~
             "tmp/corrupt-contracts/example/counter.intent.md:53: obligation `example.counter.I1` is missing `must`"

    assert output =~ "could not be parsed (1 problem(s))"

    ContractBuilder.copy_fixture_contracts(corrupt)
    greeter = Path.join(corrupt, "example/greeter.obligations.md")

    File.write!(
      greeter,
      File.read!(greeter)
      |> String.replace("`Example.Greeter.clamp/1`", "`Example.Greeter.squash/1`")
    )

    {output, status} = mix(["covenant.check", "--no-run", "--contracts", "tmp/corrupt-contracts"])
    assert status == 1

    assert output =~
             "greeter.obligations.md:16: exception `example.greeter.I2` targets Example.Greeter.squash/1, which no longer exists"

    assert output =~ "covenant.check: 1 problem(s) found in the Contract"
    assert output =~ ~r/total\s+7\/7\s+100\.0%/
  end

  @tag obligation: "covenant.tasks.I1"
  test "mix covenant.check relays a suite that prints bytes that aren't UTF-8, and keeps UTF-8 intact" do
    noisy = Path.join(@project, "test/contract/example/noisy_contract_test.exs")

    # A raw (latin1) device passes the bytes through unconverted, as a port or a
    # binary dump would.
    File.write!(noisy, """
    defmodule Example.NoisyContractTest do
      use Covenant.Case, component: "example.greeter"

      @tag obligation: "example.greeter.I1"
      test "prints invalid UTF-8 and an arrow" do
        :ok = :io.setopts(:standard_io, encoding: :latin1)
        IO.binwrite(<<"bytes:", 0xFF, 0xFE, "\\n">>)
        :ok = :io.setopts(:standard_io, encoding: :unicode)
        IO.puts("arrow: →")
        assert Example.Greeter.greet("x") =~ "x"
      end
    end
    """)

    on_exit(fn -> File.rm(noisy) end)

    {output, status} = mix(["covenant.check"])
    assert status == 0, output
    assert output =~ "bytes:��\n"
    assert output =~ "arrow: →\n"
    assert output =~ ~r/(9 tests, 0 failures|Result: 9 passed)/
    assert output =~ "the Contract holds"
  end

  @tag obligation: "covenant.tasks.I1"
  test "the relay holds back a character cut between chunks and replaces what isn't UTF-8" do
    arrow = "→"
    <<a, b, c>> = arrow

    assert Covenant.Relay.take("ok " <> <<a, b>>) == {"ok ", <<a, b>>}
    assert Covenant.Relay.take(<<a, b, c>> <> "\n") == {"→\n", ""}
    assert Covenant.Relay.take("é" |> binary_part(0, 1)) == {"", "é" |> binary_part(0, 1)}
    assert Covenant.Relay.take(<<"x", 0xFF, 0xFE, "y">>) == {"x��y", ""}
    assert Covenant.Relay.take(<<0xF0, 0x9F, 0x98>>) == {"", <<0xF0, 0x9F, 0x98>>}
    assert Covenant.Relay.take("😀") == {"😀", ""}
    assert Covenant.Relay.take("") == {"", ""}
  end

  @tag obligation: "covenant.tasks.I3"
  test "mix covenant.check fails when a contract test fails" do
    broken = Path.join(@project, "test/contract/example/broken_contract_test.exs")

    File.write!(broken, """
    defmodule Example.BrokenContractTest do
      use Covenant.Case, component: "example.greeter"

      @tag obligation: "example.greeter.I1"
      test "fails on purpose", do: assert Example.Greeter.greet("x") == "nope"
    end
    """)

    on_exit(fn -> File.rm(broken) end)

    {output, status} = mix(["covenant.check"])
    assert status == 1
    assert output =~ ~r/(1 failure|Failed: 1 test)/
    assert output =~ "test fails on purpose (obligation `example.greeter.I1`) failed"
    assert output =~ "contract suite failed (exit status 2)"
  end

  @tag obligation: "covenant.tasks.I1"
  test "mix covenant.check --results-dir deletes only the Covenant result files it finds there" do
    reports = Path.join(@project, "tmp/reports")
    File.rm_rf!(reports)
    File.mkdir_p!(Path.join(reports, "nested"))
    File.write!(Path.join(reports, "q3-audit.txt"), "keep")
    File.write!(Path.join(reports, "other.json"), ~s({"app": "mine"}))
    File.write!(Path.join(reports, "nested/deep.json"), "{}")
    Covenant.Results.write(reports, "stale_app", [])

    {output, status} = mix(["covenant.check", "--results-dir", "tmp/reports"])
    assert status == 0, output

    assert File.read!(Path.join(reports, "q3-audit.txt")) == "keep"
    assert File.read!(Path.join(reports, "other.json")) == ~s({"app": "mine"})
    assert File.exists?(Path.join(reports, "nested/deep.json"))
    refute File.exists?(Path.join(reports, "stale_app.json"))

    assert [_ | _] =
             Path.wildcard(Path.join(reports, "*.json")) -- [Path.join(reports, "other.json")]

    assert Path.wildcard(Path.join(reports, ".run-*")) == []
  end

  @tag obligation: "covenant.tasks.I6"
  test "mix covenant.check --static runs when the project's lib does not compile" do
    broken = Path.join(@project, "lib/example/broken_ahead.ex")
    File.write!(broken, "defmodule Example.BrokenAhead do\n  def (\nend\n")
    on_exit(fn -> File.rm(broken) end)
    on_exit(fn -> File.rm(Path.join(@project, "contracts/coverage.static.json")) end)

    # Mix builds the dependencies, Covenant among them, before any task runs: done here,
    # so that whatever is compiled below is the project's own code
    {_, 0} = mix(["deps.compile"])

    {output, status} = mix(["covenant.check", "--static"])
    assert status == 0, output
    assert output =~ "covenant.check: the Contract holds statically"
    refute output =~ "Compiling"
  end

  @tag obligation: "covenant.tasks.I4"
  test "mix covenant.conditions passes on the fixture and lists the checked premises" do
    {output, status} = mix(["covenant.conditions", "--verbose"])
    assert status == 0, output
    assert output =~ "ok Elixir is at least 1.18"
    assert output =~ "ok The contract tooling depends on yaml_elixir"

    assert output =~
             "ok A counter built without options is capped at 100 — Example.Counter.new/0 [max] is 100"

    assert output =~ "(not machine-checkable)"
    assert output =~ "5 record(s), 7 machine-checkable condition(s), 0 suspect record(s)"
  end

  @tag obligation: "covenant.tasks.I4"
  test "mix covenant.conditions fails on a suspect record" do
    suspect = Path.join(@project, "tmp/suspect-contracts")
    ContractBuilder.copy_fixture_contracts(suspect)
    records = Path.join(suspect, "example/counter.decisions.yml")

    File.write!(
      records,
      File.read!(records)
      |> String.replace(
        "check: { kind: dep, name: yaml_elixir, version: \"~> 2.12\" }",
        "check: { kind: dep, name: ecto }"
      )
    )

    {output, status} = mix(["covenant.conditions", "--contracts", "tmp/suspect-contracts"])
    assert status == 1
    assert output =~ "counter.decisions.yml:20: record `positive-steps` is suspect"
    assert output =~ "dependency `ecto` is not in mix.lock"
    assert output =~ "1 suspect record(s)"
  end

  @tag obligation: "covenant.tasks.I4"
  test "mix covenant.conditions runs a value check in the project's VM and leaves a missing module unchecked" do
    contracts = Path.join(@project, "tmp/value-contracts")
    ContractBuilder.copy_fixture_contracts(contracts)
    records = Path.join(contracts, "example/counter.decisions.yml")

    File.write!(
      records,
      File.read!(records) <>
        """

        - id: scope-values
          date: "2026-10-10"
          decision: The counter records three event kinds.
          driver: A premise checked against the code the task runs in.
          approved_by: lead (fixture, 2026-10-10)
          conditions:
            - text: The counter has three event kinds
              check: { kind: value, call: "Example.Scope.event_kinds/0", equals: 3 }
            - text: A module this project does not compile
              check: { kind: value, call: "Nope.Missing.limits/0", equals: 1 }
        """
    )

    {output, status} =
      mix(["covenant.conditions", "--verbose", "--contracts", "tmp/value-contracts"])

    assert status == 0, output
    assert output =~ "ok The counter has three event kinds — Example.Scope.event_kinds/0 is 3"

    assert output =~
             "A module this project does not compile (not checked: module not compiled in this VM: Nope.Missing)"

    assert output =~ "6 record(s), 8 machine-checkable condition(s), 0 suspect record(s)"
    assert output =~ "covenant.conditions: 1 condition(s) not checked in this VM"

    File.write!(records, String.replace(File.read!(records), "equals: 3 }", "equals: 4 }"))
    {output, status} = mix(["covenant.conditions", "--contracts", "tmp/value-contracts"])
    assert status == 1
    assert output =~ "record `scope-values` is suspect"
    assert output =~ "Example.Scope.event_kinds/0 is 3, the record says 4"
    assert output =~ "1 suspect record(s)"
  end

  @tag obligation: "covenant.tasks.I1"
  test "mix covenant.check warns about a ceiling whose counter raises, writes coverage.json and exits 0" do
    {_, 0} = mix(["covenant.check"])

    contracts = Path.join(@project, "tmp/unchecked-ceiling-contracts")
    ContractBuilder.copy_fixture_contracts(contracts)
    scope = Path.join(contracts, "system/scope.yml")

    File.write!(
      scope,
      File.read!(scope) <>
        """
        - name: stub
          ceiling: 3
          counter: { kind: module, module: Example.Scope, function: unimplemented }
          why: A counter that is not implemented yet.
        """
    )

    {output, status} =
      mix(["covenant.check", "--no-run", "--contracts", "tmp/unchecked-ceiling-contracts"])

    assert status == 0, output

    assert output =~
             "covenant.check: warning: scope ceiling `stub` unchecked: Example.Scope.unimplemented/0 raised RuntimeError"

    assert output =~ "the Contract holds"
    assert File.exists?(Path.join(contracts, "coverage.json"))
  end

  @tag obligation: "covenant.tasks.I5"
  test "mix covenant.regen writes a pack and refuses an unknown component" do
    {output, status} = mix(["covenant.regen", "example.counter", "--out", "tmp/pack"])
    assert status == 0, output
    assert output =~ "covenant.regen: wrote 9 file(s) to tmp/pack"
    assert File.exists?(Path.join(@project, "tmp/pack/PROMPT.md"))
    assert File.exists?(Path.join(@project, "tmp/pack/stubs/lib/example/counter.ex"))

    assert File.exists?(
             Path.join(@project, "tmp/pack/test/contract/example/counter_contract_test.exs")
           )

    {output, status} = mix(["covenant.regen", "example.nope"])
    assert status == 1
    assert output =~ "unknown component `example.nope`"
  end

  @tag obligation: "covenant.tasks.I5"
  test "mix covenant.regen skips references to modules the component does not own" do
    contracts = Path.join(@project, "tmp/skipping-contracts")
    File.rm_rf!(contracts)

    surface = """
    - `Demo.Widget.size/1` — its size; an empty one calls `System.halt(1)` and `Scope.put/1`.
    - `Example.MixProject.project/0` — loadable, but compiled from a script: its beam lies nowhere.
    - `Elsewhere.Thing.go/0` — a namespace the component does not use, not loadable.
    - `Covenant.Error.format/1` — an app of the fixture's dependencies, loadable.
    """

    ContractBuilder.demo_contracts(contracts, surface, "")

    {output, status} =
      mix([
        "covenant.regen",
        "demo.widget",
        "--contracts",
        contracts,
        "--test-path",
        Path.join(@project, "test/*"),
        "--out",
        "tmp/skipping-pack"
      ])

    assert status == 0, output

    assert output =~
             "covenant.regen: skipped 4 references to modules the component does not own: Covenant.Error, Elsewhere.Thing, Scope, System"

    assert output =~
             "covenant.regen: possibly_foreign: Example.MixProject (stubbed; list the component's modules"

    assert File.exists?(Path.join(@project, "tmp/skipping-pack/stubs/lib/example/mix_project.ex"))
    refute File.exists?(Path.join(@project, "tmp/skipping-pack/stubs/lib/elsewhere/thing.ex"))
    refute File.exists?(Path.join(@project, "tmp/skipping-pack/stubs/lib/system.ex"))
    assert File.exists?(Path.join(@project, "tmp/skipping-pack/stubs/lib/demo/widget.ex"))
  end

  @tag obligation: "covenant.tasks.I5"
  test "mix covenant.regen attributes a module another component lists and notes what the project already implements" do
    contracts = Path.join(@project, "tmp/owned-contracts")
    File.rm_rf!(contracts)

    surface = """
    - `Demo.Widget.size/1` — its size; it reads `Example.Counter.value/1` and `Example.Greeter.greet/1`.
    - `Demo.Gadget.beep/0` — the gadget's, through a fragment: `Gadget.beep/0`.
    """

    ContractBuilder.demo_contracts(contracts, surface, "")

    File.write!(
      Path.join(contracts, "demo/gadget.obligations.md"),
      """
      ---
      modules: [Demo.Gadget, Example.Counter]
      ---
      """ <> ContractBuilder.light_obligations()
    )

    {output, status} =
      mix([
        "covenant.regen",
        "demo.widget",
        "--contracts",
        contracts,
        "--test-path",
        Path.join(@project, "test/*"),
        "--out",
        "tmp/owned-pack"
      ])

    assert status == 0, output

    # listed by the gadget: attributed to it, loadable in the fixture or not
    assert output =~
             "covenant.regen: skipped (owned by demo.gadget): Demo.Gadget, Example.Counter"

    # in an app of the fixture project and listed by nobody: already implemented
    assert output =~
             "covenant.regen: skipped (already implemented in this project): Example.Greeter"

    refute File.exists?(Path.join(@project, "tmp/owned-pack/stubs/lib/example/counter.ex"))
    refute File.exists?(Path.join(@project, "tmp/owned-pack/stubs/lib/example/greeter.ex"))
    assert File.exists?(Path.join(@project, "tmp/owned-pack/stubs/lib/demo/widget.ex"))
  end

  @tag obligation: "covenant.tasks.I6"
  test "mix covenant.check --static reads the tests, runs none and writes only coverage.static.json" do
    coverage = Path.join(@project, "contracts/coverage.json")
    static = Path.join(@project, "contracts/coverage.static.json")
    File.rm(coverage)
    File.rm(static)
    on_exit(fn -> File.rm(static) end)

    {output, status} = mix(["covenant.check", "--static"])
    assert status == 0, output

    assert output =~
             "covenant.check --static: read 2 file(s), 2 contract test module(s), 8 tagged test(s) under test/contract; no test was compiled or run"

    refute output =~ "Running ExUnit"

    assert output =~
             "Static contract coverage (obligations with a tagged test / active obligations)"

    assert output =~ ~r/total\s+7\/7\s+100\.0%/

    assert output =~
             "skipped (need compiled code): 1 exception target(s), 1 module ceiling(s): counter-event-kinds, example.greeter.I2"

    assert output =~ "covenant.check: warning: 1 component(s) declare no modules: example.greeter"
    assert output =~ "covenant.check: the Contract holds statically"
    refute File.exists?(coverage)

    assert %{"mode" => "static", "totals" => %{"covered" => 7}} =
             static |> File.read!() |> JSON.decode!()
  end

  @tag obligation: "covenant.tasks.I6"
  test "mix covenant.check --static passes tests that could not compile and fails bad tags precisely" do
    tests = Path.join(@project, "tmp/static-tests")
    File.mkdir_p!(tests)

    File.write!(Path.join(tests, "unbuilt_contract_test.exs"), """
    defmodule Example.UnbuiltContractTest do
      use Covenant.Case, component: "example.counter"

      @moduletag obligation: "example.counter.I1"

      test "calls code that does not exist" do
        assert Example.NotWrittenYet.call!(%{}) == :ok
      end

      @tag obligation: ["example.counter.I2", "example.counter.I3", "example.counter.I4"]
      test "more", do: Example.NotWrittenYet.more()

      @tag obligation: ["example.counter.I6", "example.counter.I7"]
      test "rest", do: Example.NotWrittenYet.rest()
    end

    defmodule Example.UnbuiltGreeterContractTest do
      use Covenant.Case, component: "example.greeter"

      @tag obligation: "example.greeter.I1"
      test "greets", do: Example.NotWrittenYet.greet()
    end
    """)

    {output, status} = mix(["covenant.check", "--static", "--test-path", "tmp/static-tests"])
    assert status == 0, output
    assert output =~ "read 1 file(s), 2 contract test module(s), 4 tagged test(s)"

    File.write!(Path.join(tests, "bad_contract_test.exs"), """
    defmodule Example.BadContractTest do
      use Covenant.Case, component: "example.counter"

      @tag obligation: "example.counter.I99"
      test "unknown", do: :ok

      @tag obligation: "example.counter.I5"
      test "retired", do: :ok

      test "untagged", do: :ok
    end
    """)

    {output, status} =
      mix(["covenant.check", "--static", "--test-path", "tmp/static-tests", "--root", "."])

    assert status == 1

    assert output =~
             "tmp/static-tests/bad_contract_test.exs:5: test unknown is tagged with unknown obligation `example.counter.I99`"

    assert output =~
             "tmp/static-tests/bad_contract_test.exs:8: test retired is tagged with `example.counter.I5`, which is retired"

    assert output =~
             "tmp/static-tests/bad_contract_test.exs:10: test untagged has no obligation tag"

    assert output =~ "covenant.check: 3 problem(s) found in the Contract (static)"
  end

  @tag obligation: "covenant.tasks.I7"
  test "mix covenant.mutate credits every mutant the same with --jobs 1 and --jobs 4, each worker on a tmp_dir of its own" do
    File.mkdir_p!(Path.join(@project, "tmp"))

    # The fixture's counter test appends "<os pid> <tmp_dir>" to this file.
    mutate = fn jobs ->
      log = Path.join(@project, "tmp/tmp-dirs-jobs-#{jobs}.log")
      out = "tmp/mutate-jobs-#{jobs}.json"
      File.rm(log)

      {output, status} =
        mix(["covenant.mutate", "example.counter", "--jobs", "#{jobs}", "--out", out],
          env: [{"COVENANT_TMPDIR_LOG", log}]
        )

      assert status == 0, output
      matrix = Path.join(@project, out) |> File.read!() |> JSON.decode!()

      credit =
        for m <- matrix["mutants"],
            into: %{},
            do: {m["id"], {m["verdict"], Enum.sort(m["killed_by"])}}

      used =
        log
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.uniq()
        |> Enum.map(&List.to_tuple(String.split(&1, " ", parts: 2)))

      {credit, used}
    end

    {serial, _} = mutate.(1)
    {parallel, used} = mutate.(4)

    assert Enum.any?(serial, fn {_, {verdict, killers}} ->
             verdict == "killed" and killers != []
           end)

    assert parallel == serial

    pids = used |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    assert length(pids) == 4, "expected 4 workers to report, got #{inspect(used)}"

    for {dir, users} <- Enum.group_by(used, &elem(&1, 1), &elem(&1, 0)) do
      assert length(users) == 1, "workers #{inspect(users)} shared the tmp_dir #{dir}"

      refute String.starts_with?(dir, Path.join(@project, "tmp")),
             "#{dir} is the project's own tmp"
    end

    for pid <- pids do
      refute File.exists?(Path.join(System.tmp_dir!(), "covenant-mutate-#{pid}")),
             "worker #{pid} left its working directory behind"
    end
  end

  @tag obligation: "covenant.tasks.I8"
  test "mix help covenant.mutate documents the survivors file: location, keys, every sort and the exit status" do
    help = Mix.Task.moduledoc(Mix.Tasks.Covenant.Mutate)

    assert help =~ "contracts/<app>/<component>.survivors.yml"
    assert help =~ "`survivors.yml` beside a"
    assert help =~ "component-directory Contract"

    for key <- ~w(at operator mutation sort reason),
        do: assert(help =~ "`#{key}`" or help =~ "#{key}:")

    for sort <- Covenant.Mutate.Survivors.sorts() do
      assert help =~ "* `#{sort}` — ", "the help does not explain the sort #{sort}"
    end

    assert help =~ "Exit status 0 when"
    assert help =~ "keep `--jobs 1`"
  end
end
