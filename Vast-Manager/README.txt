Vast-Switch-Log: manage your Vast.ai rentals
=============================================

What it is
----------
A terminal tool for Vast.ai: see your rentals (GPU, state, price, template,
running image), switch a rental to one of your private templates (update +
recycle, with progress and logs), reboot a rental, follow the logs live, and
keep several API keys. It never destroys a rental.

The language follows your system: French on a French system, English
otherwise. Force it with -Language en (or fr), see "Options" below.

It drives the official Vast.ai command-line tool, "vastai" (a Python
program): if it is missing, the script offers to install it.

macOS
-----
1. Install PowerShell 7 once:   brew install --cask powershell
   (or the .pkg from https://github.com/PowerShell/PowerShell/releases).
   Python 3 is needed for vastai (macOS has it, or: brew install python).
2. Keep vast-switch-log.command and vast-switch-log.ps1 in the same folder.
3. Double-click vast-switch-log.command. The first time, macOS blocks it
   ("cannot be opened because it is from an unidentified developer"):
   right-click the file > Open > Open. This is asked only once.
   If the Finder says the file is not executable, run once in Terminal:
   chmod +x /path/to/vast-switch-log.command
4. The script looks for vastai on the PATH, then in Homebrew, pipx and
   ~/Library/Python/3.x/bin (where "pip install --user" puts it).
5. Extra API keys (menu 5) go to the macOS Keychain (Keychain Access >
   login > "Vast-Switch-Log"). The first time the script reads one, macOS
   asks whether pwsh may use it: click "Always Allow". The active key stays
   where vastai keeps it: ~/.config/vastai/vast_api_key (plain text, that is
   how vastai works).

Windows
-------
Keep vast-switch-log.bat and vast-switch-log.ps1 in the same folder and
double-click the .bat (Windows PowerShell 5.1 is enough). Python from
python.org is needed for vastai. If Windows shows "Windows protected your
PC": More info > Run anyway. To stop that message: right-click each file >
Properties > Unblock > OK.
Extra API keys are stored encrypted for your Windows session (DPAPI); the
active key is in C:\Users\<you>\.config\vastai\vast_api_key (vastai's file).

Menu
----
1. View my rentals
   State, age, price per hour, hashrate (last reading of each GPU in the
   rental logs, read in parallel; a few seconds per batch of 6 rentals),
   template, running image (yellow when it differs from the template image).
   Below the table: total per hour and per day, total hashrate of the
   running rentals, then the Vast.ai credit and the remaining time at the
   current rate (yellow under 24 h, red under 6 h). The credit comes from
   Vast.ai, nothing to enter.
   Then the PRL line: price (CoinGecko, in $, 24 h change), network
   hashrate, block reward and block time (whattomine), refreshed every 5 min;
   and the profitability of your total hashrate, source by source:
     Profitability for 2,736.8 TH/s  ·  cost $513.44 /day
     Source       PRL/day   $/day     Result/day
     whattomine      57.1   $57.65    -$455.79
     unMineable      54.2   $54.19    -$459.25
     HeroMiners      55.7   $55.70    -$457.74
   (a source that does not answer is left out),
   then, if you saved an address (menu P), the "Power" table: hardware / at
   the pool / ratio, per pool and in total.
   Numbers are shown the English way in English ($1,234.56) and the French
   way in French (1 234,56 $), whatever the system regional setting.

2. Change the template
   - pick the rentals: 1   or   1,3   or   2-4   or   A (all);
   - your private templates are listed (one line per template, always the
     latest version);
   - type the template number: its configuration is shown (image, launch
     mode, variables, ports, start-up script);
   - "y" to apply, "n" to pick another one;
   - the script runs "update" then "recycle" (the only way to apply a
     template), waits for the restart (10 min at most), shows the last 100
     log lines, then a summary.

3. Reboot
   Stops then restarts the container, same template and image. Progress
   every 5 s, logs, then a summary.

4. Live logs
   One rental, a filter (everything, hashrates, GPU only, CPU only, shares
   and errors, image messages, or free text), refreshed every 5 s
   (-LogRefreshSeconds). Q or Esc = back to the menu. Nothing is changed.

5. Vast.ai API keys (switch, add, remove)
   Known keys: account, last 4 characters, active one.
   - a number: switch to that key (tested first; a revoked key does not
     replace the active one); every menu then uses that account;
   - A: add a key (hidden input, test, account and credit shown,
     confirmation) and make it active;
   - R: remove a key from the list (it stays valid on Vast.ai);
   - K: when vastai's active key is not in the list yet.
   The menu title shows the active account.

6. GPUs: prices and offers
   For the GPUs you type (Enter = 5090, 4090, 3090; "3090 Ti" works too):
   number of offers rentable right now (on demand, verified machines), min
   and median price per GPU per hour, and the cheapest offer (number of
   GPUs, country, reliability, download speed). Same search as
   "vastai search offers".

P. Pool: my wallet
   Give the PRL address you mine with on HeroMiners and/or unMineable (kept
   in pools.json next to keys.json; an address is public). The menu first
   shows the "Power" table: per pool, hardware (total hashrate from the logs
   of the last menu 1), at the pool (what the pool sees right now) and ratio =
   pool ÷ hardware (green ≥ 0.95, yellow from 0.85 to 0.95, red below), then
   the combined total of the pools. Then one box per pool: power (now, 1 h,
   24 h), workers, earnings (HeroMiners: yesterday, 7-day average, paid 24 h /
   7 d; unMineable: 24 h, 7 d, 30 d), balance.
   Menu 1 shows the same "Power" table below the profitability table.
   Option 4: another pool (without API) with a ratio entered by hand (e.g.
   0.8) appears in the profitability table as "Kryptex (×0.80)".

7. Quit (Q works too)

API keys
--------
If Vast.ai rejects your key at start-up, the script asks for a new one
(hidden input), tests it and stores it with "vastai set api-key".
Create keys on cloud.vast.ai > Account > Keys.

Safety
------
The script only uses: show user, set api-key, show instances,
search templates, update instance, recycle instance, reboot instance, logs.
Menus 1 and 4 only read; menu 5 only touches keys. It never destroys a
rental and keeps no template hash in its files.

Display
-------
Frames and tables use box-drawing characters. On Windows, if you see "?"
instead of lines, pick the Consolas font in the window properties.

Options (optional)
------------------
From a terminal, in the script folder:
  macOS:   ./vast-switch-log.command -Language en -PollSeconds 30
  Windows: .\vast-switch-log.bat -Language en -PollSeconds 30
  -Language          : auto (default), en or fr
  -PollSeconds       : interval between two checks (15 s by default)
  -TimeoutSeconds    : maximum wait for the restart (600 s by default)
  -LogRefreshSeconds : live logs refresh (5 s by default, 3 minimum)
