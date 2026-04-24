const path = require("path");
const { expect, test } = require("@playwright/test");

const loaderPath = path.resolve(__dirname, "../../branding/openwebui/loader.js");
const cssPath = path.resolve(__dirname, "../../branding/openwebui/custom.css");

async function routeDropzoneApis(page) {
  await page.route("**/api/v1/images/models", async (route) => {
    await route.fulfill({
      contentType: "application/json",
      body: JSON.stringify({
        data: [
          {
            id: "chutes/Qwen-Image-2512",
            name: "Qwen-Image-2512",
            description: "Preferred general image model",
          },
          {
            id: "chutes/hunyuan-image-3",
            name: "hunyuan-image-3",
            description: "Tencent Hunyuan Image 3",
          },
        ],
      }),
    });
  });

  await page.route("**/api/models", async (route) => {
    await route.fulfill({
      contentType: "application/json",
      body: JSON.stringify({ data: [] }),
    });
  });

  await page.route("**/api/v1/dropzone/account-summary", async (route) => {
    await route.fulfill({
      contentType: "application/json",
      body: JSON.stringify({ username: "browser-test", links: {} }),
    });
  });

  await page.route("**/api/version/updates", async (route) => {
    await route.fulfill({
      contentType: "application/json",
      body: JSON.stringify({ current: "test", latest: "test" }),
    });
  });
}

async function mountToolsMenu(page, imageEnabled) {
  await routeDropzoneApis(page);
  await page.route("**/__browser-tools-menu", async (route) => {
    await route.fulfill({
      contentType: "text/html",
      body: `
    <!doctype html>
    <html>
      <head>
        <base href="https://e2ee-local-proxy.chutes.dev/">
        <style>
          body {
            margin: 0;
            font-family: sans-serif;
            background: #101010;
            color: white;
          }
          .tools-menu {
            display: flex;
            flex-direction: column;
            width: 28rem;
            padding: 1rem;
            gap: 0.75rem;
          }
          .tool-row {
            display: flex;
            align-items: center;
            gap: 1rem;
            min-height: 2.5rem;
          }
          .tool-row .label {
            flex: 1;
            text-align: left;
          }
          .toggle {
            border-radius: 999px;
            padding: 0.25rem 0.75rem;
          }
        </style>
      </head>
      <body>
        <div class="tools-menu" data-test-id="tools-menu">
          <button class="tool-row" data-test-id="web-row" data-state="on">
            <svg><path d="M12 21a9.004"></path></svg>
            <span class="label">Web Search</span>
            <span class="toggle" aria-checked="true"></span>
          </button>
          <button class="tool-row" data-test-id="image-row" data-state="${imageEnabled ? "on" : "off"}">
            <svg><path d="M21 7.6V20.4C21 20.7314"></path></svg>
            <span class="label">Image</span>
            <span class="toggle" aria-checked="${imageEnabled ? "true" : "false"}"></span>
          </button>
          <button class="tool-row" data-test-id="code-row" data-state="off">
            <svg><path d="M13 16H18"></path></svg>
            <span class="label">Code Interpreter</span>
            <span class="toggle" aria-checked="false"></span>
          </button>
        </div>
      </body>
    </html>
  `,
    });
  });
  await page.goto("https://e2ee-local-proxy.chutes.dev/__browser-tools-menu");
  await page.addStyleTag({ path: cssPath });
  await page.addScriptTag({ path: loaderPath });
}

test("image model selector appears only as a stable sub-row when image mode is on", async ({ page }) => {
  await mountToolsMenu(page, true);

  const slot = page.locator('[data-chutes-image-model-slot="true"]');
  const select = slot.locator("select");
  await expect(slot).toBeVisible();
  await expect(select).toHaveValue("chutes/Qwen-Image-2512");

  const placement = await page.evaluate(() => {
    const imageRow = document.querySelector('[data-test-id="image-row"]');
    const slotNode = document.querySelector('[data-chutes-image-model-slot="true"]');
    const rowRect = imageRow.getBoundingClientRect();
    const slotRect = slotNode.getBoundingClientRect();
    const selectRect = slotNode.querySelector("select").getBoundingClientRect();

    return {
      previousIsImageRow: slotNode.previousElementSibling === imageRow,
      slotStartsBelowRow: slotRect.top >= rowRect.bottom - 1,
      selectIsIndented: selectRect.left > rowRect.left + 24,
      selectFitsPanel: selectRect.right <= document.querySelector('[data-test-id="tools-menu"]').getBoundingClientRect().right + 1,
    };
  });

  expect(placement).toEqual({
    previousIsImageRow: true,
    slotStartsBelowRow: true,
    selectIsIndented: true,
    selectFitsPanel: true,
  });

  await select.selectOption("chutes/hunyuan-image-3");
  await expect(select).toHaveValue("chutes/hunyuan-image-3");
  await expect
    .poll(() => page.evaluate(() => document.cookie))
    .toContain("dropzone-image-model=chutes%2Fhunyuan-image-3");
});

test("image model selector is hidden while the image tool is off", async ({ page }) => {
  await mountToolsMenu(page, false);

  await expect(page.locator('[data-chutes-image-model-slot="true"]')).toHaveCount(0);
});
