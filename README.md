# JSX Playground

A fast, zero-setup JSX playground that runs entirely in your browser. Paste or upload a JSX file and see your React component rendered live - no build step, no server, no install.

**Live:** [jsx.zxcv.fyi](https://jsx.zxcv.fyi)

## Features

- **Live preview** - auto-renders as you type (180 ms debounce)
- **Upload a file** - click the Upload button or drag-and-drop any `.jsx` / `.js` / `.tsx` / `.ts` file onto the app
- **Full-screen preview** - one click to expand the preview to fill the entire screen
- **Draggable exit button** - a floating icon button lets you exit full-screen; drag it anywhere on the screen
- **Resizable panes** - drag the divider between the editor and preview to adjust the split
- **React 18** - hooks, context, suspense all work
- **Tailwind CSS** - available inside the preview automatically
- **lucide-react** - all icons available (pinned to `0.511.0`)

## Supported import targets

| Package | Version |
|---|---|
| `react` | 18 |
| `react-dom` / `react-dom/client` | 18 |
| `lucide-react` | 0.511.0 |

Other packages are not available in the sandbox (no Node.js, no npm).

## How it works

1. User code is normalised - `import` statements are extracted and placed at the ESM module top level, `export default` is stripped.
2. Babel Standalone transpiles the JSX to plain JS.
3. The transpiled code is injected into an `<iframe>` as an ES module with an [import map](https://developer.mozilla.org/en-US/docs/Web/HTML/Element/script/type/importmap) pointing to [esm.sh](https://esm.sh) CDN.
4. React mounts the default export into `#root` via `createRoot`.

## Local development

Any static file server works:

```bash
npx serve . -l 4173
```

Then open [http://localhost:4173](http://localhost:4173).

## License

[BSD Zero Clause License](LICENSE) - Jeremie Bornais, 2026
