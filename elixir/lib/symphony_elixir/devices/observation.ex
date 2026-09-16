defmodule SymphonyElixir.Devices.Observation do
  @moduledoc """
  Records what the host actually observed about a device.

  A dump is saved as the bytes that arrived together with the identity the host
  wrote down when the firmware was built — never a summary, and never a value
  nobody measured. A decode is recorded as a *derived* material that names the
  dump it came from, and a decode that was refused or failed is recorded as
  exactly that: its `content_status` is `missing`, because no material was
  produced, and its limitations say why. There is no path here that turns "we
  could not symbolise this" into something that reads like a decoded stack.
  """

  alias SymphonyElixir.Devices.{Config, Decoder}
  alias SymphonyElixir.Experience.{Project, Store}

  @dump_kind "dump"
  @media_type "application/octet-stream"
  @identity_fields ~w(device_id hardware_revision firmware_sha256 build_id elf_sha256 boot_id chip config_sha256)
  # The host records observations; a human verdict is not its to write.
  @unseen "unseen"

  @type receipt :: %{String.t() => term()}

  @doc """
  Save a raw dump as evidence and report what was written.

  `attrs` carries the bytes and the identity the host knows: `device_id`,
  `hardware_revision`, `firmware_sha256`, `build_id`, `elf_sha256`, `boot_id`,
  `chip`, `config_sha256`. Anything the host does not know stays out of the
  binding rather than being guessed, and a dump whose identity is incomplete is
  still saved — it simply cannot support a decode later.
  """
  @spec record_dump(Project.t(), map(), keyword()) :: {:ok, receipt()} | {:error, atom(), map()}
  def record_dump(%Project{} = project, attrs, opts \\ []) do
    with {:ok, bytes} <- fetch_bytes(attrs),
         {:ok, blob} <- put_blob(project, bytes, opts) do
      evidence = %{
        "id" => evidence_id(attrs, blob),
        "title" => Map.get(attrs, "title") || "raw dump",
        "source_kind" => @dump_kind,
        "raw" => [raw_range(blob)],
        "source_refs" => [],
        "binding" => dump_binding(attrs),
        "captured_at" => Map.get(attrs, "captured_at"),
        "received_at" => now(),
        "capture_session_id" => Map.get(attrs, "capture_session_id"),
        "derivation_of" => [],
        "supersedes" => nil,
        "content_status" => "available",
        "review_status" => @unseen,
        "limitations" => identity_limitations(attrs)
      }

      append_evidence(project, evidence, opts)
    end
  end

  @doc """
  Decode a saved dump and record the attempt.

  The decoder is a host-registered one and the symbol source defaults to the ELF
  the dump itself was taken from; the run is recorded whatever happened, so a
  refused or failed decode is visible as a material with no stack rather than as
  a gap in the record.
  """
  @spec decode_dump(Project.t(), Config.Decoder.t() | map(), map(), keyword()) ::
          {:ok, receipt()} | {:error, atom(), map()}
  def decode_dump(%Project{} = project, decoder, dump_evidence, opts \\ []) do
    with {:ok, dump_id} <- fetch(dump_evidence, "id"),
         {:ok, digest} <- dump_digest(dump_evidence),
         {:ok, path} <- material_path(project, digest),
         {:ok, result} <- Decoder.decode(evidence_binding(dump_evidence), decoder, path, opts) do
      record_decoding(project, decoder, result, dump_id, opts)
    end
  end

  @doc """
  The image sources the host registered, as the device page lists them.

  An unavailable source is listed with its reason: hiding it would make a
  missing observation path look like a missing feature.
  """
  @spec image_sources(Config.Settings.t() | map()) :: [map()]
  def image_sources(settings) do
    settings
    |> Map.get(:image_sources, [])
    |> Enum.map(fn source ->
      %{
        "key" => Map.get(source, :key),
        "label" => Map.get(source, :label) || Map.get(source, :key),
        "adapter" => Map.get(source, :adapter),
        "available" => Map.get(source, :available, true),
        "reason" => if(Map.get(source, :available, true), do: nil, else: "宿主标记该图像源当前不可用")
      }
    end)
  end

  @doc """
  Choose the observation source for a device, or `nil` to stop observing.

  Connecting is a *selection*, not a capture: it says which registered source the
  device should be observed through, and refuses a key the host never registered
  or one it switched off. Nothing here invents a frame.
  """
  @spec select_image_source(Config.Settings.t() | map(), String.t() | nil) ::
          {:ok, map() | nil} | {:error, atom(), map()}
  def select_image_source(_settings, nil), do: {:ok, nil}

  def select_image_source(settings, key) do
    case Enum.find(image_sources(settings), &(&1["key"] == key)) do
      nil ->
        {:error, :unknown_image_source, %{key: key, registered: Enum.map(image_sources(settings), & &1["key"])}}

      %{"available" => false} = source ->
        {:error, :image_source_unavailable, %{key: key, reason: source["reason"]}}

      source ->
        {:ok, source}
    end
  end

  # ------------------------------------------------------------------
  # Recording
  # ------------------------------------------------------------------

  defp record_decoding(project, decoder, result, dump_id, opts) do
    stack = result["decoded"]

    with {:ok, raw} <- stack_raw(project, stack, opts),
         {:ok, evidence} <- decoding_evidence(decoder, result, dump_id, raw) do
      append_evidence(project, evidence, opts)
    end
  end

  defp decoding_evidence(decoder, result, dump_id, raw) do
    {:ok,
     %{
       "id" => "DEC-" <> String.slice(digest_of(dump_id <> "-" <> to_string(Map.get(decoder, :key))), 0, 16),
       "title" => "decoded dump #{dump_id}",
       "source_kind" => @dump_kind,
       "raw" => raw,
       "source_refs" => [],
       "binding" => decoder_binding(decoder, result),
       "captured_at" => nil,
       "received_at" => now(),
       "capture_session_id" => nil,
       "derivation_of" => [dump_id],
       "supersedes" => nil,
       "content_status" => if(raw == [], do: "missing", else: "available"),
       "review_status" => @unseen,
       "limitations" => result["limitations"]
     }}
  end

  defp decoder_binding(decoder, result) do
    %{
      "decoder" => result["decoder"] || Map.get(decoder, :key),
      "executable" => result["executable"] || Map.get(decoder, :executable),
      "argv" => result["argv"] || Map.get(decoder, :argv, []),
      "match" => result["match"],
      "decode" => result["decode"],
      "elf_sha256" => result["elf_sha256"]
    }
  end

  defp stack_raw(_project, nil, _opts), do: {:ok, []}

  # A stack that exists but cannot be stored is an error, not a decode that
  # produced nothing: the two must not end up looking the same.
  defp stack_raw(project, stack, opts) do
    with {:ok, blob} <- put_blob(project, stack, opts) do
      {:ok, [raw_range(blob)]}
    end
  end

  defp raw_range(blob) do
    %{
      "blob_sha256" => blob["sha256"],
      "start_byte" => 0,
      "end_byte_exclusive" => blob["size_bytes"],
      "source_seq_start" => nil,
      "source_seq_end" => nil
    }
  end

  defp append_evidence(project, evidence, opts) do
    payload = Map.put(evidence, "project_id", project.project_id)

    # A store refusal comes back to the caller as it is: recording what the host
    # observed must not look successful when nothing was written.
    with {:ok, record} <-
           Store.append(
             project.project_id,
             "Evidence",
             evidence["id"],
             current_revision(project, evidence["id"]),
             payload,
             actor(),
             server: project.store,
             idempotency_key: Keyword.get(opts, :idempotency_key)
           ) do
      {:ok,
       %{
         "evidence_id" => record.entity_id,
         "revision" => record.entity_revision,
         "raw" => evidence["raw"],
         "content_status" => evidence["content_status"],
         "binding" => evidence["binding"],
         "limitations" => evidence["limitations"]
       }}
    end
  end

  # A tool is only ever handed a path to bytes that are really there: a decoder
  # pointed at a missing file would report its own confusion, not a fact about
  # the build.
  defp material_path(project, digest) do
    with {:ok, path} <- Store.blob_path(digest, server: project.store) do
      if File.regular?(path) do
        {:ok, path}
      else
        {:error, :dump_material_missing, %{sha256: digest, path: path}}
      end
    end
  end

  # Recording the same material again is another revision of the same evidence,
  # not a second piece of it — the id is derived from what was observed.
  defp current_revision(project, evidence_id) do
    case Store.get(project.project_id, "Evidence", evidence_id, server: project.store) do
      {:ok, record} -> record.entity_revision
      {:error, _code, _details} -> 0
    end
  end

  defp put_blob(project, bytes, opts) do
    Store.put_blob(project.project_id, bytes, Keyword.get(opts, :media_type, @media_type), server: project.store)
  end

  # ------------------------------------------------------------------
  # Identity
  # ------------------------------------------------------------------

  defp dump_binding(attrs) do
    @identity_fields
    |> Enum.reduce(%{}, fn field, acc ->
      case Map.get(attrs, field) do
        nil -> acc
        value -> Map.put(acc, field, value)
      end
    end)
  end

  # Evidence binding is keyed by the same names the decoder matches on, so a
  # saved dump can be decoded later without anyone re-typing its identity.
  defp evidence_binding(dump_evidence), do: Map.get(dump_evidence, "binding", %{})

  defp identity_limitations(attrs) do
    missing =
      for {field, label} <- [{"chip", "芯片型号"}, {"elf_sha256", "ELF 哈希"}],
          not present?(Map.get(attrs, field)),
          do: label

    if missing == [] do
      []
    else
      ["没有登记 #{Enum.join(missing, "、")}，因此无法判断符号是否匹配，也不能据此解码。"]
    end
  end

  defp present?(value) when is_binary(value), do: value != ""
  defp present?(_absent), do: false

  defp dump_digest(dump_evidence) do
    case dump_evidence |> Map.get("raw", []) |> List.first() do
      %{"blob_sha256" => digest} -> {:ok, digest}
      _absent -> {:error, :dump_has_no_material, %{evidence_id: Map.get(dump_evidence, "id")}}
    end
  end

  # A blank id is not an identity: the same bytes produce the same evidence id,
  # so a caller cannot split one observation into several by omitting the name.
  defp evidence_id(attrs, blob) do
    case Map.get(attrs, "id") do
      id when is_binary(id) and id != "" -> id
      _absent -> "DUMP-" <> String.slice(blob["sha256"], 0, 16)
    end
  end

  defp digest_of(result), do: :crypto.hash(:sha256, :erlang.term_to_binary(result)) |> Base.encode16(case: :lower)

  defp actor, do: %{kind: "system", id: "device-observation", display_name: "设备观测"}

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp fetch(map, key) when is_map(map) do
    case Map.get(map, key) do
      nil -> {:error, :invalid_arguments, %{missing: key}}
      value -> {:ok, value}
    end
  end

  defp fetch(_map, key), do: {:error, :invalid_arguments, %{missing: key}}

  defp fetch_bytes(attrs) do
    case Map.get(attrs, "bytes") do
      bytes when is_binary(bytes) and byte_size(bytes) > 0 -> {:ok, bytes}
      _absent -> {:error, :dump_bytes_required, %{reason: "没有原始字节就不是一次 dump"}}
    end
  end
end
