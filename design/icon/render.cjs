// Renders the app icon PNGs from the SVG sources with Playwright's Chromium.
// Usage: node design/icon/render.cjs   (needs `npm i -g playwright` or NODE_PATH to it)
// 16–64 px use icon_small.svg: thicker strokes stay readable at small sizes.
const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');

const here = __dirname;
const out = path.join(here, '..', '..', 'App', 'Assets.xcassets', 'AppIcon.appiconset');
const variants = [
  ['icon.svg', [1024, 512, 256, 128]],
  ['icon_small.svg', [64, 32, 16]],
];

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage();
  for (const [file, sizes] of variants) {
    const svg = fs.readFileSync(path.join(here, file), 'utf8');
    for (const size of sizes) {
      await page.setViewportSize({ width: size, height: size });
      const sized = svg.replace('width="1024" height="1024"', `width="${size}" height="${size}"`);
      await page.setContent(`<!doctype html><body style="margin:0;background:transparent">${sized}</body>`);
      await page.screenshot({ path: path.join(out, `icon_${size}.png`), omitBackground: true, clip: { x: 0, y: 0, width: size, height: size } });
    }
  }
  await browser.close();
})();
