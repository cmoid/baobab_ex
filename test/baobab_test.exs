defmodule BaobabTest do
  use ExUnit.Case
  doctest Baobab

  # I do not see the case for a config variable for this
  @export_dir "/tmp/bao_text_export"

  setup do
    spool = Application.fetch_env!(:baobab, :spool_dir) |> Path.expand()
    File.mkdir_p(Path.join([spool, "default"]))

    on_exit(fn ->
      File.rm_rf(spool)
      File.rm_rf(@export_dir)
    end)
  end

  test "import remote" do
    remote_entry = File.read!("test/remote_entry")

    [local_entry | _] = Baobab.Interchange.import_binaries(remote_entry)

    assert %Baobab.Entry{seqnum: 1, log_id: 0, size: 33, tag: <<0>>} = local_entry
    author = local_entry.author

    assert local_entry == Baobab.log_entry(author, :max)
    assert remote_entry == Baobab.log_entry(author, :max, format: :binary)
    assert [{"7nzwZrUYdugEt4WH8FRuWLPekR4MFzrRauIudDhmBmG", 0, 1}] = Baobab.stored_info()
    assert "4XwOPI3gAo" == Baobab.current_hash(:content)
    assert "1MxoSSY9hs" == Baobab.current_hash(:identity)
    assert ["default"] == Baobab.clumps()

    # More interchange stuff might as well do it here
    # We demand at least one identity, so...
    Baobab.Identity.create("rando")
    idhash = Baobab.current_hash(:identity)
    assert @export_dir == Baobab.Interchange.export_store(@export_dir)
    assert [] == Baobab.purge(:all, log_id: :all)
    refute "4XwOPI3gAo" == Baobab.current_hash(:content)
    Baobab.Identity.drop("rando")
    assert "1MxoSSY9hs" == Baobab.current_hash(:identity)
    assert :ok == Baobab.Interchange.import_store(@export_dir)
    assert "4XwOPI3gAo" == Baobab.current_hash(:content)
    assert idhash == Baobab.current_hash(:identity)
  end

  test "local use" do
    b62author = Baobab.Identity.create("testy")
    root = Baobab.append_log("An entry for testing", "testy")
    assert %Baobab.Entry{seqnum: 1, log_id: 0} = root

    assert %Baobab.Entry{seqnum: 2, log_id: 0} =
             Baobab.append_log("A second entry for testing", "testy")

    assert root == Baobab.log_entry("testy", 1, revalidate: true)

    other_root = Baobab.append_log("A whole new log!", "testy", log_id: 1)
    assert %Baobab.Entry{seqnum: 1, log_id: 1} = other_root
    assert other_root == Baobab.log_entry("testy", 1, log_id: 1)

    <<short::binary-size(5), _::binary>> = b62author
    assert b62author == Baobab.Identity.as_base62("~" <> short)

    assert Baobab.full_log(b62author) |> Enum.count() == 2
    assert Baobab.full_log(b62author, log_id: 1) == [other_root]

    for n <- 3..14 do
      assert %Baobab.Entry{seqnum: ^n, log_id: 0} =
               Baobab.append_log("Entry: " <> Integer.to_string(n), "testy")
    end

    author_key = Baobab.Identity.key("testy", :public)
    partial = Baobab.log_at(b62author, 5, format: :binary)
    assert Enum.count(partial) == 8
    latest = Baobab.log_at(author_key, :max, revalidate: true)
    assert Enum.count(latest) == 4
    full = Baobab.full_log(author_key, log_id: 0)
    assert Enum.count(full) == 14
    assert %Baobab.Entry{payload: "Entry: 6"} = Baobab.log_entry(author_key, 6)

    assert [^root | _] = Baobab.Interchange.import_binaries(partial)
    assert [^root | _] = latest
    assert [^root | _] = full

    assert Baobab.max_seqnum("testy", log_id: 0) == 14
    assert Baobab.max_seqnum("testy", log_id: 1) == 1

    assert [{^b62author, 0, 14}, {^b62author, 1, 1}] = Baobab.stored_info()
    assert Baobab.log_range(b62author, {2, 14}) |> length() == 13

    assert [
             {:ok, 2},
             {:ok, 3},
             {:ok, 5},
             {:ok, 6},
             {:ok, 7},
             {:ok, 8},
             {:ok, 9},
             {:ok, 10},
             {:ok, 11},
             {:ok, 12}
           ] = Baobab.compact("testy")

    assert :error = Baobab.log_entry("testy", 2)
    assert [{^b62author, 0, 14}, {^b62author, 1, 1}] = Baobab.stored_info()

    assert Baobab.log_range(b62author, {2, 14}) |> length() == 3
    assert Baobab.all_entries() |> length() == 5
  end

  test "identity management" do
    b62id = Baobab.Identity.create("first_id")
    sk = Baobab.Identity.key("first_id", :secret)
    assert b62id == Baobab.Identity.create("first_dupe", sk)
    assert b62id == Baobab.Identity.create("first_dupe", BaseX.Base62.encode(sk))
    assert 2 == Enum.count(Baobab.Identity.list())

    assert b62id == Baobab.Identity.key("first_dupe", :public) |> Baobab.Identity.as_base62()
    assert b62id == Baobab.Identity.rename("first_dupe", "final_id")
    assert :error == Baobab.Identity.key("first_dupe", :public)

    assert :ok == Baobab.Identity.drop("final_id")
    assert :error == Baobab.Identity.key("final_id", :public)
    assert [{"first_id", _}] = Baobab.Identity.list()
  end

  test "errors or not" do
    assert {:error, "Improper arguments"} == Baobab.Identity.create(:dude)
    assert {:error, "Improper arguments"} == Baobab.Identity.create(nil)
    assert {:error, "Improper arguments"} = Baobab.Identity.create("bad_alias", "notakey")

    assert {:error, "Improper Base62 key"} =
             Baobab.Identity.create("bad_alias", "itsmaybeakeymaybeakeymaybeakeymaybeakeynah!")

    new_guy = Baobab.Identity.create("newbie")
    assert {:error, "Identities must be strings"} = Baobab.Identity.rename("newbie", nil)
    assert new_guy == Baobab.Identity.key("newbie", :public) |> Baobab.Identity.as_base62()
    assert {:error, "No such identity"} == Baobab.Identity.drop(new_guy)
    assert :error = Baobab.Identity.key("newb", :secret)
    assert :error = Baobab.Identity.key("newb", :public)

    assert {:error, "Unknown identity: ~short"} = Baobab.Identity.as_base62("~short")

    assert [{:error, "Import requires a list of binaries"}] =
             Baobab.Interchange.import_binaries(:stuff)

    assert [] = Baobab.log_at("0123456789ABCDEF0123456789ABCDEF", 5)
    assert [] = Baobab.log_at("0123456789ABCDEF0123456789ABCDEF0123456789A", 5)
  end

  test "purgeitory" do
    b62first = Baobab.Identity.create("first")
    b62second = Baobab.Identity.create("second")

    Baobab.append_log("The first guy says", "first")
    Baobab.append_log("The second guy says", "second")
    Baobab.append_log("jive talk", "first", log_id: 1337)
    Baobab.append_log("jive response", "second", log_id: 1337)
    Baobab.append_log("alt.binaries.bork.bork.bork", "first", log_id: 42)

    assert length(Baobab.stored_info()) == 5
    assert length(Baobab.purge(:all, log_id: 1337)) == 3
    assert length(Baobab.purge(b62second, log_id: :all)) == 2

    assert [{b62first, 0, 1}] == Baobab.purge("first", log_id: 42)

    assert [] == Baobab.purge(:all, log_id: :all)
  end
end
