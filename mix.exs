defmodule Covenant.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/tools4imps/covenant"

  def project do
    [
      app: :covenant,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      # The fixture project under test/fixtures has its own tests; they run
      # from inside it (see test/contract/covenant/tasks), not as ours.
      test_load_filters: [
        &(String.ends_with?(&1, "_test.exs") and not String.starts_with?(&1, "test/fixtures/"))
      ],
      test_ignore_filters: [&String.starts_with?(&1, "test/fixtures/")],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      name: "Covenant",
      source_url: @source_url,
      homepage_url: @source_url
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:yaml_elixir, "~> 2.12"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp description do
    "The Contract layer of Impatient Programming for Elixir: intent documents, " <>
      "decision records, obligation-tagged contract tests, contract coverage, " <>
      "regeneration packs and mutation testing credited to obligations."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Impatient Programming" => "https://impatientprogramming.org"
      },
      files: ~w(lib docs .formatter.exs mix.exs README.md LICENSE CHANGELOG.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      source_ref: "v#{@version}",
      extras: [
        "README.md",
        "CHANGELOG.md",
        "docs/contract-convention.md",
        "docs/development-mutation.md"
      ]
    ]
  end
end
