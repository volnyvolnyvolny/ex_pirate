defmodule ExPirate.MixProject do
  use Mix.Project

  def project do
    [
      app: :ex_pirate,
      name: "ExPirate",
      description: """
      Yo-ho-ho! `ExPirate` is a layer on top of the `AgentMap` library that
      provides TTL and statistics.
      """,
      version: "0.1.0",
      elixir: "~> 1.8",
      deps: deps(),
      docs: docs(),
      package: package()
    ]
  end

  def application, do: []

  defp docs, do: [main: "ExPirate"]

  defp package do
    [
      maintainers: ["Valentin Tumanov (Vasilev)"],
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/zergera/ex_pirate",
        "Docs" => "http://hexdocs.pm/ex_pirate"
      }
    ]
  end

  defp deps do
    [
      {:ex_doc, "~> 0.19", only: :dev, runtime: false},
      {:agent_map, "~> 1.1-rc.1"}
    ]
  end
end
