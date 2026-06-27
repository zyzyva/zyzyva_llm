defmodule ZyzyvaLlm.Provider do
  @moduledoc """
  Behaviour implemented by every LLM provider.

  A provider takes a list of messages and options and returns a uniform
  success or error shape. Messages are maps with string `:role` and
  `:content` keys; `"system"` messages are handled per provider.
  """

  @type message :: %{role: String.t(), content: String.t()}
  @type opts :: keyword()

  @callback chat([message()], opts()) :: {:ok, String.t()} | {:error, term()}
end
