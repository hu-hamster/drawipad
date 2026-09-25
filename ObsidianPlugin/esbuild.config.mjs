import esbuild from "esbuild";
import { builtinModules } from "node:module";

const production = process.argv[2] === "production";

const buildOptions = {
  entryPoints: ["src/main.ts"],
  bundle: true,
  external: [
    "obsidian",
    "electron",
    ...builtinModules,
    ...builtinModules.map((moduleName) => `node:${moduleName}`),
  ],
  format: "cjs",
  platform: "node",
  target: "es2018",
  sourcemap: production ? false : "inline",
  minify: production,
  outfile: "main.js",
  logLevel: "info",
};

if (production) {
  await esbuild.build(buildOptions);
} else {
  const context = await esbuild.context(buildOptions);
  await context.watch();
  console.log("Watching for changes...");
}
