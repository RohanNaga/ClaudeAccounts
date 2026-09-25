# Claude Accounts

A macOS menu bar app that shows the 5-hour and weekly usage of several Claude
accounts at once, and marks the one the Claude desktop app is signed in to.

## Build and run

```bash
./build.sh
open "Claude Accounts.app"
```

It needs the Xcode Command Line Tools (`swiftc`) and Claude Code installed at
`~/.local/bin/claude`. The build writes only into this folder. The icon is
drawn by `app/make-icon.swift`; delete `app/AppIcon.icns` to regenerate it.

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

The account shown as **In use** is the one Claude's own log reports
(`[LocalSessionManager] Initialization succeeded — accountId=…, orgId=…`).
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
