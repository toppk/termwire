import { defineConfig } from "vite";
import vue from "@vitejs/plugin-vue";

// base "./" so the bundle works from any path termwire-webd serves it at.
export default defineConfig({
  base: "./",
  plugins: [vue()],
  server: {
    // `npm run dev` proxies websockets to a running termwire-webd,
    // so the dev server gets hot reload while webd does the bridging.
    proxy: {
      "/ws": {
        target: "ws://127.0.0.1:7181",
        ws: true,
      },
    },
  },
  build: {
    target: "es2022",
  },
});
