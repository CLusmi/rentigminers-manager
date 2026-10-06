Salad-Switch-Log: manage your SaladCloud container groups and machines
=======================================================================

What it is
----------
A terminal tool that talks directly to the SaladCloud API: see your groups
and machines (with the GPU, hashrate and watchdog state read from the logs),
change the image tag, replicas, watchdog settings, priority or GPU miner, reallocate or
restart machines, follow the logs live, start or stop a group, and check GPU
prices and availability. It never deletes a group.

The language follows your system: French on a French system, English
otherwise. Force it with -Language en (or fr), see "Options" below.

macOS
-----
1. Install PowerShell 7 once:   brew install --cask powershell
   (or the .pkg from https://github.com/PowerShell/PowerShell/releases).
2. Keep salad-switch-log.command and salad-switch-log.ps1 in the same folder.
3. Double-click salad-switch-log.command. The first time, macOS blocks it
   ("cannot be opened because it is from an unidentified developer"):
   right-click the file > Open > Open. This is asked only once.
   If the Finder says the file is not executable, run once in Terminal:
   chmod +x /path/to/salad-switch-log.command
4. Your API key is stored in the macOS Keychain (Keychain Access > login >
   "Salad-Switch-Log"). The first time the script reads it, macOS asks
   whether pwsh may use it: click "Always Allow".

Windows
-------
Keep salad-switch-log.bat and salad-switch-log.ps1 in the same folder and
double-click the .bat. Nothing to install (Windows PowerShell 5.1 is enough).
If Windows shows "Windows protected your PC": More info > Run anyway. To stop
that message: right-click each file > Properties > Unblock > OK.
The API key is stored encrypted for your Windows session (DPAPI).

First run
---------
The script asks for:
  - organization and project: the two names in the portal address,
    portal.salad.com/organizations/ORGANIZATION/projects/PROJECT/containers
  - an API key: portal > your organization > API Access > Create key.
The key is tested, then stored (Keychain on macOS, encrypted on Windows).

Menu
----
1. View my groups
   State, running / requested machines, GPUs, priority, image, version,
   price per hour; totals per hour and per day; replica quota; balance and
   remaining time (see menu S); PRL line: price (CoinGecko, in $, 24 h
   change), network hashrate, block reward and block time (whattomine),
   refreshed every 5 min.

2. View the machines of a group
   Per machine: state, version, age, GPU and hashrate (read from the SRBMiner
   logs), price per hour, last watchdog verdict; totals per hour and per day,
   and the total hashrate of the running machines (sum of the last readings).
   "–" = nothing in the recent logs (allocating, downloading...).
   Below the table, the profitability of the total hashrate, source by source:
     Profitability for 3,412.8 TH/s  ·  cost $96.00 /day
     Source       PRL/day   $/day     Result/day
     whattomine      71.4   $73.52    -$22.48
     unMineable      64.9   $67.53    -$28.47
     HeroMiners      71.0   $73.25    -$22.75
   (a source that does not answer is left out),
   then, if you saved an address (menu P), the "Power" table: hardware / at
   the pool / ratio, per pool and in total.
   Numbers are shown the English way ($1,234.56) in English and the French
   way (1 234,56 $) in French, whatever the Windows regional setting.
   Logs are read in parallel over small windows, 12 s maximum per request
   (beyond that the window is split in two and read again). What has been
   read is kept in memory for the session: later views only fetch new lines.
   "partial" = some requests did not answer; the table shows what was read.

3. Edit a group
   - Image tag: the tags of the Docker Hub repository are listed, pick one
     (Salad only pulls an image again when the tag changes). Redeploys every
     machine, follows the progress, then shows the logs.
   - Number of replicas: running machines are not restarted.
   - Watchdog: mode (observe / reallocate / disabled), thresholds per GPU,
     grace period, readings, restarts, readings at 0 H/s, minutes without
     statistics. Enter = keep the current value,
     "none" = remove the variable. The script reads the group back and shows
     the variables really in place. Redeploys every machine.
   - Priority (price of each GPU shown per level). Redeploys.
   - GPU miner and its arguments (GPU_MINER, GPU_ARGS): the five miners of
     the rentingminers image (srbminer, forgeminer, krigminer, peakminer,
     rgminer) with the shape of each one's arguments; pick by number or by
     value, then type the arguments (each miner has its own syntax, see the
     image README). Enter = keep the current value. The group is read back
     afterwards. Redeploys every machine.

4. Reallocate / recreate / restart machines
   Pick machines (1   1,3   2-4   A = all), then:
   - Reallocate: drop this PC and take another one;
   - Recreate: new container on the same PC;
   - Restart: restart on the same PC.
   Progress, then a summary. Salad limits these actions per minute (429).

5. Live logs
   One group, all its machines or one, a filter (everything, hashrates,
   shares and errors, watchdog [salad], image messages, free text), refreshed
   every 5 s. With "all machines" each line starts with the first 8 characters
   of the machine id. Q or Esc = back to the menu.

6. Start / stop a group
   Stop cuts the machines and keeps the group (its replicas still count
   against the quota); Start launches it again. Confirmation required.

7. GPUs: prices and availability
   Every GPU class with its price per priority (High, Medium, Low, Lowest),
   then, for the GPUs you pick, the number of machines free right now per
   priority (same figure as the portal creation form).

8. Salad API keys
   Known keys (organization, project, last 4 characters). A number = switch
   (the key is tested again); A = add; R = remove.

S. Salad balance
   The Salad API (API key) does not expose the balance. Two ways to get it:
   - Enter the balance by hand (read in the portal, Billing & Usage), e.g.
     42.50. Menu 1 then shows an estimate: the entered balance minus the
     spending at the current rate since the entry (the highest rate of the
     range, to stay on the safe side). Enter it again after a top-up or a
     change of GPUs. Kept in balances.json next to keys.json.
   - Connect the Salad portal: e-mail + password of your Salad account (not
     the API key). The script signs in to portal-api.salad.com, the portal's
     internal API (undocumented: Salad may change it), and reads the real
     balance on every menu 1 view. The password is typed hidden and never
     shown; it is kept on this computer only if you ask (encrypted like the
     keys, in portal.json). Otherwise, menu S on each launch to enter it
     again. If the portal fails, menu 1 falls back to the balance entered by
     hand and says why.
   In menu 1:
     Balance: $42.50 (Salad portal, just now)  ·  remaining ≈ 21 h at the
     current rate ($2.000 /h)      — yellow under 24 h, red under 6 h.
   To avoid a surprise stop at $0, the portal also offers auto recharge
   (Billing → Auto Recharge).

P. Pool: my wallet
   Give the PRL address you mine with on HeroMiners and/or unMineable (kept
   in pools.json next to keys.json; an address is public). The menu first
   shows the "Power" table:
     Power            Hardware      At the pool     Ratio
     HeroMiners       757.8 TH/s    687.2 TH/s      ×0.91
     unMineable       757.8 TH/s    720.0 TH/s      ×0.95
     Combined total   757.8 TH/s    1,407.2 TH/s    ×1.86
   Hardware = total hashrate from the logs (last menu 2); at the pool = what
   the pool sees right now; ratio = pool ÷ hardware (green ≥ 0.95, yellow from
   0.85 to 0.95, red below). Then one box per pool: power (now, 1 h, 24 h),
   active workers, earnings (HeroMiners: yesterday, 7-day average, paid 24 h /
   7 d; unMineable: 24 h, 7 d, 30 d), pending balance.
   Menu 2 shows the same "Power" table below the profitability table.
   Option 4: another pool (without API) with a ratio entered by hand (e.g.
   0.8) appears in the profitability table as "Kryptex (×0.80)".

9. Quit (Q works too)

Keys and safety
---------------
The key list is in:
  macOS:   ~/Library/Application Support/Salad-Switch-Log/keys.json
           (the keys themselves are in the Keychain)
  Windows: C:\Users\<you>\AppData\Roaming\Salad-Switch-Log\keys.json
           (keys encrypted for your Windows session)
A Salad API key gives full rights on the organization: do not share it.
The script never deletes a group; the only actions that change something are
in menus 3, 4 and 6, always after a confirmation.

Display
-------
Frames and tables use box-drawing characters. On Windows, if you see "?"
instead of lines, pick the Consolas font in the window properties.

Options (optional)
------------------
From a terminal, in the script folder:
  macOS:   ./salad-switch-log.command -Language en -PollSeconds 10
  Windows: .\salad-switch-log.bat -Language en -PollSeconds 10
  -Language          : auto (default), en or fr
  -PollSeconds       : redeployment polling interval (5 s by default)
  -TimeoutSeconds    : maximum wait for a redeployment (600 s by default)
  -LogRefreshSeconds : live logs refresh (5 s by default, 3 minimum)
Environment variable SALAD_LOG_TIMEOUT: maximum duration of one log request,
in seconds (12 by default), if Salad answers really slowly.
