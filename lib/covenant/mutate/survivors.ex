defmodule Covenant.Mutate.Survivors do
  @moduledoc """
  The survivor sort annotates every surviving mutant with the judgment a
  human made about it. It is either
  `contracts/<app>/<component>.survivors.yml` or `survivors.yml` in a
  component directory.

  ```yaml
  - at: lib/example/counter.ex:29:17
    operator: element_removal
    mutation: "`value: 0` → `(removed)`"
    sort: equivalent
    reason: The struct default for value is already 0.
  ```

  An entry's key is `at`, `operator` and `mutation`, all three required, so an
  entry names one mutant and never the next one to land on the same site
  (record `survivor-keys-name-one-mutant`).

  `sort` is one of `equivalent`, `log-only`, `dead-code`, `timeout`,
  `evaluation-gap`, `decision-hole` or `unpromised`.

  A primitive of the sibling layout declares its survivors in
  `contract/<primitive>/mutants.md` instead, as flinch does: `equivalent` and
  `unpromised` blocks of `Module.function/arity: from -> to` lines under a
  heading that gives the reason (`Covenant.Parser.Primitive.declarations/2`).
  `equivalent` maps onto the `equivalent` sort and `unpromised` onto
  `unpromised`. A survivor without an annotation and an
  annotation without a survivor both fail `mix covenant.mutate`, the way a
  stale `kind: exception` fails `mix covenant.check`: the counts only say
  where to look, the sort is where the judgment is.
  """

  alias Covenant.Error
  alias Covenant.Mutate.Mutant
  alias Covenant.Parser.Primitive

  @sorts ~w(equivalent log-only dead-code timeout evaluation-gap decision-hole unpromised)
  @item_line ~r/^-[ \t]/

  defmodule Annotation do
    @moduledoc """
    One annotated survivor. An entry of a survivors file names a site (`at`,
    `operator`, `mutation`); a declaration in a primitive's `mutants.md` names
    a `unit` (`Module.function/arity`) and a `change` (`from -> to`, with an
    `occurrence` when several of the unit's mutants share it), or no change for
    a wildcard over the unit. `resolve/2` pins each declaration with a change
    to the one mutant it names (`pinned`, a mutant id, or `:none`).
    """

    @type t :: %__MODULE__{
            at: String.t(),
            operator: String.t(),
            mutation: String.t() | nil,
            sort: String.t(),
            reason: String.t(),
            file: String.t(),
            line: pos_integer(),
            unit: String.t() | nil,
            change: String.t() | nil,
            occurrence: pos_integer() | nil,
            from: String.t() | nil,
            to: String.t() | nil,
            pinned: String.t() | :none | nil
          }

    @enforce_keys [:at, :operator, :sort, :reason, :file, :line]
    defstruct [
      :at,
      :operator,
      :mutation,
      :sort,
      :reason,
      :file,
      :line,
      :unit,
      :change,
      :occurrence,
      :from,
      :to,
      :pinned
    ]
  end

  @doc "The sort names, in the order the survivors file documents them."
  @spec sorts() :: [String.t()]
  def sorts, do: @sorts

  @doc """
  Where a component's annotations live: `<contracts dir>/<app>/<name>.survivors.yml`,
  `survivors.yml` beside a component-directory intent or obligations file, or
  `mutants.md` beside a primitive's README.
  """
  @spec path(Path.t(), Covenant.Contract.Component.t()) :: Path.t()
  def path(_contracts_dir, %{form: :primitive, file: readme}),
    do: Path.join(Path.dirname(readme), "mutants.md")

  def path(contracts_dir, %{form: :system}),
    do: Path.join([contracts_dir, "system", "survivors.yml"])

  def path(contracts_dir, component),
    do: component_survivors_path(contracts_dir, component)

  defp component_survivors_path(contracts_dir, component) do
    if Path.basename(component.file) in ["intent.md", "obligations.md"] do
      Path.join(Path.dirname(component.file), "survivors.yml")
    else
      Path.join([contracts_dir, component.app, "#{component.name}.survivors.yml"])
    end
  end

  @doc "Reads the annotations file (a `mutants.md` by its extension); a missing file is an empty list."
  @spec load(Path.t()) :: {:ok, [Annotation.t()]} | {:error, [Error.t()]}
  def load(path) do
    case File.read(path) do
      {:ok, text} ->
        if Path.extname(path) == ".md",
          do: Primitive.declarations(text, path),
          else: parse(text, path)

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, [Error.new(path, nil, "cannot read file: #{:file.format_error(reason)}")]}
    end
  end

  @doc "Parses annotations from `text`; `file` is used for provenance."
  @spec parse(String.t(), Path.t()) :: {:ok, [Annotation.t()]} | {:error, [Error.t()]}
  def parse(text, file) do
    if String.trim(text) == "" do
      {:ok, []}
    else
      case YamlElixir.read_from_string(text) do
        {:ok, nil} ->
          {:ok, []}

        {:ok, items} when is_list(items) ->
          lines = item_lines(text)

          items
          |> Enum.with_index()
          |> Enum.map(fn {item, i} -> annotation(item, i, Enum.at(lines, i, 1), file) end)
          |> collect()

        {:ok, _} ->
          {:error, [Error.new(file, 1, "survivors file must be a YAML list of annotations")]}

        {:error, %{line: line, message: message}} ->
          {:error, [Error.new(file, line, "invalid YAML: #{message}")]}

        {:error, error} ->
          {:error, [Error.new(file, 1, "invalid YAML: #{Exception.message(error)}")]}
      end
    end
  end

  defp collect(results) do
    case Enum.split_with(results, &match?({:ok, _}, &1)) do
      {oks, []} -> {:ok, Enum.map(oks, fn {:ok, a} -> a end)}
      {_, errors} -> {:error, Enum.flat_map(errors, fn {:error, e} -> e end)}
    end
  end

  defp item_lines(text) do
    text
    |> String.split(["\r\n", "\n"])
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _} -> Regex.match?(@item_line, line) end)
    |> Enum.map(fn {_, n} -> n end)
  end

  defp annotation(%{} = item, index, line, file) do
    label = "annotation ##{index + 1}"
    operators = Enum.map(Mutant.operators(), &Atom.to_string/1)

    errors =
      [
        string(item, "at", label, file, line),
        string(item, "operator", label, file, line),
        string(item, "mutation", label, file, line),
        string(item, "sort", label, file, line),
        string(item, "reason", label, file, line),
        enum(item, "operator", operators, label, file, line),
        enum(item, "sort", @sorts, label, file, line),
        at_shape(item, label, file, line)
      ]
      |> List.flatten()

    case errors do
      [] ->
        {:ok,
         %Annotation{
           at: item["at"],
           operator: item["operator"],
           mutation: item["mutation"],
           sort: item["sort"],
           reason: to_string(item["reason"]),
           file: file,
           line: line
         }}

      errors ->
        {:error, errors}
    end
  end

  defp annotation(_item, index, line, file),
    do: {:error, [Error.new(file, line, "annotation ##{index + 1} must be a mapping")]}

  defp string(item, key, label, file, line) do
    case Map.get(item, key) do
      nil -> Error.new(file, line, "#{label} is missing `#{key}`")
      "" -> Error.new(file, line, "#{label} has an empty `#{key}`")
      value when is_binary(value) -> []
      value -> Error.new(file, line, "#{label} `#{key}` must be a string, got #{inspect(value)}")
    end
  end

  defp enum(item, key, allowed, label, file, line) do
    case Map.get(item, key) do
      value when is_binary(value) and value != "" ->
        if value in allowed,
          do: [],
          else:
            Error.new(
              file,
              line,
              "#{label} has unknown `#{key}` `#{value}` (expected one of: #{Enum.join(allowed, ", ")})"
            )

      _ ->
        []
    end
  end

  defp at_shape(%{"at" => at}, label, file, line) when is_binary(at) do
    if Regex.match?(~r/^.+:\d+:\d+$/, at),
      do: [],
      else: Error.new(file, line, "#{label} `at` must be `file:line:column`, got `#{at}`")
  end

  defp at_shape(_, _, _, _), do: []

  @doc "The annotation that covers `mutant`, if any."
  @spec find([Annotation.t()], Mutant.t()) :: Annotation.t() | nil
  def find(annotations, %Mutant{} = mutant), do: Enum.find(annotations, &matches?(&1, mutant))

  @doc """
  True when the annotation names the mutant's location, operator and (if given)
  mutation; a declaration, when it names the mutant's unit and (unless it is a
  wildcard) its `from` and `to`.
  """
  @spec matches?(Annotation.t(), Mutant.t()) :: boolean()
  def matches?(%Annotation{pinned: :none}, %Mutant{}), do: false
  def matches?(%Annotation{pinned: id}, %Mutant{id: mutant}) when is_binary(id), do: id == mutant

  def matches?(%Annotation{unit: unit} = annotation, %Mutant{} = mutant) when unit != nil,
    do: unit in units(mutant) and (wildcard?(annotation) or same_change?(annotation, mutant))

  def matches?(%Annotation{} = annotation, %Mutant{} = mutant) do
    annotation.at == Mutant.at(mutant) and
      annotation.operator == Atom.to_string(mutant.operator) and
      (annotation.mutation == nil or annotation.mutation == Mutant.mutation(mutant))
  end

  @doc """
  Pins every `mutants.md` declaration that names a change to the one mutant it
  names among `mutants` (the run's mutants, every verdict): the unit's mutants
  with that change, in source order, of which the declaration's occurrence
  (`#k`) picks one. Returns the annotations and the errors: a declaration that
  several mutants share and that gives no occurrence is ambiguous, and one
  whose occurrence is past the last is out of range; both are left out, so
  their survivors stay unsorted. A declaration that matches no mutant is
  pinned to `:none` (the matrix reports it). Wildcards and survivors-file
  entries pass through.
  """
  @spec resolve([Annotation.t()], [Mutant.t()]) :: {[Annotation.t()], [Error.t()]}
  def resolve(annotations, mutants) do
    Enum.reduce(annotations, {[], []}, fn annotation, {kept, errors} ->
      case pin(annotation, mutants) do
        {:ok, annotation} -> {kept ++ [annotation], errors}
        {:error, error} -> {kept, errors ++ [error]}
      end
    end)
  end

  defp pin(%Annotation{unit: unit} = annotation, mutants) when unit != nil do
    if wildcard?(annotation),
      do: {:ok, annotation},
      else: pin(annotation, sharing(mutants, unit, &same_change?(annotation, &1)), unit)
  end

  defp pin(annotation, _mutants), do: {:ok, annotation}

  defp pin(annotation, candidates, unit) do
    change = annotation.change || "#{annotation.from} -> #{annotation.to}"

    case {candidates, annotation.occurrence} do
      {[], _} ->
        {:ok, %{annotation | pinned: :none}}

      {[mutant], nil} ->
        {:ok, pinned(annotation, mutant)}

      {many, nil} ->
        {:error,
         Error.new(
           annotation.file,
           annotation.line,
           "ambiguous: #{length(many)} mutants in #{unit} share #{change}; " <>
             "add #1 to ##{length(many)} to name one (in source order)"
         )}

      {many, k} when k <= length(many) ->
        {:ok, pinned(annotation, Enum.at(many, k - 1))}

      {many, k} ->
        {:error,
         Error.new(
           annotation.file,
           annotation.line,
           "##{k}: only #{length(many)} mutant(s) in #{unit} share #{change}"
         )}
    end
  end

  # A declaration names its change as written (`change`) or as `from` and `to`; a
  # wildcard names neither.
  defp wildcard?(%Annotation{change: nil, from: nil}), do: true
  defp wildcard?(%Annotation{}), do: false

  defp same_change?(%Annotation{change: nil, from: from, to: to}, %Mutant{} = mutant),
    do: from == mutant.from and to == mutant.to

  defp same_change?(%Annotation{change: change}, %Mutant{} = mutant),
    do: Primitive.change?(change, mutant.from, mutant.to)

  defp pinned(annotation, %Mutant{} = mutant),
    do: %{annotation | pinned: mutant.id, from: mutant.from, to: mutant.to}

  # The unit's mutants that pass `fun`, in source order.
  defp sharing(mutants, unit, fun) do
    mutants
    |> Enum.filter(&(unit in units(&1) and fun.(&1)))
    |> Enum.sort_by(&{&1.file, &1.line, &1.column, &1.id})
  end

  defp units(%Mutant{function: function} = mutant) do
    for module <- Mutant.modules(mutant),
        do: if(function, do: "#{module}.#{function}", else: module)
  end

  @doc "The unit a mutant belongs to, `Module.function/arity`, or the module for code outside a function."
  @spec unit(Mutant.t()) :: String.t()
  def unit(%Mutant{module: module, function: nil}), do: module
  def unit(%Mutant{module: module, function: function}), do: "#{module}.#{function}"

  @doc """
  An entry for a survivor, ready to paste: a YAML entry for a survivors file,
  or (`format: :md`) a declaration line for a primitive's `mutants.md`. Given
  the run's mutants (`mutants: [...]`), a declaration that several of the
  unit's mutants share carries its occurrence, `#k`.
  """
  @spec template(Mutant.t(), keyword()) :: String.t()
  def template(mutant, opts \\ [])

  def template(%Mutant{} = mutant, [{:format, :md} | opts]) do
    line = "#{unit(mutant)}: #{mutant.from} -> #{mutant.to}"
    same = &(&1.from == mutant.from and &1.to == mutant.to)

    many = sharing(Keyword.get(opts, :mutants, [mutant]), unit(mutant), same)

    case {length(many), Enum.find_index(many, &(&1.id == mutant.id))} do
      {n, k} when n > 1 and k != nil -> "#{line} ##{k + 1}"
      _ -> line
    end
  end

  def template(%Mutant{} = mutant, _opts) do
    """
    - at: #{Mutant.at(mutant)}
      operator: #{mutant.operator}
      mutation: #{inspect(Mutant.mutation(mutant))}
      sort: #{if mutant.verdict == :timeout, do: "timeout", else: "evaluation-gap"}
      reason: TODO
    """
  end
end
