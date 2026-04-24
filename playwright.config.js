const { defineConfig } = require("@playwright/test");

module.exports = defineConfig({
  testDir: "./tests/browser",
  timeout: 30000,
  reporter: process.env.CI ? [["list"]] : "list",
  use: {
    browserName: "chromium",
    headless: true,
    viewport: { width: 1280, height: 720 },
  },
});
