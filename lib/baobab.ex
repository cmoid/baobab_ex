defmodule Baobab do
  @moduledoc """
  Baobab is a pure Elixir implementation of the 
  [Bamboo](https://github.com/AljoschaMeyer/bamboo) append-only log.

  It is fairly opinionated about the DETS persistence of the logs.
  They are considered to be a spool of the logs as retreived.

  Consumers of this library may wish to place a local copy of the logs in
  a store with better indexing and query properties.

  ### Configuration

  config :baobab, spool_dir: "/tmp"

  ### Options

  - `format`: `:entry` or `:binary`, default: `:entry`
  - `log_id`: the author's log identifier, default `0`
  - `revalidate`: confirm the store contents are unchanged, default: `false`
  - `replace`: rewrite log contents even if it exists, default: `false`
  """

  BaseX.prepare_module(
    "Base62",
    "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz",
    32
  )

  @defaults %{format: :entry, log_id: 0, revalidate: false, replace: false}

  @doc false
  def optvals(opts, keys), do: optvals(opts, keys, [])
  def optvals(_, [], acc), do: Enum.reverse(acc) |> List.to_tuple()

  def optvals(opts, [k | rest], acc),
    do: optvals(opts, rest, [Keyword.get(opts, k, @defaults[k]) | acc])

  @doc """
  Create and store a new log entry for a stored identity
  """
  def append_log(payload, identity, options \\ []) do
    {log_id} = options |> optvals([:log_id])
    Baobab.Entry.create(payload, identity, log_id)
  end

  @doc """
  Compact log contents to only items in the certificate pool for
  the latest entry.  This allows validation while reducing space used
  """
  def compact(author, options \\ []) do
    a = author |> b62identity
    {log_id} = options |> optvals([:log_id])

    case all_seqnum(a, options) do
      [] ->
        []

      entries ->
        last = List.last(entries)
        pool = certificate_pool(a, last, log_id) |> MapSet.new()
        eset = entries |> MapSet.new()

        for e <- MapSet.difference(eset, pool) do
          {Baobab.Entry.delete(a, e, log_id), e}
        end
    end
  end

  @doc """
  Import and store a list of log entries from their binary format.
  """
  @spec import([binary]) :: [%Baobab.Entry{} | {:error, String.t()}]
  def import(binaries, options \\ [])

  def import(binaries, options) when is_list(binaries) do
    {replace} = options |> optvals([:replace])
    do_import(binaries, replace, [])
  end

  def import(_, _), do: [{:error, "Import requires a list of Baobab.Entry structs"}]
  defp do_import([], _, acc), do: Enum.reverse(acc)

  defp do_import([binary | rest], overwrite, acc) do
    result =
      case binary |> Baobab.Entry.from_binary(false) do
        {:error, _} = error ->
          error

        entry ->
          Baobab.Entry.store(entry, overwrite)
      end

    do_import(rest, overwrite, [result | acc])
  end

  @doc """
  Retrieve the latest entry.

  Includes the available certificate pool for its verification.
  """
  def latest_log(author, options \\ []) do
    author |> b62identity |> log_at(max_seqnum(author, options), options)
  end

  @doc """
  Retrieve an author log at a particular sequence number.

  Includes the available certificate pool for its verification.
  """
  def log_at(author, seq, options \\ []) do
    ak = author |> b62identity
    {_, log_id, _} = opts = options |> optvals([:format, :log_id, :revalidate])

    certificate_pool(ak, seq, log_id)
    |> Enum.reverse()
    |> Enum.map(fn n -> Baobab.Entry.retrieve(ak, n, opts) end)
  end

  @doc """
  Purges a given log.

  `:all` may be specified for `author` and/or the `log_id` option.
  Specifying both effectively clears the entire store.

  Returns `Baobab.stored_info/0`

  ## Examples

  iex> Baobab.purge(:all, log_id: :all)
  []

  """
  def purge(author, options \\ []) do
    case {author, optvals(options, [:log_id])} do
      {:all, {:all}} -> spool(:content, :truncate)
      {:all, {n}} -> spool(:content, :match_delete, {:_, n, :_})
      {author, {:all}} -> spool(:content, :match_delete, {author |> b62identity, :_, :_})
      {author, {n}} -> spool(:content, :match_delete, {author |> b62identity, n, :_})
    end

    Baobab.stored_info()
  end

  @doc """
  Retrieve all available entries in a particular log
  """
  def full_log(author, options \\ []) do
    opts = options |> optvals([:format, :log_id, :revalidate])

    author |> b62identity |> gather_all_entries(opts, max_seqnum(author, options), [])
  end

  defp gather_all_entries(_, _, 0, acc), do: acc

  defp gather_all_entries(author, opts, n, acc) do
    newacc =
      case Baobab.Entry.retrieve(author, n, opts) do
        :error -> acc
        entry -> [entry | acc]
      end

    gather_all_entries(author, opts, n - 1, newacc)
  end

  @doc false
  def certificate_pool(author, seq, log_id) do
    max = max_seqnum(author, log_id: log_id)
    seq |> Lipmaa.cert_pool() |> Enum.reject(fn n -> n > max end)
  end

  @doc """
  Retrieve the latest sequence number on a particular log identified by the
  author key and log number
  """
  def max_seqnum(author, options \\ []) do
    case all_seqnum(author, options) |> List.last() do
      nil -> 0
      max -> max
    end
  end

  @doc """
  Retrieve the list of  sequence numbers on a particular log identified by the
  author key and log number
  """
  def all_seqnum(author, options \\ []) do
    auth = author |> b62identity

    {log_id} = options |> optvals([:log_id])

    :content
    |> spool(:match, {auth, log_id, :"$1"})
    |> List.flatten()
    |> Enum.sort()
  end

  @doc """
  Retrieve the latest entry on a particular log identified by the
  author key and log number
  """
  def max_entry(author, options \\ [])

  def max_entry(author, options) do
    opts = options |> optvals([:format, :log_id, :revalidate])
    author |> b62identity |> Baobab.Entry.retrieve(max_seqnum(author, options), opts)
  end

  @doc """
  Create and store a new identity

  An optional secret key to be associated with the identity may provided, either
  raw or base62 encoded. The public key will be derived therefrom.

  """
  def create_identity(identity, secret_key \\ nil) do
    # This is just unrolling how Ed25519 works
    secret =
      case secret_key do
        nil -> :crypto.strong_rand_bytes(32)
        <<raw::binary-size(32)>> -> raw
        <<b62::binary-size(43)>> -> BaseX.Base62.decode(b62)
      end

    pair = {secret, Ed25519.derive_public_key(secret)}
    spool(:identity, :put, {identity, pair})
    elem(pair, 1) |> b62identity
  end

  @doc """
  A list of {author, log_id, max_seqnum} tuples in the configured store
  """
  # This is all crazy inefficient, but I will clean it up at some
  # point in the future if I care enough.
  def stored_info(), do: stored_info(logs(), [])

  defp stored_info([], acc), do: acc |> Enum.sort()

  defp stored_info([{a, l} | rest], acc) do
    a =
      case max_seqnum(a, log_id: l) do
        0 -> acc
        n -> [{a, l, n} | acc]
      end

    stored_info(rest, a)
  end

  defp logs do
    :content
    |> spool(:foldl, fn item, acc ->
      case item do
        {{a, l, _}, _} -> [{a, l} | acc]
        _ -> acc
      end
    end)
    |> Enum.uniq()
  end

  @doc """
  Retrieve the key for a stored identity.

  Can be either the `:public` or `:secret` key
  """
  def identity_key(identity, which) do
    case spool(:identity, :get, identity) do
      {secret, public} ->
        case which do
          :secret -> secret
          :public -> public
          _ -> :error
        end

      _ ->
        :error
    end
  end

  @doc false
  defp spool(which, action, value \\ nil) do
    spool_store(which, :open)
    retval = spool_act(which, action, value)
    spool_store(which, :close)
    retval
  end

  defp spool_act(which, :get, key) do
    case :dets.lookup(which, key) do
      [{^key, val} | _] -> val
      [] -> nil
    end
  end

  defp spool_act(which, :foldl, fun), do: :dets.foldl(fun, [], which)
  defp spool_act(which, :delete, key), do: :dets.delete(which, key)
  defp spool_act(which, :put, kv), do: :dets.insert(which, kv)
  defp spool_act(which, :truncate, _), do: :dets.delete_all_objects(which)

  defp spool_act(which, :match_delete, key_pattern),
    do: :dets.match_delete(which, {key_pattern, :_})

  defp spool_act(which, :match, key_pattern),
    do: :dets.match(which, {key_pattern, :_})

  defp spool_store(which, :open),
    do: {:ok, ^which} = :dets.open_file(which, file: proper_db_path(which))

  defp spool_store(which, :close), do: :dets.close(which)

  @doc false
  def manage_content_store(entry_id, {name, how}),
    do: manage_content_store(entry_id, {name, how, nil})

  def manage_content_store({author, log_id, seq}, {name, how, content}) do
    spool_store(:content, :open)
    key = {author |> Baobab.b62identity(), log_id, seq}
    curr = spool_act(:content, :get, key)

    actval =
      case {how, curr} do
        {:delete, nil} ->
          :ok

        {:delete, _} ->
          spool_act(:content, :delete, key)

        {:contents, nil} ->
          :error

        {:contents, map} ->
          case name do
            :both -> {Map.get(map, :entry, :error), Map.get(map, :payload, :error)}
            key -> Map.get(map, key, :error)
          end

        {:hash, %{^name => c}} ->
          YAMFhash.create(c, 0)

        {:write, prev} ->
          case name do
            :both ->
              {entry, payload} = content

              spool_act(:content, :put, {key, %{:entry => entry, :payload => payload}})

            map_key ->
              map = if is_nil(prev), do: %{}, else: prev
              spool_act(:content, :put, {key, Map.merge(map, %{map_key => content})})
          end

        {:exists, nil} ->
          false

        {:exists, _} ->
          true

        {_, _} ->
          :error
      end

    spool_store(:content, :close)
    actval
  end

  defp proper_db_path(which) do
    file = Atom.to_string(which) <> ".dets"
    dir = Application.fetch_env!(:baobab, :spool_dir) |> Path.expand()
    Path.join([dir, file]) |> to_charlist
  end

  @doc """
  Resolve an identity to its Base62 representation
  """
  # Looks like a base62-encoded key
  def b62identity(author) when byte_size(author) == 43, do: author
  # Looks like a proper key
  def b62identity(author) when byte_size(author) == 32, do: BaseX.Base62.encode(author)
  # I guess it's a stored identity?
  def b62identity(author) do
    case identity_key(author, :public) do
      :error -> raise "Cannot resolve author: " <> author
      key -> BaseX.Base62.encode(key)
    end
  end
end
