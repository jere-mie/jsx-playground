# JSX Playground

A fast, zero-setup JSX and HTML playground that runs entirely in your browser. Paste or upload a JSX file to render a React component, or drop in a full HTML document and preview it directly - no build step, no server, no install.

**Live:** [jsx.zxcv.fyi](https://jsx.zxcv.fyi)

## Features

- **Live preview** - auto-renders as you type (180 ms debounce)
- **Upload a file** - click Upload or drag-and-drop any `.jsx` / `.js` / `.tsx` / `.ts` / `.html` / `.htm` file onto the app
- **Download preview** - save the rendered preview as a standalone `.html` file (uses the OS Save As dialog where supported)
- **Full-screen preview** - one click (or press `F`) to expand the preview; press `F` or `Esc` to exit
- **Draggable exit button** - a floating button lets you exit full-screen; drag it anywhere on screen, click it to exit
- **Resizable panes** - drag the divider between editor and preview to adjust the split
- **React 18** - hooks, context, suspense all work
- **Tailwind CSS** - available inside the preview automatically
- **lucide-react** - all icons available (pinned to `0.511.0`)

## Supported import targets

| Package | Version / Notes |
|---|---|
| `react` | 18 |
| `react-dom` / `react-dom/client` | 18 |
| `lucide-react` | 0.511.0 |
| `framer-motion` | available via esm.sh |
| `recharts` | available via esm.sh |
| `react-hook-form` | available via esm.sh |
| `zod` | available via esm.sh |
| `zustand` / `zustand/middleware` | available via esm.sh |
| `@tanstack/react-query` | available via esm.sh |
| `clsx` | available via esm.sh |
| `tailwind-merge` | available via esm.sh |
| `date-fns` | available via esm.sh |
| `immer` | available via esm.sh |

Other packages are not available in the sandbox (no Node.js, no npm).

## How it works

1. Full HTML documents that start with `<!DOCTYPE html>` or `<html>` are passed straight into the preview iframe.
2. Otherwise, user code is treated as JSX: `import` statements are extracted and placed at the ESM module top level, and `export default` is stripped.
3. Babel Standalone transpiles the JSX to plain JS.
4. The transpiled code is injected into an `<iframe>` as an ES module with an [import map](https://developer.mozilla.org/en-US/docs/Web/HTML/Element/script/type/importmap) pointing to [esm.sh](https://esm.sh) CDN.
5. React mounts the default export into `#root` via `createRoot`.

## `jsxcc` CLI

The repository now includes `jsxcc/`, a Zig CLI that turns single-file JSX into standalone HTML without Node.js or npm. The generated HTML keeps the same CDN-based model as the playground: React, Tailwind, Babel Standalone, and supported packages are loaded in the browser, so the CLI itself ships as a single binary with no runtime dependencies.

### CLI features

| Command | What it does |
|---|---|
| `jsxcc build <file>` | Convert one JSX/JS/TSX/TS file into standalone HTML |
| `jsxcc build <directory>` | Recursively build a directory, preserve structure, and copy non-JSX assets |
| `jsxcc serve <file-or-directory>` | Run a live server that renders JSX on request and reloads when the source changes |
| `jsxcc version` | Print the version embedded from `version.txt` |

### Build the CLI locally

```bash
cd jsxcc
zig build -Doptimize=ReleaseSafe
```

Binary output:

- Windows: `jsxcc\zig-out\bin\jsxcc.exe`
- macOS / Linux: `jsxcc/zig-out/bin/jsxcc`

### CLI usage

```bash
jsxcc build .\demo.jsx
jsxcc build .\pages -o .\dist
jsxcc build .\demo.jsx --stdout > demo.html

jsxcc serve .\demo.jsx
jsxcc serve .\pages --port 5000
```

### Live server behavior

- Directory targets behave like a normal file server with directory listings.
- Clicking a `.jsx`, `.js`, `.tsx`, or `.ts` entry renders built HTML instead of raw source.
- HTML files are passed through as HTML.
- The server starts at port `4173` by default and keeps incrementing until it finds an open port.
- `--port` or `JSXCC_PORT` can change the starting port. `JSXCC_HOST` can change the bind host.

### Versioning and releases

- `version.txt` is the source of truth for the CLI version.
- `jsxcc version` prints the embedded version string.
- `.github/workflows/release-jsxcc.yml` reads `version.txt`, builds release binaries for Linux (`x86_64`, `aarch64`), Windows (`x86_64`), and macOS (`x86_64`, `aarch64`) from one Ubuntu job, and publishes a GitHub release tagged as `v<version>`.

## Local development

Any static file server works:

```bash
npx serve . -l 4173
```

Then open [http://localhost:4173](http://localhost:4173).

## License

[BSD Zero Clause License](LICENSE) - Jeremie Bornais, 2026
