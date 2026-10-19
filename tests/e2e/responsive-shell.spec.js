const { test, expect } = require('@playwright/test');

async function openHome(page) {
  await page.goto('/', { waitUntil: 'domcontentloaded' });
  await expect(page).toHaveTitle(/Tamİşim/i);
  await expect(page.locator('body')).toBeVisible();
  await expect(page.locator('.hero')).toBeVisible();
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

  test('guest ana ilan aksiyonu görünür', async ({ page }) => {
    await openHome(page);

    const cta = page.getByText(/İlan (ver|Oluştur)/i).filter({ visible: true }).first();
    await expect(cta).toBeVisible();
  });

  test('navigation breakpoint guest görünümünde bozulmaz', async ({ page }, testInfo) => {
    await openHome(page);

    const width = testInfo.project.use.viewport.width;
    const bottomNav = page.locator('.bottomnav');
    const desktopNav = page.locator('.desktopnav');
    const guestHeader = page.locator('#guest-hdr');

    await expect(guestHeader).toBeVisible();
    await expect(desktopNav).toBeHidden();

    if (width >= 1024) {
      await expect(bottomNav).toBeHidden();
    }
  });

  test('desktop shell mobil kolon gibi kalmaz', async ({ page }, testInfo) => {
    await openHome(page);

    const viewport = page.viewportSize();
    const appShell = page.locator('.app');
    const hero = page.locator('.hero');

    const appBox = await appShell.boundingBox();
    const heroBox = await hero.boundingBox();

    expect(viewport).not.toBeNull();
    expect(appBox).not.toBeNull();
    expect(heroBox).not.toBeNull();

    expect(appBox.x).toBeGreaterThanOrEqual(-1);
    expect(appBox.x + appBox.width).toBeLessThanOrEqual(viewport.width + 1);

    if (testInfo.project.use.viewport.width >= 1024) {
      expect(
        appBox.width,
        `desktop app shell too narrow: ${appBox.width}px at viewport ${viewport.width}px`
      ).toBeGreaterThanOrEqual(viewport.width * 0.82);

      expect(
        heroBox.width,
        `desktop hero too narrow: ${heroBox.width}px at viewport ${viewport.width}px`
      ).toBeGreaterThanOrEqual(viewport.width * 0.72);
    }
  });

  test('desktop kategori grid en az 4 kolon kullanır', async ({ page }, testInfo) => {
    test.skip(testInfo.project.use.viewport.width < 1024, 'desktop-only acceptance check');

    await openHome(page);

    const visibleCards = page.locator('.homecat').filter({ visible: true });
    const count = await visibleCards.count();
    expect(count).toBeGreaterThanOrEqual(4);

    const firstFour = [];
    for (let i = 0; i < 4; i += 1) {
      const box = await visibleCards.nth(i).boundingBox();
      expect(box).not.toBeNull();
      firstFour.push(box);
    }

    const distinctColumns = new Set(firstFour.map((box) => Math.round(box.x)));
    expect(
      distinctColumns.size,
      `expected at least 4 desktop columns, found ${distinctColumns.size}`
    ).toBeGreaterThanOrEqual(4);
  });

  test('kanıt screenshot üretilebilir', async ({ page }, testInfo) => {
    await openHome(page);

    await page.screenshot({
      path: testInfo.outputPath('tamisim-home.png'),
      fullPage: true,
    });
  });
});
