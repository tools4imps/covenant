defmodule Covenant.Contract.LoadContractTest do
  use Covenant.Case, component: "covenant.contract", async: true

  alias Covenant.Contract
  alias Covenant.Contract.{Component, Obligation, Record}
  alias Covenant.ContractBuilder
  alias Covenant.Error

  defp messages({:error, errors}), do: Enum.map(errors, &Error.format/1)

  @tag obligation: "covenant.contract.I1"
  test "loads the fixture Contract: components, records, ceilings, provenance" do
    assert {:ok, %Contract{} = contract} = Contract.load(ContractBuilder.fixture_contracts())
    assert Contract.component_ids(contract) == ["example.counter", "example.greeter", "system"]

    counter = Contract.component(contract, "example.counter")
    assert %Component{form: :heavy, app: "example", name: "counter"} = counter
    assert String.ends_with?(counter.file, "contracts/example/counter.intent.md")
    assert String.ends_with?(counter.records_file, "contracts/example/counter.decisions.yml")

    assert Enum.map(counter.records, & &1.id) == [
             "clamp-at-zero",
             "positive-steps",
             "fixed-max-100",
             "configurable-max"
           ]

    assert Enum.map(counter.obligations, & &1.id) == Enum.map(1..7, &"example.counter.I#{&1}")

    greeter = Contract.component(contract, "example.greeter")
    assert %Component{form: :light, records: [], records_file: nil} = greeter

    system = Contract.component(contract, "system")
    assert %Component{form: :system, obligations: []} = system
    assert Enum.map(system.records, & &1.id) == ["one-example-app"]

    assert Map.keys(contract.records) |> Enum.sort() == [
             "clamp-at-zero",
             "configurable-max",
             "fixed-max-100",
             "one-example-app",
             "positive-steps"
           ]

    assert %Record{component_id: "system"} = Contract.record(contract, "one-example-app")
    assert Enum.map(contract.ceilings, & &1.name) == ["example-modules", "counter-event-kinds"]
  end

  @tag obligation: "covenant.contract.I1"
  test "looks obligations up by id" do
    {:ok, contract} = Contract.load(ContractBuilder.fixture_contracts())

    assert %Obligation{id: "example.greeter.I2", kind: :exception} =
             Contract.obligation(contract, "example.greeter.I2")

    assert Contract.obligation(contract, "example.greeter.I9") == nil
    assert Contract.obligation(contract, "nope.I1") == nil
    assert Contract.obligation(contract, "garbage") == nil
    assert Enum.map(Contract.obligations(contract), & &1.id) |> length() == 9
  end

  @tag :tmp_dir
  @tag obligation: "covenant.contract.I8"
  test "an empty contracts directory is a valid, empty Contract", %{tmp_dir: dir} do
    assert {:ok, %Contract{components: components, records: records, ceilings: []}} =
             Contract.load(dir)

    assert components == %{}
    assert records == %{}
  end

  @tag obligation: "covenant.contract.I8"
  test "a missing directory is an error" do
    assert [message] = messages(Contract.load("no/such/contracts"))
    assert message =~ "no/such/contracts: contracts directory not found"
    assert message =~ ~S(config :covenant, contracts_dir: "../contracts")
    assert message =~ "COVENANT_ROOT"
    assert message =~ "config :covenant, root:"

    assert_raise Covenant.ContractError, ~r/contracts directory not found/, fn ->
      Contract.load!("no/such/contracts")
    end
  end

  @tag :tmp_dir
  @tag obligation: "covenant.contract.I7"
  test "collects problems from every file", %{tmp_dir: dir} do
    ContractBuilder.write(dir, %{
      "demo/widget.intent.md" =>
        String.replace(ContractBuilder.heavy_intent(), "- **must:** store the size\n", ""),
      "demo/widget.decisions.yml" => "- id: keep-size\n",
      "demo/gadget.obligations.md" => ContractBuilder.light_obligations()
    })

    assert [widget_error, records_error | _] = messages(Contract.load(dir))
    assert widget_error =~ "obligation `demo.widget.I1` is missing `must`"
    assert records_error =~ "record `keep-size` is missing `date`"
  end

  @tag :tmp_dir
  @tag obligation: "covenant.contract.I4"
  test "a component declared in both forms is an error", %{tmp_dir: dir} do
    ContractBuilder.write(dir, %{
      "demo/widget.intent.md" => ContractBuilder.heavy_intent(),
      "demo/widget.obligations.md" =>
        String.replace(ContractBuilder.light_obligations(), "demo.gadget", "demo.widget")
    })

    assert [message] = messages(Contract.load(dir))
    assert message =~ "component `demo.widget` is declared twice"
  end

  @tag :tmp_dir
  @tag obligation: "covenant.contract.I4"
  test "a record id declared in two files is an error", %{tmp_dir: dir} do
    ContractBuilder.demo_contracts(dir)
    ContractBuilder.write(dir, %{"system/decisions.yml" => ContractBuilder.widget_records()})

    assert [message] = messages(Contract.load(dir))

    assert message =~
             ~r/system\/decisions.yml:1: record `keep-size` is declared twice \(also in .*demo\/widget.decisions.yml:1\)/
  end

  @tag :tmp_dir
  @tag obligation: "covenant.contract.I1"
  test "records without a component file are still loaded", %{tmp_dir: dir} do
    ContractBuilder.write(dir, %{"demo/orphan.decisions.yml" => ContractBuilder.widget_records()})
    assert {:ok, contract} = Contract.load(dir)
    assert %Record{component_id: "demo.orphan"} = Contract.record(contract, "keep-size")
  end

  @tag obligation: "covenant.contract.I1"
  test "derives component ids from paths" do
    assert Contract.component_id("contracts", "contracts/billing/invoices.intent.md") ==
             "billing.invoices"

    assert Contract.component_id("contracts", "contracts/billing/invoices.decisions.yml") ==
             "billing.invoices"

    assert Contract.component_id("contracts", "contracts/web/admin.obligations.md") == "web.admin"
    assert Contract.component_id("contracts", "contracts/web.admin/obligations.md") == "web.admin"

    assert Contract.component_id(
             "contracts",
             "contracts/web.admin/session/decisions.yml"
           ) == "web.admin.session"

    assert Contract.component_id("contracts", "contracts/system/intent.md") == "system"
    assert Contract.component_id("contracts", "contracts/system/decisions.yml") == "system"
  end

  @tag :tmp_dir
  @tag obligation: "covenant.contract.I1"
  test "loads component-directory files beside their component tests", %{tmp_dir: dir} do
    ContractBuilder.write(dir, %{
      "demo.gadget/obligations.md" => ContractBuilder.light_obligations(),
      "demo.widget/intent.md" => ContractBuilder.heavy_intent(),
      "demo.widget/decisions.yml" => ContractBuilder.widget_records(),
      "demo.widget/history/obligations.md" =>
        String.replace(ContractBuilder.light_obligations(), "demo.gadget", "demo.widget.history"),
      "demo.widget/history/contract_test.exs" => "# executable obligation beside its records\n"
    })

    assert {:ok, contract} = Contract.load(dir)

    assert Contract.component_ids(contract) == [
             "demo.gadget",
             "demo.widget",
             "demo.widget.history"
           ]

    assert %Component{
             form: :light,
             file: gadget_file
           } = Contract.component(contract, "demo.gadget")

    assert gadget_file == Path.join(dir, "demo.gadget/obligations.md")

    assert %Component{
             form: :heavy,
             records_file: records_file,
             records: records
           } = Contract.component(contract, "demo.widget")

    assert records_file == Path.join(dir, "demo.widget/decisions.yml")
    assert Enum.map(records, & &1.id) == ["keep-size"]
    assert %Component{form: :light} = Contract.component(contract, "demo.widget.history")
  end

  @tag :tmp_dir
  @tag obligation: "covenant.contract.I4"
  test "a component declared in file and directory forms is an error", %{tmp_dir: dir} do
    ContractBuilder.write(dir, %{
      "demo/gadget.obligations.md" => ContractBuilder.light_obligations(),
      "demo.gadget/obligations.md" => ContractBuilder.light_obligations()
    })

    assert [message] = messages(Contract.load(dir))
    assert message =~ "component `demo.gadget` is declared twice"
  end
end
