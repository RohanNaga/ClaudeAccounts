# ClaudeAccounts

**Switch Claude accounts without losing your chats.**

[![Latest release](https://img.shields.io/github/v/release/RohanNaga/ClaudeAccounts?style=flat-square&color=0a0a0c)](https://github.com/RohanNaga/ClaudeAccounts/releases/latest)
[![macOS 15+](https://img.shields.io/badge/macOS-15%2B-0a0a0c?style=flat-square)](https://github.com/RohanNaga/ClaudeAccounts/releases/latest)
[![Homebrew](https://img.shields.io/badge/brew-rohannaga%2Ftap%2Fclaudeaccounts-orange?style=flat-square)](https://github.com/RohanNaga/homebrew-tap)
[![License: MIT](https://img.shields.io/badge/license-MIT-6e5aff?style=flat-square)](LICENSE)

A macOS menu bar app for people with more than one Claude account, like a work
plan, a school plan and a personal one. It shows the 5-hour and weekly usage of
every account at once. One click switches the Claude desktop app to another
account, and your open Claude Code chats come with you: same history, same
worktrees. Turn on **Auto-Switch** and it does that by itself when the account
in use is about to run out, moving to the account with the most room left.

<p align="center">
  <img src="docs/menu.png" width="355" alt="The ClaudeAccounts menu: four accounts with 5-hour and weekly usage bars, the one in use marked, and a Switch button on the others">
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
Claude desktop 2.9939.2 on macOS 27; auto-switch was built against Claude
desktop 6.6395.1.

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
   **Set Up**. Claude reopens at its sign-in page; sign in as that account. This
   saves the account's Claude login without signing the others out.
3. From then on, **Switch** on any row moves Claude, and your open chats, to
   that account.
4. To let it switch by itself, pick a threshold under **Auto-Switch** in the
   header's `···` menu and allow **Claude Accounts** under System Settings ›
   Privacy & Security › Accessibility when macOS asks (see
   [Auto-switch](#auto-switch)).

## Read this before you switch

Switching works by editing the Claude desktop app's own files while it is quit:
its cookie database, its settings file and its chat records. None of that is a
public interface, and an update to Claude can change it. The app is built to
fail closed. It backs everything up first, refuses to act when something looks
off, and undoes a switch that Claude doesn't confirm. Still, use it at your own
risk, and keep the backups in the app's `backups` folder until you trust it on
your setup.

## What it touches

| Where | What | When |
|---|---|---|
| `~/Library/Application Support/ClaudeAccounts` | Everything the app keeps: accounts, per-account Claude Code logins, saved Claude logins, backups, settings, the usage cache | Always |
| Login keychain | One `Claude Code-credentials-<hash>` item per account, written by Claude Code | Adding or signing in to an account |
| `api.anthropic.com/api/oauth/usage` | Each account's usage, about once a minute | Always; this is the only network traffic |
| `~/Library/Application Support/Claude` | The claude.ai cookie rows, three keys in `config.json`, and chat records in `claude-code-sessions` | Only on **Switch** or **Set Up**, with Claude quit |
| `~/Library/Logs/Claude/main.log` | Read only, to see which account Claude reports | Always |
| Claude's quit prompt, through Accessibility | Reads whether the prompt is open; presses **Quit anyway** | Only on an automatic or `--unattended` switch |
| `claude://code/continue?session=…` | Opens a chat a quit cut off, so Claude resumes it | After an automatic or `--unattended` switch |

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
   account is.
4. It loads the target account's saved login.
5. It moves each open session's record (not archived, not a scheduled run) from
   `claude-code-sessions/<account>/<org>` to the target's folder. The session
   id, transcript, worktree and lease stay the same. If the target already has a
   copy, the newer one wins and the older one goes to the backup's `quarantine`.
6. It reopens Claude. The switch counts only when Claude's log reports the
   target account and organization. A sign-out, another account, or no answer
   within a minute undoes every step from the journal.
7. After an automatic switch it gets the chats the quit cut off going again
   (see [After the switch](#after-the-switch)).

The account shown as **In use** is the one Claude's own log reports: the line
Claude writes each time it loads an account's chats, naming the account and its
organization. Each switch leaves a folder in `backups` with the files from before
it and `switch.json` listing what moved; the last ten are kept.

## Auto-switch

**Auto-Switch** in the header's `···` menu is off until you pick a threshold:
80, 90 or 95 percent used. About once a minute, when the account in use has
passed it on either the 5-hour or the weekly meter, the app switches Claude to
the set-up account with the most room left, as if you had clicked Switch. It
switches before the meter reaches 100 percent on purpose: a chat that hits the
limit fails its turn, and Claude's retry of a failed turn starts that chat's
transcript over under a new id, leaving its subagents behind.

It never switches:

- to an account that is past the threshold itself, isn't set up, has no recent
  reading, or shows **Sign in again**;
- within 30 minutes of its last attempt, whatever happened then, so it can't
  bounce between two accounts or keep quitting Claude after a failed try;
- while Claude isn't running, or while another switch runs.

Nobody is there to answer Claude's quit prompt, so an automatic switch presses
**Quit anyway** itself, through Accessibility. That interrupts the chats that
were mid-reply, which is what a person switching by hand does too; Claude marks
each of them so it can resume it. The app needs Accessibility access for this:
macOS asks when you turn Auto-Switch on, and the menu says so while it is
missing. Without it an automatic switch waits at the prompt for a person, and
nothing changes until someone answers it. macOS ties the permission to the
app's signature, so after installing a new version you may need to allow it
again.

Each automatic switch posts a notification with its outcome. The notification
shows on the Mac only.

## After the switch

Nothing outside Claude can type into a Claude Code chat. Claude itself resumes
the chats a quit cut off: when Claude quits with a chat mid-reply, it marks that
chat, and at its next launch it resumes a few of them in the background and
each of the rest when that chat is opened. The mark travels with the chat's
record, so it survives the switch. After an automatic switch the app waits for
Claude's own pass, then opens each marked chat that hasn't carried on yet with
Claude's `claude://code/continue?session=<id>` link, one at a time, and reports
how many carried on.

What still needs a person:

- A chat Claude didn't mark. Claude decides which chats to mark, and some
  Claude builds or accounts don't mark any. Those chats wait for a message;
  the notification says when that is the case.
- Reaching a chat from your phone. Remote Control re-registers under the new
  account, so the Claude app on your phone has to be signed in to that account
  to see the chats.

A chat that was running in bypass-permissions mode keeps it: the mode is part of
the chat's record, and Claude starts the chat again with it. Claude does not
resume a bypass chat on its own where bypass is no longer allowed.

A switch keeps each chat's Claude Code session id. Claude gives a chat a new id
when a failed turn is retried, and the chat's subagents stay with the old id;
Auto-Switch's threshold is there so turns don't fail on the limit first.

## Workspaces

An account that belongs to two organizations, like a personal plan and a team,
has one row per workspace, each with its own usage. **Add Account…** with the
same account and the other organization picked in the browser adds the second
row. To save its Claude login, switch Claude to that workspace once from your
name in Claude's sidebar; **Set Up** on the row says so. From then on
**Switch** moves Claude and your open chats between the two workspaces the same
way it moves them between accounts.

## Command line

The binary is at `Claude Accounts.app/Contents/MacOS/ClaudeAccounts`.

| Command | What it does |
|---|---|
| `--status` | Prints what a switch would act on |
| `--switch <name>` | Runs a switch to the row named by id, label, email or the email's first part |
| `--auto-switch` | Runs the Auto-Switch rule once on the usage the menu last read, and switches if it says so; `--at <percent>` overrides the menu's threshold |
| `--unattended` | With `--switch`, answers Claude's quit prompt with Quit anyway (implied by `--auto-switch`) |
| `--dry-run` | Prints every check and what would happen, and changes nothing |
| `--detach` | Starts the command in its own session and returns; output goes to `--log <file>`, by default `last-switch.log` in the app's state folder |

Quitting Claude ends the processes Claude started, so from a shell inside
Claude, for example in a Claude Code chat, add `--detach`. Without it, run the
command from a terminal outside Claude.

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

## Build from source

```bash
git clone https://github.com/RohanNaga/ClaudeAccounts.git
cd ClaudeAccounts
./build.sh
open "Claude Accounts.app"
```

It needs the Xcode Command Line Tools (`xcode-select --install`). `build.sh`
compiles one binary for Apple Silicon and Intel with `swiftc`. `test.sh` runs
the tests for the switching rules in `app/Rules.swift`, then drives the quit
prompt code against a real native alert, which flashes a small window for a
moment; that part needs Accessibility access for your terminal. `release.sh`
builds and zips it into `dist/` for a GitHub release and prints the checksum the
Homebrew cask needs. The icon is drawn by `app/make-icon.swift`; delete
`app/AppIcon.icns` to regenerate it. Before 0.3 the app kept its state in a
`data` folder beside itself; the first launch of 0.3 moves it to Application
Support and carries each login's keychain item over.

## License

MIT. See [LICENSE](LICENSE).
