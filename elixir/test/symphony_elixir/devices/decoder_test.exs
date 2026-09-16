defmodule SymphonyElixir.Devices.DecoderTest do
  # The decoder runs host-configured executables, so these tests use real
  # binaries from the host rather than a stub that could hide a failure mode.
  use ExUnit.Case, async: true

  alias SymphonyElixir.Devices.{Config, Decoder}

  @elf "3600812f2e5a6d7bb2bd07676ceef7d57d0287e9"
  @dump %{"chip" => "STM32F4", "elf_sha256" => @elf, "build_id" => "build-17"}

  setup do
    dir = Path.join(System.tmp_dir!(), "symphony-decoder-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dump = Path.join(dir, "dump.bin")
    File.write!(dump, "raw dump bytes\n")
    on_exit(fn -> File.rm_rf(dir) end)

    %{dump_path: dump}
  end

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

  describe "match_status/3" do
    test "matches when the recorded chip and ELF agree" do
      assert {:ok, "matched", []} = Decoder.match_status(@dump, decoder(), elf_sha256: @elf)
    end

    test "is unknown when nothing recorded a chip or an ELF" do
      assert {:ok, "unknown", [reason]} = Decoder.match_status(@dump, decoder(%{chip: nil}), elf_sha256: @elf)
      assert reason =~ "芯片"

      assert {:ok, "unknown", [reason]} = Decoder.match_status(%{@dump | "chip" => nil}, decoder(), elf_sha256: @elf)
      assert reason =~ "芯片"

      assert {:ok, "unknown", [reason]} = Decoder.match_status(%{@dump | "elf_sha256" => nil}, decoder(), elf_sha256: @elf)
      assert reason =~ "ELF"

      assert {:ok, "unknown", [reason]} = Decoder.match_status(@dump, decoder(), elf_sha256: nil)
      assert reason =~ "ELF"
    end

    test "refuses a decoder the host switched off" do
      assert {:ok, "unknown", [reason]} = Decoder.match_status(@dump, decoder(%{available: false}), elf_sha256: @elf)
      assert reason =~ "不可用"
    end

    test "is mismatched when the chip differs" do
      assert {:ok, "mismatched", [reason]} = Decoder.match_status(@dump, decoder(%{chip: "ESP32"}), elf_sha256: @elf)
      assert reason =~ "ESP32"
    end

    test "is mismatched when the decoder used another firmware's symbols" do
      other = String.duplicate("a", 40)

      assert {:ok, "mismatched", [reason]} = Decoder.match_status(@dump, decoder(), elf_sha256: other)
      assert reason =~ "不是同一份"
    end

    test "defaults the symbol source to the dump's own ELF hash" do
      assert {:ok, "matched", []} = Decoder.match_status(@dump, decoder())
    end
  end

  describe "decode/4" do
    test "symbolises a matched dump and keeps the exact command it ran", %{dump_path: dump} do
      assert {:ok, result} = Decoder.decode(@dump, decoder(), dump, elf_sha256: @elf)

      assert result["match"] == "matched"
      assert result["decode"] == "symbolised"
      assert result["decoded"] =~ "firmware.elf"
      assert result["argv"] == ["-e", "firmware.elf", dump]
      assert result["executable"] == "/bin/echo"
      assert result["elf_sha256"] == @elf
      assert result["limitations"] == []
    end

    test "a decoder that exits non-zero is a failed run, not a stack", %{dump_path: dump} do
      assert {:ok, result} = Decoder.decode(@dump, decoder(%{executable: "/bin/false"}), dump, elf_sha256: @elf)

      assert result["match"] == "matched"
      assert result["decode"] == "failed"
      assert result["decoded"] == nil
      assert Enum.any?(result["limitations"], &String.contains?(&1, "退出码"))
    end

    test "a decoder that prints nothing has not symbolised anything", %{dump_path: dump} do
      assert {:ok, result} = Decoder.decode(@dump, decoder(%{executable: "/bin/true"}), dump, elf_sha256: @elf)

      assert result["decode"] == "failed"
      assert result["decoded"] == nil
      assert Enum.any?(result["limitations"], &String.contains?(&1, "没有输出"))
    end

    test "a decoder that cannot run is reported instead of crashing the caller", %{dump_path: dump} do
      assert {:ok, result} = Decoder.decode(@dump, decoder(%{executable: "/nonexistent/decoder"}), dump, elf_sha256: @elf)

      assert result["decode"] == "failed"
      assert result["decoded"] == nil
      assert Enum.any?(result["limitations"], &String.contains?(&1, "执行失败"))
    end

    test "no registered executable is refused rather than reported as a success", %{dump_path: dump} do
      assert {:ok, result} = Decoder.decode(@dump, decoder(%{executable: nil}), dump, elf_sha256: @elf)

      assert result["decode"] == "failed"
      assert result["decoded"] == nil
      assert Enum.any?(result["limitations"], &String.contains?(&1, "没有为这个解码器登记可执行文件"))
    end

    test "a mismatched build is refused before any tool runs", %{dump_path: dump} do
      assert {:ok, result} = Decoder.decode(@dump, decoder(%{executable: "/bin/echo"}), dump, elf_sha256: String.duplicate("b", 40))

      assert result["match"] == "mismatched"
      assert result["decode"] == "refused"
      assert result["decoded"] == nil
      assert Enum.any?(result["limitations"], &String.contains?(&1, "未运行解码器"))
    end

    test "an unknown build is refused too, and keeps the raw material readable", %{dump_path: dump} do
      assert {:ok, result} = Decoder.decode(%{@dump | "elf_sha256" => nil}, decoder(), dump)

      assert result["match"] == "unknown"
      assert result["decode"] == "refused"
      assert result["decoded"] == nil
      assert result["argv"] == ["-e", "firmware.elf", "{dump}"]
    end

    test "a dump that is not on the host yet is not decoded", %{dump_path: _dump} do
      assert {:ok, result} = Decoder.decode(@dump, decoder(), nil, elf_sha256: @elf)

      assert result["match"] == "matched"
      assert result["decode"] == "failed"
      assert result["decoded"] == nil
      assert Enum.any?(result["limitations"], &String.contains?(&1, "还没有落到宿主的文件上"))
    end

    test "a decoder whose fixed arguments do not name the dump cannot be handed one", %{dump_path: dump} do
      assert {:ok, result} = Decoder.decode(@dump, decoder(%{argv: ["-e", "firmware.elf"]}), dump, elf_sha256: @elf)

      assert result["decode"] == "failed"
      assert result["decoded"] == nil
      assert Enum.any?(result["limitations"], &String.contains?(&1, "{dump}"))

      assert {:ok, doubled} = Decoder.decode(@dump, decoder(%{argv: ["{dump}", "{dump}"]}), dump, elf_sha256: @elf)

      assert doubled["decode"] == "failed"
      assert Enum.any?(doubled["limitations"], &String.contains?(&1, "拒绝拼装命令"))
    end

    test "a decoder that dies before answering is a failed run", %{dump_path: dump} do
      assert {:ok, result} =
               Decoder.decode(@dump, decoder(%{argv: ["{dump}"]}), dump, elf_sha256: @elf, timeout_ms: 0)

      assert result["decode"] == "failed"
      assert result["decoded"] == nil
      assert Enum.any?(result["limitations"], &String.contains?(&1, "超时"))
    end

    test "a decoder that hangs is stopped by the configured timeout", %{dump_path: dump} do
      executable = Path.join(System.tmp_dir!(), "symphony-slow-decoder-#{System.unique_integer([:positive])}")
      File.write!(executable, "#!/bin/sh\nsleep 30\n")
      File.chmod!(executable, 0o755)
      on_exit(fn -> File.rm_rf(executable) end)

      assert {:ok, result} =
               Decoder.decode(@dump, decoder(%{executable: executable, argv: [executable, "{dump}"]}), dump,
                 elf_sha256: @elf,
                 timeout_ms: 300
               )

      assert result["decode"] == "failed"
      assert result["decoded"] == nil
      assert Enum.any?(result["limitations"], &String.contains?(&1, "超时"))
    end
  end

  describe "known/1" do
    test "lists every registered decoder, including the ones switched off" do
      settings = %Config.Settings{
        decoders: [
          %Config.Decoder{key: "addr2line", display_name: "addr2line", chip: "STM32F4", available: true},
          %Config.Decoder{key: "xtensa", chip: "ESP32", available: false}
        ]
      }

      assert [
               %{"key" => "addr2line", "display_name" => "addr2line", "chip" => "STM32F4", "available" => true, "reason" => nil},
               %{"key" => "xtensa", "display_name" => "xtensa", "chip" => "ESP32", "available" => false, "reason" => reason}
             ] = Decoder.known(settings)

      assert reason =~ "不可用"
    end

    test "a host with no decoders lists none" do
      assert Decoder.known(%Config.Settings{}) == []
    end
  end
end
