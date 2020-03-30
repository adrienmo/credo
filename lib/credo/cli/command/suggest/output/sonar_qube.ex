defmodule Credo.CLI.Command.Suggest.Output.SonarQube do
    @moduledoc false
  
    alias Credo.CLI.Options
    alias Credo.CLI.Output.Formatter.SonarQube
    alias Credo.Execution
  
    def print_before_info(_source_files, _exec), do: nil
  
    def print_after_info(_source_files, exec, _time_load, _time_run) do
      base_folder = extract_base_folder(exec)
      export_file_name = extract_export_file_name(exec)
      exec
      |> Execution.get_issues()
      |> SonarQube.print_issues(base_folder, export_file_name)
    end

    defp extract_base_folder(%Execution{cli_options: %Options{switches: %{base_folder: base_folder}}}) when is_bitstring(base_folder) do
      base_folder
    end

    defp extract_base_folder(_exec), do: ""

    defp extract_export_file_name(%Execution{cli_options: %Options{switches: %{export_file_name: export_file_name}}}) when is_bitstring(export_file_name) do
      export_file_name
    end

    defp extract_export_file_name(_exec), do: nil
  end
  