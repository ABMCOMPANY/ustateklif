const { test, expect } = require('@playwright/test');

function offlineSupabase() {
  const signed = new URLSearchParams(location.search).get('qa') === 'customer';
  const id = '00000000-0000-4000-8000-000000000021';
  const user = { id, email: 'qa@example.invalid' };
  const profile = {
    id, name: 'QA Kullanıcısı', title: 'Klima uzmanı',
    bio: 'İzole görsel test', service_categories: ['klima'],
    service_city: 'Mersin', service_districts: [], account_status: 'active',
    expert_status: 'approved', identity_verified: true
  };
  function query(table) {
    const value = table === 'profiles' ? [profile] : [];
    const q = {
      select: () => q, eq: () => q, in: () => q, order: () => q,
      limit: () => q, single: () => q, maybeSingle: () => q,
      then: (ok, fail) => Promise.resolve({ data: value, error: null }).then(ok, fail)
    };
    return q;
  }
  const client = {
    auth: {
      onAuthStateChange(callback) {
        setTimeout(() => callback('INITIAL_SESSION', signed ? { user } : null), 0);
        return { data: { subscription: { unsubscribe() {} } } };
      }
    },
    from: query,
    rpc(name) {
      return Promise.resolve({ data: name === 'is_admin' ? false : [], error: null });
    },
    channel() {
      const channel = { on: () => channel, subscribe: () => channel };
      return channel;
    },
    removeChannel() {}
  };
  window.supabase = { createClient: () => client };
}

async function openIsolated(page, view = 'guest', palette = null, scheme = 'light') {
  const blocked = [];
  if (palette) await page.addInitScript(value => localStorage.setItem('tamisim_palette', value), palette);
  await page.emulateMedia({ colorScheme: scheme });
  await page.route('**/*', async route => {
    const url = route.request().url();
    if (url.includes('/@supabase/supabase-js@') && url.includes('cdn.jsdelivr.net')) {
      return route.fulfill({ status: 200, contentType: 'application/javascript',
        body: '(' + offlineSupabase.toString() + ')()' });
    }
    if (url.startsWith('http://127.0.0.1:4173/')) return route.continue();
    if (url.startsWith('https://fonts.googleapis.com/') ||
        url.startsWith('https://fonts.gstatic.com/')) return route.continue();
    blocked.push(url);
    return route.abort();
  });
  await page.goto(view === 'customer' ? '/?qa=customer' : '/', { waitUntil: 'domcontentloaded' });
  await expect(page.locator('.boot-skeleton')).toHaveCount(0);
  await expect(page.locator('.fatal-state')).toHaveCount(0);
  return blocked;
}

async function capture(page, testInfo, name) {
  await page.screenshot({ path: testInfo.outputPath(name + '.png'), fullPage: true });
}

test.afterEach(async ({ page }, testInfo) => {
  const width = await page.evaluate(() => ({
    scroll: document.documentElement.scrollWidth,
    client: document.documentElement.clientWidth
  }));
  expect(width.scroll, 'horizontal overflow').toBeLessThanOrEqual(width.client + 1);
});

test('misafir ana sayfa, kategori, arama ve ilan butonu', async ({ page }, testInfo) => {
  const blocked = await openIsolated(page);
  await expect(page.locator('.hero')).toBeVisible();
  await expect(page.locator('.homecat').first()).toBeVisible();
  await expect(page.locator('.hero-create')).toBeVisible();
  await capture(page, testInfo, 'guest-home');
  await page.locator('.homecat').first().click();
  await expect(page.locator('.create-head')).toBeVisible();
  await capture(page, testInfo, 'guest-category');
  await page.locator('[data-a="guestBack"]').click();
  await page.locator('#guest-search').fill('klima');
  await expect(page.locator('.homecat[data-v="klima"]')).toBeVisible();
  await expect(page.locator('.homecat[data-v="boya"]')).toBeHidden();
  await capture(page, testInfo, 'guest-search');
  await page.locator('.hero-create').click();
  await expect(page.locator('.create-head')).toBeVisible();
  await capture(page, testInfo, 'guest-create');
  expect(blocked, 'unexpected external requests').toEqual([]);
});

test('müşteri ve uzman görünümü: fixture', async ({ page }, testInfo) => {
  const blocked = await openIsolated(page, 'customer');
  await expect(page.locator('#hdr-r')).toBeVisible();
  await expect(page.locator('[data-a="role"][data-v="musteri"]')).toHaveAttribute('aria-pressed', 'true');
  await capture(page, testInfo, 'customer');
  await page.locator('[data-a="role"][data-v="usta"]').click();
  await expect(page.locator('.pro-dashboard')).toBeVisible();
  await capture(page, testInfo, 'expert');
  expect(blocked, 'unexpected external requests').toEqual([]);
});

test('eski palet tercihi ve açık/koyu tema', async ({ page }, testInfo) => {
  const blocked = await openIsolated(page, 'guest', 'navy-teal', 'light');
  await expect(page.locator('html')).toHaveAttribute('data-palette', 'navy-teal');
  await capture(page, testInfo, 'legacy-palette-light');
  const light = await page.locator('body').evaluate(el => getComputedStyle(el).backgroundColor);
  await page.emulateMedia({ colorScheme: 'dark' });
  const dark = await page.locator('body').evaluate(el => getComputedStyle(el).backgroundColor);
  expect(dark).not.toBe(light);
  await capture(page, testInfo, 'legacy-palette-dark');
  expect(blocked, 'unexpected external requests').toEqual([]);
});
