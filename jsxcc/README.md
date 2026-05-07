# jsxcc

`jsxcc` is a Zig CLI that turns single-file JSX into standalone HTML without Node.js or npm. It uses the same browser-side rendering model as the main JSX Playground: React, Babel Standalone, Tailwind CSS, and supported packages are loaded from the browser, so the CLI ships as a single binary with no runtime dependencies.

## Features

- Build one JSX-like file into standalone HTML.
- Recursively build a directory and preserve its structure.
- Copy non-JSX assets alongside rendered output.
- Serve a file or directory locally with live JSX rendering and reload.
- Embed the CLI version directly from `../version.txt`.

## Supported commands

| Command | What it does |
|---|---|
| `jsxcc build <input>` | Build one file or recursively build a directory |
| `jsxcc build <input> -o <output>` | Write to a specific file or output directory |
| `jsxcc build <input> --stdout` | Print rendered HTML to stdout |
| `jsxcc serve <input>` | Serve a file or directory locally |
| `jsxcc serve <input> --port 5000 --host 0.0.0.0` | Override the listen port or host |
| `jsxcc version` | Print the embedded version |
| `jsxcc help` | Show built-in help |

## Build locally

From this directory:

```bash
zig build test
zig build -Doptimize=ReleaseSafe
```

Binary output:

- Windows: `zig-out\bin\jsxcc.exe`
- macOS / Linux: `zig-out/bin/jsxcc`

## Usage examples

```bash
jsxcc build .\demo.jsx
jsxcc build .\pages -o .\dist
jsxcc build .\demo.jsx --stdout > demo.html

jsxcc serve .\demo.jsx
jsxcc serve .\pages --port 5000

jsxcc version
```

## Build behavior

- File input defaults to a sibling `.html` file.
- Directory input defaults to a sibling `<name>-dist` directory.
- JSX-like files (`.jsx`, `.js`, `.tsx`, `.ts`) are rendered to HTML.
- Existing `.html` and `.htm` files are copied through unchanged by `build`.
- Non-JSX assets are copied as-is when building directories.

## Serve behavior

- `serve` binds to `127.0.0.1` by default.
- The default starting port is `4173`.
- If the requested port is busy, `jsxcc` keeps trying higher ports until it finds an open one.
- `JSXCC_HOST` sets the default host when `--host` is omitted.
- `JSXCC_PORT` sets the default starting port when `--port` is omitted.
- Directory targets render a built-in directory listing.
- JSX-like files are rendered as HTML on request and include live reload.

## Versioning and releases

- `../version.txt` is the source of truth for the embedded CLI version.
- `zig build test` and `zig build -Doptimize=ReleaseSafe` are exercised in CI.
- The release workflow publishes archives for Linux (`x86_64`, `aarch64`), Windows (`x86_64`), and macOS (`x86_64`, `aarch64`).
