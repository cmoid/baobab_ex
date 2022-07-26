defmodule Baobab.Line do
  alias Baobab.Line.Validator

  @typedoc """
  A tuple referring to a specific log line

  {author, log_id, seqnum}
  """
  @type line_id :: {binary, non_neg_integer, pos_integer}

  defstruct tag: <<0>>,
            author:
              <<0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0>>,
            log_id: 0,
            seqnum: 0,
            lipmaalink: nil,
            backlink: nil,
            size: 0,
            payload_hash:
              <<0, 64, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0, 0, 0>>,
            sig:
              <<0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0>>,
            payload: ""

  def create(payload, author, log_id \\ 0) do
    %Baobab.Line{seqnum: bl} = Baobab.max_line(author, log_id) |> IO.inspect()
    seq = bl + 1
    backl = file({author, log_id, bl}, :hash)

    ll =
      case Lipmaa.linkseq(seq) do
        ^bl -> nil
        n -> file({author, log_id, n}, :hash)
      end

    size = byte_size(payload)
    payload_hash = YAMFhash.create(payload, 0)

    %Baobab.Line{
      tag: <<0>>,
      author: author,
      log_id: log_id,
      seqnum: seq,
      lipmaalink: ll,
      backlink: backl,
      size: size,
      payload_hash: payload_hash,
      payload: payload
    }
  end

  def by_id(line_id) do
    line_id
    |> file(:content)
    |> from_binary()
  end

  defp from_binary(<<tag::binary-size(1), author::binary-size(32), rest::binary>>) do
    add_logid(%Baobab.Line{tag: tag, author: author}, rest)
  end

  defp add_logid(map, bin) do
    {logid, rest} = Varu64.decode(bin)
    add_sequence_num(Map.put(map, :log_id, logid), rest)
  end

  defp add_sequence_num(map, bin) do
    {seqnum, rest} = Varu64.decode(bin)
    add_lipmaa(Map.put(map, :seqnum, seqnum), rest, seqnum)
  end

  # This needs to be extensible sooner or later
  defp add_lipmaa(map, bin, 1), do: add_size(map, bin)

  defp add_lipmaa(map, full = <<yamfh::binary-size(66), rest::binary>>, seq) do
    ll = Lipmaa.linkseq(seq)

    case ll == seq - 1 do
      true -> add_backlink(map, full, seq)
      false -> add_backlink(Map.put(map, :lipmaalink, yamfh), rest, seq)
    end
  end

  defp add_backlink(map, <<yamfh::binary-size(66), rest::binary>>, _seq) do
    add_size(Map.put(map, :backlink, yamfh), rest)
  end

  defp add_size(map, bin) do
    {size, rest} = Varu64.decode(bin)
    add_payload_hash(Map.put(map, :size, size), rest)
  end

  defp add_payload_hash(map, <<yamfh::binary-size(66), rest::binary>>) do
    add_sig(Map.put(map, :payload_hash, yamfh), rest)
  end

  defp add_sig(map, <<sig::binary-size(64), _::binary>>) do
    add_payload(Map.put(map, :sig, sig))
  end

  defp add_payload(map) do
    Validator.validate(
      Map.put(
        map,
        :payload,
        payload_file(
          {Map.fetch!(map, :author), Map.fetch!(map, :log_id), Map.fetch!(map, :seqnum)},
          :content
        )
      )
    )
  end

  @spec file(line_id, atom) :: binary | :error
  def file(line_id, which),
    do: handle_seq_file(line_id, "entry", which)

  @spec payload_file(line_id, atom) :: binary | :error
  defp payload_file(line_id, which),
    do: handle_seq_file(line_id, "payload", which)

  defp handle_seq_file({author, log_id, seq}, name, how) do
    a = BaseX.Base62.encode(author)
    s = Integer.to_string(seq)
    n = Path.join([hashed_dir({a, Integer.to_string(log_id), s}), name <> "_" <> s])

    case how do
      :name ->
        n

      :content ->
        case File.read(n) do
          {:ok, c} -> c
          _ -> :error
        end

      :hash ->
        case File.read(n) do
          {:ok, c} -> YAMFhash.create(c, 0)
          _ -> :error
        end
    end
  end

  defp hashed_dir({author, log_id, seq}) do
    {top, bot} = seq |> Blake2.hash2b(2) |> Base.encode16(case: :lower) |> String.split_at(2)
    Path.join([Baobab.log_dir(author, log_id), top, bot])
  end
end
