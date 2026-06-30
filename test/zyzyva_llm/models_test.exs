defmodule ZyzyvaLlm.ModelsTest do
  # async: false — these tests mutate global System/Application env.
  use ExUnit.Case, async: false

  alias ZyzyvaLlm.Models

  describe "model/1 built-in defaults" do
    test "text role defaults to gpt-oss-120b" do
      assert Models.model(:text) == "openai/gpt-oss-120b"
    end

    test "fast role defaults to gpt-oss-20b" do
      assert Models.model(:fast) == "openai/gpt-oss-20b"
    end

    test "search role defaults to groq/compound" do
      assert Models.model(:search) == "groq/compound"
    end
  end

  describe "model/1 vision roles" do
    test "vision role defaults to gemini-3.1-flash-lite" do
      assert Models.model(:vision) == "gemini-3.1-flash-lite"
    end

    test "vision_secondary role defaults to gemini-2.5-flash-lite" do
      assert Models.model(:vision_secondary) == "gemini-2.5-flash-lite"
    end

    test "vision_fallback role defaults to qwen/qwen3.6-27b" do
      assert Models.model(:vision_fallback) == "qwen/qwen3.6-27b"
    end

    test "ZYZYVA_LLM_VISION_MODEL overrides the vision default" do
      System.put_env("ZYZYVA_LLM_VISION_MODEL", "custom-vision-model")
      on_exit(fn -> System.delete_env("ZYZYVA_LLM_VISION_MODEL") end)

      assert Models.model(:vision) == "custom-vision-model"
    end
  end

  describe "model/1 overrides" do
    test "environment variable overrides the default" do
      System.put_env("ZYZYVA_LLM_TEXT_MODEL", "custom-text-model")
      on_exit(fn -> System.delete_env("ZYZYVA_LLM_TEXT_MODEL") end)

      assert Models.model(:text) == "custom-text-model"
    end

    test "application config overrides the default" do
      Application.put_env(:zyzyva_llm, :models, %{text: "configured-text-model"})
      on_exit(fn -> Application.delete_env(:zyzyva_llm, :models) end)

      assert Models.model(:text) == "configured-text-model"
    end

    test "environment variable beats application config" do
      Application.put_env(:zyzyva_llm, :models, %{text: "configured-text-model"})
      System.put_env("ZYZYVA_LLM_TEXT_MODEL", "env-text-model")

      on_exit(fn ->
        Application.delete_env(:zyzyva_llm, :models)
        System.delete_env("ZYZYVA_LLM_TEXT_MODEL")
      end)

      assert Models.model(:text) == "env-text-model"
    end
  end
end
