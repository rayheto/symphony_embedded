defmodule SymphonyElixir.Devices.Decoder do
  @moduledoc """
  Symbolise a raw dump only when the symbols match the build that produced it.

  A translated call stack is a claim about code that actually ran on a device.
  It is only that claim when the ELF the decoder used is the ELF that produced
  the dump, so the decision is made from recorded hashes and build identity —
  never from the decoder exiting zero, and never from an empty output.

  Two facts are reported separately and neither is derived from the other:

    * `match` — whether the recorded ELF, chip and build agree with the decoder;
    * `decode` — what the tool run actually produced.

  A matched dump whose decoder crashed is a *failed* run of a correctly matched
  build. An unmatched dump is refused before any tool is started, because a
  confident-looking stack from the wrong symbols is worse than no stack.
  """

  require Logger

  alias SymphonyElixir.Devices.Config

  @default_timeout_ms 30_000
  # The host writes this token into a decoder's fixed argument list; the path it
  # is replaced with is one the host produced, so a caller can never shape the
  # command, and more than one token is refused rather than assembled.
  @dump_token "{dump}"

  @type result :: %{
          required(String.t()) => term()
        }

  @doc """
  Decide whether the decoder's symbols are the ones this dump was produced from.

  Every input is a recorded identity, not a caller's description: `chip` and
  `elf_sha256` are what the host wrote down when the firmware was built, and the
  dump carries the same fields from the boot it came from.
  """
  @spec match_status(map(), Config.Decoder.t() | map(), keyword()) :: {:ok, String.t(), [String.t()]}
  def match_status(dump, decoder, opts \\ []) do
    decoder_chip = Map.get(decoder, :chip)
    dump_chip = Map.get(dump, "chip")
    dump_elf = Map.get(dump, "elf_sha256")
    symbol_elf = Keyword.get(opts, :elf_sha256, dump_elf)

    cond do
      Map.get(decoder, :available) == false ->
        {:ok, "unknown", ["宿主登记该解码器当前不可用。"]}

      blank?(decoder_chip) or blank?(dump_chip) ->
        {:ok, "unknown", ["没有登记芯片型号，无法判断符号是否匹配。"]}

      decoder_chip != dump_chip ->
        {:ok, "mismatched", ["解码器针对 #{decoder_chip}，而这次 dump 来自 #{dump_chip}。"]}

      blank?(dump_elf) ->
        {:ok, "unknown", ["这次 dump 没有记录 ELF 哈希，符号是否匹配无法证明。"]}

      blank?(symbol_elf) ->
        {:ok, "unknown", ["没有提供用于解码的 ELF 哈希，符号是否匹配无法证明。"]}

      symbol_elf != dump_elf ->
        {:ok, "mismatched", ["用于解码的 ELF 与产生 dump 的固件不是同一份。"]}

      true ->
        {:ok, "matched", []}
    end
  end

  @doc """
  Run one registered decoder against a raw dump that is already on the host.

  `dump_path` is a path the *host* produced — the material it saved — and the
  caller cannot choose where in the command it lands: the host wrote a single
  `{dump}` token into the fixed argument list, and a template with no token or
  more than one is refused instead of being assembled.

  A refused or failed run is an answer, not an error: the caller records what
  happened to the material instead of inventing a stack that was never produced.
  """
  @spec decode(map(), Config.Decoder.t() | map(), String.t() | nil, keyword()) :: {:ok, result()}
  def decode(dump, decoder, dump_path, opts \\ []) do
    symbol_elf = Keyword.get(opts, :elf_sha256, Map.get(dump, "elf_sha256"))
    {:ok, match, match_limits} = match_status(dump, decoder, elf_sha256: symbol_elf)
    {:ok, decoded, run_limits, argv} = decode_attempt(match, decoder, dump_path, opts)

    {:ok, result(match, match_limits, decoded, run_limits, decoder, symbol_elf, argv)}
  end

  @doc """
  The decoders the host registered, as the device page lists them.

  A decoder the host switched off is listed with its reason: hiding it would
  make a missing capability look like a missing feature.
  """
  @spec known(Config.Settings.t() | map()) :: [map()]
  def known(settings) do
    settings
    |> Map.get(:decoders, [])
    |> Enum.map(fn decoder ->
      %{
        "key" => Map.get(decoder, :key),
        "display_name" => Map.get(decoder, :display_name) || Map.get(decoder, :key),
        "chip" => Map.get(decoder, :chip),
        "available" => Map.get(decoder, :available, true),
        "reason" => if(Map.get(decoder, :available, true), do: nil, else: "宿主标记该解码器不可用")
      }
    end)
  end

  # ------------------------------------------------------------------
  # Running the tool
  # ------------------------------------------------------------------

  defp decode_attempt("matched", decoder, dump_path, opts) do
    executable = Map.get(decoder, :executable)
    argv = Map.get(decoder, :argv, [])

    cond do
      blank?(executable) ->
        {:ok, nil, ["宿主没有为这个解码器登记可执行文件。"], argv}

      blank?(dump_path) ->
        {:ok, nil, ["这次 dump 还没有落到宿主的文件上，未运行解码器。"], argv}

      Enum.count(argv, &(&1 == @dump_token)) != 1 ->
        {:ok, nil, ["解码器的固定参数必须正好包含一个 #{@dump_token} 占位，拒绝拼装命令。"], argv}

      true ->
        expanded = Enum.map(argv, &if(&1 == @dump_token, do: dump_path, else: &1))
        {decoded, limits} = run_tool(executable, expanded, opts)
        {:ok, decoded, limits, expanded}
    end
  end

  # The wrong symbols are refused before a tool runs: a plausible-looking stack
  # from another build is worse than no stack at all.
  defp decode_attempt(match, decoder, _dump_path, _opts) do
    {:ok, nil, ["符号状态为 #{match}，未运行解码器，也不显示调用栈。"], Map.get(decoder, :argv, [])}
  end

  # The tool runs in its own process so a decoder that hangs, crashes or is
  # missing is a reported failure rather than something that takes the caller
  # down or becomes a successful decode.
  defp run_tool(executable, argv, opts) do
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    parent = self()
    ref = make_ref()

    # The tool's own failures come back as `{:failed, message}`; a process that
    # never answers — killed from outside, for instance — is stopped by the
    # timeout below and reported as a run that produced nothing.
    {pid, monitor} = spawn_monitor(fn -> send(parent, {ref, attempt(executable, argv)}) end)

    receive do
      {^ref, {:ok, output, 0}} ->
        Process.demonitor(monitor, [:flush])
        empty_output(output)

      {^ref, {:ok, output, exit_code}} ->
        Process.demonitor(monitor, [:flush])
        {nil, run_limits(output, exit_code)}

      {^ref, {:failed, message}} ->
        Process.demonitor(monitor, [:flush])
        Logger.warning("decoder #{executable} could not run: #{message}")
        {nil, ["解码器本身执行失败：#{message}"]}
    after
      timeout ->
        Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])
        Logger.warning("decoder #{executable} timed out after #{timeout}ms")
        {nil, ["解码器执行超时（#{timeout}ms），已停止，不显示调用栈。"]}
    end
  end

  defp attempt(executable, argv) do
    {output, exit_code} = System.cmd(executable, argv, stderr_to_stdout: true)
    {:ok, output, exit_code}
  rescue
    error -> {:failed, Exception.message(error)}
  end

  # "An empty output is not a success": a tool that printed nothing has not
  # symbolised anything, whatever its exit code was.
  defp empty_output(output) do
    if String.trim(output) == "" do
      {nil, ["解码器没有输出，不算成功。"]}
    else
      {output, []}
    end
  end

  defp run_limits(output, exit_code) do
    [
      "解码器以退出码 #{exit_code} 结束，不显示确定的调用栈。",
      "输出长度 #{byte_size(output)} 字节已保存，供人工查看。"
    ]
  end

  defp result(match, match_limits, decoded, run_limits, decoder, symbol_elf, argv) do
    limits = Enum.uniq(match_limits ++ run_limits)

    %{
      "match" => match,
      "decode" => decode_status(match, decoded),
      "decoded" => decoded,
      "chip" => Map.get(decoder, :chip),
      "elf_sha256" => symbol_elf,
      "decoder" => Map.get(decoder, :key),
      "executable" => Map.get(decoder, :executable),
      "argv" => argv,
      "limitations" => limits
    }
  end

  defp decode_status("matched", nil), do: "failed"
  defp decode_status("matched", _output), do: "symbolised"
  defp decode_status(_match, _decoded), do: "refused"

  defp blank?(value) when is_binary(value), do: value == ""
  defp blank?(_absent), do: true
end
