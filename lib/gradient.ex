defmodule Gradient do
  @moduledoc """
  Documentation for `Gradient`.
  """

  alias Gradient.ElixirFileUtils
  alias Gradient.ElixirFmt
  alias Gradient.AstSpecifier
  alias Gradient.ElixirChecker

  require Logger

  @typedoc """
  - `app_path` - Path to the app that contains file with code (for umbrella apps).
  - `source_path` - Path to a file with code (e.g. when beam was compiled without project).
  - `no_gradualizer_check` - Skip Gradualizer checks if true.
  - `no_ex_check` - Skip Elixir checks if true.
  - `no_specify` - Skip AST specifying if true.
  """
  @type options() :: [
          app_path: String.t(),
          source_path: String.t(),
          no_gradualizer_check: boolean(),
          no_ex_check: boolean(),
          no_specify: boolean()
        ]

  @doc """
  Type-checks file in `path` with provided `opts`, and prints the result.
  """
  @spec type_check_file(String.t(), options()) :: :ok | {:error, list()}
  def type_check_file(path, opts \\ []) do
    opts = Keyword.put(opts, :return_errors, true)
    module = Keyword.get(opts, :module, "all_modules")

    with {:ok, asts} <- ElixirFileUtils.get_forms(path, module),
         {:ok, first_ast} <- get_first_forms(asts),
         {:elixir, _} <- wrap_language_name(first_ast) do
      asts
      |> Enum.map(fn module_forms ->
        single_module_forms = maybe_specify_forms(module_forms, opts)

        case maybe_gradient_check(single_module_forms, opts) ++
               maybe_gradualizer_check(single_module_forms, opts) do
          [] ->
            :ok

          errors ->
            opts = Keyword.put(opts, :forms, single_module_forms)
            ElixirFmt.print_errors(errors, opts)

            {:error, errors}
        end
      end)
    else
      {:erlang, forms} ->
        case maybe_gradualizer_check(forms, opts) do
          [] ->
            :ok

          errors ->
            opts = Keyword.put(opts, :forms, forms)
            ElixirFmt.print_errors(errors, opts)
            {:error, errors}
        end

      {:error, :module_not_found} ->
        Logger.error("Can't find module specified by '--module' flag.")
        {:error, [{:module_not_found, module}]}

      error ->
        Logger.error("Can't load file - #{inspect(error)}")
        {:error, [error]}
    end
  end

  defp maybe_gradualizer_check(forms, opts) do
    opts = Keyword.put(opts, :return_errors, true)

    unless opts[:no_gradualizer_check] do
      try do
        :gradualizer.type_check_forms(forms, opts)
      catch
        err ->
          {:attribute, _, :file, {path, _}} = hd(forms)
          [{path, err}]
      end
    else
      []
    end
  end

  defp maybe_gradient_check(forms, opts) do
    unless opts[:no_ex_check] do
      ElixirChecker.check(forms, opts)
    else
      []
    end
  end

  defp maybe_specify_forms(forms, opts) do
    unless opts[:no_specify] do
      forms
      |> put_source_path(opts)
      |> AstSpecifier.specify()
    else
      forms
    end
  end

  defp wrap_language_name([{:attribute, _, :file, {file_name, _}} | _] = forms) do
    if :string.str(file_name, '.erl') > 0 do
      {:erlang, forms}
    else
      {:elixir, forms}
    end
  end

  defp put_source_path(forms, opts) do
    case opts[:source_path] do
      nil ->
        case opts[:app_path] do
          nil ->
            forms

          app_path ->
            {:attribute, anno, :file, {path, line}} = hd(forms)

            [
              {:attribute, anno, :file, {String.to_charlist(app_path) ++ '/' ++ path, line}}
              | tl(forms)
            ]
        end

      path ->
        [{:attribute, 1, :file, {path, 1}} | tl(forms)]
    end
  end

  defp get_first_forms(forms) do
    forms
    |> List.first()
    |> case do
      nil -> {:error, :module_not_found}
      forms -> {:ok, forms}
    end
  end
end
