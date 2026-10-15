const { test, expect } = require('@playwright/test');

async function openHome(page) {
  await page.goto('/', { waitUntil: 'domcontentloaded' });
  await expect(page).toHaveTitle(/Tamİşim/i);
  await expect(page.locator('body')).toBeVisible();
}

test.describe('D1-A responsive shell', () => {
  test('ana sayfa yatay taşma üretmez', async ({ page }) => {
    await openHome(page);

    const overflow = await page.evaluate(() => ({
      scrollWidth: document.documentElement.scrollWidth,
      clientWidth: document.documentElement.clientWidth,
    }));

    expect(
      overflow.scrollWidth,
      `horizontal overflow: scrollWidth=${overflow.scrollWidth}, clientWidth=${overflow.clientWidth}`
    ).toBeLessThanOrEqual(overflow.clientWidth + 1);
  });

  test('İlan Oluştur ana aksiyonu görünür', async ({ page }) => {
    await openHome(page);

    const cta = page.getByText(/İlan Oluştur/i).filter({ visible: true }).first();
    await expect(cta).toBeVisible();
  });

  test('mobil ve desktop navigation breakpoint davranışı doğru', async ({ page }, testInfo) => {
    await openHome(page);

    const width = testInfo.project.use.viewport.width;
    const bottomNav = page.locator('.bottomnav');
    const desktopNav = page.locator('.desktopnav');

    if (width >= 1024) {
      await expect(desktopNav).toBeVisible();
      await expect(bottomNav).toBeHidden();
    } else {
      await expect(bottomNav).toBeVisible();
      await expect(desktopNav).toBeHidden();
    }
  });

  test('ana shell viewport içinde kalır', async ({ page }) => {
    await openHome(page);

    const app = page.locator('#app');
    await expect(app).toBeVisible();

    const box = await app.boundingBox();
    const viewport = page.viewportSize();

    expect(box).not.toBeNull();
    expect(viewport).not.toBeNull();
    expect(box.x).toBeGreaterThanOrEqual(-1);
    expect(box.x + box.width).toBeLessThanOrEqual(viewport.width + 1);
  });

  test('kanıt screenshot üretilebilir', async ({ page }, testInfo) => {
    await openHome(page);

    await page.screenshot({
      path: testInfo.outputPath('tamisim-home.png'),
      fullPage: true,
    });
  });
});
