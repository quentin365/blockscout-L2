defmodule NFTMediaHandler.Dispatcher do
  use GenServer

  alias Task.Supervisor, as: TaskSupervisor
  require Logger

  def start_link(_) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def init(_) do
    Process.send(self(), :spawn_tasks, [])

    {:ok, %{max_concurrency: 10, current_concurrency: 0, batch_size: 1, waiting_timeout: 100, ref_to_batch: %{}}}
  end

  # todo: add spawn with timeout
  def handle_info(
        :spawn_tasks,
        %{max_concurrency: max_concurrency, current_concurrency: current_concurrency, ref_to_batch: tasks_map} = state
      )
      when max_concurrency > current_concurrency do
    to_spawn = max_concurrency - current_concurrency
    batch_size = batch_size()

    spawned =
      (batch_size * to_spawn)
      |> NFTMediaHandlerDispatcherInterface.get_urls()
      |> Enum.chunk_every(batch_size)
      |> Enum.map(&run_task/1)

    Process.send_after(self(), :spawn_tasks, timeout())

    {:noreply,
     %{
       state
       | current_concurrency: current_concurrency + Enum.count(spawned),
         ref_to_batch: Map.merge(tasks_map, Enum.into(spawned, %{}))
     }}
  end

  def handle_info(:spawn_tasks, state) do
    Process.send_after(self(), :spawn_tasks, timeout())
    {:noreply, state}
  end

  def handle_info({ref, _result}, %{current_concurrency: current_concurrency, ref_to_batch: tasks_map} = state) do
    Process.demonitor(ref, [:flush])
    Process.send(self(), :spawn_tasks, [])

    {:noreply, %{state | current_concurrency: current_concurrency - 1, ref_to_batch: Map.drop(tasks_map, [ref])}}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{current_concurrency: current_concurrency, ref_to_batch: tasks_map} = state
      ) do
    {url, tasks_map_updated} = Map.pop(tasks_map, ref)
    Logger.error("Failed to fetch and upload url (#{url}): #{reason}")

    NFTMediaHandlerDispatcherInterface.store_result({:down, reason}, url)
    Process.send(self(), :spawn_tasks, [])

    {:noreply, %{state | current_concurrency: current_concurrency - 1, ref_to_batch: tasks_map_updated}}
  end

  defp run_task(batch),
    do:
      {TaskSupervisor.async_nolink(NFTMediaHandler.TaskSupervisor, fn ->
         Enum.map(batch, fn url ->
           url |> NFTMediaHandler.prepare_and_upload_by_url() |> NFTMediaHandlerDispatcherInterface.store_result(url)
         end)
       end).ref, batch}

  defp batch_size(), do: 1

  def timeout, do: 100
end
