import SwiftUI

// The scenarios drive the Store, not the menu, so they compile without app/Views.swift (which a
// branch may be rewriting). These empty stand-ins satisfy the app's scene declaration only; the
// menu's own height is measured by the menu scenario through MenuLayout.

struct MenuContent: View { init(store: Store) {}; var body: some View { EmptyView() } }
struct SignInView: View { init(store: Store) {}; var body: some View { EmptyView() } }
func menuBarImage(title: String, fraction: Double, warning: Bool) -> NSImage { NSImage() }
