defmodule ZyzyvaLlm.MixProject do
  use Mix.Project

  def project do
    [
      app: :zyzyva_llm,
      version: "0.2.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Shared LLM client and model registry for zyzyva apps.",
      package: package()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto]
    ]
  end

  defp deps do
    [
      {:req, "~> 0.5"}
    ]
  end

  defp package do
    [
      licenses: ["Proprietary"],
      links: %{}
    ]
  end
end
