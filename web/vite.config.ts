import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";

export default defineConfig({
  plugins: [react(), tailwindcss()],
  server: {
    host: "127.0.0.1",
    proxy: {
      "/api": {
        target: process.env.OMNI_MLX_ADMIN_ORIGIN ?? "http://127.0.0.1:8081",
        // Preserve the browser's loopback Host and Origin for the local-only guard.
        changeOrigin: false,
      },
    },
  },
  build: { assetsInlineLimit: 0 },
});
