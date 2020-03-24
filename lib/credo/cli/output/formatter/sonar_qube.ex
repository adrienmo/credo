defmodule Credo.CLI.Output.Formatter.SonarQube do
  @moduledoc false

  alias Credo.CLI.Output.Formatter.Oneline
  alias Credo.Issue

  @file_output "credo_sonarqube.json"

  def print_issues(issues) do
    map = %{"issues" => Enum.map(issues, &to_json/1)}
    output = Jason.encode!(map, pretty: true)
    File.write(@file_output, output)
    Oneline.print_issues(issues)
  end

  defp to_json(
         %Issue{
           check: check,
           category: category,
           message: message,
           filename: filename,
           priority: priority
         } = issue
       ) do
    check_name =
      check
      |> to_string()
      |> String.replace(~r/^(Elixir\.)/, "")

    _column_end =
      if issue.column && issue.trigger do
        _ = issue.column + String.length(to_string(issue.trigger))
      end

    %{
      "engineId" => "credo",
      "ruleId" => check_name,
      "severity" => get_severity(priority),
      "type" => get_type(category),
      "effortMinutes" => 90,
      "primaryLocation" => %{
        "message" => message,
        "filePath" => "backend/backend/" <> to_string(filename),
        "textRange" => %{
          "startLine" => issue.line_no
        }
      }
    }
  end

  def get_type(_category), do: "CODE_SMELL"

  def get_severity(priority) do
    cond do
      priority in 20..999 -> "CRITICAL"
      priority in 10..19 -> "MAJOR"
      priority in 0..9 -> "MINOR"
      priority in -10..-1 -> "INFO"
      priority in -999..-11 -> "INFO"
      true -> "INFO"
    end
  end
end
