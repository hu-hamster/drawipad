// 把 SharedWeb 的白板编辑器（whiteboard.html + Excalidraw vendor 资产）
// 复制到插件构建目录（与 main.js 同级），运行时通过 app://local 在 iframe 中加载。
// 安装插件时需连同这些文件一起复制到 Vault 的插件目录。
import { cpSync, existsSync, rmSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const sharedRoot = resolve(here, "../SharedWeb");
const outDir = here; // main.js 所在目录

if (!existsSync(resolve(sharedRoot, "whiteboard.html"))) {
  console.error("缺少 SharedWeb/whiteboard.html");
  process.exit(1);
}

const vendorFiles = [
  "excalidraw.production.min.js",
  "excalidraw.production.min.css",
];

cpSync(resolve(sharedRoot, "whiteboard.html"), resolve(outDir, "whiteboard.html"));
for (const file of vendorFiles) {
  cpSync(resolve(sharedRoot, "vendor", file), resolve(outDir, "vendor", file));
}
rmSync(resolve(outDir, "vendor/excalidraw-assets"), { recursive: true, force: true });
cpSync(
  resolve(sharedRoot, "vendor/excalidraw-assets"),
  resolve(outDir, "vendor/excalidraw-assets"),
  { recursive: true },
);

console.log("已复制白板 Web 资产（whiteboard.html + vendor/）");
