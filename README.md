# ‹ Tuck

**Your menu bar is a junk drawer. Tuck shuts it.**

You have 23 menu bar icons. You use 4 of them. The rest are a VPN you forgot you pay for, three different "AI usage" meters, a weather app that has said `invalidAuthorization: 401` since September, and something with a cat face that you are honestly scared to click.

On a MacBook with a notch it's worse. Half of them just *vanish* behind the notch, silently, like socks in a dryer. Is RustDesk running? Who knows. It's in the notch now. It lives there.

Tuck is a tiny menu bar app that hides the clutter and gives it back when you want it. Free, open source, no subscription, no "Tuck Pro", no "we've updated our Terms", and no 401 errors from a weather widget you never asked for.

```
  [always hidden…]  ‖  [hidden…]  │  [shown…]  ‹   🔋 Wi-Fi  Sun 18:30
                    ↑             ↑              ↑
           always-hidden     the divider     click me
              divider
```

## How it works

- **Click ‹** → the hidden icons slide back in. Click again (or wait 10s) and they're gone.
- **Too many icons to fit next to the notch?** Clicking ‹ opens a **dropdown** instead, listing every hidden icon with its app icon. Pick one and its real menu opens, even if it's living under the notch. When you close that menu, Tuck tidies up after itself.
- **⌥-click ‹** → reveal *everything*, including the always-hidden ones (and the ‖ divider, so you can drag things past it).
- **Right-click ‹** → menu with Settings and Quit.

### Arranging: just ⌘-drag

Hold **⌘** and drag any menu bar icon:

| Put it… | It's… |
| --- | --- |
| right of **│** | always shown |
| between **‖** and **│** | hidden until you click ‹ |
| left of **‖** | always hidden (⌥-click ‹ to see them) |

That's it. It's the same ⌘-drag macOS has had forever, so it's 100% reliable and survives OS updates. Tuck does **not** fake mouse movements to rearrange your icons. We tried. Your cursor went on a little adventure every time. Never again.

### Settings

Right-click ‹ → **Settings…**

- A live list of what's **Shown / Hidden / Always hidden**. It updates as you ⌘-drag, so you can see the effect immediately.
- **Auto-hide:** never, or after 5s / 10s / 15s / 30s / 1 min. It waits while your pointer is in the menu bar, so icons don't disappear right before you click one.
- **Dropdown menu:** only when icons don't fit (default), always, or never.
- **Launch at login**

## Install

You need macOS 14+ and the Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/hazy2go/tuck.git
cd tuck
./build.sh
open ~/Applications/Tuck.app
```

On first launch macOS asks to give Tuck **Accessibility** access. Hiding and showing works without it. The dropdown and the Settings list need it, because that's how Tuck sees which app owns each icon and opens its menu.

### Optional: stop macOS forgetting the permission after every rebuild

By default `build.sh` signs Tuck "ad-hoc" (no developer certificate), so every rebuild looks like a brand-new app to macOS and you have to grant Accessibility again. If you plan to hack on it, run this once:

```bash
./scripts/make-signing-cert.sh
```

It creates a local self-signed code-signing certificate called **Tuck Local Signing** in your login keychain. From then on `build.sh` signs with it, and the permission survives rebuilds. It doesn't make Tuck trusted by anyone else and it's never uploaded anywhere.

## How it works (the nerdy bit)

- **Hiding:** Tuck owns two invisible-ish menu bar items, the dividers. To hide, it stretches a divider to 10,000 points wide, which shoves everything to its left off the edge of the screen. To show, it shrinks it back. Every other icon is completely untouched. This is why it doesn't break when Apple redesigns the menu bar every other year.
- **Safety catch:** if you ever drag │ to the *right* of ‹, stretching it would push the chevron itself off screen and you'd have no way back. Tuck notices, refuses to hide, and tells you to drag it back.
- **Dropdown:** each app's menu bar icons are visible through the public Accessibility API (owner, position, size). "Opening" one is the Accessibility equivalent of clicking it. No screen recording, no private APIs, no code injected into other apps.
- **Speed:** of the ~100 processes on a typical Mac, only about a dozen own menu bar icons. Tuck finds those once, keeps the list fresh in the background, and opens the dropdown from that saved list, so it's instant.

About 700 lines of Swift in three files. No dependencies. No network access. No analytics.

## Uninstall

```bash
./uninstall.sh
```

Quits Tuck (which slides everything back into view), deletes the app and its settings, and resets its Accessibility permission. Your icons go back to fighting over the notch, as nature intended.

## FAQ

**Isn't this just Bartender?**
Bartender is great when it works. This is ~700 lines you can read in one sitting, it's free, and it doesn't phone a weather server.

**Isn't this just Ice / Hidden Bar?**
Same family. Tuck is closest to Hidden Bar's "stretchy divider" trick, plus a notch-aware dropdown and an always-hidden section.

**Can Tuck sort my icons for me?**
No, and on purpose. macOS has no way for one app to move another app's icon, so tools that do it fake mouse drags, and that's exactly the part that breaks. ⌘-drag takes two seconds and never fails.

**I dragged the divider somewhere weird and now everything is gone.**
⌥-click ‹ to show everything, or quit Tuck, which always leaves every icon visible.

## License

MIT. Tuck it in, tuck it out, do what you want.
