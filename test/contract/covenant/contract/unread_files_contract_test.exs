defmodule Covenant.Contract.UnreadFilesContractTest do
  use Covenant.Case, component: "covenant.contract", async: true

  alias Covenant.Contract
  alias Covenant.ContractBuilder
  alias Covenant.Error
  alias Covenant.Parser.Markdown

  @path "demo/gadget.obligations.md"

  defp messages({:error, errors}), do: Enum.map(errors, &Error.format/1)

  defp light(extra \\ ""), do: ContractBuilder.light_obligations() <> extra

  defp parse(text), do: Markdown.parse(text, @path, "demo.gadget", :light)

  @tag :tmp_dir
  @tag obligation: "covenant.contract.I1"
  test "a misnamed Markdown/YAML file is an error naming it, known files are not",
       %{tmp_dir: dir} do
    ContractBuilder.write(dir, %{
      "demo/gadget.obligations.md" => light(),
      "README.md" => "# Contracts\n",
      "coverage.json" => "{}",
      "coverage.static.json" => "{}",
      "demo/gadget.survivors.yml" => "[]\n"
    })

    assert {:ok, _} = Contract.load(dir)

    ContractBuilder.write(dir, %{
      "obligations.md" => light(),
      "system/obligations.md" => light(),
      "demo/sub/other.obligations.md" => light(),
      "demo/widget.obligation.md" => "# nope\n",
      "demo/sub/x.obligations.markdown" => light(),
      "demo/Decisions-2024.txt" => "nope\n"
    })

    assert {:error, _} = result = Contract.load(dir)

    assert messages(result) |> Enum.map(&String.replace(&1, dir <> "/", "")) |> Enum.sort() == [
             "demo/Decisions-2024.txt:1: this file is not read: a component is `<app>/<name>.obligations.md` (or `.intent.md`) or `<component-id>/obligations.md` (or `intent.md`), and its records use the matching `decisions.yml` form; rename or move it",
             "demo/sub/other.obligations.md:1: this file is not read: a component is `<app>/<name>.obligations.md` (or `.intent.md`) or `<component-id>/obligations.md` (or `intent.md`), and its records use the matching `decisions.yml` form; rename or move it",
             "demo/sub/x.obligations.markdown:1: this file is not read: a component is `<app>/<name>.obligations.md` (or `.intent.md`) or `<component-id>/obligations.md` (or `intent.md`), and its records use the matching `decisions.yml` form; rename or move it",
             "demo/widget.obligation.md:1: this file is not read: a component is `<app>/<name>.obligations.md` (or `.intent.md`) or `<component-id>/obligations.md` (or `intent.md`), and its records use the matching `decisions.yml` form; rename or move it",
             "obligations.md:1: this file is not read: a component is `<app>/<name>.obligations.md` (or `.intent.md`) or `<component-id>/obligations.md` (or `intent.md`), and its records use the matching `decisions.yml` form; rename or move it",
             "system/obligations.md:1: this file is not read: a component is `<app>/<name>.obligations.md` (or `.intent.md`) or `<component-id>/obligations.md` (or `intent.md`), and its records use the matching `decisions.yml` form; rename or move it"
           ]
  end

  @tag :tmp_dir
  @tag obligation: "covenant.contract.I1"
  test "prose under the contracts directory (notes, ADRs, other YAML) is not an error",
       %{tmp_dir: dir} do
    ContractBuilder.write(dir, %{
      "demo/gadget.obligations.md" => light(),
      "NOTES.md" => "# Notes\n",
      "docs/overview.md" => "# Overview\n",
      "adr/0001-use-elixir.md" => "# ADR\n",
      "demo/notes.yml" => "a: 1\n"
    })

    assert {:ok, _} = Contract.load(dir)
  end

  @tag obligation: "covenant.contract.I10"
  test "an id-shaped heading written with a colon is an error, even with plain bullets after it" do
    text = light("\n### demo.gadget.I9: Gadgets glow\n- scope: `Demo.Gadget.glow/0`\n")
    line = length(String.split(light(), "\n"))

    assert messages(parse(text)) == [
             "demo/gadget.obligations.md:#{line + 1}: obligation heading must be `### demo.gadget.I<n> — <title>`"
           ]
  end

  @tag obligation: "covenant.contract.I10"
  test "a fence indented four spaces opens nothing" do
    assert {:ok, component} = parse(light("\n    ```\n    code, never closed\n"))
    assert Enum.map(component.obligations, & &1.id) == ["demo.gadget.I1", "demo.gadget.I2"]
    assert {:error, _} = parse(light("\n   ```\n   code, never closed\n"))
  end

  @tag obligation: "covenant.contract.I10"
  test "a nested bullet under an enum field does not join its value" do
    text =
      String.replace(light(), "- **status:** active", "- **status:** active\n  - a note",
        global: false
      )

    assert {:ok, component} = parse(text)
    assert hd(component.obligations).status == :active
  end

  @tag obligation: "covenant.contract.I11"
  test "front matter with duplicate keys or several documents is an error" do
    assert messages(parse("---\nmodules: []\nmodules: []\n---\n" <> light())) != []
    assert messages(parse("---\na: 1\n...\nb: 2\n---\n" <> light())) != []
  end

  @tag obligation: "covenant.contract.I11"
  test "a front matter YAML error without a line is an error, not a crash" do
    assert {:error, [%Error{line: 1, message: "invalid YAML: " <> _}]} =
             parse("---\n\t a: 1\n---\n" <> light())
  end
end
