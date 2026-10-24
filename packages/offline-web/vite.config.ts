import { defineConfig } from "vite";
import { resolve } from "node:path";
import { existsSync } from "node:fs";

const coreSrc = resolve(__dirname, "../offline-core-js/src/index.ts");
const coreDist = resolve(__dirname, "../offline-core-js/dist/index.js");

export default defineConfig(({ command }) => {
  // Production/archive builds prefer compiled dist + release pkg wasm.
  const useDist = command === "build" && existsSync(coreDist);
  return {
    root: ".",
    // Relative to index.html so archives / nested hosts resolve
    // `./assets/…` instead of absolute `/assets/…` (404 when not at site root).
    base: "./",
    server: {
      host: "127.0.0.1",
      port: 5173,
      // Web Bluetooth requires a secure context (localhost qualifies).
      strictPort: true,
      fs: {
        allow: [resolve(__dirname, "..")],
      },
    },
    assetsInclude: ["**/*.wasm"],
    optimizeDeps: {
      exclude: ["@offline/core"],
    },
    build: {
      target: "es2022",
      assetsInlineLimit: 0,
      sourcemap: false,
      minify: "esbuild",
      // Stable names (no content hash) so rebuilds don't leave orphan
      // assets/index-XXXX.js files in commits / deploy folders.
      assetsDir: "assets",
      emptyOutDir: true,
      rollupOptions: {
        output: {
          entryFileNames: "assets/index.js",
          chunkFileNames: "assets/[name].js",
          assetFileNames: (info) => {
            const name = info.name ?? "asset";
            if (name.endsWith(".css")) return "assets/index.css";
            // Keep wasm basename stable: offline_wasm_bg.wasm
            if (name.endsWith(".wasm")) return "assets/[name][extname]";
            return "assets/[name][extname]";
          },
        },
      },
    },
    resolve: {
      alias: {
        "@offline/core": useDist ? coreDist : coreSrc,
      },
    },
  };
});
