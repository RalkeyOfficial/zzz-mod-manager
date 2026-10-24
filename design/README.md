# Design

The app's UI designs, as working HTML boards. Each design lives in its own folder (`v3/` is the Zenith redesign); this folder holds what every design uses to be opened, used and rendered. A design folder is its design's source: a design change is an edit there, committed with its renders like any other change.

## Opening a design

The boards load the app's own images from `mod_manager_flutter/assets`, so serve the repository root:

```sh
python3 -m http.server 8000
```

Then open <http://localhost:8000/design/>. The overview opens on the newest design and shows every board in its section; click one to use it. With more than one design, buttons under the title switch between them, and `?set=v3` links to one directly. Opening a file straight from disk (`file://`) doesn't work, because the runtime reads the board's own file over HTTP.

To look without running anything, each design's `renders/` folder has a PNG of every board and its main states.

## What's here

- `index.html`: the overview.
- `designs.json`: the list of designs the overview offers, newest first, with the title from each `canvas.json`. The render tool writes it from the folders it finds, so it isn't edited by hand.
- `runtime/support.js`: the runtime every board loads.
- `tools/render.mjs`: makes the renders.
- `<design>/boards/*.dc.html`: one file per screen, dialog or foundation sheet.
- `<design>/canvas.json`: each board's title, size and place, and the section titles. The overview groups boards under the nearest section title above them and orders them by position.
- `<design>/renders/`: a PNG per board in its default state, and one per option of each enum tweak, named `<Board>--<tweak>-<option>.png`. A board taller than its `canvas.json` size is captured whole.

## The board format

A board is a plain HTML file. Its markup sits in `<x-dc>`, its fonts and CSS in a `<helmet>` inside it, and its logic in a `<script type="text/x-dc" data-dc-script>` after it. It loads the runtime with `<script src="../../runtime/support.js">`.

- `{{name}}` fills in a value; a dotted path (`{{mod.name}}`) is allowed, an expression is not. `{{$index}}` is the position inside a loop.
- `<sc-for list="{{mods}}" as="m">…</sc-for>` repeats its content for each item, and `<sc-if value="{{open}}">…</sc-if>` shows its content when the value is truthy. Both work inside tables.
- An attribute that is only a placeholder takes the raw value: `false`, `null` or a missing value leaves the attribute out. `onClick`, `onInput`, `onMouseEnter`, `onMouseLeave`, `onFocus` and `onBlur` take a function.
- The script defines `class Component extends DCLogic` with `renderVals()`, which returns every value and handler the markup uses. `this.props`, `this.state`, `this.setState()` and the React-style lifecycle methods (`componentDidMount`, `componentDidUpdate`) are available.
- `data-props` on the script declares the tweaks: `{"accent": {"editor": "color", "default": "#A98BFF", "options": [...]}}`. Editors are `color`, `enum`, `text`, `boolean`, `int`, `float` and `range`. `default` is the value the board opens with.
- A link to another board is a normal link, `<a href="Updates.dc.html">`.

The format is the claude.ai Design canvas format, so a board can be copied onto such a canvas by pointing its runtime script back at `./support.js`.

## Tweaks

A board with tweaks shows a Tweaks button in its corner. Changing a tweak updates the address, so `v3/boards/Updates.dc.html?state=After%20marking` opens that state directly and can be shared. `?embed=1` hides the button; the overview and the renders use it.

## Adding or changing a board

1. Edit or add `<design>/boards/<Name>.dc.html`. A new board also needs an entry in that design's `canvas.json` under `boards`, with `title`, `w`, `h`, `x` and `y`, plus `"is_interactive": true` when it responds to clicks. Its `y` decides its section.
2. Open it through the server and check it in the browser.
3. Render it: `node design/tools/render.mjs v3 <Name>`.
4. Look at the new PNGs before committing them. A broken board shows as a mostly black image or as the error text in red.

## Adding a design

Make a folder next to `v3/`, named so it sorts after the others (`v4`), with a `boards/` folder and a `canvas.json` whose `title` names the design. Boards load the runtime the same way, `../../runtime/support.js`. Then run the render tool: it adds the design to `designs.json`, and the overview opens on it from then on. Nothing else changes.

## The render tool

`node design/tools/render.mjs` renders every design; `node design/tools/render.mjs v3` renders one, and names after it (`v3 Updates Browse`) limit it to those boards. A run over a whole design also deletes renders whose board or state is gone. Every run brings `designs.json` up to date.

It needs Node 22 or newer and Chrome or Chromium. It looks for `chromium`, `google-chrome` or `chrome` on the path and for a Playwright download in `~/.cache/ms-playwright`; `--chrome <path>` or `CHROME=<path>` picks one. It waits for the web fonts before each screenshot and says so when a font fails to load or an image looks blank. `--no-states` renders only the default states.
