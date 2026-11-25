Claude Accounts 0.4.1 resumes the chats that 0.4.0 missed after a switch, and says plainly which chats it could not restart.

## What's new

- **Chats with background work resume.** After a switch, a chat whose turn had ended but that still had background work running at the quit, such as subagents, a workflow or a background shell like a dev server, now gets its one "resume" message too. A chat that was idle with nothing running still gets nothing.
- **A true "chats resumed" count.** The switch notification counts a chat as resumed only once its Stop button shows, so the number is the chats you can see running.
- **The chats it could not restart are named.** When a chat doesn't start, the notification says what to do and names it, as in "Couldn't resume 1 chat, send it a message: “Fix the importer”." The menu shows the count, and its line names them on hover.

## What changes when you update from 0.4.0

- **macOS asks for Accessibility again.** Release builds are signed ad hoc, and macOS ties the permission to the signature. Click **Allow…** in the menu and turn on Claude Accounts under System Settings › Privacy & Security › Accessibility. If it already shows there as on, remove it with the minus button and click **Allow…** again.

## Known limits

Unchanged from 0.4.0; see the [0.4.0 notes](https://github.com/RohanNaga/ClaudeAccounts/blob/main/docs/release-0.4.0.md#known-limits).

Install with `brew install --cask rohannaga/tap/claudeaccounts` (or `brew upgrade --cask claudeaccounts`), or download `ClaudeAccounts-0.4.1.zip` below.
