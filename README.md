# ClaudeAccounts

**Switch Claude accounts without losing your chats.**

[![Latest release](https://img.shields.io/github/v/release/RohanNaga/ClaudeAccounts?style=flat-square&color=0a0a0c)](https://github.com/RohanNaga/ClaudeAccounts/releases/latest)
[![macOS 15+](https://img.shields.io/badge/macOS-15%2B-0a0a0c?style=flat-square)](https://github.com/RohanNaga/ClaudeAccounts/releases/latest)
[![Homebrew](https://img.shields.io/badge/brew-rohannaga%2Ftap%2Fclaudeaccounts-orange?style=flat-square)](https://github.com/RohanNaga/homebrew-tap)
[![License: MIT](https://img.shields.io/badge/license-MIT-6e5aff?style=flat-square)](LICENSE)

A macOS menu bar app for people with more than one Claude seat: a work plan, a
team, a personal plan. A seat is one Claude account in one organization, and
each seat is one row in the menu. The app does three things:

1. It shows each seat and how much usage it has left: the 5-hour and weekly
   limits, with their reset times.
2. It switches the Claude desktop app to a seat when you click **Switch**, and
   your open Claude Code chats move with it: same history, same worktrees.
3. It switches by itself when the seat in use is truly out, then sends each
   chat that was stopped one "resume" message.

<p align="center">
  <img src="docs/menu.png" width="346" alt="The ClaudeAccounts menu: eight seats across five accounts, the seat in use with both meters and their resets, two seats out with their reset times, one seat still to set up, and Switch on every other one-line row">
</p>

> ClaudeAccounts is an independent project. It is not made, endorsed or
> supported by Anthropic. Claude is a trademark of Anthropic. Use each account
> under Anthropic's terms for that account.

## Install

```bash
brew install --cask rohannaga/tap/claudeaccounts
```

Or download `ClaudeAccounts-<version>.zip` from the
[latest release](https://github.com/RohanNaga/ClaudeAccounts/releases/latest),
unzip it, and move **Claude Accounts** to Applications.

You also need the Claude desktop app, and Claude Code installed at
`~/.local/bin/claude`: each seat's meters are read through its own Claude Code
sign-in. The app runs on macOS 15 or later.

The app isn't notarized by Apple, so macOS stops the first launch with "Apple
could not verify Claude Accounts is free of malware". Open **System Settings ›
Privacy & Security**, scroll down, and click **Open Anyway**. If you'd rather
use Terminal:

```bash
xattr -dr com.apple.quarantine "/Applications/Claude Accounts.app"
```

## Getting started

Before there are any rows, the menu says what the app reads and keeps, and asks
you to open Claude and sign in.

1. Open Claude and sign in. A minute later the seat Claude is on becomes the
   first row. When Claude is later on a seat that isn't a row, the menu says so
   and offers **Add**.
2. **Add Account…** in the menu's `···` signs a seat in to Claude Code for its
   meters. Your browser opens Claude's sign-in page; paste the code it shows
   back into the app. A row whose meters have no sign-in has **Sign in
   again…** in its `···` menu.
3. A row with no saved Claude login reads "Sign in once" and has **Set Up**.
   Set Up quits Claude and reopens it at its sign-in page. Sign in as that seat.
   Once Claude has stayed on it for a minute, the app saves its login, and from
   then on Switch moves to it.
4. For the automatic switch, click **Allow…** in the menu and turn on
   **Claude Accounts** under System Settings › Privacy & Security ›
   Accessibility. It answers Claude's quit prompt and types "resume" with it.

## How a switch works

Switch, Set Up and the automatic switch all run one procedure. Each step is
written to a journal before it runs, so an interrupted switch can be finished
or undone. The menu's one notice line says which step is running.

1. **Quit.** The app asks Claude to quit and watches its process and windows
   ("Quitting Claude…"). If a chat is mid-reply, Claude asks first. A switch you
   started waits for your answer. **Cancel** ends it with "Switch cancelled."
   and nothing changed.
2. **Back up and save.** It backs up Claude's cookie database and settings
   file. If Claude had stayed on the current seat for a minute, it saves that
   seat's login ("Saving <seat>…"). A login is written to a new file, checked,
   then renamed over the old one, and the previous copy is kept until the new
   one checks out.
3. **Move chats.** Each open chat's record moves from the current seat's folder
   to the target's, so its session id, transcript and worktree stay the same.
   Archived chats and scheduled runs stay with their seat.
4. **Load.** It loads the target's saved login ("Loading <seat>…"). Set Up
   clears the sign-in instead, so Claude asks for one.
5. **Launch and confirm.** It reopens Claude and waits up to 3 minutes (10 for
   Set Up) for Claude's log to name the target and stay on it for a minute
   ("Waiting for Claude to open as <seat>…"). Then the notice reads "Switched
   to <seat>." and the chats are resumed.

If Claude names another seat, asks for a new sign-in, or doesn't open in time,
the switch rolls back: Claude quits, the chats move back, the previous login is
loaded, and Claude reopens. The notice says why and ends "Back on <seat>." If
you close Claude during the wait, the notice reads "Open Claude to finish
switching to <seat>." If the app or the Mac stops mid-switch, the next launch
reads the journal. A switch stopped before its load step is undone, and one
stopped after it is finished. Only one switch runs at a time.

Each switch leaves a folder in `backups` with the files from before it and
`switch.json` listing what moved. The last ten are kept.

## Automatic switching

The automatic switch runs only when the seat in use is truly out. Claude must
have stayed on that seat for a minute, and then either stopped a chat because
the seat hit its limit, or ended a turn after which the seat's meter reads 100
percent. The meters alone never start a switch.

It goes down the menu from the seat in use, wrapping round to the top, and
picks the first seat that is ready, has a reading from the last 15 minutes, and
hasn't failed a switch in the last 10 minutes. **Move Up** and **Move Down** in
a row's `···` menu set that order. Because nobody is there to answer Claude's
quit prompt, the automatic switch presses **Quit anyway** itself. If Claude
still hasn't quit after 3 minutes, it cancels and changes nothing.

When every seat is out, it stays put, and the notice says which seat resets
first. With more than one seat, one notification says so too.

It pauses itself, with one line in the menu saying why:

- **Auto-Switch When Out** in the menu's `···` is off. That toggle is the only
  setting for it, and it is on from the start.
- Accessibility isn't allowed. macOS ties that permission to the app's
  signature, so a new version may need it again.
- Something the app expects from Claude is missing at run time: Claude reopens
  without its log naming a seat within the confirm wait, the quit prompt has no
  **Quit anyway** button, or Claude's cookie database is in a format the app
  doesn't know. The line reads "Switching on its own is paused." with the
  reason, and switching turns back on by itself once that changes. The app
  never looks at Claude's version, so an update that changes none of these
  changes nothing. **Switch** by hand keeps working when the log line or the
  button is missing, because it needs only quit, launch and that one log line,
  and it rolls back if the line never comes. An unknown cookie format stops it
  too, before anything changes.

The app posts notifications only for automatic outcomes: a switch that
succeeded or failed, and every seat being out.

## After the switch

Once Claude confirms the new seat, each moved chat that was stopped by the
limit, wrapped up its turn, or was cut off by the quit gets one new message,
"resume". The app opens the chat with a `claude://code/continue` link, checks
through Accessibility that Claude's window shows that chat, puts "resume" in
its message box and presses Send, once. It skips a chat that is running, a
chat whose message box holds a draft, and a chat it has already resumed. It
never presses Retry, Rewind, Stop or Keep working.

A chat that doesn't start is tried again every minute for 30 minutes, and only
after a minute with nobody using the Mac. After that the menu names the chats
that need a message from you. Each step is written to `resume.log` in the app's
folder.

## What it cannot guarantee

- **Claude can change its log, files or window in an update.** Automatic
  switching and resume pause, manual Switch keeps working where its few needs
  hold, and one line says so. If Claude's cookie format changes, every switch
  stops before it changes anything, until the format is one the app knows.
- **The meters come from an undocumented usage service.** If it fails or
  changes, the meters aren't read, the automatic switch has no target, and
  manual Switch still works.
- **Claude may refuse a saved login at any time**, for a sign-in that is too
  old or a change on its side. The switch rolls back, and the row asks you to
  sign in once more.
- **Typing "resume" depends on Claude's window and on Accessibility.** If
  either fails, the app names the chats that need a message.
- **A chat that wrapped up may have been finished.** It still gets one
  "resume", which costs one short reply.
- **Usage credits.** A meter at 100 percent with credits still available can
  count as out after a turn ends, so the switch can come early.
- **A crash of the Mac itself mid-switch.** The journal finishes or undoes the
  switch at the next launch.

## Privacy

Nothing the app keeps leaves the Mac. It has no analytics and no update check.

### Network

- **Usage service.** The app's only network request of its own is
  `GET https://api.anthropic.com/api/oauth/usage`, made with each seat's Claude
  Code token: every 5 minutes, a minute after each reset, and at most once a
  minute after a turn ends. An HTTP 429 answer waits as long as the service
  asks, or 5 minutes.
- **Token renewal.** When a seat's token has under 10 minutes left, the app
  runs `claude -p /usage --no-session-persistence` for that seat, and Claude
  Code renews the token itself. This spends no model usage.
- **Sign-in and removal, only when you click.** **Add Account…** and **Sign in
  again…** run `claude auth login --claudeai` and open Claude's sign-in page in
  your browser. **Remove…** runs `claude auth logout` for that seat.

The `claude://` links that open chats and the link to System Settings stay on
the Mac. Claude itself, which the app quits and reopens, makes its own
connections as usual.

### On the Mac

| Where | What | When |
|---|---|---|
| `~/Library/Application Support/ClaudeAccounts` | Everything the app keeps: `accounts.json`, settings, each seat's Claude Code login folder, saved Claude logins, meter readings, the switch journal, backups, `resume.log`, and `diagnostics.jsonl` | Always |
| `diagnostics.jsonl` | One line per change of Claude's state, a seat's state or the automatic decision, and each switch's start and end, with times, state names and row numbers only. No names, emails, ids or tokens. It rotates at 4 MB | Always |
| Login keychain | One `Claude Code-credentials-<hash>` item per seat, written by Claude Code. The app reads its token for the usage service | Always |
| `~/Library/Application Support/Claude` | The claude.ai cookie rows, three keys in `config.json`, and chat records in `claude-code-sessions` | Written only during a switch, with Claude quit. Read to save the seat in use's login once Claude has stayed on it for a minute |
| `~/Library/Logs/Claude/main.log` | Read only: which seat Claude is on and since when, refused sign-ins, chats stopped at a limit, and turns that ended | Always |
| Claude's windows, through Accessibility | The quit prompt's **Quit anyway** button, and each chat's message box and Send button | During an automatic switch, and when resuming chats |

**Remove…** in a row's `···` menu deletes its saved login, signs its Claude Code
login out and deletes its keychain item. Its chats stay in Claude. To
uninstall, remove your rows, quit the app, and delete it and the
`~/Library/Application Support/ClaudeAccounts` folder.

## The menu

The title bar and one notice line stay in place, and the rows scroll. The menu
is never taller than the screen, and it opens on the seat in use.

- A ready or out seat is one line: its name, the fuller meter with its percent,
  "Out" with its reset time when out, and **Switch**. Click the name to see both
  meters.
- The seat in use shows both meters with their resets.
- An account in several organizations, like a personal plan and a team, is one
  card with a row per organization. Its own personal organization shows as
  **Individual**. Click the account's name to fold its organizations away.
- A row's `···` menu has **Rename…** (rename to an empty name, or **Reset
  Name**, to go back), **Color**, **Move Up**, **Move Down**, **Sign in
  again…** and **Remove…**.
- The title's `···` menu has **Add Account…**, **Menu Bar Shows**, **Gauge
  Tracks** (5-hour or weekly limit), **Auto-Switch When Out**, **Open at Login**
  and **Quit Claude Accounts**.

## Command line

The binary is at `Claude Accounts.app/Contents/MacOS/ClaudeAccounts`.

| Command | What it does |
|---|---|
| `--status` | Prints Claude's state, whether automatic switching is on, each row's state by its label, and the automatic decision. It reads the same facts as the menu and changes nothing |
| `--test-resume <title or id>` | Sends "resume" to that one open chat by the steps a switch takes after it reopens Claude, once, and prints each step. Use a chat you don't mind getting it |

`--test-resume` needs Accessibility. To use the app's own access rather than
your terminal's, start it through the app:

```sh
open -n -W -o "$(tty)" --stderr "$(tty)" -a "/Applications/Claude Accounts.app" --args --test-resume "<chat title>"
```

## Build from source

```bash
git clone https://github.com/RohanNaga/ClaudeAccounts.git
cd ClaudeAccounts
./build.sh
open "Claude Accounts.app"
```

It needs the Xcode Command Line Tools (`xcode-select --install`). `build.sh`
compiles one binary for Apple Silicon and Intel with `swiftc`. If this folder's
copy of the app is running, `build.sh` quits it before signing and opens it
again afterwards. It never touches a copy elsewhere.

macOS ties the Accessibility permission to the app's signature, and the ad-hoc
signature `build.sh` uses by default changes with every build, so each rebuild
asks for the permission again. To keep it across builds, run
`scripts/make-signing-identity.sh` once to add a local signing identity to your
login keychain; `build.sh` signs with it from then on.

`test.sh` runs the rule checks in `tests/`, then drives the quit prompt code
against a real native alert and the resume step against a stand-in chat window.
Those flash small windows for a moment and need Accessibility for your
terminal. `release.sh` builds and zips the app into `dist/` for a GitHub
release and prints the checksum the Homebrew cask needs. The icon is drawn by
`app/make-icon.swift`; delete `app/AppIcon.icns` to regenerate it.

Before 0.3 the app kept its state in a `data` folder beside itself. A launch
that finds one moves it to Application Support and carries each login's
keychain item over.

## License

MIT. See [LICENSE](LICENSE).
