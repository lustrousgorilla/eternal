defmodule Eternal do
  @moduledoc """
  This module implements bindings around what should be an eternal ETS table,
  or at least until you decide to terminate it. It works by using "bouncing"
  GenServers which come up as needed to provide an heir for the ETS table. It
  operates as follows:

  1. An ETS table is created with the provided name and options.
  2. Two GenServers are started, an `owner` and an `heir`. The ETS table is gifted
    to the `owner`, and has the `heir` set as the heir.
  3. If the `owner` crashes, the `heir` becomes the owner, and a new GenServer
    is started and assigned the role of `heir`.
  4. If an `heir` dies, we attempt to start a new GenServer and notify the `owner`
    so that they may change the assigned `heir`.

  This means that there should always be an `heir` to your table, which should
  ensure that you don't lose anything inside ETS.
  """

  # import guards
  import Eternal.Table
  import Eternal.Priv

  # alias while we're at it
  alias Eternal.Priv
  alias Eternal.Table
  alias Eternal.Supervisor, as: Sup

  # Return values of `start_link` functions
  @type on_start :: { :ok, pid } | :ignore |
                    { :error, { :already_started, pid } | { :shutdown, term } | term }

  @doc """
  Creates a new ETS table using the provided `ets_opts`.

  These options are passed through as-is, with the exception of prepending the
  `:public` and `:named_table` options. Seeing as you can't execute inside the
  GenServers, your table will have to be public to be interacted with.

  ## Options

  You may provide a third parameter containing Eternal options:

  - `:quiet` - by default, Eternal logs debug messages. Setting this to true will
    disable this logging.

  ## Examples

      iex> Eternal.new(:table1)
      { :ok, _pid1 }

      iex> Eternal.new(:table2, [ :compressed ])
      { :ok, _pid2 }

      iex> Eternal.new(:table3, [ ], [ quiet: true ])
      { :ok, _pid3 }

  """
  @spec start_link(name :: atom, ets_opts :: Keyword.t, opts :: Keyword.t) :: on_start
  def start_link(name, ets_opts \\ [], opts \\ []) when is_opts(name, ets_opts, opts) do
    Priv.exec_with { :ok, pid, _table }, create(name, [ :named_table ] ++ ets_opts, opts) do
      { :ok, pid }
    end
  end

  @doc false
  # As of v1.1, this function is deprecated and you should use `start_link/3` or
  # `start/3`. It still exists only to support semantic versioning.
  #
  # Creates a new ETS table using the provided `ets_opts`.
  #
  # These options are passed through as-is, with the exception of prepending the
  # `:public` option. Seeing as you can't execute inside the GenServers, your table
  # will have to be public to be interacted with.
  #
  # The result of the call to `:ets.new/2` is the return value of this function.
  #
  # ## Options
  #
  # You may provide a third parameter containing Eternal options:
  #
  # - `:quiet` - by default, Eternal logs debug messages. Setting this to true will
  #   disable this logging.
  #
  # ## Examples
  #
  #     iex> Eternal.new(:table1)
  #     126995
  #
  #     iex> Eternal.new(:table2, [ :named_table ])
  #     :table2
  #
  #     iex> Eternal.new(:table3, [ :named_table ], [ quiet: true ])
  #     :table3
  #
  @spec new(name :: atom, ets_opts :: Keyword.t, opts :: Keyword.t) :: Table.t
  def new(name, ets_opts \\ [], opts \\ []) when is_opts(name, ets_opts, opts) do
    Deppie.warn("Eternal.new/3 is deprecated! Please use Eternal.start_link/3 instead.")
    Priv.exec_with { :ok, pid, table }, create(name, ets_opts, opts) do
      :erlang.unlink(pid) && table
    end
  end

  @doc """
  Returns the heir of a given ETS table.

  ## Examples

      iex> Eternal.heir(:my_table)
      #PID<0.134.0>

  """
  @spec heir(table :: Table.t) :: pid | :undefined
  def heir(table) when is_table(table) do
    :ets.info(table, :heir)
  end

  @doc """
  Returns the owner of a given ETS table.

  ## Examples

      iex> Eternal.owner(:my_table)
      #PID<0.132.0>

  """
  @spec owner(table :: Table.t) :: pid | :undefined
  def owner(table) when is_table(table) do
    :ets.info(table, :owner)
  end

  @doc """
  Terminates both servers in charge of a given ETS table.

  Note: this will terminate your ETS table.

  ## Examples

      iex> Eternal.stop(:my_table)
      :ok

  """
  @spec stop(table :: Table.t) :: :ok
  def stop(table) when is_table(table) do
    name = Table.to_name(table)
    proc = GenServer.whereis(name)

    if proc && Process.alive?(proc) do
      Supervisor.stop(proc)
    end

    :ok
  end

  @doc false
  # Terminates both servers in charge of a given ETS table.
  #
  # Note: this will terminate your ETS table.
  #
  # ## Examples
  #
  #     iex> Eternal.terminate(:my_table)
  #     :ok
  #
  @spec terminate(table :: Table.t) :: :ok
  def terminate(table) when is_table(table) do
    Deppie.warn("Eternal.terminate/1 is deprecated! Please use Eternal.stop/1 instead.")
    stop(table)
  end

  # Creates a table supervisor with the provided options and nominates the children
  # as owner/heir of the ETS table immediately afterwards. We do this by fetching
  # the children of the supervisor and using the process id to nominate.
  defp create(name, ets_opts, opts) do
    Priv.exec_with { :ok, pid, table } = res, Sup.start_link(name, ets_opts, opts) do
      [ proc1, proc2 ] = Supervisor.which_children(pid)

      { _id1, pid1, :worker, [__MODULE__.Server] } = proc1
      { _id2, pid2, :worker, [__MODULE__.Server] } = proc2

      Priv.heir(table, pid2)
      Priv.gift(table, pid1)

      res
    end
  end

end
