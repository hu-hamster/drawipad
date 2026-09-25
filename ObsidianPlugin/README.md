# DrawPad Sync for Obsidian

This is a desktop-only Obsidian plugin that exposes the current Vault's
`.excalidraw.md` and `.excalidraw` files to the existing DrawPad iPad app.
It uses the Vault's native directory hierarchy directly: ancestor folders are
published as nested DrawPad folders, with no separate folder database or UI.
When the active file is open in the Obsidian Excalidraw view, canvas panning
and zooming are synchronized bidirectionally with the connected iPad.

The plugin intentionally lives outside the Xcode project. It speaks the same
version-3 protocol as the native Mac server:

- Bonjour: `_drawpad._tcp`
- TCP frames: 4-byte big-endian payload length followed by JSON
- Excalidraw scenes: compressed Markdown (`compressed-json`) or JSON files

## Local build

```sh
npm install
npm test
npm run build
```

Copy `main.js`, `manifest.json`, and `styles.css` into
`<vault>/.obsidian/plugins/drawpad-sync/` and enable **DrawPad Sync** in
Obsidian. The plugin is desktop-only because the sync server uses Node's TCP
and Bonjour APIs.
