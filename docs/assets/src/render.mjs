// Renders docs/assets/olcos-preview.png (RU) and olcos-preview-en.png (EN)
// from preview.html with headless Chromium.
//
//   npm i -g playwright && npx playwright install chromium   (once)
//   node docs/assets/src/render.mjs
//
// The page lays itself out at a fixed 1248 px width; the PNGs are written at
// device scale 1 so the README shows them at their natural size.
import { chromium } from 'playwright';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const here = path.dirname(fileURLToPath(import.meta.url));
const html = 'file://' + path.join(here, 'preview.html');
const out = (name) => path.join(here, '..', name);

const browser = await chromium.launch();
try {
  for (const [lang, file] of [['ru', 'olcos-preview.png'], ['en', 'olcos-preview-en.png']]) {
    const page = await browser.newPage({ viewport: { width: 1248, height: 1064 }, deviceScaleFactor: 1 });
    await page.goto(`${html}?lang=${lang}`, { waitUntil: 'networkidle' });
    await page.waitForFunction(() => document.body.dataset.ready === '1');
    await page.locator('#page').screenshot({ path: out(file) });
    console.log('wrote', out(file));
    await page.close();
  }
} finally {
  await browser.close();
}
