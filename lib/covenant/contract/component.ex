defmodule Covenant.Contract.Section do
  @moduledoc "A `##` section of an intent or obligations file: title, line and body text."

  @type t :: %__MODULE__{title: String.t(), line: pos_integer(), body: String.t()}

  @enforce_keys [:title, :line, :body]
  defstruct [:title, :line, :body]
end

defmodule Covenant.Contract.Component do
  @moduledoc """
  One component of the Contract: its intent (heavy form) or obligations file
  (light form), the obligations declared in it and the decision records that
  belong to it.

  Component ids are `<app>.<component>` and are derived from the file path
  inside the contracts directory. `billing/invoices.intent.md` and
  `billing.invoices/intent.md` both declare `billing.invoices`. Nested
  component directories add id segments. The whole-product `system/intent.md`
  is the component `system`, with form `:system`. A primitive of the sibling layout
  (`contract/calc/README.md`, see `Covenant.Parser.Primitive`) is the component
  `calc`, with form `:primitive`, app `"contract"` and the references of its
  `covers` block in `covers`.

  A file may open with YAML front matter (`---` ... `---`); its keys land in
  `meta`. The convention uses `modules:` there to declare the implementation
  modules of a component when they cannot be derived from the Public surface
  and the obligations' `scope` (see `Covenant.Mutate.Modules`).
  """

  alias Covenant.Contract.{Obligation, Record, Section}

  @type form :: :heavy | :light | :system | :primitive

  @type t :: %__MODULE__{
          id: String.t(),
          app: String.t(),
          name: String.t(),
          form: form(),
          file: String.t(),
          purpose: String.t() | nil,
          sections: [Section.t()],
          obligations: [Obligation.t()],
          records: [Record.t()],
          records_file: String.t() | nil,
          meta: %{optional(String.t()) => term()},
          covers: [Covenant.Covers.t()]
        }

  @enforce_keys [:id, :app, :name, :form, :file]
  defstruct [
    :id,
    :app,
    :name,
    :form,
    :file,
    :purpose,
    :records_file,
    sections: [],
    obligations: [],
    records: [],
    meta: %{},
    covers: []
  ]

  @doc "Finds a `##` section by exact title."
  @spec section(t(), String.t()) :: Section.t() | nil
  def section(%__MODULE__{sections: sections}, title),
    do: Enum.find(sections, &(&1.title == title))

  @doc "Obligations that are active promises (not retired, not exceptions)."
  @spec testable_obligations(t()) :: [Obligation.t()]
  def testable_obligations(%__MODULE__{obligations: obligations}),
    do: Enum.filter(obligations, &Obligation.testable?/1)

  @doc "The implementation modules declared in the front matter (`modules:`), as strings."
  @spec declared_modules(t()) :: [String.t()]
  def declared_modules(%__MODULE__{meta: meta}), do: List.wrap(meta["modules"])

  @doc "Active `kind: exception` declarations."
  @spec exceptions(t()) :: [Obligation.t()]
  def exceptions(%__MODULE__{obligations: obligations}),
    do: Enum.filter(obligations, &(Obligation.exception?(&1) and Obligation.active?(&1)))
end
