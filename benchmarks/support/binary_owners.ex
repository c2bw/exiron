defmodule Exiron.Benchmarks.BinaryOwners do
  @moduledoc false

  # Counts referenced buffers, never their contents. References shared between
  # processes are deduplicated globally; per-process totals must not be summed.
  # This is a concurrent sample, not an atomic heap/allocator snapshot.
  def snapshot(pids \\ Process.list()) do
    owners =
      Enum.flat_map(pids, fn pid ->
        try do
          case Process.info(pid, [
                 :binary,
                 :registered_name,
                 :current_function,
                 :memory,
                 :message_queue_len
               ]) do
            info when is_list(info) ->
              binaries = Map.new(info[:binary], fn {id, bytes, _refs} -> {id, bytes} end)

              if map_size(binaries) == 0 do
                []
              else
                [
                  {%{
                     pid: inspect(pid),
                     registered_name: inspect(info[:registered_name]),
                     initial_call: inspect(:proc_lib.translate_initial_call(pid)),
                     current_function: inspect(info[:current_function]),
                     process_bytes: info[:memory],
                     mailbox: info[:message_queue_len],
                     referenced_bytes: Enum.sum(Map.values(binaries)),
                     binary_count: map_size(binaries),
                     largest_binary_bytes: Enum.max(Map.values(binaries))
                   }, binaries}
                ]
              end

            nil ->
              []
          end
        rescue
          ArgumentError -> []
        catch
          :exit, _reason -> []
        end
      end)

    unique = Enum.reduce(owners, %{}, fn {_owner, binaries}, acc -> Map.merge(acc, binaries) end)

    %{
      unique_referenced_bytes: Enum.sum(Map.values(unique)),
      unique_binary_count: map_size(unique),
      owners_with_binaries: length(owners),
      top_owners:
        owners
        |> Enum.map(&elem(&1, 0))
        |> Enum.sort_by(& &1.referenced_bytes, :desc)
        |> Enum.take(12)
    }
  end
end
