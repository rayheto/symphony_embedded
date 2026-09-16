defmodule SymphonyElixir.Devices.ObservationTest do
  # The observation path writes real evidence into the project store, so the
  # store is real and these tests run synchronously.
  use ExUnit.Case, async: false

  alias SymphonyElixir.Devices.{Config, Observation}
  alias SymphonyElixir.Experience.{Project, Store}

  @project_id "embedded-lab-demo"
  @elf "3600812f2e5a6d7bb2bd07676ceef7d57d0287e9"
  @dump_bytes <<0x7F, 0x45, 0x4C, 0x46, 0x00, 0x0A>>

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-observation-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    store = Module.concat(__MODULE__, :"Store#{System.unique_integer([:positive])}")
    start_supervised!({Store, name: store, data_root: root})
    on_exit(fn -> File.rm_rf(root) end)

    %{store: store, root: root}
  end

  defp project(context) do
    %Project{
      project_id: @project_id,
      mode: "demo",
      adapter: SymphonyElixir.Experience.DemoAdapter,
      store: context.store,
      display_states: ["待办", "进行中", "已完成"],
      workspace_root: "/tmp/workspaces",
      tracker_settings: %{active_states: ["Todo"], terminal_states: ["Done"]}
    }
  end

  defp identity(overrides \\ %{}) do
    Map.merge(
      %{
        "device_id" => "board-a",
        "hardware_revision" => "rev A",
        "firmware_sha256" => String.duplicate("f", 64),
        "build_id" => "build-17",
        "elf_sha256" => @elf,
        "boot_id" => "boot-3",
        "chip" => "STM32F4"
      },
      overrides
    )
  end

  defp dump_attrs(overrides \\ %{}) do
    Map.merge(%{"bytes" => @dump_bytes, "captured_at" => "2026-09-14T10:38:00Z"}, Map.merge(identity(), overrides))
  end

  # Prints the dump path it was handed, so the recorded run shows the exact
  # command that produced the stack.
  defp decoder(overrides \\ %{}) do
    struct!(
      %Config.Decoder{
        key: "addr2line",
        display_name: "Arm GNU addr2line",
        executable: "/bin/echo",
        chip: "STM32F4",
        argv: ["-e", "firmware.elf", "{dump}"],
        available: true
      },
      overrides
    )
  end

  describe "record_dump/3" do
    test "saves the bytes as evidence with the identity the host recorded", context do
      project = project(context)

      assert {:ok, receipt} = Observation.record_dump(project, dump_attrs())

      assert receipt["content_status"] == "available"
      assert receipt["binding"]["elf_sha256"] == @elf
      assert receipt["binding"]["build_id"] == "build-17"
      assert receipt["limitations"] == []

      [%{"blob_sha256" => digest, "end_byte_exclusive" => size}] = receipt["raw"]
      assert size == byte_size(@dump_bytes)
      assert {:ok, @dump_bytes} = Store.get_blob(@project_id, digest, server: context.store)

      # The record the page reads is the same material.
      assert {:ok, record} = Store.get(@project_id, "Evidence", receipt["evidence_id"], server: context.store)
      assert record.payload["source_kind"] == "dump"
      assert record.payload["review_status"] == "unseen"
      assert record.payload["derivation_of"] == []
    end

    test "keeps an incomplete identity instead of guessing the missing parts", context do
      project = project(context)

      assert {:ok, receipt} =
               Observation.record_dump(project, dump_attrs(%{"chip" => nil, "elf_sha256" => nil}))

      refute Map.has_key?(receipt["binding"], "chip")
      refute Map.has_key?(receipt["binding"], "elf_sha256")
      assert Enum.any?(receipt["limitations"], &String.contains?(&1, "芯片"))
      assert Enum.any?(receipt["limitations"], &String.contains?(&1, "ELF"))
    end

    test "refuses a dump with no bytes", context do
      assert {:error, :dump_bytes_required, %{}} = Observation.record_dump(project(context), identity())

      assert {:error, :dump_bytes_required, %{}} =
               Observation.record_dump(project(context), dump_attrs(%{"bytes" => <<>>}))
    end

    test "a blank id is not an identity, so the bytes name the evidence", context do
      project = project(context)

      assert {:ok, blank} = Observation.record_dump(project, dump_attrs(%{"id" => ""}))
      assert {:ok, derived} = Observation.record_dump(project, dump_attrs())

      assert blank["evidence_id"] == derived["evidence_id"]
      assert String.starts_with?(blank["evidence_id"], "DUMP-")
    end

    test "a dump saved twice under the same id is one piece of evidence", context do
      project = project(context)
      attrs = dump_attrs(%{"id" => "DUMP-fixed"})

      assert {:ok, first} = Observation.record_dump(project, attrs)
      assert {:ok, second} = Observation.record_dump(project, attrs)

      assert first["evidence_id"] == second["evidence_id"]
      assert first["revision"] == 1
      assert second["revision"] == 2
    end
  end

  describe "decode_dump/4" do
    test "records a matched decode as material derived from the dump", context do
      project = project(context)
      {:ok, dump} = Observation.record_dump(project, dump_attrs())

      {:ok, evidence} = dump_evidence(project, dump)

      assert {:ok, receipt} = Observation.decode_dump(project, decoder(), evidence)

      assert receipt["content_status"] == "available"
      assert receipt["binding"]["match"] == "matched"
      assert receipt["binding"]["decode"] == "symbolised"
      assert receipt["binding"]["argv"] |> List.last() =~ "blobs/sha256"

      {:ok, record} = Store.get(@project_id, "Evidence", receipt["evidence_id"], server: context.store)
      assert record.payload["derivation_of"] == [dump["evidence_id"]]

      [%{"blob_sha256" => digest}] = receipt["raw"]

      assert {:ok, stack} = Store.get_blob(@project_id, digest, server: context.store)
      assert stack =~ "firmware.elf"
    end

    test "a refused decode is recorded as an attempt with no material", context do
      project = project(context)

      # The dump was taken from another chip, so the registered decoder's
      # symbols are not this build's symbols.
      {:ok, dump} = Observation.record_dump(project, dump_attrs(%{"chip" => "ESP32"}))
      {:ok, evidence} = dump_evidence(project, dump)

      assert {:ok, receipt} = Observation.decode_dump(project, decoder(), evidence)

      assert receipt["content_status"] == "missing"
      assert receipt["raw"] == []
      assert receipt["binding"]["decode"] == "refused"
      assert Enum.any?(receipt["limitations"], &String.contains?(&1, "未运行解码器"))
    end

    test "a decoder that fails leaves an attempt, not a stack", context do
      project = project(context)
      {:ok, dump} = Observation.record_dump(project, dump_attrs())
      {:ok, evidence} = dump_evidence(project, dump)

      assert {:ok, receipt} = Observation.decode_dump(project, decoder(%{executable: "/bin/false"}), evidence)

      assert receipt["content_status"] == "missing"
      assert receipt["binding"]["match"] == "matched"
      assert receipt["binding"]["decode"] == "failed"
      assert Enum.any?(receipt["limitations"], &String.contains?(&1, "退出码"))
    end

    test "decoding the same dump twice with one decoder is one record", context do
      project = project(context)
      {:ok, dump} = Observation.record_dump(project, dump_attrs())
      {:ok, evidence} = dump_evidence(project, dump)

      assert {:ok, first} = Observation.decode_dump(project, decoder(), evidence)
      assert {:ok, second} = Observation.decode_dump(project, decoder(), evidence)
      assert first["evidence_id"] == second["evidence_id"]
      assert second["revision"] == 2
    end

    test "refuses material that is not a saved dump", context do
      assert {:error, :invalid_arguments, %{missing: "id"}} =
               Observation.decode_dump(project(context), decoder(), %{"raw" => []})

      assert {:error, :invalid_arguments, %{missing: "id"}} =
               Observation.decode_dump(project(context), decoder(), "not a dump")

      assert {:error, :dump_has_no_material, %{evidence_id: "DUMP-x"}} =
               Observation.decode_dump(project(context), decoder(), %{"id" => "DUMP-x"})
    end

    test "reports a dump whose bytes are gone instead of decoding nothing", context do
      project = project(context)
      {:ok, dump} = Observation.record_dump(project, dump_attrs())
      {:ok, evidence} = dump_evidence(project, dump)

      [%{"blob_sha256" => digest}] = dump["raw"]
      File.rm!(Store.blob_path(digest, server: context.store) |> elem(1))

      assert {:error, :dump_material_missing, %{sha256: ^digest}} =
               Observation.decode_dump(project, decoder(), evidence)
    end

    defp dump_evidence(project, dump) do
      {:ok, record} = Store.get(project.project_id, "Evidence", dump["evidence_id"], server: project.store)
      {:ok, Map.put(record.payload, "id", record.entity_id)}
    end
  end

  describe "image sources" do
    test "lists every registered source, including the ones switched off" do
      settings = %Config.Settings{
        image_sources: [
          %Config.ImageSource{key: "uvc", label: "USB 摄像头", adapter: "v4l2", available: true},
          %Config.ImageSource{key: "http-snap", adapter: "http", available: false}
        ]
      }

      assert [
               %{"key" => "uvc", "label" => "USB 摄像头", "adapter" => "v4l2", "available" => true, "reason" => nil},
               %{"key" => "http-snap", "label" => "http-snap", "available" => false, "reason" => reason}
             ] = Observation.image_sources(settings)

      assert reason =~ "不可用"
    end

    test "connecting selects a registered source and refuses anything else" do
      settings = %Config.Settings{
        image_sources: [%Config.ImageSource{key: "uvc", label: "USB 摄像头", available: true}]
      }

      assert {:ok, %{"key" => "uvc"}} = Observation.select_image_source(settings, "uvc")
      assert {:ok, nil} = Observation.select_image_source(settings, nil)

      assert {:error, :unknown_image_source, %{key: "camera-2", registered: ["uvc"]}} =
               Observation.select_image_source(settings, "camera-2")

      off = %Config.Settings{image_sources: [%Config.ImageSource{key: "http-snap", available: false}]}

      assert {:error, :image_source_unavailable, %{key: "http-snap"}} =
               Observation.select_image_source(off, "http-snap")
    end

    test "a host with no sources lists none" do
      assert Observation.image_sources(%Config.Settings{}) == []
    end
  end
end
