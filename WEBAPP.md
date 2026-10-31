# Embedded web app specification

A pattern for a program that serves its own web interface: one page, embedded in the binary, with a tiling workspace of equal views. The reference implementation is [src/web/play.html](src/web/play.html), with behavior listed in [AGENTS.md](AGENTS.md).

## Principles

* One app: one page at `/`, no separate pages for secondary tools.
* One stylesheet namespace: a view's classes carry a prefix (`log-`), or sit under its pane's id, so they cannot match another view's rules.
* Standard library only; the HTML, CSS, and JavaScript are embedded files, with no build step, bundler, framework, or network fetch.
* Every view is equal: any can move, split, resize, close, and reopen.
* Privileged views stay locked until a person on the machine unlocks them; unlocking should be logged.
* The page works at phone width, with a reduced layout.
* State that belongs to one viewer (layout, text size, theme, name) lives in the browser; shared state lives in the program.

## Server

* Listens on 127.0.0.1 by default; another address is opt-in and needs a password.
* Refuses and logs requests whose `Host` is not this server or whose `Origin` does not match (DNS rebinding, cross-site requests).
* Routes belong to modules; the web module imports none of them, and the app hands each module's routes to the server. Each route reply may carry an audit entry.
* Identity comes from the peer address, a header for programs, and a session cookie for remote people. Access rules sit in one place, not in handlers.
* An audit log records commands, joins, leadership, kicks, unlocks, and refusals, with the actor and client, and marks suspicious events. It is open to every player. Each entry also records the address it came from: "this machine" for a local one, shown as is, and a remote address shown in full only to clients on this machine (others see "remote"), since the log is open to everyone.

## Page layout

* Header: the primary status, a live indicator, and buttons. Extra status from unlocked views joins the header in free space; nothing already shown moves.
* A workspace fills the rest: a tree of splits, each leaf a panel with a tab bar and a body.
* Controls for a view sit at the right end of its tab bar while its tab is in front.
* Panels that share a row keep equal header and footer heights, whatever the content size.
* Controls are drawn icons, centered in their button, every one the same height (24 px) and an icon-only button the same width (29 px), in the header, tab bars, and popovers; related ones join into one segmented button (− +, A A). Pressed toggles show a tinted background. Focus uses the color of the adjacent action button. Symbols are drawn icons or glyphs sized to match, never mixed text and symbols in one control.

## Tabs

* A view is a tab with a title, a pane, and optional controls. Tabs are not `<button>` elements, because Safari and Firefox do not drag those.
* Drag a tab onto a tab bar to move it there, before the tab it lands on. Drag it onto a panel's body to split that panel along its longer side, the tab taking the half nearer the pointer, previewed by a dashed outline. A panel left empty disappears.
* ✕ closes a tab. The ▦ menu lists every view with a check for open ones, reopens a closed one in its last panel, and ends with a rule and Default layout.
* The last open tab cannot be closed.
* Boundaries drag to resize, limited to 15 to 85 percent.
* A tab out of sight (behind another, or closed) that gets news shows an accent dot at its top-right, left of ✕, until it is shown. News is a new post (Discussion), new text after the first load (Game), or a new suspicious entry (Audit log); not every audit entry, which would never clear.
* The layout (tree, closed tabs, sizes) is saved in the browser, accepted only if it names every tab once, and overridden by query parameters (`?log`, `?game=hide`).
* At 860 px wide or less the panels stack, fixed, without dragging or resizing.

## Privileged views

* A button (not shown on phones, or to remote clients) asks for confirmation, then fetches the views as an HTML fragment (`<style>` scoped under `#ws`, panes, header items, and a script in a function scope). The server logs the fetch as suspicious.
* The page adds the panes, runs the script, and shows the tabs. A second press hides them and the header items; the unlock is remembered and restored after a reload, logging again.
* The fragment names its panes with `data-*` attributes and does not touch the page's layout code. The page calls `window.onPaneShown(id)` so a view can redraw after it is shown or resized.

## Appearance settings

* A view's look (colors, attributes) is set in a popover from the program's own style language, so a setting works in the page and on the command line. A bad name shows an error and keeps the previous look; a live sample shows the result; the setting is remembered and a query parameter overrides it.

## Forms

* One line, fixed height; text size follows the user's choice up to a limit.
* `autocapitalize`, `autocorrect`, and `spellcheck` off for commands. At least 16 px on phones, so iOS does not zoom.

## Checks

* Unit tests for the server's access rules, routes, and audit entries; a browser pass for layout (tab move, split, resize, close and reopen, unlock and reload, phone width).
* Measure alignment (header and footer heights, header positions before and after unlocking) instead of judging by eye.
