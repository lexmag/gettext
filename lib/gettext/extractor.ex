defmodule Gettext.Extractor do
  @moduledoc false

  alias Gettext.ExtractorAgent
  alias Gettext.PO
  alias Gettext.PO.Translation
  alias Gettext.PO.PluralTranslation
  alias Gettext.Error

  @doc """
  Performs some generic setup needed to extract translations from source.

  For example, starts the agent that stores the translations while they're
  extracted and other similar tasks.
  """
  @spec setup() :: :ok
  def setup do
    {:ok, _} = ExtractorAgent.start_link
    :ok
  end

  @doc """
  Performs teardown after the sources have been extracted.

  For now, it only stops the agent that stores the translations.
  """
  @spec teardown() :: :ok
  def teardown do
    :ok = ExtractorAgent.stop
  end

  @doc """
  Tells whether translations are being extracted.
  """
  @spec extracting?() :: boolean
  def extracting? do
    ExtractorAgent.alive?
  end

  @doc """
  Extracts a translation by temporarily storing it in an agent.

  Note that this function doesn't perform any operation on the filesystem.
  """
  @spec extract(Macro.Env.t, module, binary, binary | {binary, binary}) :: :ok
  def extract(%Macro.Env{file: file, line: line} = _caller, backend, domain, id) do
    ExtractorAgent.add_translation(backend, domain, create_translation_struct(id, file, line))
  end

  @doc """
  Returns a list of POT files based o the results of the extraction.

  Returns a list of paths and their contents to be written to disk. Existing POT
  files are either purged from obsolete translations (in case no extracted
  translation ends up in that file) or merged with the extracted translations;
  new POT files are returned for extracted translations that belong to a POT
  file that doesn't exist yet.
  """
  @spec pot_files() :: [{path :: String.t, contents :: iodata}]
  def pot_files do
    existing_pot_files = pot_files_for_backends(ExtractorAgent.get_backends)
    po_structs = create_po_structs_from_extracted_translations(ExtractorAgent.get_translations)
    merge_pot_files(existing_pot_files, po_structs)
  end

  # Returns all the .pot files for each of the given `backends`.
  defp pot_files_for_backends(backends) do
    Enum.flat_map backends, fn backend ->
      backend.__gettext__(:priv)
      |> Path.join("**/*.pot")
      |> Path.wildcard()
    end
  end

  # This returns a list of {absolute_path, %Gettext.PO{}} tuples.
  # `all_translations` looks like this:
  #
  #     %{MyBackend => %{"a_domain" => %{"a translation id" => a_translation}}}
  #
  defp create_po_structs_from_extracted_translations(all_translations) do
    for {backend, domains}     <- all_translations,
        {domain, translations} <- domains do
      create_po_struct(backend, domain, Map.values(translations))
    end
  end

  # Returns a {path, %Gettext.PO{}} tuple.
  defp create_po_struct(backend, domain, translations) do
    {pot_path(backend, domain), po_struct_from_translations(translations)}
  end

  defp pot_path(backend, domain) do
    Path.join(backend.__gettext__(:priv), "#{domain}.pot")
  end

  defp po_struct_from_translations(translations) do
    # Sort all the translations and the references of each translation in order
    # to make as few changes as possible to the PO(T) files.
    translations =
      translations
      |> Enum.sort_by(&PO.Translations.key/1)
      |> Enum.map(&sort_references/1)

    %PO{translations: translations}
  end

  defp sort_references(translation) do
    update_in(translation.references, &Enum.sort/1)
  end

  defp create_translation_struct({msgid, msgid_plural}, file, line),
    do: %PluralTranslation{
          msgid: [msgid],
          msgid_plural: [msgid_plural],
          msgstr: %{0 => [""], 1 => [""]},
          references: [{Path.relative_to_cwd(file), line}],
        }
  defp create_translation_struct(msgid, file, line),
    do: %Translation{
          msgid: [msgid],
          msgstr: [""],
          references: [{Path.relative_to_cwd(file), line}],
        }

  # Made public for testing.
  @doc false
  def merge_pot_files(pot_files, po_structs) do
    # pot_files is a list of paths to existing .pot files while po_structs is a
    # list of {path, struct} for new %Gettext.PO{} structs that we have
    # extracted. If we turn pot_files into a list of {path, whatever} tuples,
    # that we can take advantage of Dict.merge/3 to find clashing paths.
    pot_files
    |> Enum.map(&{&1, :existing})
    |> Enum.into(%{})
    |> Map.merge(Enum.into(po_structs, %{}), &merge_existing_and_extracted/3)
    |> Enum.map(&purge_unmerged_files/1)
    |> Enum.map(fn({path, pot}) -> {path, PO.dump(pot)} end)
  end

  defp merge_existing_and_extracted(path, :existing, extracted) do
    path |> PO.parse_file! |> merge_template(extracted)
  end

  defp purge_unmerged_files({path, :existing}),
    do: {path, path |> PO.parse_file! |> merge_template(%PO{})}
  defp purge_unmerged_files(already_merged),
    do: already_merged

  # Merges a %PO{} struct representing an existing POT file with an
  # in-memory-only %PO{} struct representing the new POT file.
  # Made public for testing.
  @doc false
  def merge_template(existing, new) do
    old_and_merged = Enum.flat_map existing.translations, fn(t) ->
      cond do
        same = PO.Translations.find(new.translations, t) ->
          [merge_translations(t, same)]
        PO.Translations.autogenerated?(t) ->
          []
        true ->
          [t]
      end
    end

    # We reject all translations that appear in `existing` so that we're left
    # with the translations that only appear in `new`.
    unique_new = Enum.reject(new.translations, &PO.Translations.find(existing.translations, &1))

    %PO{translations: old_and_merged ++ unique_new, headers: existing.headers}
  end

  defp merge_translations(%Translation{} = old, %Translation{comments: []} = new) do
    ensure_empty_msgstr!(old)
    ensure_empty_msgstr!(new)
    %Translation{
      msgid: old.msgid,
      msgstr: old.msgstr,
      # The new in-memory translation has no comments.
      comments: old.comments,
      references: new.references,
    }
  end

  defp merge_translations(%PluralTranslation{} = old, %PluralTranslation{comments: []} = new) do
    ensure_empty_msgstr!(old)
    ensure_empty_msgstr!(new)
    %PluralTranslation{
      msgid: old.msgid,
      msgid_plural: old.msgid_plural,
      msgstr: old.msgstr,
      # The new in-memory translation has no comments.
      comments: old.comments,
      references: new.references,
    }
  end

  defp ensure_empty_msgstr!(%Translation{msgstr: msgstr} = t) do
    unless blank?(msgstr) do
      raise Error, "translation with msgid '#{IO.iodata_to_binary(t.msgid)}' has a non-empty msgstr"
    end
  end

  defp ensure_empty_msgstr!(%PluralTranslation{msgstr: %{0 => str0, 1 => str1}} = t) do
    if not blank?(str0) or not blank?(str1) do
      raise Error,
        "plural translation with msgid '#{IO.iodata_to_binary(t.msgid)}' has a non-empty msgstr"
    end
  end

  defp ensure_empty_msgstr!(%PluralTranslation{} = t) do
    raise Error,
      "plural translation with msgid '#{IO.iodata_to_binary(t.msgid)}' has a non-empty msgstr"
  end

  defp blank?(nil), do: true
  defp blank?(str), do: IO.iodata_length(str) == 0
end