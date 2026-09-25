# ClaudeAccounts

A macOS menu bar app for people with more than one Claude account, like a work
plan, a school plan and a personal one. It shows the 5-hour and weekly usage of
every account at once, and switches the Claude desktop app between them in one
click while keeping your open Claude Code chats, their worktrees and their
history.

<p align="center">
  <img src="docs/menu.png" width="355" alt="The ClaudeAccounts menu: four accounts with 5-hour and weekly usage bars, the one in use marked, and a Switch button on the others">
</p>

> ClaudeAccounts is an independent project. It is not made, endorsed or
> supported by Anthropic. Claude is a trademark of Anthropic. Use each account
> under Anthropic's terms for that account.

## Requirements

- macOS 15 or later on Apple Silicon
- Xcode Command Line Tools (`xcode-select --install`), for `swiftc`
- The Claude desktop app, and Claude Code installed at `~/.local/bin/claude`

Tested with Claude desktop 2.9939.2 on macOS 27.

## Build and run

```bash
git clone https://github.com/RohanNaga/ClaudeAccounts.git
cd ClaudeAccounts
./build.sh
open "Claude Accounts.app"
```

The build writes only into this folder. The icon is drawn by
`app/make-icon.swift`; delete `app/AppIcon.icns` to regenerate it.

## Read this before you switch

Switching works by editing the Claude desktop app's own files while it is quit:
its cookie database, its settings file and its chat records. None of that is a
public interface, and an update to Claude can change it. The app is built to
fail closed. It backs everything up first, refuses to act when something looks
off, and undoes a switch that Claude doesn't confirm. Still, use it at your own
risk, and keep the backups in `data/backups/` until you trust it on your setup.

## How it works

- **Add Account…** runs `claude auth login` against a private config folder,
  `data/logins/<id>`, opens the sign-in page, and takes the code you paste. The
  account is labeled with its email.
- About once a minute the app reads each account's usage from
  `api.anthropic.com/api/oauth/usage`, the same endpoint and pace as the Claude
  app's own usage reader, which reuses a good reading for 60 s. Asking faster
  earns HTTP 429 with a multi-minute `Retry-After`; when that happens the row
  keeps its last numbers, notes when it will retry, and waits exactly that long.
  Readings and waits are saved in `data/usage-cache.json`, so a relaunch shows
  numbers at once without asking again.
- Each row's `···` menu can **Rename** an account (an empty name restores the
  email) and pick its **Color**. The menu bar label uses the name.
- The menu bar item is a gauge whose needle follows the in-use account. The
  header's `···` menu sets what it shows (**Menu Bar Shows**: gauge only, gauge
  and percentage, or gauge, name and percentage) and which limit it follows
  (**Gauge Tracks**: 5-hour or weekly). Settings live in `data/settings.json`.
  The item is drawn as one template image so the gauge and text share a centre
  line exactly.
- Access tokens last about 8 hours. When one is close to expiry the app runs
  `claude -p /usage --no-session-persistence` in that account's folder, and
  Claude Code renews the login itself. This spends no model usage.
- Each login has a fixed deadline about four weeks out that renewals don't
  extend. A day before it, the row shows **Sign in again** and the menu bar
  icon turns into a warning. Signing in again keeps the row's place, name and
  color. If you pick a different Google account, the previous login is kept.

## Footprint

Everything lives in this folder: the app, its `data/` folder and the build
cache. The only thing outside it is one login keychain item per account, named
`Claude Code-credentials-<hash>`. **Remove** on an account's `···` menu signs
it out and deletes that item, so remove accounts before deleting the folder.

Moving the folder breaks the logins, because they are tied to its path; add the
accounts again after a move. **Open at Login** registers the app in System
Settings > Login Items.

## Switching the Claude app's account

**Switch** on a row signs the Claude desktop app in as that account and brings
your open Code sessions along:

1. It asks Claude to quit the way ⌘Q does and waits until Claude's process is
   gone. If a chat is mid-reply Claude asks first; answering "don't quit" ends
   the switch with nothing changed.
2. It backs up Claude's `Cookies` and `config.json` and writes a journal to
   `data/switch-journal.json` before changing anything.
3. It saves the current account's login (its claude.ai cookie rows and three
   settings keys) to `data/slots/<id>`, but only if Claude's log and settings
   agree on who that account is.
4. It loads the target account's saved login.
5. It moves each open session's record (not archived, not a scheduled run) from
   `claude-code-sessions/<account>/<org>` to the target's folder. The session
   id, transcript, worktree and lease stay the same. If the target already has a
   copy, the newer one wins and the older one goes to the backup's `quarantine`.
6. It reopens Claude. The switch counts only when Claude's log reports the
   target account and organization. A sign-out, another account, or no answer
   within a minute undoes every step from the journal.

The account shown as **In use** is the one Claude's own log reports: the line
Claude writes each time it loads an account's chats, naming the account and its
organization.
**Set Up** on an account with no saved login saves the current one and reopens
Claude at its sign-in page, so signing in as another account never signs the
current one out. `ClaudeAccounts --status` prints what a switch would act on;
`ClaudeAccounts --switch <name>` runs a switch from a terminal outside Claude.

Each switch leaves `data/backups/<time>/` with the files from before it and
`switch.json` listing what moved. The last ten are kept.

## Limits

- A `claude setup-token` token can't read usage, because it lacks the
  `user:profile` scope. That's why the app uses full logins.
- Switching depends on Claude's cookie schema (version 24), its session-record
  layout, and one log line. If an update changes them, a switch fails closed:
  it is refused or undone rather than half-applied.
- Archived sessions and scheduled-task runs stay with the account they belong to.
- A chat that was running in bypass-permissions mode may come back in a safer
  mode after the restart; Claude re-launches it without the bypass flag.
