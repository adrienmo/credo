defmodule Credo.Execution do
  @moduledoc """
  Every run of Credo is configured via a `Execution` struct, which is created and
  manipulated via the `Credo.Execution` module.
  """

  @doc """
  The `Execution` struct is created and manipulated via the `Credo.Execution` module.
  """
  defstruct argv: [],
            cli_options: nil,
            cli_switches: [
              all_priorities: :boolean,
              all: :boolean,
              files_included: :keep,
              files_excluded: :keep,
              checks: :string,
              config_name: :string,
              config_file: :string,
              color: :boolean,
              crash_on_error: :boolean,
              debug: :boolean,
              enable_disabled_checks: :string,
              mute_exit_status: :boolean,
              format: :string,
              help: :boolean,
              ignore_checks: :string,
              ignore: :string,
              min_priority: :string,
              only: :string,
              read_from_stdin: :boolean,
              strict: :boolean,
              verbose: :boolean,
              version: :boolean
            ],
            cli_aliases: [
              a: :all,
              A: :all_priorities,
              c: :checks,
              C: :config_name,
              d: :debug,
              h: :help,
              i: :ignore_checks,
              v: :version
            ],
            cli_switch_plugin_param_converters: [],

            # config
            files: nil,
            color: true,
            debug: false,
            checks: nil,
            requires: [],
            plugins: [],
            parse_timeout: 5000,
            strict: false,

            # checks if there is a new version of Credo
            check_for_updates: true,

            # options, set by the command line
            min_priority: 0,
            help: false,
            version: false,
            verbose: false,
            all: false,
            format: nil,
            enable_disabled_checks: nil,
            only_checks: nil,
            ignore_checks: nil,
            crash_on_error: true,
            mute_exit_status: false,
            read_from_stdin: false,

            # state, which is accessed and changed over the course of Credo's execution
            pipeline_map: %{},
            commands: %{},
            config_files: [],
            current_task: nil,
            parent_task: nil,
            initializing_plugin: nil,
            halted: false,
            config_files_pid: nil,
            source_files_pid: nil,
            issues_pid: nil,
            timing_pid: nil,
            skipped_checks: nil,
            assigns: %{},
            results: %{},
            config_comment_map: %{}

  @type t :: %__MODULE__{}

  @execution_pipeline [
    __pre__: [
      {Credo.Execution.Task.AppendDefaultConfig, []},
      {Credo.Execution.Task.ParseOptions, []},
      {Credo.Execution.Task.ConvertCLIOptionsToConfig, []},
      {Credo.Execution.Task.InitializePlugins, []}
    ],
    parse_cli_options: [
      {Credo.Execution.Task.ParseOptions, []}
    ],
    initialize_plugins: [
      # This is where plugins can put their hooks to initialize themselves based on
      # the params given in the config as well as in their own command line switches.
    ],
    validate_cli_options: [
      {Credo.Execution.Task.ValidateOptions, []}
    ],
    convert_cli_options_to_config: [
      {Credo.Execution.Task.ConvertCLIOptionsToConfig, []}
    ],
    determine_command: [
      {Credo.Execution.Task.DetermineCommand, []}
    ],
    set_default_command: [
      {Credo.Execution.Task.SetDefaultCommand, []}
    ],
    resolve_config: [
      {Credo.Execution.Task.UseColors, []},
      {Credo.Execution.Task.RequireRequires, []}
    ],
    validate_config: [
      {Credo.Execution.Task.ValidateConfig, []}
    ],
    run_command: [
      {Credo.Execution.Task.RunCommand, []}
    ],
    halt_execution: [
      {Credo.Execution.Task.AssignExitStatusForIssues, []}
    ]
  ]

  alias Credo.Execution.ExecutionConfigFiles
  alias Credo.Execution.ExecutionIssues
  alias Credo.Execution.ExecutionSourceFiles
  alias Credo.Execution.ExecutionTiming

  @doc "Builds an Execution struct for the the given `argv`."
  def build(argv \\ []) when is_list(argv) do
    %__MODULE__{argv: argv}
    |> put_pipeline(__MODULE__, @execution_pipeline)
    |> put_builtin_command("categories", Credo.CLI.Command.Categories.CategoriesCommand)
    |> put_builtin_command("explain", Credo.CLI.Command.Explain.ExplainCommand)
    |> put_builtin_command("gen.check", Credo.CLI.Command.GenCheck)
    |> put_builtin_command("gen.config", Credo.CLI.Command.GenConfig)
    |> put_builtin_command("help", Credo.CLI.Command.Help)
    |> put_builtin_command("info", Credo.CLI.Command.Info.InfoCommand)
    |> put_builtin_command("list", Credo.CLI.Command.List.ListCommand)
    |> put_builtin_command("suggest", Credo.CLI.Command.Suggest.SuggestCommand)
    |> put_builtin_command("version", Credo.CLI.Command.Version)
    |> start_servers()
  end

  @doc false
  defp start_servers(%__MODULE__{} = exec) do
    exec
    |> ExecutionConfigFiles.start_server()
    |> ExecutionSourceFiles.start_server()
    |> ExecutionIssues.start_server()
    |> ExecutionTiming.start_server()
  end

  @doc """
  Returns the checks that should be run for a given `exec` struct.

  Takes all checks from the `checks:` field of the exec, matches those against
  any patterns to include or exclude certain checks given via the command line.
  """
  def checks(exec)

  def checks(%__MODULE__{checks: nil}) do
    {[], [], []}
  end

  def checks(%__MODULE__{checks: checks, only_checks: only_checks, ignore_checks: ignore_checks}) do
    only_matching = filter_only_checks(checks, only_checks)
    ignore_matching = filter_ignore_checks(checks, ignore_checks)
    result = only_matching -- ignore_matching

    {result, only_matching, ignore_matching}
  end

  defp filter_only_checks(checks, nil), do: checks
  defp filter_only_checks(checks, []), do: checks
  defp filter_only_checks(checks, patterns), do: filter_checks(checks, patterns)

  defp filter_ignore_checks(_checks, nil), do: []
  defp filter_ignore_checks(_checks, []), do: []
  defp filter_ignore_checks(checks, patterns), do: filter_checks(checks, patterns)

  defp filter_checks(checks, patterns) do
    regexes =
      patterns
      |> List.wrap()
      |> to_match_regexes

    Enum.filter(checks, &match_regex(&1, regexes, true))
  end

  defp match_regex(_tuple, [], default_for_empty), do: default_for_empty

  defp match_regex(tuple, regexes, _default_for_empty) do
    check_name =
      tuple
      |> Tuple.to_list()
      |> List.first()
      |> to_string

    Enum.any?(regexes, &Regex.run(&1, check_name))
  end

  defp to_match_regexes(list) do
    Enum.map(list, fn match_check ->
      {:ok, match_pattern} = Regex.compile(match_check, "i")
      match_pattern
    end)
  end

  @doc """
  Sets the exec values which `strict` implies (if applicable).
  """
  def set_strict(exec)

  def set_strict(%__MODULE__{strict: true} = exec) do
    %__MODULE__{exec | all: true, min_priority: -99}
  end

  def set_strict(%__MODULE__{strict: false} = exec) do
    %__MODULE__{exec | min_priority: 0}
  end

  def set_strict(exec), do: exec

  @doc false
  def get_path(exec) do
    exec.cli_options.path
  end

  # Commands

  @doc "Returns the name of the command, which should be run by the given execution."
  def get_command_name(exec) do
    exec.cli_options.command
  end

  @doc "Returns all valid command names."
  def get_valid_command_names(exec) do
    Map.keys(exec.commands)
  end

  def get_command(exec, name) do
    Map.get(exec.commands, name) ||
      raise ~S'Command not found: "#{name}"\n\nRegistered commands: #{
              inspect(exec.commands, pretty: true)
            }'
  end

  @doc false
  def put_command(exec, _plugin_mod, name, command_mod) do
    commands = Map.put(exec.commands, name, command_mod)

    %__MODULE__{exec | commands: commands}
    |> init_command(command_mod)
  end

  @doc false
  def set_initializing_plugin(%__MODULE__{initializing_plugin: nil} = exec, plugin_mod) do
    %__MODULE__{exec | initializing_plugin: plugin_mod}
  end

  def set_initializing_plugin(exec, nil) do
    %__MODULE__{exec | initializing_plugin: nil}
  end

  def set_initializing_plugin(%__MODULE__{initializing_plugin: mod1}, mod2) do
    raise "Attempting to initialize plugin #{inspect(mod2)}, " <>
            "while already initializing plugin #{mod1}"
  end

  # Plugin params

  def get_plugin_param(exec, plugin_mod, param_name) do
    exec.plugins[plugin_mod][param_name]
  end

  def put_plugin_param(exec, plugin_mod, param_name, param_value) do
    plugins =
      Keyword.update(exec.plugins, plugin_mod, [], fn list ->
        Keyword.update(list, param_name, param_value, fn _ -> param_value end)
      end)

    %__MODULE__{exec | plugins: plugins}
  end

  # CLI switches

  @doc false
  def put_cli_switch(exec, _plugin_mod, name, type) do
    %__MODULE__{exec | cli_switches: exec.cli_switches ++ [{name, type}]}
  end

  @doc false
  def put_cli_switch_alias(exec, _plugin_mod, name, alias_name) do
    %__MODULE__{exec | cli_aliases: exec.cli_aliases ++ [{alias_name, name}]}
  end

  @doc false
  def put_cli_switch_plugin_param_converter(exec, plugin_mod, cli_switch_name, plugin_param_name) do
    converter_tuple = {cli_switch_name, plugin_mod, plugin_param_name}

    %__MODULE__{
      exec
      | cli_switch_plugin_param_converters:
          exec.cli_switch_plugin_param_converters ++ [converter_tuple]
    }
  end

  def get_given_cli_switch(exec, switch_name) do
    if Map.has_key?(exec.cli_options.switches, switch_name) do
      {:ok, exec.cli_options.switches[switch_name]}
    else
      :error
    end
  end

  # Assigns

  @doc "Returns the assign with the given `name` for the given `exec` struct (or return the given `default` value)."
  def get_assign(exec, name, default \\ nil) do
    Map.get(exec.assigns, name, default)
  end

  @doc "Puts the given `value` with the given `name` as assign into the given `exec` struct."
  def put_assign(exec, name, value) do
    %__MODULE__{exec | assigns: Map.put(exec.assigns, name, value)}
  end

  # Config Files

  @doc "Returns all config files for the given `exec` struct."
  def get_config_files(exec) do
    Credo.Execution.ExecutionConfigFiles.get(exec)
  end

  @doc false
  def append_config_file(exec, {_, _, _} = config_file) do
    config_files = get_config_files(exec) ++ [config_file]

    ExecutionConfigFiles.put(exec, config_files)

    exec
  end

  # Source Files

  @doc "Returns all source files for the given `exec` struct."
  def get_source_files(exec) do
    Credo.Execution.ExecutionSourceFiles.get(exec)
  end

  @doc "Puts the given `source_files` into the given `exec` struct."
  def put_source_files(exec, source_files) do
    ExecutionSourceFiles.put(exec, source_files)

    exec
  end

  # Issues

  @doc "Returns all issues for the given `exec` struct."
  def get_issues(exec) do
    exec
    |> ExecutionIssues.to_map()
    |> Map.values()
    |> List.flatten()
  end

  @doc "Returns all issues for the given `exec` struct that relate to the given `filename`."
  def get_issues(exec, filename) do
    exec
    |> ExecutionIssues.to_map()
    |> Map.get(filename, [])
  end

  @doc "Sets the issues for the given `exec` struct, overwriting any existing issues."
  def set_issues(exec, issues) do
    ExecutionIssues.set(exec, issues)

    exec
  end

  # Results

  @doc "Returns the result with the given `name` for the given `exec` struct (or return the given `default` value)."
  def get_result(exec, name, default \\ nil) do
    Map.get(exec.results, name, default)
  end

  @doc "Puts the given `value` with the given `name` as result into the given `exec` struct."
  def put_result(exec, name, value) do
    %__MODULE__{exec | results: Map.put(exec.results, name, value)}
  end

  # Halt

  @doc "Halts further execution of the pipeline."
  def halt(exec) do
    %__MODULE__{exec | halted: true}
  end

  # Task tracking

  @doc false
  def set_parent_and_current_task(exec, parent_task, current_task) do
    %__MODULE__{exec | parent_task: parent_task, current_task: current_task}
  end

  # Running tasks

  @doc false
  def run(exec) do
    run_pipeline(exec, __MODULE__)
  end

  @doc false
  def run_pipeline(initial_exec, pipeline_key) do
    initial_pipeline = get_pipeline(initial_exec, pipeline_key)

    Enum.reduce(initial_pipeline, initial_exec, fn {group_name, _list}, outer_exec ->
      outer_pipeline = get_pipeline(outer_exec, pipeline_key)
      task_group = outer_pipeline[group_name]

      Enum.reduce(task_group, outer_exec, fn {task_mod, opts}, inner_exec ->
        Credo.Execution.Task.run(task_mod, inner_exec, opts)
      end)
    end)
  end

  @doc false
  defp get_pipeline(exec, pipeline_key) do
    case exec.pipeline_map[pipeline_key] do
      nil -> raise "Could not find execution pipeline for '#{pipeline_key}'"
      pipeline -> pipeline
    end
  end

  def put_pipeline(exec, pipeline_key, pipeline) do
    new_pipelines = Map.put(exec.pipeline_map, pipeline_key, pipeline)

    %__MODULE__{exec | pipeline_map: new_pipelines}
  end

  @doc false
  def prepend_task(exec, plugin_mod, nil, group_name, task_tuple) do
    prepend_task(exec, plugin_mod, __MODULE__, group_name, task_tuple)
  end

  def prepend_task(exec, plugin_mod, pipeline_key, group_name, task_mod) when is_atom(task_mod) do
    prepend_task(exec, plugin_mod, pipeline_key, group_name, {task_mod, []})
  end

  @doc false
  def prepend_task(exec, _plugin_mod, pipeline_key, group_name, task_tuple) do
    pipeline =
      exec
      |> get_pipeline(pipeline_key)
      |> Enum.map(fn
        {^group_name, list} -> {group_name, [task_tuple] ++ list}
        value -> value
      end)

    put_pipeline(exec, __MODULE__, pipeline)
  end

  @doc false
  def append_task(exec, plugin_mod, nil, group_name, task_tuple) do
    append_task(exec, plugin_mod, __MODULE__, group_name, task_tuple)
  end

  def append_task(exec, plugin_mod, pipeline_key, group_name, task_mod) when is_atom(task_mod) do
    append_task(exec, plugin_mod, pipeline_key, group_name, {task_mod, []})
  end

  @doc false
  def append_task(exec, _plugin_mod, pipeline_key, group_name, task_tuple) do
    pipeline =
      exec
      |> get_pipeline(pipeline_key)
      |> Enum.map(fn
        {^group_name, list} -> {group_name, list ++ [task_tuple]}
        value -> value
      end)

    put_pipeline(exec, pipeline_key, pipeline)
  end

  defp put_builtin_command(exec, name, command_mod) do
    put_command(exec, Credo, name, command_mod)
  end

  defp init_command(exec, command_mod) do
    exec
    |> command_mod.init()
    |> ensure_execution_struct("#{command_mod}.init/1")
  end

  @doc ~S"""
  Ensures that the given `value` is a `%Credo.Execution{}` struct, raises an error otherwise.

  Example:

      exec
      |> mod.init()
      |> Execution.ensure_execution_struct("#{mod}.init/1")
  """
  def ensure_execution_struct(value, fun_name)

  def ensure_execution_struct(%__MODULE__{} = exec, _fun_name), do: exec

  def ensure_execution_struct(value, fun_name) do
    raise("Expected #{fun_name} to return %Credo.Execution{}, got: #{inspect(value)}")
  end
end
