Code.require_file("utils/json.ex", __DIR__)
Code.require_file("utils/banner.ex", __DIR__)

defmodule JVaultMiner do
  @moduledoc false

  @my_project "JVault Miniapp"
  @base_url "https://jvaultminer.world"
  @root __DIR__
  @tap_count 10
  @tap_gap_ms 1_200
  @tap_attempts 3

  @reset "\e[0m"
  @bold "\e[1m"
  @red "\e[91m"
  @green "\e[92m"
  @yellow "\e[93m"

  def run do
    :logger.set_primary_config(:level, :error)
    install_signal_handler()

    Application.ensure_all_started(:inets)
    Application.ensure_all_started(:ssl)

    Banner.set_title(@my_project)
    Banner.show_banner(@my_project)

    accounts = load_lines("data.txt")

    if accounts == [] do
      red("File data.txt is empty, please add your initData entries")
      System.halt(1)
    end

    proxies = load_lines("proxy.txt")
    settings = load_settings()

    loop(accounts, proxies, settings, 1)
  end

  defp loop(accounts, proxies, settings, cycle) do
    yellow("Starting automation cycle number #{cycle}")

    Enum.with_index(accounts)
    |> Enum.each(fn {account, index} ->
      if index > 0, do: IO.puts("")

      proxy = proxy_for(proxies, index)

      case proxy do
        nil -> yellow("Running without proxy for this account")
        line -> yellow("Using proxy #{mask_proxy(line)}")
      end

      try do
        process_account(account, index, proxy)
      rescue
        _error -> red("Account #{index + 1} was skipped after an error")
      end
    end)

    yellow("All accounts processed for cycle number #{cycle}")

    countdown(sleep_seconds(settings), "Next cycle starts in")
    Banner.show_banner(@my_project)
    loop(accounts, proxies, settings, cycle + 1)
  end

  defp process_account(account, index, proxy) do
    label = "#{index + 1}"

    case identity(account) do
      {:ok, user_id, profile, username} ->
        case sync(profile, account, proxy) do
          {:ok, data} ->
            user = get(data, "user", %{})
            symbol = get(get(data, "settings", %{}), "tokenSymbol", "JVT")

            cond do
              get(user, "isBanned", false) ->
                red("Account #{label} is banned and was skipped by the bot")

              not is_map(user) or map_size(user) == 0 ->
                red("Account #{label} state fetch failed with an empty snapshot")

              true ->
                name = display_name(user, profile)

                green(
                  "Signed in #{shorten(clean_text(name, "account"), "account", 20)} with #{money(number(get(user, "totalAssets", 0)))} #{symbol}"
                )

                process_taps(user_id, symbol, account, proxy)
                process_mining(user, user_id, symbol, account, proxy)
                process_tasks(user_id, symbol, account, proxy)
                process_referrals(user_id, symbol, account, proxy)
                process_leaderboard(username, account, proxy)
                :ok
            end

          {:error, reason} ->
            red("Account #{label} state fetch failed with #{short_reason(reason)}")
        end

      {:error, reason} ->
        red("Account #{label} initData refused with #{short_reason(reason)}")
    end
  end

  defp process_taps(user_id, symbol, account, proxy) do
    before = assets_of(account, proxy)
    tapped = tap_round(user_id, @tap_count, 0, account, proxy)
    gained = assets_of(account, proxy) - before

    cond do
      gained > 0 ->
        green("Mining taps credited #{money(gained)} #{symbol} to the pool wallet")

      tapped > 0 ->
        green("Mining taps credited #{money(tapped)} #{symbol} to the pool wallet")

      true ->
        yellow("No mining tap reward could be verified on this run")
    end
  end

  defp tap_round(_user_id, 0, credited, _account, _proxy), do: credited

  defp tap_round(user_id, left, credited, account, proxy) do
    case tap_once(user_id, account, proxy, @tap_attempts) do
      {:ok, amount} ->
        :timer.sleep(@tap_gap_ms)
        tap_round(user_id, left - 1, credited + amount, account, proxy)

      :slow ->
        :timer.sleep(@tap_gap_ms)
        tap_round(user_id, left, credited, account, proxy)

      {:error, _reason} ->
        credited
    end
  end

  defp tap_once(_user_id, _account, _proxy, 0), do: {:error, "tap refused"}

  defp tap_once(user_id, account, proxy, attempts) do
    case call("/api/user/tap-mine", %{"userId" => user_id}, account, proxy) do
      {:ok, data} ->
        {:ok, number(get(data, "minedAmount", 0))}

      {:error, reason} ->
        text = String.upcase(to_string(reason))

        if String.contains?(text, "SLOW") do
          :slow
        else
          tap_once(user_id, account, proxy, attempts - 1)
        end
    end
  end

  defp process_mining(user, user_id, symbol, account, proxy) do
    left = remaining(get(user, "nextCycleAt"))

    if left > 0 do
      yellow("Mining cycle is still running with #{format_duration(left)} left")
    else
      claim_mining(user_id, number(get(user, "totalAssets", 0)), symbol, account, proxy)
    end
  end

  defp claim_mining(user_id, before, symbol, account, proxy) do
    case call("/api/user/claim", %{"userId" => user_id}, account, proxy) do
      {:ok, _data} ->
        case sync_assets(account, proxy) do
          {:ok, after_assets} ->
            gained = after_assets - before

            if gained > 0 do
              green("Mining cycle reward of #{money(gained)} #{symbol} was claimed")
            else
              yellow("Mining claim was accepted without a confirmed reward")
            end

          {:error, _reason} ->
            yellow("Mining claim was accepted without a confirmed reward")
        end

      {:error, reason} ->
        text = String.upcase(to_string(reason))

        if String.contains?(text, "NEXT CLAIM") do
          yellow("Mining cycle reward is not ready on the server yet")
        else
          yellow("Mining cycle claim was refused with #{short_reason(reason)}")
        end
    end
  end

  defp process_tasks(user_id, symbol, account, proxy) do
    case call_get("/api/tasks", account, proxy) do
      {:ok, data} ->
        done =
          case get(data, "completedTaskIds", []) do
            list when is_list(list) -> Enum.map(list, &to_string/1)
            _other -> []
          end

        open =
          case get(data, "tasks", []) do
            list when is_list(list) -> Enum.reject(list, fn task -> task_id(task) in done end)
            _other -> []
          end

        cond do
          open == [] ->
            green("Every available account task was already completed")

          true ->
            green("Found #{plural(length(open), "account task")} to process")
            Enum.each(open, fn task -> claim_task(task, user_id, symbol, account, proxy) end)
        end

      {:error, reason} ->
        red("Task list could not be fetched with #{short_reason(reason)}")
    end
  end

  defp task_id(task), do: to_string(get(task, "id", ""))

  defp claim_task(task, user_id, symbol, account, proxy) do
    title = shorten(clean_text(get(task, "title", "task"), "task"), "task", 18)
    path = "/api/tasks/claim/" <> task_id(task)

    case call(path, %{"userId" => user_id}, account, proxy) do
      {:ok, data} ->
        green(
          "Task #{title} claimed earning #{money(number(get(data, "reward", 0)))} #{symbol}"
        )

      {:error, reason} ->
        text = String.upcase(to_string(reason))

        cond do
          String.contains?(text, "MEMBERSHIP") or String.contains?(text, "NOT JOIN") ->
            yellow("Task #{title} still needs a manual channel join")

          String.contains?(text, "ALREADY") ->
            yellow("Task #{title} was already completed on this account")

          true ->
            yellow("Task #{title} was refused with #{short_reason(reason)}")
        end
    end
  end

  defp process_referrals(user_id, symbol, account, proxy) do
    invite = claim_referral("/api/user/claim-invite-bonus", user_id, account, proxy)
    team = claim_referral("/api/user/claim-team-commission", user_id, account, proxy)
    total = invite + team

    if total > 0 do
      green("Referral bonus credited #{money(total)} #{symbol} to this account")
    else
      yellow("No referral commission was pending on this account")
    end
  end

  defp claim_referral(path, user_id, account, proxy) do
    case call(path, %{"userId" => user_id}, account, proxy) do
      {:ok, data} -> number(get(data, "amountClaimed", 0))
      {:error, _reason} -> 0
    end
  end

  defp process_leaderboard(username, account, proxy) do
    case call_get("/api/leaderboard", account, proxy) do
      {:ok, data} ->
        case get(data, "currentUserRank", %{}) do
          %{} = me ->
            case whole(get(me, "rank", 0), 0) do
              rank when rank > 0 ->
                green("Leaderboard position #{rank} for #{shorten(clean_text(username, "account"), "account", 20)}")

              _other ->
                yellow("This account is not ranked on the leaderboard yet")
            end

          _other ->
            yellow("This account is not ranked on the leaderboard yet")
        end

      {:error, _reason} ->
        yellow("The leaderboard position was not returned by the server")
    end
  end

  defp sync(profile, account, proxy) do
    call("/api/user/sync", profile, account, proxy)
  end

  defp sync_assets(account, proxy) do
    case identity_of(account) do
      {:ok, profile, _username} ->
        case sync(profile, account, proxy) do
          {:ok, data} -> {:ok, number(get(get(data, "user", %{}), "totalAssets", 0))}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp assets_of(account, proxy) do
    case sync_assets(account, proxy) do
      {:ok, value} -> value
      {:error, _reason} -> 0
    end
  end

  defp identity(init_data) do
    with {:ok, profile, username} <- identity_of(init_data),
         id when not is_nil(id) <- get(profile, "id") do
      {:ok, "usr_" <> to_string(id), profile, username}
    else
      nil -> {:error, "user object missing"}
      {:error, reason} -> {:error, reason}
      _other -> {:error, "unreadable initData"}
    end
  end

  defp identity_of(init_data) do
    with {:ok, params} <- parse_query(init_data),
         raw when is_binary(raw) <- Map.get(params, "user"),
         {:ok, user} <- YuurisanJSON.decode(URI.decode_www_form(raw)),
         id when not is_nil(id) <- get(user, "id") do
      {:ok, user, to_string(get(user, "username", ""))}
    else
      nil -> {:error, "user object missing"}
      {:error, reason} -> {:error, reason}
      _other -> {:error, "unreadable initData"}
    end
  end

  defp parse_query(raw) do
    pairs =
      raw
      |> String.trim()
      |> String.split("&")
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(fn pair ->
        case String.split(pair, "=", parts: 2) do
          [key, value] -> {key, value}
          [key] -> {key, ""}
        end
      end)

    if Enum.any?(pairs, fn {key, _value} -> key == "hash" end) do
      {:ok, Map.new(pairs)}
    else
      {:error, "initData has no hash"}
    end
  end

  defp call(path, payload, account, proxy) do
    case request(:post, path, payload, account, proxy) do
      {:ok, body} -> unwrap(body)
      {:error, reason} -> {:error, reason}
    end
  end

  defp call_get(path, account, proxy) do
    case request(:get, path, %{}, account, proxy) do
      {:ok, body} -> unwrap(body)
      {:error, reason} -> {:error, reason}
    end
  end

  defp unwrap(body) do
    case body do
      %{"error" => error} -> {:error, error}
      %{"success" => false} = data -> {:error, get(data, "error", "request refused")}
      %{} = data -> {:ok, data}
      _other -> {:ok, %{}}
    end
  end

  defp request(method, path, payload, init_data, proxy) do
    url = String.to_charlist(String.trim_trailing(@base_url, "/") <> path)
    {profile, auth} = proxy_setup(proxy)

    headers = [
      {~c"content-type", ~c"application/json"},
      {~c"accept", ~c"*/*"},
      {~c"accept-language", ~c"en-US,en;q=0.9"},
      {~c"origin", String.to_charlist(@base_url)},
      {~c"referer", String.to_charlist(@base_url <> "/")},
      {~c"x-telegram-init-data", String.to_charlist(init_data)},
      {~c"authorization", String.to_charlist("tma " <> init_data)},
      {~c"user-agent",
       ~c"Mozilla/5.0 (Linux; Android 13; SM-S918B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"}
    ]

    body =
      payload
      |> Map.put("initData", init_data)
      |> YuurisanJSON.encode()

    options = [ssl: [verify: :verify_none], timeout: 30_000, connect_timeout: 15_000] ++ auth

    dispatch(method, url, headers, body, options, profile)
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp dispatch(:get, url, headers, _body, options, profile) do
    handle(:httpc.request(:get, {url, headers}, options, [body_format: :binary], profile))
  end

  defp dispatch(:post, url, headers, body, options, profile) do
    handle(
      :httpc.request(
        :post,
        {url, headers, ~c"application/json", body},
        options,
        [body_format: :binary],
        profile
      )
    )
  end

  defp handle({:ok, {{_version, status, _reason}, _headers, response}})
       when status >= 200 and status < 300 do
    case YuurisanJSON.decode(response) do
      {:ok, value} -> {:ok, value}
      {:error, _reason} -> {:error, "unreadable response"}
    end
  end

  defp handle({:ok, {{_version, status, _reason}, _headers, response}}) do
    case YuurisanJSON.decode(response) do
      {:ok, %{"error" => error}} -> {:error, error}
      {:ok, %{"message" => message}} -> {:error, message}
      {:ok, _value} -> {:error, "HTTP #{status}"}
      {:error, _reason} -> {:error, "HTTP #{status}"}
    end
  end

  defp handle({:error, reason}), do: {:error, reason}

  defp proxy_setup(nil), do: {:default, []}

  defp proxy_setup(line) do
    case parse_proxy(line) do
      {host, port, user, pass} -> proxy_profile(host, port, user, pass)
      {host, port} -> proxy_profile(host, port, "", "")
      nil -> {:default, []}
    end
  end

  defp proxy_profile(host, port, user, pass) do
    name = String.to_atom("proxy_#{host}_#{port}")
    address = {String.to_charlist(host), port}

    case :inets.start(:httpc, profile: name) do
      {:ok, _pid} -> :httpc.set_options([proxy: {address, []}, https_proxy: {address, []}], name)
      {:error, {:already_started, _pid}} -> :ok
      _other -> :ok
    end

    case user do
      "" -> {name, []}
      _ -> {name, [proxy_auth: {String.to_charlist(user), String.to_charlist(pass)}]}
    end
  end

  defp parse_proxy(line) do
    value =
      line
      |> String.trim()
      |> String.replace_prefix("http://", "")
      |> String.replace_prefix("https://", "")
      |> String.replace_prefix("socks5://", "")

    case String.split(value, "@") do
      [credentials, host_part] ->
        case String.split(credentials, ":") do
          [user, pass] -> with_host_port(host_part, user, pass)
          _other -> with_host_port(host_part, "", "")
        end

      [host_part] ->
        case String.split(host_part, ":") do
          [host, port] -> with_port(host, port)
          [host, port, user, pass] -> with_port_creds(host, port, user, pass)
          _other -> nil
        end
    end
  end

  defp with_host_port(host_part, user, pass) do
    case String.split(host_part, ":") do
      [host, port] -> with_port_creds(host, port, user, pass)
      _other -> nil
    end
  end

  defp with_port(host, port) do
    case Integer.parse(port) do
      {number, ""} -> {host, number}
      _other -> nil
    end
  end

  defp with_port_creds(host, port, user, pass) do
    case Integer.parse(port) do
      {number, ""} -> {host, number, user, pass}
      _other -> nil
    end
  end

  defp mask_proxy(line) do
    case parse_proxy(line) do
      {host, port, _user, _pass} -> "http://user:pass@#{mask_host(host)}:#{port}"
      {host, port} -> "http://user:pass@#{mask_host(host)}:#{port}"
      nil -> "http://user:pass@***:***"
    end
  end

  defp mask_host(host) do
    parts = String.split(host, ".")

    case parts do
      [a, _b, _c, d] ->
        "#{a}*****#{d}"

      _other ->
        if String.length(host) > 4 do
          String.slice(host, 0, 2) <> "*****" <> String.slice(host, -2, 2)
        else
          "***"
        end
    end
  end

  defp proxy_for([], _index), do: nil
  defp proxy_for(proxies, index), do: Enum.at(proxies, rem(index, length(proxies)))

  defp load_lines(name) do
    case File.read(Path.join(@root, name)) do
      {:ok, content} ->
        content
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      {:error, _reason} ->
        []
    end
  end

  defp load_settings do
    case File.read(Path.join(@root, "config.json")) do
      {:ok, content} ->
        case YuurisanJSON.decode(content) do
          {:ok, value} -> value
          {:error, _reason} -> default_settings()
        end

      {:error, _reason} ->
        settings = default_settings()
        File.write(Path.join(@root, "config.json"), YuurisanJSON.encode_pretty(settings))
        settings
    end
  end

  defp default_settings, do: %{"settings" => %{"sleep_seconds" => 3600}}

  defp sleep_seconds(settings) do
    case get(get(settings, "settings", %{}), "sleep_seconds", 3600) do
      value when is_integer(value) and value > 0 -> value
      value when is_float(value) and value > 0 -> trunc(value)
      _other -> 3600
    end
  end

  defp get(map, key, default \\ nil)
  defp get(map, key, default) when is_map(map), do: Map.get(map, key, default)
  defp get(_other, _key, default), do: default

  defp display_name(user, profile) do
    value = get(user, "firstName", "")

    cond do
      is_binary(value) and String.trim(value) != "" -> value
      true -> get(profile, "first_name", "account")
    end
  end

  defp clean_text(value, fallback) do
    text =
      value
      |> stringify()
      |> String.replace(
        ["[", "]", "|", "#", "!", "@", "$", "%", "^", "&", "*", "(", ")", "-"],
        " "
      )

    case String.split(text) |> Enum.join(" ") do
      "" -> fallback
      cleaned -> cleaned
    end
  end

  defp short_reason(reason), do: shorten(clean_text(reason, "reason"), "reason", 20)

  defp stringify(value) when is_binary(value), do: value
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value) when is_integer(value), do: Integer.to_string(value)
  defp stringify(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 2)
  defp stringify({:failed_connect, _reason}), do: "no network connection"
  defp stringify({:timeout, _reason}), do: "the request timed out"
  defp stringify({:failed_connect, _reason, _host}), do: "no network connection"
  defp stringify(value), do: inspect(value)

  defp whole(value, _fallback) when is_integer(value), do: value
  defp whole(value, _fallback) when is_float(value), do: trunc(value)
  defp whole(_value, fallback), do: fallback

  defp number(value) when is_integer(value), do: value
  defp number(value) when is_float(value), do: value
  defp number(_value), do: 0

  defp money(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 2)
  defp money(value), do: to_string(value)

  defp remaining(nil), do: 0

  defp remaining(stamp) do
    case whole(stamp, 0) do
      0 -> 0
      millis -> max(div(millis, 1000) - System.system_time(:second), 0)
    end
  end

  defp install_signal_handler do
    handler = fn ->
      IO.write("\n" <> @red <> @bold <> "Script stopped by user" <> @reset <> "\n")
      System.halt(0)
    end

    for signal <- [:sigint, :sigterm, :sighup, :sigquit] do
      try do
        System.trap_signal(signal, handler)
      rescue
        _error -> :ok
      end
    end
  end

  defp shorten(value, fallback, limit) do
    text = value |> to_string() |> String.trim()

    case String.slice(text, 0, limit) do
      "" -> fallback
      short -> String.trim(short)
    end
  end

  defp plural(count, word) do
    if count == 1, do: "#{count} #{word}", else: "#{count} #{pluralize(word)}"
  end

  defp pluralize(word) do
    cond do
      String.ends_with?(word, "y") -> String.slice(word, 0, String.length(word) - 1) <> "ies"
      true -> word <> "s"
    end
  end

  defp countdown(seconds, label) do
    left = max(trunc(seconds), 0)

    if left >= 1 do
      width = frame(label, left, 0)
      tick(left, label, width)
    end
  end

  defp tick(0, _label, width) do
    IO.write("\r" <> String.duplicate(" ", width) <> "\r")
  end

  defp tick(left, label, width) do
    width = frame(label, left, width)
    :timer.sleep(1000)
    tick(left - 1, label, width)
  end

  defp frame(label, left, width) do
    text = label <> " " <> format_duration(left)
    IO.write("\r" <> @yellow <> @bold <> text <> @reset)
    max(width, String.length(text))
  end

  defp format_duration(total) do
    days = div(total, 86_400)
    hours = div(rem(total, 86_400), 3600)
    minutes = div(rem(total, 3600), 60)
    seconds = rem(total, 60)

    if days > 0 do
      pad(days) <> ":" <> pad(hours) <> ":" <> pad(minutes) <> ":" <> pad(seconds)
    else
      pad(hours) <> ":" <> pad(minutes) <> ":" <> pad(seconds)
    end
  end

  defp pad(value), do: String.pad_leading(Integer.to_string(value), 2, "0")

  defp green(message), do: IO.puts(@green <> @bold <> message <> @reset)
  defp yellow(message), do: IO.puts(@yellow <> @bold <> message <> @reset)
  defp red(message), do: IO.puts(@red <> @bold <> message <> @reset)
end

JVaultMiner.run()
