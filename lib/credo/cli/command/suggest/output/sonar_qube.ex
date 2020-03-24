defmodule Credo.CLI.Command.Suggest.Output.SonarQube do
    @moduledoc false
  
    alias Credo.CLI.Output.Formatter.SonarQube
    alias Credo.Execution
  
    def print_before_info(_source_files, _exec), do: nil
  
    def print_after_info(_source_files, exec, _time_load, _time_run) do
      exec
      |> Execution.get_issues()
      |> SonarQube.print_issues()
    end
  end
  