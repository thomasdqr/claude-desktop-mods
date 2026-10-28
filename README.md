# Claude Colors

Color and icon each project in the Claude desktop app's Code sidebar, like tab groups in Arc.

<p align="center">
  <img src="docs/sidebar.png" alt="The Claude sidebar with each project as a colored block with its own icon" width="360">
</p>

- Each project becomes a block tinted with its own color.
- Click a block's icon to pick one of 2,000+ [Lucide](https://lucide.dev) icons and a color.
- Each block shows its 5 latest sessions, with "Show more" for the rest.
- A light circles the border of a block while one of its sessions is running.
- Drag blocks to reorder them, folded or unfolded.

> **Unofficial.** This is not made or supported by Anthropic. It runs as a DevTools snippet,
> through Claude's own Developer Mode. The Claude app itself is not modified.

## Requirements

- macOS, with the Claude desktop app
- Python 3

## Install with Claude Code

Paste this into a Claude Code session:

```text
Install Claude Colors from https://github.com/thomasdqr/claude-colors.
1. Clone it into ~/Documents/GitHub/claude-colors, unless I already have it there.
2. Run `python3 snippet.py` in that folder: it builds the snippet and copies it to my clipboard.
3. Then walk me through the "One-time setup" steps of its README.
```

## Install by hand

```bash
git clone https://github.com/thomasdqr/claude-colors ~/Documents/GitHub/claude-colors
cd ~/Documents/GitHub/claude-colors
python3 snippet.py
```

`snippet.py` builds `dist/claude-colors-snippet.js` and copies it to the clipboard.

## One-time setup

1. In Claude, open **Help → Enable Developer Mode…** and confirm.
2. In the new **Developer** menu, choose **Show All Dev Tools**. Keep the window whose title
   contains **claude.ai** and close the others.
3. In that window, open **Sources → Snippets → + New snippet**, and name it `claude-colors`.
4. Paste the snippet (⌘V), save it (⌘S), and run it (⌘↵).

## After each Claude launch

**Developer → Show All Dev Tools**, then in the claude.ai window press ⌘P, type
`!claude-colors` and press Enter. You can close DevTools after that.

## Use

- **Icon and color:** click the icon at the left of a project's name. Your choices are saved
  in Claude itself, so they survive restarts.
- **Starting colors:** `config.json` maps a project name to a color and a
  [Lucide icon name](https://lucide.dev/icons). `snippet.py` creates it from
  `config.example.json` the first time; edit it, run `python3 snippet.py` again, and paste
  the new snippet over the old one.
- **If the colors disappear** after a Claude update, the sidebar's markup probably changed.
  The markup `inject.js` relies on is listed at the top of that file.

## Older Claude versions

Before Claude 4.29, `patch.py` could build a patched copy of the app that applied the
colors on its own. Claude 4.29 refuses modified copies, so the snippet is the way now.

## License

MIT. Lucide icons are under the ISC license, see `LUCIDE-LICENSE`.
