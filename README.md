# ClaudeAccounts

**Switch Claude accounts without losing your chats.**

[![Latest release](https://img.shields.io/github/v/release/RohanNaga/ClaudeAccounts?style=flat-square&color=0a0a0c)](https://github.com/RohanNaga/ClaudeAccounts/releases/latest)
[![macOS 15+](https://img.shields.io/badge/macOS-15%2B-0a0a0c?style=flat-square)](https://github.com/RohanNaga/ClaudeAccounts/releases/latest)
[![Homebrew](https://img.shields.io/badge/brew-rohannaga%2Ftap%2Fclaudeaccounts-orange?style=flat-square)](https://github.com/RohanNaga/homebrew-tap)
[![License: MIT](https://img.shields.io/badge/license-MIT-6e5aff?style=flat-square)](LICENSE)

A macOS menu bar app for people with more than one Claude account, like a work
plan, a school plan and a personal one. It shows the usage of every account at
once: the 5-hour and weekly limits, or the weekly limit alone for a plan that
has no 5-hour limit. One click switches the Claude desktop app to another
account, and your open Claude Code chats come with you: same history, same
worktrees. When Claude stops a chat because the account in use is out of usage,
it switches by itself to the next account in the menu, in the order you set.
An account that
belongs to two
organizations, like a personal plan and a team, shows both under the account's
name, each with its own usage, and either one can be switched to; click the
name to fold them away. The account's own individual organization shows as
**Individual**. **Rename…** on an organization's `···` menu names that
organization, and the `···` beside the account's name renames the account. A
row that isn't set up yet says how. Every other row has a Switch button, even
for an account that is out of usage: its red meter and reset time say so, and
the choice is yours. Only the automatic switch skips accounts that are out.

<p align="center">
  <img src="docs/menu.png" width="355" alt="The ClaudeAccounts menu: an account with two organizations, the one in use marked, the row auto-switch goes to next marked Next, and Switch on every other row, including an account out of usage, each with its usage">
</p>

> ClaudeAccounts is an independent project. It is not made, endorsed or
> supported by Anthropic. Claude is a trademark of Anthropic. Use each account
> under Anthropic's terms for that account.

## Why

The Claude desktop app holds one account at a time. Signing out and back in as
another account works, but your open Claude Code chats stay behind with the old
account. ClaudeAccounts swaps the account for you and carries the chats over, and
its menu shows at a glance which account has room left.

## Install

```bash
brew install --cask rohannaga/tap/claudeaccounts
```

Or download `ClaudeAccounts-<version>.zip` from the
[latest release](https://github.com/RohanNaga/ClaudeAccounts/releases/latest),
unzip it, and move **Claude Accounts** to Applications.

You also need the Claude desktop app, and Claude Code installed at
`~/.local/bin/claude` (the app uses it to sign in to each account). The app runs
on macOS 15 or later, on Apple Silicon and Intel. Switching was tested with
Claude desktop 2.9939.2 on macOS 27. Auto-switch, resuming stopped chats and
switching between organizations were built against Claude desktop 6.6395.1
and are tested on fixtures only so far (see
[Read this before you switch](#read-this-before-you-switch)).

### First launch

The app isn't notarized by Apple, so macOS stops the first launch with "Apple
could not verify Claude Accounts is free of malware". Open **System Settings ›
Privacy & Security**, scroll down, and click **Open Anyway**. If you'd rather
use Terminal:

```bash
xattr -dr com.apple.quarantine "/Applications/Claude Accounts.app"
```

## Getting started

1. Click the gauge in the menu bar, then **Add Account…**. Your browser opens
   Claude's sign-in page; paste the code it shows back into the app. Repeat for
   each account.
2. For every account other than the one Claude is signed in to, click
   **Set Up**. Claude reopens at its sign-in page; sign in as that account. Once
   Claude has stayed on it for a minute, the app saves its Claude login without
   signing the others out, and brings over the chats that were open in the
   previous row the way a switch does. If you end up signed in to another
   account, nothing is saved or moved, Claude stays open, and the menu says which
   account Claude is on.
3. From then on, **Switch** on any row moves Claude, and your open chats, to
   that account.
4. Auto-switch is on from the start: when Claude stops a chat because the
   account in use is out of usage, the app quits Claude, reopens it on the
   next account in the menu that has room, and sends "resume" to each chat that was working. Click **Allow…** in the menu, then
   turn on **Claude Accounts** under System Settings › Privacy & Security ›
   Accessibility, so an automatic switch can answer Claude's quit prompt and
   type that message (see [Auto-switch](#auto-switch)).

## Read this before you switch

Switching works by editing the Claude desktop app's own files while it is quit:
its cookie database, its settings file and its chat records. Resuming chats
reads Claude's window through Accessibility. None of that is a public
interface, and an update to Claude can change it. The app is built to
fail closed. It backs everything up first, refuses to act when something looks
off, and undoes a switch that Claude doesn't confirm. Still, use it at your own
risk, and keep the backups in the app's `backups` folder until you trust it on
your setup.

Auto-switch, answering Claude's quit prompt, resuming stopped chats and
switching between an account's organizations are new. So far they are tested
on fixtures: rule checks, plus stand-in windows built like Claude's quit prompt
and chat window. They have not yet run through a real switch. A chat the app
can't resume is named in a notification, and **Auto-Switch When Out** in the
header's `···` menu turns the automatic part off.

## What it touches

| Where | What | When |
|---|---|---|
| `~/Library/Application Support/ClaudeAccounts` | Everything the app keeps: accounts, per-account Claude Code logins (each pinned to its organization by a `forceLoginOrgUUID` line in its own `settings.json`), saved Claude logins, backups, settings, the usage cache, and `diagnostics.jsonl`: one line per change of Claude's state, a row's state, the automatic decision or a switch, with its time, state names and row numbers only, never a name, email, id or token. It never leaves the Mac | Always |
| Login keychain | One `Claude Code-credentials-<hash>` item per account, written by Claude Code | Adding or signing in to an account |
| `api.anthropic.com/api/oauth/usage` | Each account's usage, about once a minute | Always; this is the only network traffic |
| `~/Library/Application Support/Claude` | The claude.ai cookie rows, three keys in `config.json`, and chat records in `claude-code-sessions` | Written only on **Switch** or **Set Up**, with Claude quit; the account in use's cookie rows and keys are also read (copied into its saved login) once Claude has stayed on it for a minute; the folder names in `claude-code-sessions` are also read to find an account's other organizations |
| `~/Library/Logs/Claude/main.log` | Read only, to see which account Claude reports and since when, which organization sign-ins Claude refused as too old, and which chats Claude stopped because that account is out of usage | Always |
| Claude's quit prompt, through Accessibility | Reads whether the prompt is open; presses **Quit anyway** | Only on an automatic or `--unattended` switch |
| `claude://code/continue?session=…` and the chat's message box, through Accessibility | Opens each chat the quit or the limit stopped; types "resume" into that chat's own message box and presses its Send button, once; tries a chat that isn't running again every minute for 30 minutes while nobody uses the Mac | After every switch Claude confirms |

**Remove** on an account's `···` menu signs its login out and deletes its
keychain item. To uninstall, remove your accounts, quit the app, and delete it
and the `~/Library/Application Support/ClaudeAccounts` folder.

## How switching works

**Switch** on a row signs the Claude desktop app in as that account and brings
your open Code sessions along:

1. It asks Claude to quit the way ⌘Q does and waits until Claude's process is
   gone. If a chat is mid-reply Claude asks first, with **Quit anyway**, **Wait
   for Claude** and **Cancel**. The switch waits as long as that prompt is
   open, so a late answer is never lost: Quit anyway carries on, Wait for
   Claude carries on once Claude's chats finish and it quits, and Cancel ends
   the switch with nothing changed. An automatic switch answers Quit anyway
   itself (see [Auto-switch](#auto-switch)).
2. It backs up Claude's `Cookies` and `config.json` and writes a journal before
   changing anything.
3. It saves the current account's login (its claude.ai cookie rows and three
   settings keys), but only if Claude's log and settings agree on who that
   account is and Claude had stayed on it for a minute. An organization that
   wants a new sign-in is refused by Claude a few seconds after it opens, and
   Claude falls back to your individual organization; a login saved in that
   window would be the refused one, so the row keeps its last saved login.
4. It loads the target account's saved login.
5. It moves each open session's record (not archived, not a scheduled run) from
   `claude-code-sessions/<account>/<org>` to the target's folder. The session
   id, transcript, worktree and lease stay the same. If the target already has a
   copy, the newer one wins and the older one goes to the backup's `quarantine`.
6. It reopens Claude. The switch counts only when Claude's log reports the
   target account and organization. A sign-out, another account, or no answer
   within a minute undoes every step from the journal.
7. Once Claude confirms, it gets every chat the quit or the limit stopped
   running again (see [After the switch](#after-the-switch)).

The account shown as **In use** is the one Claude's own log reports: the line
Claude writes each time it loads an account's chats, naming the account and its
organization. Each switch leaves a folder in `backups` with the files from before
it and `switch.json` listing what moved; the last ten are kept.

## Auto-switch

Auto-switch is on unless you turn off **Auto-Switch When Out** in the header's
`···` menu. It switches when Claude itself says the account in use is out:
Claude stops a chat with "You've hit your … limit" or another of its
out-of-usage messages and writes that to its log. The app reads Claude's log
every 15 seconds. The usage meters never start a switch, at any value, so the
account is used up to the last request Claude accepts.

On that stop, the app quits Claude and reopens it on the next row in the menu
that is set up and has room, as if you had clicked Switch, then sends one
"resume" message to each chat that was working (see
[After the switch](#after-the-switch)). It goes down the menu from the row in
use and wraps round to the top. Each organization of an account is its own row,
in the order the menu lists them. The menu marks the row it would go to with
**Next**; when that row's account is folded away, the mark is on the account's
name.

You choose the order. **Move Up** and **Move Down** in a row's `···` menu move
it: on an organization row they move it among that account's organizations, and
on an account they move the whole account. The app remembers the order. A new
install, or an update, keeps the order the menu already shows.

It never switches:

- before Claude has stopped a chat of the account in use for usage, once it had
  stayed on that account for a minute (a stop sooner than that ends a turn
  begun on the account before);
- to an account that is out itself (a meter at 100 percent), isn't set up, has
  no reading from the last 15 minutes, or shows **Sign in again**;
- back to the account it left, until that account's usage resets, whatever its
  meter shows by then;
- within 10 minutes of its last try, whatever happened then, so a failed switch
  can't keep quitting Claude;
- while Claude isn't running, or while another switch runs.

When every other account is out too, it stays put and posts one notification
saying so.

Nobody is there to answer Claude's quit prompt, so an automatic switch presses
**Quit anyway** itself, through Accessibility. Claude shows that prompt only
while a chat is still mid-reply or running a command, and Quit anyway is what a
person switching by hand presses then. The app needs Accessibility access for
this and for resuming chats, and the menu asks for it while it is missing.
Without it an automatic switch waits at the prompt for a person, and nothing
changes until someone answers. macOS ties the
permission to the app's signature, so after installing a new version you may
need to allow it again.

Each automatic switch posts a notification that says which account Claude
stopped at its limit and how the switch went. The app posts its notifications
itself, so its first launch asks once to allow them; until you allow them in
that prompt or in System Settings > Notifications, none are shown. They show on
the Mac only.

## After the switch

Once Claude confirms the new account, the app gets every chat that was working
running again, the way you would by hand: it sends each one a new message,
"resume". A chat that was idle is left alone. A working chat stopped in one of
two ways:

- **Stopped by the limit.** When the account runs out, Claude ends each
  working chat's turn with "You've hit your … limit".
- **Cut off by the quit.** A chat still mid-reply or running a command when the
  app quits Claude. Claude may mark such a chat and resume it itself after it
  reopens; the app gives Claude 45 seconds for that first.

The app reads both from Claude's log of the run that just ended, after Claude
has quit.

Then, one chat at a time, most recently active first:

1. It opens the chat with `claude://code/continue?session=<id>`.
2. It checks, through Accessibility, that Claude's window now shows that chat.
   It matches the session id in the page's address, never the window's place
   or order.
3. It waits, up to two minutes, for the chat's page to finish loading and show
   its message box. The box is the page's own text box named Prompt, or else its
   only multi-line text box, so a side panel's address field or an artifact's
   own text box is never taken for it.
4. If the chat is already running, it leaves it alone. If its message box holds
   text you haven't sent, it leaves that too. A chat the quit cut off gets 10
   seconds to resume by itself on open.
5. Otherwise it puts "resume" in that chat's message box, waits for Claude to
   show Send beside it (Claude shows Send only once the box holds text), and
   presses it, once. It posts no keystrokes, so it doesn't matter which window
   has keyboard focus, and it never presses a suggested reply.
6. It waits for the chat to show its turn running, up to 30 seconds, before it
   opens the next one.

A chat that isn't running after that is tried again every minute for 30
minutes, until it runs or someone types in it. A retry opens a chat only after
a minute with nobody using the Mac, so it never pulls you away from another
chat. A chat that was sent "resume" is never sent it again. Then the
notification says how many stopped chats are running again.

A chat's subagents run inside it and stop with it, so the chat is what gets the
message: its next turn starts them again.

It never presses Retry or Rewind. Retry on a failed message rewinds the chat and
starts its transcript over under a new id, without its subagents; a new message
keeps them. A chat still not running after the 30 minutes is named in the
notification and the menu with the reason, for example "it has an unsent draft".
Send that one a message yourself. Each step is written to `resume.log` in the
app's state folder.

To watch these steps on one chat, run `--test-resume` with the chat's title or
session id (see [Command line](#command-line)). It sends "resume" to that chat,
so use a chat you don't mind getting it.

Reaching a chat from your phone: Remote Control re-registers under the new
account, so the Claude app on your phone has to be signed in to that account
to see the chats.

A chat that was running in bypass-permissions mode keeps it: the mode is part of
the chat's record, and Claude starts the chat again with it. Claude does not
resume a bypass chat on its own where bypass is no longer allowed.

A switch keeps each chat's Claude Code session id.

## Organizations

An account that belongs to more than one organization, like a personal plan and
a team, shows its name once with each organization beneath it, each with its
own usage, **Switch** button and Claude Code login. Switch moves Claude and your
open chats between an account's organizations the same way it moves them
between accounts.

To add the other organization, click **Add Account…** and sign in with the same
Google account. If the sign-in lands on the organization you already added,
the sheet offers **Add Other Organization**. If Claude has opened that other
organization before, the sign-in page picks it for you; otherwise choose it on
the page before you click Authorize. The app pre-selects it through Claude
Code's `forceLoginOrgUUID` setting in that login's own folder.

One step is Claude's own: choose the new organization once from your name at
the bottom of Claude's sidebar. The app saves that organization's Claude login
once Claude has stayed on it for a minute, and from then on Switch and
auto-switch can move to it. If Claude asks for a new sign-in to that
organization, its row says so: choose it in Claude, sign in, and stay
on it for a minute. That request is about one account's sign-in, so it never
touches another account's row in the same organization, and it is over once
Claude has stayed on that account and organization for a minute.

## Command line

The binary is at `Claude Accounts.app/Contents/MacOS/ClaudeAccounts`.

| Command | What it does |
|---|---|
| `--status` | Prints Claude's state, whether automatic switching is on, each row's state by its label, and the automatic decision. It reads the same facts as the menu and changes nothing |
| `--switch <name>` | Runs a switch to the row named by id, label, email or the email's first part |
| `--auto-switch` | Runs the Auto-Switch rule once: if Claude's log shows it stopped a chat of the account in use for usage, switches to the next row in the menu's order that is set up and has room, judged on the usage the menu last read. With `--dry-run` it prints the rows in that order and the one it would choose |
| `--unattended` | With `--switch`, answers Claude's quit prompt with Quit anyway (implied by `--auto-switch`) |
| `--dry-run` | Prints every check and what would happen, and changes nothing |
| `--detach` | Starts the command in its own session and returns; output goes to `--log <file>`, by default `last-switch.log` in the app's state folder |
| `--test-resume <title or id>` | Sends "resume" to that one open chat of the account Claude has open, by the steps a switch takes after it reopens Claude, once, and prints each step |

Quitting Claude ends the processes Claude started, so from a shell inside
Claude, for example in a Claude Code chat, add `--detach`. Without it, run the
command from a terminal outside Claude.

`--test-resume` needs Accessibility. To use the app's own access rather than
your terminal's, start it through the app:

```sh
open -n -W -o "$(tty)" --stderr "$(tty)" -a "/Applications/Claude Accounts.app" --args --test-resume "<chat title>"
```

## Usage and sign-in

- About once a minute the app reads each account's usage from the same endpoint
  and at the same pace as the Claude app's own reader. Asking faster earns HTTP
  429 with a multi-minute `Retry-After`; when that happens the row keeps its
  last numbers, notes when it will retry, and waits exactly that long.
- Access tokens last about 8 hours. When one is close to expiry the app runs
  `claude -p /usage --no-session-persistence` for that account, and Claude Code
  renews the login itself. This spends no model usage.
- Each login has a fixed deadline about four weeks out that renewals don't
  extend. A day before it, the row shows **Sign in again** and the menu bar icon
  turns into a warning.
- Each row's `···` menu can **Rename** an account and pick its **Color**. The
  header's `···` menu sets what the menu bar shows and whether the gauge follows
  the 5-hour or the weekly limit. **Open at Login** registers the app in System
  Settings › Login Items.

## Limits

- A `claude setup-token` token can't read usage, because it lacks the
  `user:profile` scope. That's why the app uses full logins.
- Switching depends on Claude's cookie schema (version 24), its session-record
  layout, and one log line. If an update changes them, a switch fails closed: it
  is refused or undone rather than half-applied.
- Archived sessions and scheduled-task runs stay with the account they belong to.
- The quit prompt is found by its **Quit anyway** button, so a Claude update
  that renames it makes an automatic switch wait for a person instead.
- Auto-switch starts only from Claude's log line for a chat stopped for usage,
  and the chats to resume come from Claude's log lines too. If an update
  changes those lines, auto-switch doesn't switch and the chats wait for a
  message; Switch by hand still works.

## Build from source

```bash
git clone https://github.com/RohanNaga/ClaudeAccounts.git
cd ClaudeAccounts
./build.sh
open "Claude Accounts.app"
```

It needs the Xcode Command Line Tools (`xcode-select --install`). `build.sh`
compiles one binary for Apple Silicon and Intel with `swiftc`.

macOS ties the Accessibility permission to the app's signature, and the ad-hoc
signature `build.sh` uses by default changes with every build, so each rebuild
asks for the permission again. If you rebuild often, run
`scripts/make-signing-identity.sh` once to add a local signing identity to your
login keychain; `build.sh` signs with it from then on, and after allowing the
app once more the permission stays across builds. `test.sh` runs
the tests for the switching rules in `app/Rules.swift`, then drives the quit
prompt code against a real native alert and the resume step against a
stand-in chat window, which flash small windows for a moment; those parts need
Accessibility access for your terminal. `release.sh`
builds and zips it into `dist/` for a GitHub release and prints the checksum the
Homebrew cask needs. The icon is drawn by `app/make-icon.swift`; delete
`app/AppIcon.icns` to regenerate it. Before 0.3 the app kept its state in a
`data` folder beside itself; the first launch of 0.3 moves it to Application
Support and carries each login's keychain item over.

## License

MIT. See [LICENSE](LICENSE).
