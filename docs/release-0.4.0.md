Claude Accounts now switches between every account you have, personal and organization, switches by itself when the one in use runs out, and brings your chats over and resumes them.

## What's new

- **Every seat is a row.** A seat is one account in one organization. An account that has a personal plan and a team shows as one card with a row for each, and its personal plan reads **Individual**. **Switch** works on any of them.
- **Automatic switching.** When Claude stops a chat because the seat in use hit its 5-hour or weekly limit, and that seat reads 100 percent, the app quits Claude, switches to the next seat with room, and reopens Claude there. It is on from the start; **Auto-Switch When Out** in the menu's `···` turns it off.
- **Stopped chats resume.** After a switch, each chat Claude stopped for the limit, and each chat the quit cut off, gets one "resume" message in its own window. Chats you are typing in or that are already running are left alone. This works after a switch by hand too.
- **You choose the order.** The automatic switch goes down the menu from the top. **Move Up** and **Move Down** in a row's `···` set that order, and **Switch Order** can put every personal seat first or every organization seat first. **Next** marks the seat it would go to.
- **When every seat is out, it waits.** The menu says which seat resets first, and when the seat in use has room again, its stopped chats are resumed in place.
- **A smaller menu.** A ready seat is one line with its fuller meter; click its name to see both meters with their reset times. Accounts with several organizations can be folded, organizations can be renamed, and the menu never grows taller than the screen.
- **Less setup.** When Claude is on a seat that isn't a row yet, such as a team you just signed in to inside Claude, the menu offers **Add**. Once Claude has stayed on a seat for a minute, the app saves its login, so switching back to it needs no **Set Up**.
- **Interrupted switches finish.** If the app or the Mac stops partway through a switch, the next launch finishes it or undoes it.
- **Notifications** for automatic switches only: one that worked or failed, a quit prompt it couldn't answer, and every seat being out.

## What changes when you update from 0.3.0

- **Accessibility is asked for.** The automatic switch and resume need it to press Claude's **Quit anyway** button and type "resume". Click **Allow…** in the menu and turn on Claude Accounts under System Settings › Privacy & Security › Accessibility. macOS ties this permission to the app's signature, and release builds are signed ad hoc, so every update asks for it again. If Claude Accounts already shows there as on, remove it with the minus button and click **Allow…** again.
- **The automatic switch starts from the top of the menu**, skipping the seat in use, rather than from the seat in use onward. Put the seat you want used first at the top.
- **Your accounts and saved logins carry over**, each as the seat it was saved in. A row with no saved login reads "Sign in once" and needs **Set Up** once. To add an account's other organizations, open Claude on each one and click **Add**.
- **Meters are read every 5 minutes**, a minute after each reset, and soon after a chat finishes a turn, instead of about once a minute.
- **The `--switch` command line option is gone.** `--status` still prints what the app sees, and `--test-resume` sends "resume" to one chat you name.

## Known limits

- The app isn't notarized by Apple, so the first launch needs **System Settings › Privacy & Security › Open Anyway**.
- It works by reading Claude's log, files and windows, which aren't public interfaces. If a Claude update changes them, automatic switching and resume pause with one line saying why, and **Switch** by hand keeps working where it can. An unknown cookie format stops every switch before anything changes.
- The meters come from an undocumented usage service. If it stops answering, the meters go stale and the automatic switch has no target; **Switch** by hand still works.
- The automatic switch acts only on a real stop: a chat Claude stopped for a limit while the seat reads 100 percent. A seat at 100 percent with no stopped chat stays in use. In practice the switch comes 10 to 15 minutes after the stop, and automatic switches are at least 15 minutes apart.
- A seat at 100 percent that still has usage credits reads out and is never a target.
- Claude can refuse a saved login at any time. The switch then rolls back and the row asks you to sign in once more.
- Typing "resume" needs Accessibility and Claude's chat window. A chat that doesn't start is retried every minute for 30 minutes, only while nobody is using the Mac, and after that the menu names the chats that need a message from you.
- It needs macOS 15 or later, the Claude desktop app, and Claude Code at `~/.local/bin/claude`.

Install with `brew install --cask rohannaga/tap/claudeaccounts` (or `brew upgrade --cask claudeaccounts`), or download `ClaudeAccounts-0.4.0.zip` below.
