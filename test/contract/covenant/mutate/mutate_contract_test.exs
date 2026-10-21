defmodule Covenant.MutateContractTest do
  @moduledoc """
  Unit-level contract tests of `covenant.mutate`: pure calls into the mutate
  modules, so `mix covenant.mutate covenant.mutate --test-path <this file>`
  can hot-swap those modules and see these tests catch the mutants. The
  end-to-end obligations live in `mutate_e2e_contract_test.exs`.
  """

  use Covenant.Case, component: "covenant.mutate", async: true

  alias Covenant.{Contract, Error, Mutate}
  alias Covenant.Contract.Component
  alias Covenant.ContractBuilder
  alias Covenant.Mutate.{Matrix, Modules, Mutant, Mutator, Operators, Runner, Survivors}

  @moduletag :tmp_dir

  # absolute, so the tests do not depend on the working directory (a mutate
  # worker runs them from a private one)
  @root Path.expand("../../../..", __DIR__)

  setup_all do
    contract = Contract.load!(ContractBuilder.fixture_contracts())
    {:ok, fixture: contract, counter: Contract.component(contract, "example.counter")}
  end

  # -- helpers ----------------------------------------------------------------

  defp parse!(source) do
    assert {:ok, ast} = Mutator.parse(source, "sample.ex")
    ast
  end

  defp mutants(body, opts \\ []) do
    ("defmodule Sample do\n" <> body <> "\nend\n")
    |> parse!()
    |> Mutator.sites([file: "sample.ex"] ++ opts)
    |> Mutator.numbered()
  end

  defp changes(body, operator) do
    for m <- mutants(body), m.operator == operator, do: {m.from, m.to}
  end

  defp mutant(id, verdict, attrs \\ []) do
    struct!(
      Mutant,
      [
        id: id,
        file: "lib/x.ex",
        line: 4,
        column: 7,
        operator: :integer_shift,
        from: "1",
        to: "2",
        index: 1,
        module: "X",
        function: "f/0",
        verdict: verdict
      ] ++ attrs
    )
  end

  defp entry(name, obligations, outcome \\ :passed, extra \\ []) do
    Map.merge(
      %{
        key: "M:#{name}",
        module: "M",
        name: name,
        file: "test/m_test.exs",
        line: 1,
        obligations: obligations,
        mutation_blind: nil,
        outcome: outcome
      },
      Map.new(extra)
    )
  end

  defp results(tests, mutants),
    do: %{
      tests: tests,
      mutants: mutants,
      modules: ["X", "Y"],
      files: ["lib/x.ex"],
      baseline_ms: 5
    }

  # -- I1: the operators --------------------------------------------------------

  @tag obligation: "covenant.mutate.I1"
  test "boolean_flip, comparison_swap, arithmetic_swap and logical_swap swap the operator" do
    assert changes("def a, do: true", :boolean_flip) == [{"true", "false"}]
    assert changes("def a, do: false", :boolean_flip) == [{"false", "true"}]

    comparisons = [
      {"==", ["!="]},
      {"!=", ["=="]},
      {"===", ["!=="]},
      {"!==", ["==="]},
      {"<", ["<=", ">="]},
      {"<=", ["<", ">"]},
      {">", [">=", "<="]},
      {">=", [">", "<"]}
    ]

    for {op, tos} <- comparisons do
      assert changes("def a(x, y), do: x #{op} y", :comparison_swap) == Enum.map(tos, &{op, &1}),
             "comparison #{op}"
    end

    for {op, to} <- [{"+", "-"}, {"-", "+"}, {"*", "/"}, {"/", "*"}] do
      assert changes("def a(x, y), do: x #{op} y", :arithmetic_swap) == [{op, to}],
             "arithmetic #{op}"
    end

    for {op, to} <- [{"and", "or"}, {"or", "and"}, {"&&", "||"}, {"||", "&&"}] do
      assert changes("def a(x, y), do: x #{op} y", :logical_swap) == [{op, to}], "logical #{op}"
    end
  end

  @tag obligation: "covenant.mutate.I1"
  test "condition_negate negates an if or unless condition" do
    assert changes("def a(x) do\n if x, do: 1, else: 2\n end", :condition_negate) ==
             [{"if x", "if !(x)"}]

    assert changes("def a(x) do\n unless x, do: 1, else: 2\n end", :condition_negate) ==
             [{"unless x", "unless !(x)"}]
  end

  @tag obligation: "covenant.mutate.I1"
  test "statement_removal drops a non-final call, never an assignment or the last expression" do
    body = """
    def a(x) do
      IO.puts(x)
      y = x
      send(self(), y)
      y
    end
    """

    assert changes(body, :statement_removal) ==
             [{"IO.puts(x)", "(removed)"}, {"send(self(), y)", "(removed)"}]

    assert changes("def a(x), do: IO.puts(x)", :statement_removal) == []
  end

  @tag obligation: "covenant.mutate.I1"
  test "return_nil replaces the last expression of a def or defp, unless it is nil already" do
    body = "def a(x), do: x + 1\ndefp b(x) do\n IO.puts(x)\n x\n end\ndef c, do: nil"
    assert changes(body, :return_nil) == [{"x + 1", "nil"}, {"x", "nil"}]
  end

  @tag obligation: "covenant.mutate.I1"
  test "integer_shift and string_empty change written literals" do
    assert changes("def a, do: 5", :integer_shift) == [{"5", "6"}, {"5", "4"}]
    assert changes("def a, do: \"abc\"", :string_empty) == [{~s("abc"), ~s("")}]
    assert changes("def a(x), do: \"a\#{x}\"", :string_empty) == [{~S("a#{x}"), ~s("")}]
    assert changes("def a, do: \"\"", :string_empty) == []
    assert changes("def a, do: x", :integer_shift) == []
  end

  @tag obligation: "covenant.mutate.I1"
  test "guard_removal and clause_removal drop a guard or one of several clauses" do
    assert changes("def a(x) when x > 0, do: x", :guard_removal) == [{"when x > 0", "(no guard)"}]

    kase = "def a(x) do\n case x do\n 1 -> :one\n _ -> :other\n end\n end"

    assert changes(kase, :clause_removal) == [
             {"case 1 ->", "(removed)"},
             {"case _ ->", "(removed)"}
           ]

    single = "def a(x) do\n case x do\n _ -> :other\n end\n end"
    assert changes(single, :clause_removal) == []

    cond_ = "def a(x) do\n cond do\n x -> 1\n true -> 2\n end\n end"

    assert changes(cond_, :clause_removal) == [
             {"cond x ->", "(removed)"},
             {"cond true ->", "(removed)"}
           ]

    fun = "def a(l), do: Enum.map(l, fn\n 1 -> :a\n _ -> :b\n end)"
    assert changes(fun, :clause_removal) == [{"fn 1 ->", "(removed)"}, {"fn _ ->", "(removed)"}]
  end

  @tag obligation: "covenant.mutate.I1"
  test "element_removal drops one element or pair, never around a cons" do
    assert changes("def a, do: [:x, :y]", :element_removal) ==
             [{":x", "(removed)"}, {":y", "(removed)"}]

    assert changes("def a, do: %{a: :x, b: :y}", :element_removal) ==
             [{"a: :x", "(removed)"}, {"b: :y", "(removed)"}]

    assert changes("def a([h | t]), do: {h, t}", :element_removal) == []

    assert changes("def a(m), do: %{m | a: 1}", :element_removal) == []
    assert changes("def a, do: []", :element_removal) == []
  end

  @tag obligation: "covenant.mutate.I1"
  test "ecto_where_removal drops a where stage or a where: key" do
    assert changes("def a(q), do: q |> where(x == 1)", :ecto_where_removal) ==
             [{"|> where(x == 1)", "(removed)"}]

    assert changes("def a, do: from(p in P, where: p.id == 1)", :ecto_where_removal) ==
             [{"where: p.id == 1", "(removed)"}]
  end

  # -- I2: enumeration ------------------------------------------------------------

  @tag obligation: "covenant.mutate.I2"
  test "a mutant reports the file, line and column of its node, its module and its function" do
    [first, second, third] = mutants("def a, do: 5")
    assert {first.operator, Mutant.mutation(first)} == {:return_nil, "`5` → `nil`"}
    assert {second.operator, Mutant.mutation(second)} == {:integer_shift, "`5` → `6`"}
    assert {third.operator, Mutant.mutation(third)} == {:integer_shift, "`5` → `4`"}

    for mutant <- [first, second, third] do
      assert mutant.file == "sample.ex"
      assert {mutant.line, mutant.column} == {2, 12}
      assert Mutant.at(mutant) == "sample.ex:2:12"
      assert mutant.module == "Sample"
      assert mutant.function == "a/0"
    end
  end

  @tag obligation: "covenant.mutate.I2"
  test "documentation, specs, types, compiler attributes, macros, guards, use and quote are not mutated" do
    skipped = """
    @moduledoc "doc"
    @doc "d"
    @spec f(integer()) :: integer()
    @type t :: 1 | 2
    @compile {:inline, f: 1}
    defmacro m(x), do: x + 1
    defguard g(x) when x > 1
    use Foo, a: true
    import Bar, only: [a: 1]
    alias Baz.Qux, as: Q
    require Logger
    defstruct count: 0, tags: [:a, :b], name: "x"
    defexception message: "boom", code: 1
    """

    assert mutants(skipped) == []

    # a def around them is mutated, but only as a whole
    assert mutants("def q, do: quote(do: 1 + 2)") |> Enum.map(& &1.operator) == [:return_nil]
    assert mutants("def s, do: ~s(abc)") |> Enum.map(& &1.operator) == [:return_nil]
  end

  @tag obligation: "covenant.mutate.I2"
  test "only the target modules are mutated, nested modules by their own name" do
    source = """
    defmodule A do
      def f(x), do: x + 1

      defmodule Inner do
        def g, do: 2
      end
    end

    defmodule B do
      def h, do: 3
    end
    """

    ast = parse!(source)

    where = fn modules ->
      ast |> Mutator.sites(modules: modules) |> Enum.map(&{&1.module, &1.function}) |> Enum.uniq()
    end

    assert where.(nil) == [{"A", "f/1"}, {"A.Inner", "g/0"}, {"B", "h/0"}]
    assert where.(["A"]) == [{"A", "f/1"}]
    assert where.(["A.Inner"]) == [{"A.Inner", "g/0"}]
    assert where.(["B", "A.Inner"]) == [{"A.Inner", "g/0"}, {"B", "h/0"}]
    assert where.(["C"]) == []
  end

  @tag obligation: "covenant.mutate.I2"
  test "a nested module is named by its expanded alias: __MODULE__ and an absolute Elixir. alias" do
    source = """
    defmodule Outer do
      def f, do: 1

      defmodule __MODULE__.Inner do
        def g, do: 2

        defmodule __MODULE__.Deep do
          def h, do: 3
        end
      end

      defmodule Elixir.Standalone do
        def s, do: 4
      end

      defmodule Sibling do
        def t, do: 5
      end
    end
    """

    ast = parse!(source)

    names = fn modules ->
      ast |> Mutator.sites(modules: modules) |> Enum.map(& &1.module) |> Enum.uniq()
    end

    assert names.(nil) ==
             ["Outer", "Outer.Inner", "Outer.Inner.Deep", "Standalone", "Outer.Sibling"]

    assert names.(["Outer.Inner"]) == ["Outer.Inner"]
    assert names.(["Standalone"]) == ["Standalone"]
    assert names.(["Outer.Standalone"]) == []
  end

  @tag obligation: "covenant.mutate.I2"
  test "an absolute alias keeps its dots, a computed alias part is described, and code after a def has no function" do
    source = """
    defmodule Outer do
      def f, do: 1
      Module.put_attribute(__MODULE__, :after_def, 7 + 8)
      defp g, do: 2
      Module.put_attribute(__MODULE__, :after_defp, 5 + 6)

      defmodule Elixir.Abs.Two do
        def h, do: 3
      end

      defmodule unquote(m).Inner do
        def k, do: 4
      end
    end
    """

    sites = parse!(source) |> Mutator.sites([])

    assert sites |> Enum.map(& &1.module) |> Enum.uniq() ==
             ["Outer", "Abs.Two", "Outer.unquote(m).Inner"]

    after_defs =
      for s <- sites,
          s.module == "Outer",
          s.operator == :arithmetic_swap,
          do: {s.from, s.function}

    assert after_defs == [{"+", nil}, {"+", nil}]

    inside = for s <- sites, s.module == "Outer", s.from in ["1", "2"], do: s.function
    assert inside |> Enum.uniq() |> Enum.sort() == ["f/0", "g/0"]
  end

  @tag obligation: "covenant.mutate.I2"
  test "ids run m001, m002, ... in walk order and widen past m999; the walk is deterministic" do
    body = "def a(x), do: x + 1\ndef b(x), do: [x, 2]"
    first = mutants(body)

    assert Enum.map(first, & &1.id) ==
             for(i <- 1..length(first), do: "m" <> String.pad_leading("#{i}", 3, "0"))

    assert first == mutants(body)
    assert Enum.map(first, & &1.index) == Enum.sort(Enum.map(first, & &1.index))

    bare = for i <- 1..1000, do: mutant(nil, nil, index: i)
    ids = bare |> Mutator.numbered() |> Enum.map(& &1.id)
    assert hd(ids) == "m0001"
    assert List.last(ids) == "m1000"
    assert length(Enum.uniq(ids)) == 1000

    small = for i <- 1..999, do: mutant(nil, nil, index: i)
    assert small |> Mutator.numbered() |> List.last() |> Map.fetch!(:id) == "m999"
  end

  # -- I3: apply / compile / parse -------------------------------------------------

  @tag obligation: "covenant.mutate.I3"
  test "apply replaces exactly the node at the mutant's index", %{tmp_dir: _} do
    ast = parse!("defmodule Sample do\n  def f(x), do: x + 1 * 2\nend\n")
    sites = ast |> Mutator.sites() |> Mutator.numbered()
    plus = Enum.find(sites, &(&1.operator == :arithmetic_swap and &1.from == "+"))
    times = Enum.find(sites, &(&1.operator == :arithmetic_swap and &1.from == "*"))

    text = fn mutant -> ast |> Mutator.apply(mutant) |> Mutator.unwrap() |> Macro.to_string() end
    original = ast |> Mutator.unwrap() |> Macro.to_string()

    assert original =~ "x + 1 * 2"
    assert text.(plus) =~ "x - 1 * 2"
    assert text.(times) =~ "x + 1 / 2"
    assert text.(plus) == String.replace(original, "x + 1 * 2", "x - 1 * 2")
  end

  @tag obligation: "covenant.mutate.I3"
  test "compile loads the module in memory, replacing it, and reports what does not compile" do
    name =
      Module.concat(
        Covenant.MutateContractSample,
        "Compiled#{System.unique_integer([:positive])}"
      )

    source = "defmodule #{inspect(name)} do\n  def f(x), do: x + 1\nend\n"
    ast = parse!(source)

    assert {:ok, [{^name, binary}]} = Mutator.compile(ast, "nofile.ex")
    assert is_binary(binary)
    assert name.f(1) == 2
    refute File.exists?("nofile.ex")

    mutant = ast |> Mutator.sites() |> Enum.find(&(&1.operator == :arithmetic_swap))
    assert {:ok, [{^name, _}]} = Mutator.compile(Mutator.apply(ast, mutant), "nofile.ex")
    assert name.f(1) == 0

    broken = parse!("defmodule #{inspect(name)} do\n  def f([a, b]), do: a + b\nend\n")
    removal = broken |> Mutator.sites() |> Enum.find(&(&1.operator == :element_removal))
    assert {:error, message} = Mutator.compile(Mutator.apply(broken, removal), "nofile.ex")
    assert message =~ ~r/^line \d+:\d+: .*undefined variable "a"/

    :code.purge(name)
    :code.delete(name)
  end

  @tag obligation: "covenant.mutate.I3"
  test "a source that does not parse is an error naming the file and line" do
    assert {:error, message} = Mutator.parse("defmodule A do\n  def f(\nend\n", "lib/a.ex")
    assert message =~ ~r/^lib\/a\.ex:\d+: /
  end

  # -- I5: verdicts -----------------------------------------------------------------

  @tag obligation: "covenant.mutate.I5"
  test "a mutant is killed by failed or invalid tests, a timeout only survives, all green survives" do
    green = entry("a", ["x.I1"])
    red = entry("b", ["x.I1"], :failed)
    invalid = entry("c", ["x.I1"], :invalid)
    slow = entry("d", ["x.I1"], :timeout)
    skipped = entry("e", ["x.I1"], :skipped)

    killed = Runner.verdict(mutant("m1", nil), [green, red, invalid, slow, skipped])
    assert killed.verdict == :killed
    assert killed.killed_by == ["M:b", "M:c"]
    assert killed.timeouts == ["M:d"]

    assert Runner.verdict(mutant("m1", nil), [green, invalid]).verdict == :killed

    timed_out = Runner.verdict(mutant("m1", nil), [green, slow])
    assert {timed_out.verdict, timed_out.killed_by, timed_out.timeouts} == {:timeout, [], ["M:d"]}

    survived = Runner.verdict(mutant("m1", nil), [green, skipped])
    assert {survived.verdict, survived.killed_by, survived.timeouts} == {:survived, [], []}
  end

  @tag obligation: "covenant.mutate.I5"
  test "a finished test is reported with its outcome, tags and file relative to the root" do
    test = fn state, tags ->
      %ExUnit.Test{
        name: :"test it works",
        module: Sample.Test,
        state: state,
        tags: Map.merge(%{file: "/proj/test/contract/a_test.exs", line: 7}, tags)
      }
    end

    entry = Runner.entry(test.(nil, %{obligation: "x.I1"}), "/proj")

    assert entry == %{
             key: "Sample.Test:test it works",
             module: "Sample.Test",
             name: "test it works",
             file: "test/contract/a_test.exs",
             line: 7,
             obligations: ["x.I1"],
             mutation_blind: nil,
             outcome: :passed,
             ms: 0
           }

    assert Runner.entry(
             test.(nil, %{obligation: ["x.I1", "x.I2"], mutation_blind: "why"}),
             "/proj"
           )
           |> Map.take([:obligations, :mutation_blind]) ==
             %{obligations: ["x.I1", "x.I2"], mutation_blind: "why"}

    assert Runner.entry(test.(nil, %{}), "/proj").obligations == []

    timeout = {:error, %ExUnit.TimeoutError{timeout: 100, type: "test"}, []}
    failure = {:error, %ExUnit.AssertionError{message: "no"}, []}

    assert Runner.entry(test.({:failed, [timeout]}, %{}), "/proj").outcome == :timeout
    assert Runner.entry(test.({:failed, [timeout, timeout]}, %{}), "/proj").outcome == :timeout
    assert Runner.entry(test.({:failed, [failure]}, %{}), "/proj").outcome == :failed
    assert Runner.entry(test.({:failed, [timeout, failure]}, %{}), "/proj").outcome == :failed
    assert Runner.entry(test.({:invalid, Sample}, %{}), "/proj").outcome == :invalid
    assert Runner.entry(test.({:skipped, "no"}, %{}), "/proj").outcome == :skipped
    assert Runner.entry(test.({:excluded, "no"}, %{}), "/proj").outcome == :excluded
  end

  @tag obligation: "covenant.mutate.I16"
  test "a finished test reports its duration in milliseconds, rounded up" do
    finished = fn microseconds ->
      %ExUnit.Test{
        name: :"test t",
        module: Sample.Test,
        state: nil,
        tags: %{},
        time: microseconds
      }
    end

    assert Runner.entry(finished.(0), "/proj").ms == 0
    assert Runner.entry(finished.(1), "/proj").ms == 1
    assert Runner.entry(finished.(1000), "/proj").ms == 1
    assert Runner.entry(finished.(1001), "/proj").ms == 2
    assert Runner.entry(finished.(2_500_000), "/proj").ms == 2500
  end

  # -- I7: credit -------------------------------------------------------------------

  defp credited(counter) do
    tests = [
      entry("a", ["example.counter.I1"]),
      entry("b", ["example.counter.I2"]),
      entry("c", ["example.counter.I1", "example.counter.I4"], :passed,
        mutation_blind: "shares kills"
      ),
      entry("d", ["example.counter.I3"])
    ]

    mutants = [
      mutant("m001", :killed, killed_by: ["M:a"]),
      mutant("m002", :killed, killed_by: ["M:a", "M:b"]),
      mutant("m003", :killed, killed_by: ["M:b"]),
      mutant("m004", :survived),
      mutant("m005", :timeout, timeouts: ["M:a"]),
      mutant("m006", :invalid, reason: "line 1: x")
    ]

    {Matrix.build(results(tests, mutants), component: counter, seed: 3, timeout: 1000, jobs: 2),
     tests}
  end

  @tag obligation: "covenant.mutate.I7"
  test "kills are credited to the obligations of every failing test, uniquely and in total", %{
    counter: counter
  } do
    {matrix, _} = credited(counter)

    assert Enum.map(matrix.mutants, &{&1.id, &1.obligations}) == [
             {"m001", ["example.counter.I1"]},
             {"m002", ["example.counter.I1", "example.counter.I2"]},
             {"m003", ["example.counter.I2"]},
             {"m004", []},
             {"m005", []},
             {"m006", []}
           ]

    assert matrix.obligations["example.counter.I1"] ==
             %{killed: 2, unique: 1, mutants: ["m001", "m002"], unique_mutants: ["m001"]}

    assert matrix.obligations["example.counter.I2"] ==
             %{killed: 2, unique: 1, mutants: ["m002", "m003"], unique_mutants: ["m003"]}

    zero = %{killed: 0, unique: 0, mutants: [], unique_mutants: []}

    for id <- ~w(I3 I4 I6 I7) do
      assert matrix.obligations["example.counter.#{id}"] == zero, id
    end

    refute Map.has_key?(matrix.obligations, "example.counter.I5")

    assert matrix.test_stats["M:a"] ==
             %{kills: 2, unique_kills: 1, mutants: ["m001", "m002"], unique_mutants: ["m001"]}

    assert matrix.test_stats["M:b"].unique_mutants == ["m003"]

    assert matrix.test_stats["M:c"] == %{
             kills: 0,
             unique_kills: 0,
             mutants: [],
             unique_mutants: []
           }
  end

  @tag obligation: "covenant.mutate.I7"
  test "a passing test without a unique kill is mutation-blind, with its declared reason; the score excludes invalid mutants",
       %{counter: counter} do
    {matrix, _} = credited(counter)

    assert Enum.map(matrix.blind, &{&1.test.name, &1.kills, &1.declared}) ==
             [{"c", 0, "shares kills"}, {"d", 0, nil}]

    assert matrix.summary.mutants == 6
    assert matrix.summary.killed == 3
    assert matrix.summary.survived == 1
    assert matrix.summary.timeouts == 1
    assert matrix.summary.invalid == 1
    assert matrix.summary.score == 0.6

    # blind tests warn; only survivors and annotations fail the matrix
    assert Enum.all?(matrix.problems, &(&1.message =~ "survived" or &1.message =~ "timed out"))

    empty = Matrix.build(results([entry("a", ["example.counter.I1"])], []), component: counter)
    assert empty.summary.score == nil
    assert empty.summary.mutants == 0
    assert Matrix.ok?(empty)

    invalid_only =
      Matrix.build(results([entry("a", ["example.counter.I1"])], [mutant("m001", :invalid)]),
        component: counter
      )

    assert invalid_only.summary.score == nil
  end

  # -- I9: sorting and staleness ---------------------------------------------------

  defp annotation(attrs) do
    struct!(
      Survivors.Annotation,
      [
        at: "lib/x.ex:4:7",
        operator: "integer_shift",
        mutation: nil,
        sort: "equivalent",
        reason: "because",
        file: "x.survivors.yml",
        line: 3
      ] ++
        attrs
    )
  end

  defp build(component, mutants, annotations),
    do:
      Matrix.build(results([entry("a", ["example.counter.I1"])], mutants),
        component: component,
        annotations: annotations,
        survivors_path: "x.survivors.yml"
      )

  @tag obligation: "covenant.mutate.I9"
  test "an annotation sorts the survivor it names by location, operator and, when given, mutation",
       %{counter: counter} do
    survivor = mutant("m001", :survived)

    sorted = build(counter, [survivor], [annotation([])])
    assert [%{sort: "equivalent", reason: "because"}] = sorted.survivors
    assert sorted.problems == []
    assert sorted.summary.annotated == 1 and sorted.summary.unsorted == 0
    assert Matrix.ok?(sorted)

    with_mutation = build(counter, [survivor], [annotation(mutation: "`1` → `2`")])
    assert with_mutation.problems == []

    wrong_mutation = build(counter, [survivor], [annotation(mutation: "`1` → `0`")])
    assert length(wrong_mutation.problems) == 2
    refute Matrix.ok?(wrong_mutation)

    other_operator = build(counter, [survivor], [annotation(operator: "string_empty")])
    assert length(other_operator.problems) == 2

    other_place = build(counter, [survivor], [annotation(at: "lib/x.ex:4:8")])
    assert length(other_place.problems) == 2

    timed_out = build(counter, [mutant("m001", :timeout)], [annotation(sort: "timeout")])
    assert timed_out.problems == []
    assert [%{sort: "timeout"}] = timed_out.survivors
  end

  @tag obligation: "covenant.mutate.I11"
  test "a mutant with an unknown operator is an error, not a boolean_flip" do
    assert {:ok, %Mutant{operator: :guard_removal}} =
             Mutant.decode(%{"operator" => "guard_removal"})

    for map <- [%{"id" => "m007", "operator" => "frobnicate"}, %{"id" => "m008"}] do
      assert {:error, message} = Mutant.decode(map)

      assert message =~
               "mutant #{inspect(map["id"])}: unknown operator #{inspect(map["operator"])}"

      assert_raise ArgumentError, message, fn -> Mutant.from_map(map) end
    end
  end

  @tag obligation: "covenant.mutate.I9"
  test "an unannotated survivor or timeout is a problem naming the mutant", %{counter: counter} do
    matrix = build(counter, [mutant("m001", :survived), mutant("m002", :timeout, line: 9)], [])

    assert [first, second] = matrix.problems
    assert first.file == "lib/x.ex" and first.line == 4

    assert first.message =~
             "mutant m001 (integer_shift `1` → `2`) survived; add a test that catches it or annotate it in x.survivors.yml"

    assert second.line == 9
    assert second.message =~ "mutant m002"
    assert second.message =~ "timed out (a survivor)"
    assert matrix.summary.unsorted == 2
    refute Matrix.ok?(matrix)
  end

  @tag obligation: "covenant.mutate.I9"
  test "an annotation matching no mutant is moved, one matching only a killed mutant is stale", %{
    counter: counter
  } do
    killed = mutant("m001", :killed, killed_by: ["M:a"])

    stale = build(counter, [killed], [annotation([])])
    assert [problem] = stale.problems
    assert problem.file == "x.survivors.yml" and problem.line == 3

    assert problem.message =~
             "annotation for lib/x.ex:4:7 integer_shift (m001) is stale: that mutant is now killed — delete it"

    moved = build(counter, [killed], [annotation(at: "lib/x.ex:99:1")])
    assert [problem] = moved.problems

    assert problem.message =~
             "annotation for lib/x.ex:99:1 integer_shift matches no mutant; the code moved or the mutation changed — delete or update it"

    invalid = build(counter, [mutant("m001", :invalid)], [annotation([])])

    assert [%{message: message}] = invalid.problems

    assert message ==
             "annotation for lib/x.ex:4:7 integer_shift (m001) is stale: that mutant is invalid (it does not compile) — delete it"
  end

  @tag obligation: "covenant.mutate.I9"
  test "a survivor inside the target of an active exception is a decision-hole without an entry",
       %{fixture: contract} do
    greeter = Contract.component(contract, "example.greeter")
    inside = mutant("m001", :survived, module: "Example.Greeter", function: "clamp/1")
    outside = mutant("m002", :survived, module: "Example.Greeter", function: "greet/1", line: 10)

    matrix =
      Matrix.build(results([entry("a", ["example.greeter.I1"])], [inside, outside]),
        component: greeter
      )

    assert [
             %{sort: "decision-hole", reason: "declared by exception `example.greeter.I2`"},
             %{sort: nil}
           ] = matrix.survivors

    assert [%{line: 10}] = matrix.problems

    annotated =
      Matrix.build(results([entry("a", ["example.greeter.I1"])], [inside]),
        component: greeter,
        annotations: [annotation(sort: "log-only", reason: "mine")]
      )

    assert [%{sort: "log-only", reason: "mine"}] = annotated.survivors
  end

  # -- I8: the survivors file ---------------------------------------------------------

  @valid """
  # a comment
  - at: lib/example/counter.ex:29:17
    operator: element_removal
    mutation: "`value: 0` → `(removed)`"
    sort: equivalent
    reason: The struct default for value is already 0.
  - at: lib/example/counter.ex:30:1
    operator: guard_removal
    mutation: "`when x` → `(no guard)`"
    sort: decision-hole
    reason: undecided
  """

  @tag obligation: "covenant.mutate.I8"
  test "a valid survivors file is a list of annotations with their line" do
    assert {:ok, [first, second]} = Survivors.parse(@valid, "c.survivors.yml")

    assert %Survivors.Annotation{
             at: "lib/example/counter.ex:29:17",
             operator: "element_removal",
             mutation: "`value: 0` → `(removed)`",
             sort: "equivalent",
             reason: "The struct default for value is already 0.",
             file: "c.survivors.yml",
             line: 2
           } = first

    assert second.mutation == "`when x` → `(no guard)`"
    assert second.line == 7
    assert second.sort == "decision-hole"

    assert Survivors.sorts() ==
             ~w(equivalent log-only dead-code timeout evaluation-gap decision-hole unpromised)

    assert Mutant.operators() |> length() == 13
  end

  @tag obligation: "covenant.mutate.I8"
  test "every kind of bad entry is reported as file:line: message" do
    errors = fn text ->
      assert {:error, errors} = Survivors.parse(text, "s.yml")
      Enum.map(errors, &Error.format/1)
    end

    base =
      "at: a.ex:1:1\n  operator: integer_shift\n  mutation: \"`1` → `2`\"\n  sort: equivalent\n  reason: r\n"

    assert errors.("- " <> String.replace(base, "  reason: r\n", "")) ==
             ["s.yml:1: annotation #1 is missing `reason`"]

    assert errors.("- " <> String.replace(base, "reason: r", "reason: \"\"")) ==
             ["s.yml:1: annotation #1 has an empty `reason`"]

    assert errors.("- " <> String.replace(base, "reason: r", "reason: 5")) ==
             ["s.yml:1: annotation #1 `reason` must be a string, got 5"]

    [message] = errors.("- " <> String.replace(base, "integer_shift", "bend"))

    assert message =~
             "s.yml:1: annotation #1 has unknown `operator` `bend` (expected one of: boolean_flip, "

    assert message =~ "ecto_where_removal)"

    assert errors.("- " <> String.replace(base, "equivalent", "fine")) ==
             [
               "s.yml:1: annotation #1 has unknown `sort` `fine` (expected one of: equivalent, log-only, dead-code, timeout, evaluation-gap, decision-hole, unpromised)"
             ]

    assert errors.("- " <> String.replace(base, "a.ex:1:1", "a.ex:1")) ==
             ["s.yml:1: annotation #1 `at` must be `file:line:column`, got `a.ex:1`"]

    assert errors.("- just text\n") == ["s.yml:1: annotation #1 must be a mapping"]

    # the second entry is reported at its own line
    assert errors.("- " <> base <> "- sort: equivalent\n") ==
             [
               "s.yml:6: annotation #2 is missing `at`",
               "s.yml:6: annotation #2 is missing `operator`",
               "s.yml:6: annotation #2 is missing `mutation`",
               "s.yml:6: annotation #2 is missing `reason`"
             ]

    assert errors.("key: value\n") == [
             "s.yml:1: survivors file must be a YAML list of annotations"
           ]

    assert [<<"s.yml:", _::binary>>] = errors.("- [unclosed\n")
  end

  @tag obligation: "covenant.mutate.I8"
  test "a missing or empty file is no annotations; the file lives beside the component's contract",
       %{tmp_dir: dir, counter: counter} do
    assert Survivors.load(Path.join(dir, "none.yml")) == {:ok, []}
    assert Survivors.parse("", "e.yml") == {:ok, []}
    assert Survivors.parse("  \n\n", "e.yml") == {:ok, []}

    file = Path.join(dir, "real.yml")
    File.write!(file, @valid)
    assert {:ok, [%{file: ^file}, _]} = Survivors.load(file)

    assert Survivors.path("contracts", counter) == "contracts/example/counter.survivors.yml"
    assert Survivors.path("contracts", %{form: :system}) == "contracts/system/survivors.yml"

    directory_component = %{counter | file: "contracts/example.counter/obligations.md"}

    assert Survivors.path("contracts", directory_component) ==
             "contracts/example.counter/survivors.yml"

    assert {:error, [error]} = Survivors.load(dir)
    assert error.file == dir
    assert error.message =~ "cannot read file"
  end

  @tag obligation: "covenant.mutate.I8"
  test "find and matches? compare location, operator and mutation", %{tmp_dir: _} do
    survivor = mutant("m001", :survived)
    a = annotation([])
    refine = annotation(mutation: "`1` → `2`")

    assert Survivors.matches?(a, survivor)
    assert Survivors.matches?(refine, survivor)
    refute Survivors.matches?(annotation(mutation: "`1` → `3`"), survivor)
    refute Survivors.matches?(annotation(operator: "string_empty"), survivor)
    refute Survivors.matches?(annotation(at: "lib/x.ex:4:8"), survivor)
    assert Survivors.find([annotation(at: "z"), refine], survivor) == refine
    assert Survivors.find([annotation(at: "z")], survivor) == nil

    template = Survivors.template(survivor)

    assert template =~
             "- at: lib/x.ex:4:7\n  operator: integer_shift\n  mutation: \"`1` → `2`\"\n  sort: evaluation-gap\n  reason: TODO"

    assert Survivors.template(mutant("m001", :timeout)) =~ "sort: timeout"
  end

  # -- I10: modules ---------------------------------------------------------------------

  @tag obligation: "covenant.mutate.I10"
  test "the flags win over the front matter, which wins over the names in the Contract", %{
    fixture: contract,
    counter: counter
  } do
    mutate = Contract.component(Contract.load!(Covenant.contracts_dir()), "covenant.mutate")

    assert {:flag, ["A", "B.C"]} = Modules.resolve(counter, ["B.C", "Elixir.A", "A"])
    assert {:flag, ["A"]} = Modules.resolve(mutate, ["A"])

    assert {:front_matter, names} = Modules.resolve(mutate)
    assert names == Enum.sort(names)
    assert "Covenant.Mutate.Operators" in names
    assert names == Component.declared_modules(mutate) |> Enum.uniq() |> Enum.sort()

    assert {:derived, ["Example.Counter"]} = Modules.resolve(counter)

    assert {:derived, ["Example.Greeter"]} =
             Modules.resolve(Contract.component(contract, "example.greeter"))

    assert Modules.derive(counter) == ["Example.Counter"]
  end

  @tag obligation: "covenant.mutate.I10"
  test "module names are read from inline code spans, never from fenced blocks" do
    text = """
    See `Foo.Bar.baz/1` and `Qux.quux(a) :: Baz`, but not Plain.Prose or `lower.case`.

    ```elixir
    `Fenced.Module.call()`
    ```

    `Foo.Bar.other/2`
    """

    assert Modules.references(text) == ["Baz", "Foo.Bar", "Qux"]
    assert Modules.references("`String.t()` and `Foo.Bar.baz/1`") == ["Foo.Bar", "String"]
    assert Modules.references("") == []
  end

  @tag obligation: "covenant.mutate.I10"
  test "a module is located by its source file; derived ones that cannot be are skipped, explicit ones refused" do
    root = @root

    assert {:ok, [{Covenant.Conditions, file}, {Covenant.Mutate, _}], ignored} =
             Modules.locate(
               ["Covenant.Mutate", "Covenant.Conditions", "Nope.Missing", "String"],
               :derived,
               root
             )

    assert file == Path.join(root, "lib/covenant/conditions.ex")
    assert Enum.map(ignored, &elem(&1, 0)) == ["Nope.Missing", "String"]
    assert {"Nope.Missing", "is not a loaded module"} in ignored

    {"String", why} = List.keyfind(ignored, "String", 0)
    assert why =~ "outside the project" or why =~ "does not exist"

    assert {:error, message} =
             Modules.locate(["Covenant.Conditions", "Nope.Missing"], :flag, root)

    assert message == "Nope.Missing: is not a loaded module"

    assert {:error, "no implementation module to mutate" <> rest} =
             Modules.locate(["Nope.Missing"], :derived, root)

    assert rest =~ "Declare `modules:` in the front matter or pass --module"

    assert {:error, "no implementation module to mutate"} = Modules.locate([], :flag, root)

    assert {:error, message} = Modules.locate(["Covenant.Conditions"], :flag, "/nowhere")
    assert message =~ "Covenant.Conditions:"
  end

  # -- I11: plan, raw results, merge ----------------------------------------------------

  @tag obligation: "covenant.mutate.I11"
  test "the plan resolves modules and test files, or says what is missing", %{fixture: contract} do
    project = ContractBuilder.fixture_project()

    assert {:ok, plan} =
             Mutate.plan(contract, "example.counter",
               root: project,
               test_paths: ["test/contract"]
             )

    assert plan.names == ["Example.Counter"]
    assert plan.source == :derived
    assert plan.component.id == "example.counter"
    assert plan.test_files == ["test/contract/example/counter_contract_test.exs"]

    assert {:ok, %{names: ["A"], source: :flag}} =
             Mutate.plan(contract, "example.counter",
               root: project,
               test_paths: ["test/contract"],
               modules: ["A"]
             )

    assert {:error, "unknown component `nope`; known: example.counter, example.greeter" <> _} =
             Mutate.plan(contract, "nope", root: project)

    assert {:error, message} =
             Mutate.plan(contract, "example.greeter", root: project, test_paths: ["nowhere"])

    assert message ==
             "no contract test file declares `use Covenant.Case, component: \"example.greeter\"` under nowhere"

    assert {:error, message} =
             Mutate.plan(contract, "example.greeter",
               root: project,
               test_paths: ["nowhere", "elsewhere"]
             )

    assert message =~ "under nowhere, elsewhere"

    assert Mutate.default_seed() == 0
    assert Mutate.default_dir("a.b") == "tmp/covenant/mutate/a.b"
  end

  @tag obligation: "covenant.mutate.I11"
  test "a worker's results survive JSON and merging puts the mutants in id order", %{tmp_dir: dir} do
    tests = [
      entry("a", ["x.I1"]),
      entry("b", ["x.I2"], :failed, mutation_blind: "why", line: nil, file: nil)
    ]

    mutants = [
      mutant("m002", :killed, killed_by: ["M:b"], credit: :partial),
      mutant("m001", :timeout, timeouts: ["M:a"], reason: nil)
    ]

    result = %{
      files: ["lib/x.ex"],
      all: 4,
      baseline_ms: 12,
      timeout_ms: 750,
      tests: tests,
      mutants: mutants
    }

    path = Path.join(dir, "raw.json")

    File.write!(
      path,
      Mutate.encode_raw(result,
        component: "x.y",
        slice: "2/3",
        modules: ["X"],
        ignored: [{"Y", "why not"}]
      )
    )

    assert {:ok, raw} = Mutate.decode_raw(path)
    assert raw.component == "x.y"
    assert raw.slice == "2/3"
    assert raw.modules == ["X"]
    assert raw.ignored == [{"Y", "why not"}]
    assert raw.files == ["lib/x.ex"]
    assert raw.all == 4
    assert raw.baseline_ms == 12
    assert raw.timeout_ms == 750
    assert raw.tests == tests

    assert Enum.map(raw.mutants, &{&1.id, &1.verdict, &1.killed_by, &1.timeouts, &1.credit}) ==
             [{"m002", :killed, ["M:b"], [], :partial}, {"m001", :timeout, [], ["M:a"], :exact}]

    assert {:error, message} = Mutate.decode_raw(Path.join(dir, "missing.json"))
    assert message =~ "missing.json: no such file or directory"
    File.write!(path, "[1]")
    assert {:error, "#{path}: not a covenant.mutate results file"} == Mutate.decode_raw(path)
    File.write!(path, "{")
    assert {:error, invalid} = Mutate.decode_raw(path)
    assert String.starts_with?(invalid, "#{path}: invalid JSON: ")

    File.write!(path, ~s({"mutants": [{"id": "m001", "operator": "bogus"}], "tests": []}))

    assert Mutate.decode_raw(path) ==
             {:error, ~s(#{path}: mutant "m001": unknown operator "bogus")}

    one = %{raw | mutants: [mutant("m003", :killed), mutant("m001", :survived)], all: 4}

    two = %{
      raw
      | mutants: [mutant("m002", :survived), mutant("m004", :survived)],
        all: 4,
        timeout_ms: 1200
    }

    assert {:ok, merged} = Mutate.merge([one, two])
    assert Enum.map(merged.mutants, & &1.id) == ["m001", "m002", "m003", "m004"]
    assert merged.tests == tests
    assert merged.timeout_ms == 1200
    assert {:ok, %{timeout_ms: 1200}} = Mutate.merge([two, one])

    assert {:error, "worker results overlap (the same mutant was run twice)"} ==
             Mutate.merge([one, one])

    assert {:error, "worker results are incomplete: 2 of 4 mutants have a verdict"} ==
             Mutate.merge([one])

    assert {:error, "no worker results to merge"} == Mutate.merge([])
  end

  # -- I12: the JSON shape ----------------------------------------------------------------

  @tag obligation: "covenant.mutate.I12"
  test "the matrix map has a fixed shape", %{counter: counter} do
    {matrix, _} = credited(counter)
    map = Matrix.to_map(matrix)

    assert map |> Map.keys() |> Enum.sort() ==
             ~w(baseline component covenant fail_fast files jobs modules mutants obligations problems seed summary survivors tests timeout_ms)

    assert map["fail_fast"] == false
    assert map["covenant"] == Covenant.version()
    assert map["component"] == "example.counter"
    assert map["modules"] == ["X", "Y"]
    assert map["files"] == ["lib/x.ex"]
    assert {map["seed"], map["timeout_ms"], map["jobs"]} == {3, 1000, 2}
    assert map["baseline"] == %{"tests" => 4, "ms" => 5}

    assert map["summary"] ==
             %{
               "mutants" => 6,
               "killed" => 3,
               "survived" => 1,
               "timeouts" => 1,
               "invalid" => 1,
               "partial" => 0,
               "score" => 0.6,
               "annotated" => 0,
               "unsorted" => 2
             }

    assert map["mutants"] |> hd() |> Map.keys() |> Enum.sort() ==
             Enum.sort(
               ~w(at column credit file function from id killed_by line module obligations operator reason timeouts to verdict)
             )

    assert Enum.all?(map["mutants"], &(&1["credit"] == "exact"))

    assert hd(map["mutants"])["at"] == "lib/x.ex:4:7"
    assert hd(map["mutants"])["verdict"] == "killed"
    assert hd(map["mutants"])["obligations"] == ["example.counter.I1"]

    assert map["obligations"]["example.counter.I1"] ==
             %{
               "killed" => 2,
               "unique" => 1,
               "mutants" => ["m001", "m002"],
               "unique_mutants" => ["m001"]
             }

    test = map["tests"]["M:a"]

    assert test |> Map.keys() |> Enum.sort() ==
             ~w(file kills line module mutants mutation_blind name obligations unique_kills unique_mutants)

    assert {test["kills"], test["unique_kills"], test["mutation_blind"]} == {2, 1, false}
    assert map["tests"]["M:c"]["mutation_blind"] == "shares kills"
    assert map["tests"]["M:d"]["mutation_blind"] == true

    [survivor | _] = map["survivors"]

    assert survivor |> Map.keys() |> Enum.sort() ==
             ~w(at id mutation operator reason sort verdict)

    assert %{"id" => "m004", "verdict" => "survived", "sort" => nil} = survivor
    assert Enum.map(map["survivors"], & &1["verdict"]) == ["survived", "timeout"]
    assert length(map["problems"]) == 2

    text = Matrix.format(matrix)
    assert text =~ "Kill matrix — example.counter (X, Y)"
    assert text =~ "6 mutants: 3 killed, 1 survived, 1 timed out, 1 invalid — score 60.0%"
    assert text =~ "example.counter.I1       2       1"
    assert text =~ "Survivors (2; 2 unsorted)"
    assert text =~ "UNSORTED"
    assert text =~ "Mutation-blind tests (warn)"
    assert text =~ "declared: shares kills"
  end

  # -- the golden corpus (I1, I2) ---------------------------------------------------

  @corpus Path.expand("../../../fixtures/mutate/corpus.txt", __DIR__)
  @golden Path.expand("../../../fixtures/mutate/corpus.mutants.txt", __DIR__)

  @tag obligation: ["covenant.mutate.I1", "covenant.mutate.I2"]
  test "a corpus of every construct the operators and skip rules care about yields exactly the recorded mutants" do
    assert {:ok, ast} = Mutator.parse(File.read!(@corpus), "corpus.ex")
    lines = fn ast -> ast |> Mutator.unwrap() |> Macro.to_string() |> String.split("\n") end
    original = lines.(ast)

    # what the mutant changes in the source, as a diff of the rendered code
    changed = fn mutant ->
      original
      |> List.myers_difference(lines.(Mutator.apply(ast, mutant)))
      |> Enum.flat_map(fn
        {:eq, _} -> []
        {:del, ls} -> Enum.map(ls, &("-" <> String.trim(&1)))
        {:ins, ls} -> Enum.map(ls, &("+" <> String.trim(&1)))
      end)
      |> Enum.join(" ¦ ")
    end

    text =
      ast
      |> Mutator.sites(file: "corpus.ex")
      |> Mutator.numbered()
      |> Enum.map_join("", fn m ->
        "#{m.id} #{Mutant.at(m)} #{m.module} #{m.function} #{m.operator} #{Mutant.mutation(m)} => #{changed.(m)}\n"
      end)

    # a deliberate change to the operators is recorded with
    # COVENANT_UPDATE_GOLDEN=1 mix test <this file>, and the diff reviewed
    if System.get_env("COVENANT_UPDATE_GOLDEN"), do: File.write!(@golden, text)

    assert text == File.read!(@golden)
  end

  @tag obligation: "covenant.mutate.I2"
  test "a nested skipped form does not end the skipping early, and a source without a file name says nofile" do
    nested = "def a do\n  quote do\n    quote(do: 1 + 2)\n    3 + 4\n  end\n  5 + 6\nend"
    assert changes(nested, :arithmetic_swap) == [{"+", "-"}]
    assert changes(nested, :integer_shift) == [{"5", "6"}, {"5", "4"}, {"6", "7"}, {"6", "5"}]

    assert {:ok, ast} = Mutator.parse("defmodule A do\n  def f, do: 1\nend\n", "a.ex")
    assert [%Mutant{file: "nofile"} | _] = Mutator.sites(ast)
  end

  @tag obligation: "covenant.mutate.I3"
  test "parsing emits no compiler warning" do
    assert {{:ok, _}, []} =
             Code.with_diagnostics(fn -> Mutator.parse("def f, do: 'charlist'", "a.ex") end)
  end

  @tag obligation: "covenant.mutate.I3"
  test "compile reports an error position as a line, with a column when there is one" do
    name =
      Module.concat(
        Covenant.MutateContractSample,
        "Positions#{System.unique_integer([:positive])}"
      )

    ast = parse!("defmodule #{inspect(name)} do\n  def f, do: undefined_thing\nend\n")
    assert {:error, message} = Mutator.compile(ast, "nofile.ex")
    assert message =~ ~r/^line 2(:\d+)?: /
    assert message =~ "undefined"
    :code.purge(name)
    :code.delete(name)
  end

  @tag obligation: "covenant.mutate.I2"
  test "an attribute read is not a documentation attribute, other attributes are mutated, code outside a module is not" do
    assert changes("def f, do: @doc <> \"x\"", :string_empty) == [{~s("x"), ~s("")}]
    assert changes("@foo 1 + 2\ndef a, do: 1", :arithmetic_swap) == [{"+", "-"}]

    source = "x = 1 + 2\ndefmodule Top.Level do\n  def f, do: 1 + 2\nend\nz = 3 + 4\n"
    ast = parse!(source)
    assert ast |> Mutator.sites() |> Enum.map(& &1.module) |> Enum.uniq() == ["Top.Level"]

    assert ast |> Mutator.sites(modules: ["Top.Level"]) |> Enum.map(& &1.module) |> Enum.uniq() ==
             ["Top.Level"]

    assert ast |> Mutator.sites(modules: ["Other"]) == []

    assert ast |> Mutator.sites() |> Enum.filter(&(&1.operator == :arithmetic_swap)) |> length() ==
             1
  end

  @tag obligation: "covenant.mutate.I2"
  test "a module whose name is not an alias or an atom is reported as ?" do
    assert mutants("def f, do: 1") |> Enum.map(& &1.module) |> Enum.uniq() == ["Sample"]

    ast = parse!("defmodule \"not a module\" do\n  def f, do: 1\nend\n")
    assert ast |> Mutator.sites() |> Enum.map(& &1.module) |> Enum.uniq() == ["?"]
  end

  @tag obligation: "covenant.mutate.I3"
  test "a failure with no diagnostic is reported by its message, one with a line only by its line" do
    boom = parse!("defmodule Covenant.MutateContractSample.Boom do\n  raise \"boom\"\nend\n")
    assert {:error, "boom"} = Mutator.compile(boom, "nofile.ex")

    missing =
      parse!(
        "defmodule Covenant.MutateContractSample.Missing do\n  @foo 1\n  def f, do: @foo\n  use Nothing.Here\nend\n"
      )

    assert {:error, message} = Mutator.compile(missing, "nofile.ex")
    assert message =~ ~r/^line 4: module Nothing.Here is not loaded/
  end

  @tag obligation: "covenant.mutate.I1"
  test "a node is described in one line of at most 60 characters" do
    exactly = {String.to_atom(String.duplicate("a", 60)), [], nil}
    assert Operators.describe(exactly) == String.duplicate("a", 60)

    longer = {String.to_atom(String.duplicate("a", 61)), [], nil}
    assert Operators.describe(longer) == String.duplicate("a", 59) <> "…"

    assert Operators.describe(quote(do: foo(1, 2))) == "foo(1, 2)"

    assert Operators.describe(
             quote(
               do:
                 (
                   a
                   b
                 )
             )
           ) =~ "a" and
             not (Operators.describe(
                    quote(
                      do:
                        (
                          a
                          b
                        )
                    )
                  ) =~ "\n")
  end

  @tag obligation: "covenant.mutate.I12"
  test "the struct defaults of the matrix and of a mutant are the documented ones" do
    matrix = struct(Matrix)
    assert {matrix.seed, matrix.timeout, matrix.jobs, matrix.baseline_ms} == {0, 0, 1, 0}
    assert matrix.fail_fast === false
    assert {matrix.mutants, matrix.tests, matrix.problems, matrix.summary} == {[], [], [], %{}}

    mutant =
      struct!(Mutant,
        file: "a",
        line: 1,
        column: 1,
        operator: :boolean_flip,
        from: "a",
        to: "b",
        index: 1
      )

    assert {mutant.killed_by, mutant.timeouts, mutant.verdict} == {[], [], nil}
    assert mutant.credit == :exact
  end

  @tag obligation: "covenant.mutate.I11"
  test "from_map takes the index when it is given" do
    assert Mutant.from_map(%{"operator" => "integer_shift", "index" => 7}).index == 7
    assert Mutant.from_map(%{"operator" => "integer_shift"}).index == 0
  end

  @tag obligation: "covenant.mutate.I8"
  test "a YAML error is reported at its own line, a flow list gets line 1", %{tmp_dir: _} do
    assert {:error, [error]} = Survivors.parse("- a: 1\n- b: [\n- c: 2\n", "s.yml")
    assert error.line == 3
    assert error.message =~ "invalid YAML: "

    assert {:ok, [annotation]} =
             Survivors.parse(
               "[{at: a.ex:1:1, operator: integer_shift, mutation: m, sort: equivalent, reason: r}]",
               "f.yml"
             )

    assert annotation.line == 1
  end

  @tag obligation: "covenant.mutate.I10"
  test "the Public surface section alone names the modules to mutate", %{counter: counter} do
    surface = %Covenant.Contract.Section{
      title: "Public surface",
      line: 1,
      body: "- `Only.InSurface.f/1` — x\n- `Also.There.g/0` — y"
    }

    component = %{counter | sections: [surface], obligations: []}
    assert Modules.derive(component) == ["Also.There", "Only.InSurface"]

    scoped = %{
      counter
      | sections: [],
        obligations: Enum.map(counter.obligations, &%{&1 | scope: "`Scoped.Mod.h/2`"})
    }

    assert Modules.derive(scoped) == ["Scoped.Mod"]
  end

  # -- exact output of the matrix table (I12) -----------------------------------------

  @tag obligation: "covenant.mutate.I12"
  test "the matrix table prints exactly the numbers, survivors and blind tests", %{
    counter: counter
  } do
    {matrix, tests} = credited(counter)

    assert Matrix.format(matrix) == """
           Kill matrix — example.counter (X, Y)
             6 mutants: 3 killed, 1 survived, 1 timed out, 1 invalid — score 60.0%
             4 tests, baseline 5 ms, seed 3, timeout 1000 ms

             obligation          killed  unique
             example.counter.I1       2       1
             example.counter.I2       2       1
             example.counter.I3       0       0
             example.counter.I4       0       0
             example.counter.I6       0       0
             example.counter.I7       0       0

           Survivors (2; 2 unsorted)
             m004 lib/x.ex:4:7 integer_shift `1` → `2`  UNSORTED
             m005 lib/x.ex:4:7 integer_shift `1` → `2` [timeout]  UNSORTED

           Mutation-blind tests (warn): no mutant only this test catches
             c (M) — 0 kill(s), 0 unique — declared: shares kills
             d (M) — 0 kill(s), 0 unique\
           """

    sorted =
      Matrix.build(
        results([hd(tests)], [
          mutant("m001", :killed, killed_by: ["M:a"]),
          mutant("m004", :survived)
        ]),
        component: counter,
        annotations: [annotation([])]
      )

    assert Matrix.format(sorted) == """
           Kill matrix — example.counter (X, Y)
             2 mutants: 1 killed, 1 survived, 0 timed out, 0 invalid — score 50.0%
             1 tests, baseline 5 ms, seed 0, timeout 0 ms

             obligation          killed  unique
             example.counter.I1       1       1
             example.counter.I2       0       0
             example.counter.I3       0       0
             example.counter.I4       0       0
             example.counter.I6       0       0
             example.counter.I7       0       0

           Survivors (1; 0 unsorted)
             m004 lib/x.ex:4:7 integer_shift `1` → `2`  equivalent — because

           Mutation-blind tests: none (every test has a unique kill)\
           """

    bare = %{counter | obligations: []}
    empty = Matrix.build(results([entry("a", [])], []), component: bare)

    assert Matrix.format(empty) == """
           Kill matrix — example.counter (X, Y)
             0 mutants: 0 killed, 0 survived, 0 timed out, 0 invalid — score n/a
             1 tests, baseline 5 ms, seed 0, timeout 0 ms

             obligation  killed  unique

           Survivors: none

           Mutation-blind tests (warn): no mutant only this test catches
             a (M) — 0 kill(s), 0 unique\
           """

    short = %{
      counter
      | obligations: Enum.map(Enum.take(counter.obligations, 1), &%{&1 | id: "a.I1"})
    }

    narrow = Matrix.build(results([entry("a", ["a.I1"])], []), component: short)

    assert Matrix.format(narrow) =~
             "\n  obligation  killed  unique\n  a.I1             0       0\n"
  end

  @tag obligation: "covenant.mutate.I12"
  test "an empty matrix has the documented defaults and its problems say where to annotate", %{
    counter: counter
  } do
    assert %Matrix{} == %Matrix{
             component: nil,
             modules: [],
             files: [],
             seed: 0,
             timeout: 0,
             jobs: 1,
             fail_fast: false,
             baseline_ms: 0,
             tests: [],
             mutants: [],
             obligations: %{},
             test_stats: %{},
             survivors: [],
             blind: [],
             problems: [],
             summary: %{}
           }

    matrix =
      Matrix.build(results([entry("a", ["example.counter.I1"])], [mutant("m001", :survived)]),
        component: counter
      )

    assert {matrix.seed, matrix.timeout, matrix.jobs} == {0, 0, 1}
    assert [%{message: message}] = matrix.problems
    assert message =~ "or annotate it in the survivors file"
    assert Matrix.ok?(matrix) === false
    assert Matrix.ok?(%{matrix | problems: []}) === true
  end

  @tag obligation: "covenant.mutate.I7"
  test "the score is rounded to four digits and a kill by an unknown test credits no obligation",
       %{counter: counter} do
    mutants = [
      mutant("m001", :killed, killed_by: ["M:ghost"]),
      mutant("m002", :survived),
      mutant("m003", :survived)
    ]

    matrix =
      Matrix.build(results([entry("a", ["example.counter.I1"])], mutants), component: counter)

    assert matrix.summary.score == 0.3333
    assert hd(matrix.mutants).obligations == []
  end

  @tag obligation: "covenant.mutate.I9"
  test "an exception on a module or a file sorts the survivors inside it", %{fixture: contract} do
    greeter = Contract.component(contract, "example.greeter")

    retarget = fn target ->
      %{
        greeter
        | obligations:
            Enum.map(
              greeter.obligations,
              &if(&1.kind == :exception, do: %{&1 | target: target}, else: &1)
            )
      }
    end

    inside =
      mutant("m001", :survived,
        module: "Example.Greeter",
        function: "greet/1",
        file: "lib/example/greeter.ex"
      )

    outside = mutant("m002", :survived, module: "Other", function: "f/0", file: "lib/other.ex")

    run = fn component ->
      Matrix.build(results([entry("a", ["example.greeter.I1"])], [inside, outside]),
        component: component
      )
    end

    by_module = run.(retarget.("Example.Greeter"))

    assert [%{sort: "decision-hole", mutant: %{id: "m001"}}, %{sort: nil, mutant: %{id: "m002"}}] =
             by_module.survivors

    by_file = run.(retarget.("lib/example/greeter.ex"))

    assert [%{sort: "decision-hole", mutant: %{id: "m001"}}, %{sort: nil, mutant: %{id: "m002"}}] =
             by_file.survivors

    by_function = run.(retarget.("Example.Greeter.greet/1"))
    assert [%{sort: "decision-hole"}, %{sort: nil}] = by_function.survivors

    elsewhere = run.(retarget.("Example.Greeter.other/2"))
    assert [%{sort: nil}, %{sort: nil}] = elsewhere.survivors
  end

  # -- mutants as data (I3, I11) ---------------------------------------------------------

  @tag obligation: "covenant.mutate.I11"
  test "a mutant survives to_map and from_map, whatever its verdict" do
    for verdict <- [:killed, :survived, :timeout, :invalid, nil] do
      original =
        mutant("m007", verdict,
          killed_by: ["A:x"],
          timeouts: ["B:y"],
          reason: "why",
          operator: :guard_removal,
          credit: Enum.random([:exact, :partial])
        )

      back = original |> Mutant.to_map() |> Mutant.from_map()

      assert Map.take(back, [
               :id,
               :file,
               :line,
               :column,
               :operator,
               :from,
               :to,
               :module,
               :function,
               :verdict,
               :killed_by,
               :timeouts,
               :reason,
               :credit
             ]) ==
               Map.take(original, [
                 :id,
                 :file,
                 :line,
                 :column,
                 :operator,
                 :from,
                 :to,
                 :module,
                 :function,
                 :verdict,
                 :killed_by,
                 :timeouts,
                 :reason,
                 :credit
               ])

      assert back.index == 0
    end

    map = Mutant.to_map(mutant("m001", :survived))
    assert map["at"] == "lib/x.ex:4:7"
    assert map["verdict"] == "survived"
    assert Mutant.to_map(mutant("m001", nil))["verdict"] == nil

    for operator <- Mutant.operators() do
      assert operator
             |> then(&mutant("m1", :killed, operator: &1))
             |> Mutant.to_map()
             |> Mutant.from_map()
             |> Map.fetch!(:operator) == operator
    end

    assert Mutant.from_map(%{"operator" => "integer_shift", "verdict" => "weird"}).verdict == nil
    assert Mutant.from_map(%{"operator" => "integer_shift"}).killed_by == []
    assert Mutant.from_map(%{"operator" => "integer_shift"}).timeouts == []

    assert Mutant.to_map(mutant("m001", :killed, credit: :partial))["credit"] == "partial"
    assert Mutant.to_map(mutant("m001", :killed))["credit"] == "exact"

    assert Mutant.from_map(%{"operator" => "integer_shift", "credit" => "partial"}).credit ==
             :partial

    assert Mutant.from_map(%{"operator" => "integer_shift", "credit" => "exact"}).credit == :exact
    assert Mutant.from_map(%{"operator" => "integer_shift", "credit" => "weird"}).credit == :exact
    assert Mutant.from_map(%{"operator" => "integer_shift"}).credit == :exact
  end

  @tag obligation: "covenant.mutate.I2"
  test "a mutant needs its location, operator, change and index" do
    full = [
      file: "a.ex",
      line: 1,
      column: 1,
      operator: :boolean_flip,
      from: "true",
      to: "false",
      index: 1
    ]

    assert %Mutant{} = struct!(Mutant, full)

    for key <- Keyword.keys(full) do
      assert_raise ArgumentError, fn -> struct!(Mutant, Keyword.delete(full, key)) end
    end
  end

  @tag obligation: "covenant.mutate.I11"
  test "every outcome and the defaults of a worker's results survive JSON", %{tmp_dir: dir} do
    outcomes = [:passed, :failed, :timeout, :invalid, :skipped, :excluded]
    tests = for outcome <- outcomes, do: entry("t_#{outcome}", ["x.I1"], outcome)
    result = %{files: [], all: 0, baseline_ms: 1, timeout_ms: 1000, tests: tests, mutants: []}
    path = Path.join(dir, "raw.json")

    File.write!(path, Mutate.encode_raw(result, component: "x.y"))
    assert {:ok, raw} = Mutate.decode_raw(path)
    assert Enum.map(raw.tests, & &1.outcome) == outcomes
    assert raw.slice == "1/1"
    assert raw.modules == []
    assert raw.ignored == []
    assert raw.timeout_ms == 1000

    text = path |> File.read!() |> JSON.decode!()
    assert text["covenant"] == Covenant.version()
    assert text["slice"] == "1/1"

    File.write!(path, ~s({"tests": [{"key": "a", "outcome": "mystery"}], "mutants": []}))

    assert {:ok,
            %{
              tests: [%{outcome: :invalid, obligations: []}],
              baseline_ms: 0,
              timeout_ms: 0,
              all: 0
            }} = Mutate.decode_raw(path)

    File.write!(
      path,
      ~s({"tests": [], "mutants": [{"id": "m1", "operator": "integer_shift"}, {"id": "m2", "operator": "integer_shift"}]})
    )

    assert {:ok, %{all: 2, files: [], modules: []}} = Mutate.decode_raw(path)

    File.write!(path, ~s({"tests": [], "mutants": 5}))
    assert {:error, message} = Mutate.decode_raw(path)
    assert message == "#{path}: not a covenant.mutate results file"
  end

  @tag obligation: "covenant.mutate.I11"
  test "a component that names no module cannot be planned", %{
    fixture: contract,
    counter: counter
  } do
    bare = %{counter | obligations: [], sections: []}
    contract = %{contract | components: Map.put(contract.components, "example.counter", bare)}

    assert {:error, message} =
             Mutate.plan(contract, "example.counter",
               root: ContractBuilder.fixture_project(),
               test_paths: ["test/contract"]
             )

    assert message ==
             "`example.counter` names no implementation module: its Public surface and obligation scopes contain no " <>
               "`Module.function` code span. Declare `modules:` in the front matter of #{counter.file} or pass --module"
  end

  # -- survivors file edge cases (I8) ----------------------------------------------------

  @tag obligation: "covenant.mutate.I8"
  test "line endings, empty documents, invalid YAML and a missing sort are handled", %{
    counter: counter
  } do
    entry = fn n ->
      "- at: a.ex:#{n}:1\r\n  operator: integer_shift\r\n  mutation: m\r\n  sort: equivalent\r\n  reason: r\r\n"
    end

    assert {:ok, [first, second]} = Survivors.parse(entry.(1) <> entry.(2), "crlf.yml")
    assert {first.line, second.line} == {1, 6}

    assert {:error, [error]} = Survivors.parse("- a: [1\n", "bad.yml")
    assert error.file == "bad.yml"
    assert is_integer(error.line)
    assert error.message =~ "invalid YAML: "

    assert {:error, errors} =
             Survivors.parse(
               "- at: a.ex:1:1\n  operator: integer_shift\n  mutation: m\n  reason: r\n",
               "s.yml"
             )

    assert Enum.map(errors, & &1.message) == ["annotation #1 is missing `sort`"]

    assert {:error, errors} =
             Survivors.parse(
               "- at: 5\n  operator: integer_shift\n  mutation: m\n  sort: equivalent\n  reason: r\n",
               "s.yml"
             )

    assert Enum.map(errors, & &1.message) == ["annotation #1 `at` must be a string, got 5"]

    assert Survivors.path("c", counter) == "c/example/counter.survivors.yml"
  end

  # -- finding modules (I10) --------------------------------------------------------------

  @tag obligation: "covenant.mutate.I10"
  test "located modules come back sorted by name, with every reason spelled out" do
    root = @root

    assert {:ok, [{Covenant.ContractError, _}, {Covenant.Error, _}], []} =
             Modules.locate(["Covenant.Error", "Covenant.ContractError"], :flag, root)

    sibling = Path.join(Path.dirname(root), "cov")
    assert {:error, message} = Modules.locate(["Covenant.Conditions"], :flag, sibling)

    assert message ==
             "Covenant.Conditions: lives outside the project (#{Path.join(root, "lib/covenant/conditions.ex")})"

    assert {:error, message} =
             Modules.locate(["Covenant.Conditions", "Nope.One", "Nope.Two"], :flag, root)

    assert message == "Nope.One: is not a loaded module; Nope.Two: is not a loaded module"

    assert {:error, message} = Modules.locate(["Nope.One"], :derived, root)

    assert message ==
             "no implementation module to mutate; the Public surface and obligation scopes name none under #{root}. Declare `modules:` in the front matter or pass --module"

    name =
      Module.concat(
        Covenant.MutateContractSample,
        "Vanished#{System.unique_integer([:positive])}"
      )

    Code.compile_string(
      "defmodule #{inspect(name)} do\n  def f, do: 1\nend\n",
      "/nonexistent/vanished.ex"
    )

    on_exit(fn -> :code.purge(name) && :code.delete(name) end)

    assert {:ok, [], [{_, why}]} = locate_ignored(inspect(name), root)
    assert why == "was compiled from /nonexistent/vanished.ex, which does not exist"
  end

  defp locate_ignored(name, root) do
    case Modules.locate([name, "Covenant.Conditions"], :derived, root) do
      {:ok, [{Covenant.Conditions, _}], ignored} -> {:ok, [], ignored}
      other -> other
    end
  end

  # -- I16: the timeout ------------------------------------------------------------------

  @tag obligation: "covenant.mutate.I16"
  test "the default timeout is five times the slowest baseline test, never under a second" do
    timeout = fn times -> Mutate.default_timeout(Enum.map(times, &%{ms: &1})) end

    assert timeout.([]) == 1000
    assert timeout.([0, 0]) == 1000
    assert timeout.([33, 7, 199]) == 1000
    assert timeout.([200]) == 1000
    assert timeout.([201]) == 1005
    assert timeout.([5, 400, 120]) == 2000
    assert timeout.([7000, 1]) == 35_000
  end

  # -- I17: --fail-fast -----------------------------------------------------------------

  @tag obligation: "covenant.mutate.I17"
  test "a fail-fast matrix counts exact credit only, judges no test blind and says so", %{
    counter: counter
  } do
    tests = [
      entry("a", ["example.counter.I1"]),
      entry("b", ["example.counter.I2"], :passed, mutation_blind: "shares kills"),
      entry("c", ["example.counter.I3"])
    ]

    mutants = [
      mutant("m001", :killed, killed_by: ["M:a"], credit: :partial),
      mutant("m002", :killed, killed_by: ["M:a"]),
      mutant("m003", :killed, killed_by: ["M:b"], credit: :partial),
      mutant("m004", :survived),
      mutant("m005", :invalid, reason: "line 1: x")
    ]

    # the same kills, had every test run against each mutant
    exact = Enum.map(mutants, &%{&1 | credit: :exact})
    full = Matrix.build(results(tests, exact), component: counter)
    fast = Matrix.build(results(tests, mutants), component: counter, fail_fast: true)

    assert full.fail_fast === false
    assert fast.fail_fast === true

    assert %{killed: 2, unique: 2, mutants: ["m001", "m002"]} =
             full.obligations["example.counter.I1"]

    assert fast.obligations["example.counter.I1"] ==
             %{killed: 1, unique: 1, mutants: ["m002"], unique_mutants: ["m002"]}

    assert fast.obligations["example.counter.I2"] ==
             %{killed: 0, unique: 0, mutants: [], unique_mutants: []}

    assert {fast.test_stats["M:a"].kills, fast.test_stats["M:a"].unique_kills} == {1, 1}
    assert {fast.test_stats["M:b"].kills, fast.test_stats["M:b"].unique_kills} == {0, 0}
    assert {full.test_stats["M:b"].kills, full.test_stats["M:b"].unique_kills} == {1, 1}

    # the mutant keeps the credit its killers earned: it is the totals that leave it out
    assert Enum.find(fast.mutants, &(&1.id == "m001")).obligations == ["example.counter.I1"]

    assert Enum.map(full.blind, & &1.test.name) == ["c"]
    assert fast.blind == []

    assert %{killed: 3, partial: 2, survived: 1, invalid: 1, score: 0.75} = fast.summary
    assert full.summary.partial == 0

    map = Matrix.to_map(fast)
    assert map["fail_fast"] == true
    assert map["summary"]["partial"] == 2

    assert Enum.map(map["mutants"], & &1["credit"]) ==
             ["partial", "exact", "partial", "exact", "exact"]

    assert map["tests"]["M:c"]["mutation_blind"] == nil
    assert map["tests"]["M:b"]["mutation_blind"] == "shares kills"
    assert Matrix.to_map(full)["tests"]["M:c"]["mutation_blind"] == true
    assert Matrix.to_map(full)["fail_fast"] == false

    table = Matrix.format(fast)

    assert table =~
             "  --fail-fast: 2 kill(s) carry partial credit; the obligation table below counts exact kills only " <>
               "(a fail-fast matrix proves kills, not obligation credit)\n"

    assert table =~
             "\n\nMutation-blind tests: not judged (--fail-fast: a unique kill cannot be told apart)"

    refute Matrix.format(full) =~ "--fail-fast"
    assert Matrix.format(full) =~ "Mutation-blind tests (warn): no mutant only this test catches"
  end

  @tag obligation: "covenant.mutate.I17"
  test "mix help covenant.mutate says a fail-fast matrix proves kills, not obligation credit" do
    help = Mix.Task.moduledoc(Mix.Tasks.Covenant.Mutate)

    assert help =~ "`--fail-fast`"
    assert help =~ "`max_failures: 1`"
    assert help =~ "credit: partial"
    assert help =~ "A fail-fast matrix proves kills, not obligation credit"
  end

  # -- I18: progress --------------------------------------------------------------------

  @tag obligation: "covenant.mutate.I18"
  test "a progress line is due after every 25th mutant but the last" do
    due = &Mutate.progress_due?(&1, 100)

    assert due.(25)
    assert due.(50)
    assert due.(75)
    refute due.(24)
    refute due.(26)
    refute due.(0)
    refute due.(100)
    refute Mutate.progress_due?(25, 25)
    assert Mutate.progress_due?(25, 26)
    refute Mutate.progress_due?(10, 20)
  end

  @tag obligation: "covenant.mutate.I18"
  test "a progress line gives the count, the rate and the time left in the units that fit" do
    assert Mutate.progress_line(25, 700, 100_000) ==
             "progress: 25/700 mutants (3.6%), 15.0 mutants/min, ETA 45m 00s"

    # one mutant a second: the time left is the mutants left, in seconds
    eta = fn total ->
      total |> then(&Mutate.progress_line(25, &1, 25_000)) |> String.split("ETA ") |> List.last()
    end

    assert eta.(50) == "25s"
    assert eta.(84) == "59s"
    assert eta.(85) == "1m 00s"
    assert eta.(3624) == "59m 59s"
    assert eta.(3625) == "1h 00m"
    assert eta.(10_025) == "2h 46m"
    assert eta.(26) == "1s"

    assert Mutate.progress_line(50, 100, 50_000) =~ "50/100 mutants (50.0%), 60.0 mutants/min"

    # no time has passed yet: it counts as one millisecond, so the pace is finite
    assert Mutate.progress_line(25, 50, 0) ==
             "progress: 25/50 mutants (50.0%), 1500000.0 mutants/min, ETA 0s"
  end

  @tag obligation: "covenant.mutate.I18"
  test "the time left is rounded to the nearest second" do
    # 25 mutants in 12 475 ms (and 12 500 ms), one left: 499 ms (and 500 ms) to go
    assert Mutate.progress_line(25, 26, 12_475) =~ "ETA 0s"
    assert Mutate.progress_line(25, 26, 12_500) =~ "ETA 1s"
  end

  @tag obligation: "covenant.mutate.I18"
  test "mix help covenant.mutate says progress is reported every 25 mutants" do
    assert Mix.Task.moduledoc(Mix.Tasks.Covenant.Mutate) =~ "every 25 mutants"
  end

  # -- the sibling layout ---------------------------------------------------------

  defp primitive!(dir, name, readme) do
    path = Path.join([dir, "contract", name, "README.md"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, readme)
  end

  defp sibling_contract!(dir) do
    {:ok, contract} =
      Contract.load(Path.join(dir, "contracts"), sibling: Path.join(dir, "contract"))

    contract
  end

  defp declaration(attrs) do
    struct!(
      Survivors.Annotation,
      [
        at: "X.f/0",
        operator: "*",
        sort: "unpromised",
        reason: "open",
        file: "mutants.md",
        line: 3,
        unit: "X.f/0",
        from: "1",
        to: "2"
      ] ++ attrs
    )
  end

  @tag obligation: "covenant.mutate.I8"
  test "a primitive's survivors file is the mutants.md beside its README, read as declarations",
       %{tmp_dir: dir} do
    primitive!(dir, "calc", "# calc\n\n- **A1** Adds.\n\n```covers\nCalc\n```\n")
    calc = dir |> sibling_contract!() |> Contract.component("calc")

    path = Survivors.path("contracts", calc)
    assert path == Path.join([dir, "contract", "calc", "mutants.md"])

    File.write!(path, "## Kept\n\n```unpromised\nCalc.add/2: *\n```\n")

    assert {:ok, [%{unit: "Calc.add/2", from: nil, sort: "unpromised", reason: "Kept"}]} =
             Survivors.load(path)

    yml = Path.join(dir, "x.survivors.yml")

    File.write!(
      yml,
      "- at: lib/x.ex:1:1\n  operator: integer_shift\n  mutation: \"`1` → `2`\"\n  sort: equivalent\n  reason: r\n"
    )

    assert {:ok, [%{at: "lib/x.ex:1:1", unit: nil}]} = Survivors.load(yml)
  end

  @tag obligation: "covenant.mutate.I9"
  test "a declaration matches the survivors of its unit by from and to, or all of them as a wildcard" do
    m = mutant("m001", :survived)

    assert Survivors.matches?(declaration([]), m)
    refute Survivors.matches?(declaration(unit: "X.g/0"), m)
    refute Survivors.matches?(declaration(from: "0"), m)
    refute Survivors.matches?(declaration(to: "3"), m)
    assert Survivors.matches?(declaration(from: nil, to: nil), m)
    refute Survivors.matches?(declaration(from: nil, to: nil, unit: "X.g/0"), m)

    assert Survivors.unit(m) == "X.f/0"
    assert Survivors.unit(%{m | function: nil}) == "X"
    assert Survivors.template(m, format: :md) == "X.f/0: 1 -> 2"
    assert Survivors.template(m) =~ "- at: lib/x.ex:4:7\n"
  end

  defp pinned_ids(declarations, mutants) do
    {kept, errors} = Survivors.resolve(declarations, mutants)
    {Enum.map(kept, & &1.pinned), errors}
  end

  @tag obligation: "covenant.mutate.I9"
  test "a declaration is pinned to the one mutant of its unit with that change" do
    other = mutant("m3", :survived, line: 6, from: "9", to: "8")
    elsewhere = mutant("m4", :survived, line: 1, function: "g/0")
    mutants = [other, elsewhere]

    # a change only one mutant of the unit has, by from and to or as written
    assert {[%{pinned: "m3", from: "9", to: "8"}], []} =
             Survivors.resolve([declaration(from: "9", to: "8")], mutants)

    for change <- ["9 -> 8", "9 → 8", "`9` -> `8`", "`9` → `8`"] do
      assert {[%{pinned: "m3", from: "9", to: "8"}], []} =
               Survivors.resolve([declaration(from: nil, to: nil, change: change)], mutants)
    end

    assert {[%{pinned: :none}], []} =
             Survivors.resolve([declaration(from: nil, to: nil, change: "9 -> 7")], mutants)

    # the same change in another unit is not a candidate; one in this unit is
    assert {["m4"], []} = pinned_ids([declaration(unit: "X.g/0", from: "1", to: "2")], mutants)
    assert {[:none], []} = pinned_ids([declaration(from: "5", to: "6")], mutants)

    # a wildcard and a survivors-file entry pass through untouched, in order
    wildcard = declaration(from: nil, to: nil, line: 1)
    plain = annotation(line: 2)
    assert {[^wildcard, ^plain], []} = Survivors.resolve([wildcard, plain], mutants)

    assert {[%{pinned: "m3"}, ^plain], []} =
             Survivors.resolve([declaration(from: "9", to: "8"), plain], mutants)
  end

  @tag obligation: "covenant.mutate.I9"
  test "a declaration that several mutants share needs its occurrence, counted in source order" do
    second = mutant("m2", :survived, line: 5)
    first = mutant("m1", :survived, line: 4)
    other_file = mutant("m0", :survived, file: "lib/y.ex", line: 1)
    mutants = [other_file, second, first]

    assert {[], [error]} = Survivors.resolve([declaration(line: 7)], mutants)
    assert error.file == "mutants.md" and error.line == 7

    assert error.message ==
             "ambiguous: 3 mutants in X.f/0 share 1 -> 2; add #1 to #3 to name one (in source order)"

    assert {[], [%{message: "ambiguous: 3 mutants in X.f/0 share `1` → `2`; " <> _}]} =
             Survivors.resolve([declaration(from: nil, to: nil, change: "`1` → `2`")], mutants)

    # lib/x.ex sorts before lib/y.ex, a line before a later line
    assert {["m1"], []} = pinned_ids([declaration(occurrence: 1)], mutants)
    assert {["m2"], []} = pinned_ids([declaration(occurrence: 2)], mutants)
    assert {["m0"], []} = pinned_ids([declaration(occurrence: 3)], mutants)

    assert {[], [error]} = Survivors.resolve([declaration(occurrence: 4, line: 9)], mutants)
    assert error.file == "mutants.md" and error.line == 9
    assert error.message == "#4: only 3 mutant(s) in X.f/0 share 1 -> 2"

    # the kept and the refused each keep their order
    assert {[%{line: 1}, %{line: 3}], [%{line: 2}, %{line: 4}]} =
             Survivors.resolve(
               [
                 declaration(occurrence: 1, line: 1),
                 declaration(line: 2),
                 declaration(occurrence: 2, line: 3),
                 declaration(occurrence: 9, line: 4)
               ],
               mutants
             )
  end

  @tag obligation: "covenant.mutate.I9"
  test "a pinned declaration matches its one mutant, and an unmatched one matches none" do
    one = mutant("m1", :survived)
    two = mutant("m2", :survived)

    assert Survivors.matches?(declaration(pinned: "m1"), one) == true
    assert Survivors.matches?(declaration(pinned: "m1"), two) == false
    assert Survivors.matches?(declaration(pinned: :none), one) == false

    # a template names the occurrence only when the unit's mutants share the change
    mutants = [one, two, mutant("m3", :survived, from: "3", to: "4")]
    assert Survivors.template(one, format: :md, mutants: mutants) == "X.f/0: 1 -> 2 #1"
    assert Survivors.template(two, format: :md, mutants: mutants) == "X.f/0: 1 -> 2 #2"

    # sharing the from or the to alone is not sharing the change
    lone = Enum.at(mutants, 2)

    near = [
      mutant("m6", :survived, from: "3", to: "9"),
      mutant("m7", :survived, from: "7", to: "4")
    ]

    assert Survivors.template(lone, format: :md, mutants: mutants ++ near) == "X.f/0: 3 -> 4"

    assert Survivors.template(one,
             format: :md,
             mutants: [one, mutant("m5", :survived, function: "g/0")]
           ) ==
             "X.f/0: 1 -> 2"

    assert Survivors.template(mutant("m9", :survived), format: :md, mutants: [one, two]) ==
             "X.f/0: 1 -> 2"
  end

  @tag obligation: "covenant.mutate.I9"
  test "a declaration a test kills is contradicted, and one matching no survivor is unmatched",
       %{counter: counter} do
    killed = mutant("m001", :killed, killed_by: ["M:a"])

    assert [problem] = build(counter, [killed], [declaration([])]).problems
    assert problem.file == "mutants.md" and problem.line == 3

    assert problem.message ==
             "declaration `X.f/0: 1 -> 2` (m001) is contradicted: a Contract test kills that mutant — delete it"

    invalid = mutant("m002", :invalid, line: 5)

    assert [%{message: message}] = build(counter, [invalid], [declaration([])]).problems

    assert message ==
             "declaration `X.f/0: 1 -> 2` (m002) is contradicted: that mutant does not compile, so it cannot survive — delete it"

    unmatched = build(counter, [killed], [declaration(unit: "X.g/0", from: nil, to: nil)])

    assert [%{message: message}] = unmatched.problems

    assert message ==
             "declaration `X.g/0: *` matches no surviving mutant; the code moved, the mutation changed or nothing survives there — delete or update it"

    sorted = build(counter, [mutant("m001", :survived)], [declaration(from: nil, to: nil)])
    assert sorted.problems == []
    assert [%{sort: "unpromised", reason: "open"}] = sorted.survivors
  end

  @tag obligation: "covenant.mutate.I10"
  test "a primitive's modules are the ones its covers name, a tree expanded when located",
       %{tmp_dir: dir} do
    primitive!(dir, "mut", """
    # mut

    - **A1** Mutates.

    ```covers
    Covenant.Mutate.Matrix.build/2
    Covenant.Mutate.*
    Covenant.Static
    ```
    """)

    mut = dir |> sibling_contract!() |> Contract.component("mut")

    assert Modules.resolve(mut) ==
             {:covers, ["Covenant.Mutate.*", "Covenant.Mutate.Matrix", "Covenant.Static"]}

    assert Modules.resolve(mut, ["Covenant.Static"]) == {:flag, ["Covenant.Static"]}

    assert {:ok, located, []} = Modules.locate(["Covenant.Mutate.*"], :covers, @root)
    names = Enum.map(located, &inspect(elem(&1, 0)))
    assert "Covenant.Mutate" in names and "Covenant.Mutate.Matrix" in names
    refute "Covenant.Static" in names
  end

  @tag obligation: "covenant.mutate.I11"
  test "a primitive's plan takes the tests beside its README, and covered_by? applies the most specific covers",
       %{tmp_dir: dir} do
    primitive!(dir, "calc", "# calc\n\n- **A1** Adds.\n\n```covers\nCalc\n```\n")
    primitive!(dir, "sum", "# sum\n\n- **S1** Sums.\n\n```covers\nCalc.add/2\n```\n")
    primitive!(dir, "empty", "# empty\n\n- **E1** Nothing.\n")
    contract = sibling_contract!(dir)

    assert {:error, "no Contract test (`*_test.exs`) beside " <> _} =
             Mutate.plan(contract, "calc", root: dir)

    assert {:error, "`empty` covers no code: add a ```covers block to " <> _} =
             Mutate.plan(contract, "empty", root: dir)

    File.write!(Path.join([dir, "contract", "calc", "calc_test.exs"]), "")
    assert {:ok, plan} = Mutate.plan(contract, "calc", root: dir)
    assert plan.source == :covers and plan.names == ["Calc"]
    assert plan.test_files == ["contract/calc/calc_test.exs"]

    add = mutant("m001", :survived, module: "Calc", function: "add/2")
    clamp = mutant("m002", :survived, module: "Calc", function: "clamp/3")
    top = mutant("m003", :survived, module: "Calc", function: nil)

    refute Mutate.covered_by?(contract, "calc", add)
    assert Mutate.covered_by?(contract, "sum", add)
    assert Mutate.covered_by?(contract, "calc", clamp)
    assert Mutate.covered_by?(contract, "calc", top)
    refute Mutate.covered_by?(contract, "sum", clamp)
  end
end

defmodule Covenant.MutateWorkdirContractTest do
  @moduledoc "The working directory is process-wide, so these tests run one at a time."

  use Covenant.Case, component: "covenant.mutate", async: false

  alias Covenant.Mutate.Workdir

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    root = Path.join(dir, "project")
    base = Path.join(dir, "farms")
    File.mkdir_p!(base)
    File.mkdir_p!(Path.join(root, "lib"))
    File.mkdir_p!(Path.join(root, "tmp"))
    File.write!(Path.join(root, "mix.exs"), "mix")
    File.write!(Path.join(root, "lib/a.ex"), "a")
    File.write!(Path.join(root, "tmp/theirs.txt"), "theirs")
    # some tests leave read-only directories here; under mutation the suite runs again in one VM
    on_exit(fn -> System.cmd("chmod", ["-R", "u+rwx", dir]) end)
    {:ok, root: root, base: base}
  end

  @tag obligation: "covenant.mutate.I15"
  test "a worker directory holds copies of the sources, links the big dirs and has a tmp of its own",
       %{root: root, base: base} do
    File.mkdir_p!(Path.join(root, "_build/test"))
    File.mkdir_p!(Path.join(root, "deps"))
    File.mkdir_p!(Path.join(root, ".git"))
    File.mkdir_p!(Path.join(root, ".elixir_ls"))
    File.write!(Path.join(root, "_build/test/x"), "x")

    dir = Workdir.build(root, base)
    assert Path.dirname(dir) == base
    assert Path.basename(dir) =~ ~r/^covenant-mutate-#{System.pid()}-[0-9a-z]+$/
    assert dir |> File.ls!() |> Enum.sort() == ["_build", "deps", "lib", "mix.exs", "tmp"]
    assert File.read!(Path.join(dir, "mix.exs")) == "mix"
    assert File.read!(Path.join(dir, "lib/a.ex")) == "a"
    assert {:ok, %File.Stat{type: :directory}} = File.lstat(Path.join(dir, "lib"))
    assert {:ok, %File.Stat{type: :regular}} = File.lstat(Path.join(dir, "mix.exs"))
    assert {:ok, %File.Stat{type: :symlink}} = File.lstat(Path.join(dir, "_build"))
    assert {:ok, %File.Stat{type: :symlink}} = File.lstat(Path.join(dir, "deps"))
    assert {:ok, %File.Stat{type: :directory}} = File.lstat(Path.join(dir, "tmp"))
    assert File.ls!(Path.join(dir, "tmp")) == []
    assert File.stat!(dir).mode |> Bitwise.band(0o777) == 0o700

    # a second worker never reuses or clears the first one's directory
    File.write!(Path.join(dir, "tmp/stale.txt"), "stale")
    other = Workdir.build(root, base)
    refute other == dir
    assert File.exists?(Path.join(dir, "tmp/stale.txt"))
  end

  @tag obligation: "covenant.mutate.I15"
  test "build and dependency trees are links at any depth, a nested .git is left out, links are copied as links",
       %{root: root, base: base} do
    File.mkdir_p!(Path.join(root, "assets/node_modules/pkg"))
    File.write!(Path.join(root, "assets/node_modules/pkg/index.js"), "js")
    File.write!(Path.join(root, "assets/app.js"), "app")
    File.mkdir_p!(Path.join(root, "apps/x/_build/dev"))
    File.write!(Path.join(root, "apps/x/_build/dev/x.beam"), "beam")
    File.mkdir_p!(Path.join(root, "apps/x/lib"))
    File.write!(Path.join(root, "apps/x/mix.exs"), "mix")
    File.write!(Path.join(root, "apps/x/lib/x.ex"), "x")
    File.write!(Path.join(root, "apps/x/.git"), "gitdir: elsewhere")
    File.mkdir_p!(Path.join(root, "apps/y/.elixir_ls"))
    File.ln_s!("a.ex", Path.join(root, "lib/link.ex"))

    dir = Workdir.build(root, base)

    for link <- ["assets/node_modules", "apps/x/_build"] do
      assert {:ok, %File.Stat{type: :symlink}} = File.lstat(Path.join(dir, link))
    end

    assert File.read!(Path.join(dir, "assets/app.js")) == "app"
    assert {:ok, %File.Stat{type: :directory}} = File.lstat(Path.join(dir, "assets"))
    assert File.read!(Path.join(dir, "apps/x/lib/x.ex")) == "x"
    refute File.exists?(Path.join(dir, "apps/x/.git"))
    refute File.exists?(Path.join(dir, "apps/y/.elixir_ls"))
    assert {:ok, %File.Stat{type: :symlink}} = File.lstat(Path.join(dir, "lib/link.ex"))
    assert File.read_link!(Path.join(dir, "lib/link.ex")) == "a.ex"

    Workdir.within(dir, fn ->
      File.rm_rf!("assets")
      File.rm_rf!("apps")
    end)

    assert File.read!(Path.join(root, "assets/node_modules/pkg/index.js")) == "js"
    assert File.read!(Path.join(root, "apps/x/_build/dev/x.beam")) == "beam"
    assert File.read!(Path.join(root, "apps/x/lib/x.ex")) == "x"
    assert File.read!(Path.join(root, "apps/x/.git")) == "gitdir: elsewhere"
  end

  @tag obligation: "covenant.mutate.I15"
  test "writes and deletes by relative path land in the copy, never in the project", %{
    root: root,
    base: base
  } do
    File.mkdir_p!(Path.join(root, "deps"))
    File.write!(Path.join(root, "deps/dep.txt"), "dep")
    dir = Workdir.build(root, base)

    Workdir.within(dir, fn ->
      File.write!("lib/a.ex", "mutated")
      File.rm_rf!(Path.expand(""))
    end)

    refute File.exists?(dir)
    assert File.read!(Path.join(root, "lib/a.ex")) == "a"
    assert File.read!(Path.join(root, "mix.exs")) == "mix"
    assert File.read!(Path.join(root, "deps/dep.txt")) == "dep"
  end

  @tag obligation: "covenant.mutate.I15"
  test "building refuses a directory that already exists", %{root: root, base: base} do
    existing = Path.join(base, "covenant-mutate-#{System.pid()}-fixed")
    File.mkdir_p!(existing)
    File.write!(Path.join(existing, "keep"), "keep")

    assert_raise File.Error, ~r/file already exists/, fn -> Workdir.build(root, base, "fixed") end
    assert File.read!(Path.join(existing, "keep")) == "keep"
  end

  @tag obligation: "covenant.mutate.I15"
  test "removing it deletes the links, never what they point at", %{root: root, base: base} do
    File.mkdir_p!(Path.join(root, "deps"))
    File.write!(Path.join(root, "deps/dep.txt"), "dep")
    dir = Workdir.build(root, base)
    File.write!(Path.join(dir, "tmp/mine.txt"), "mine")
    File.write!(Path.join(dir, "loose.txt"), "loose")
    # a link nested in a copied entry points outside the project
    File.ln_s!(Path.join(root, "deps"), Path.join(dir, "lib/nested"))

    assert :ok = Workdir.remove(dir)

    refute File.exists?(dir)
    assert File.read!(Path.join(root, "lib/a.ex")) == "a"
    assert File.read!(Path.join(root, "mix.exs")) == "mix"
    assert File.read!(Path.join(root, "tmp/theirs.txt")) == "theirs"
    assert File.read!(Path.join(root, "deps/dep.txt")) == "dep"

    # a mutant may have deleted it already
    assert :ok = Workdir.remove(dir)
  end

  @tag obligation: "covenant.mutate.I15"
  test "a _build or deps directory is linked only beside a mix.exs; node_modules anywhere",
       %{root: root, base: base} do
    File.mkdir_p!(Path.join(root, "test/fixtures/deps"))
    File.write!(Path.join(root, "test/fixtures/deps/data.txt"), "data")
    File.mkdir_p!(Path.join(root, "test/fixtures/_build"))
    File.mkdir_p!(Path.join(root, "test/fixtures/node_modules"))
    File.mkdir_p!(Path.join(root, "deps"))

    dir = Workdir.build(root, base)

    assert {:ok, %File.Stat{type: :directory}} = File.lstat(Path.join(dir, "test/fixtures/deps"))
    assert File.read!(Path.join(dir, "test/fixtures/deps/data.txt")) == "data"

    assert {:ok, %File.Stat{type: :directory}} =
             File.lstat(Path.join(dir, "test/fixtures/_build"))

    assert {:ok, %File.Stat{type: :symlink}} =
             File.lstat(Path.join(dir, "test/fixtures/node_modules"))

    assert {:ok, %File.Stat{type: :symlink}} = File.lstat(Path.join(dir, "deps"))
  end

  @tag obligation: "covenant.mutate.I15"
  test "symlinks never lead a write into the project, and none dangles", %{root: root, base: base} do
    outside = Path.join(Path.dirname(root), "outside")
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "o.txt"), "o")
    File.ln_s!(Path.join(root, "lib"), Path.join(root, "abs_in"))
    File.ln_s!(Path.join(root, "lib/a.ex"), Path.join(root, "abs_in_file"))
    File.ln_s!("../outside/o.txt", Path.join(root, "rel_out"))
    File.ln_s!("lib/a.ex", Path.join(root, "rel_in"))
    File.ln_s!("/somewhere/else", Path.join(root, "abs_out"))

    dir = Workdir.build(root, base)

    assert File.read_link!(Path.join(dir, "abs_in")) == Path.join(dir, "lib")
    assert File.read_link!(Path.join(dir, "abs_in_file")) == Path.join(dir, "lib/a.ex")
    assert File.read_link!(Path.join(dir, "rel_out")) == Path.join(outside, "o.txt")
    assert File.read!(Path.join(dir, "rel_out")) == "o"
    assert File.read_link!(Path.join(dir, "rel_in")) == "lib/a.ex"
    assert File.read_link!(Path.join(dir, "abs_out")) == "/somewhere/else"

    Workdir.within(dir, fn -> File.write!("abs_in/a.ex", "through the link") end)
    assert File.read!(Path.join(root, "lib/a.ex")) == "a"
    assert File.read!(Path.join(dir, "lib/a.ex")) == "through the link"
  end

  @tag obligation: "covenant.mutate.I15"
  test "removing it survives a read-only directory a test left behind", %{root: root, base: base} do
    dir = Workdir.build(root, base)
    File.mkdir_p!(Path.join(dir, "tmp/ro/inner"))
    File.write!(Path.join(dir, "tmp/ro/inner/f"), "f")
    File.chmod!(Path.join(dir, "tmp/ro/inner"), 0o500)
    File.chmod!(Path.join(dir, "tmp/ro"), 0o500)

    assert :ok = Workdir.remove(dir)
    refute File.exists?(dir)
  end

  @tag obligation: "covenant.mutate.I15"
  test "an unreadable entry is left out with a warning, and a failed build leaves no directory",
       %{root: root, base: base} do
    File.mkdir_p!(Path.join(root, "data/pg"))
    File.write!(Path.join(root, "data/pg/f"), "f")
    File.write!(Path.join(root, "data/ok"), "ok")
    File.chmod!(Path.join(root, "data/pg"), 0o000)

    try do
      warning =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          send(self(), {:dir, Workdir.build(root, base)})
        end)

      assert_received {:dir, dir}
      assert warning =~ "data/pg"
      assert File.read!(Path.join(dir, "data/ok")) == "ok"
      refute File.exists?(Path.join(dir, "data/pg"))
    after
      File.chmod!(Path.join(root, "data/pg"), 0o755)
    end

    before = File.ls!(base)
    assert_raise File.Error, fn -> Workdir.build(Path.join(root, "nowhere"), base) end
    assert File.ls!(base) == before
  end

  @tag obligation: "covenant.mutate.I15"
  test "within runs in the directory and restores the previous one, even on a raise", %{
    root: root,
    base: base
  } do
    dir = Workdir.build(root, base)
    here = File.cwd!()

    resolved = Workdir.within(dir, fn -> {File.cwd!(), File.read!("mix.exs")} end)
    assert elem(resolved, 1) == "mix"
    assert Path.basename(elem(resolved, 0)) == Path.basename(dir)
    assert File.cwd!() == here

    assert_raise RuntimeError, "boom", fn -> Workdir.within(dir, fn -> raise "boom" end) end
    assert File.cwd!() == here

    assert Workdir.within(dir, fn -> :value end) == :value
  end
end
