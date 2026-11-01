import assert from 'node:assert/strict';
import { chromium } from 'playwright';
import { extractProductCards } from './crazyparts-price-monitor.mjs';

const browser = await chromium.launch({ channel: 'chrome', headless: true });
try {
  const page = await browser.newPage();
  await page.setContent(`
    <article><a href="/product/missing-cart?variant_id=1">Back Flip Leather Wallet Case</a>
      <div>SYD:Out of Stock</div><div>MEL:Out of Stock</div>
      <div>Diamond</div><div>$4.<span>80</span></div><div>+ GST</div>
      <div>Retail Price (Ex. Tax): $32.00</div><button>Add to Wishlist</button></article>
    <article><a href="/product/screen?variant_id=2">OLED Screen</a>
      <div>SYD:In Stock</div><div>Diamond</div><div>$48.<span>90</span></div><div>+ GST</div>
      <div>Retail Price (Ex. Tax): $100.00</div><button>Add To Cart</button></article>
    <article><a href="/product/login?variant_id=3">Battery awaiting login</a>
      <div>SYD:In Stock</div><div>Login to see price</div><div>Retail Price: $30.00</div></article>
  `);
  // innerText deliberately uses separate lines, matching the live card layout.
  await page.locator('span').evaluateAll((spans) => spans.forEach((span) => { span.style.display = 'block'; }));
  const cards = await extractProductCards(page, { expectedMemberTier: 'Diamond' });
  assert.equal(cards.length, 2);
  assert.equal(cards.find((card) => card.href.includes('missing-cart')).memberPriceLine, '$4.80');
  assert.equal(cards.find((card) => card.href.includes('screen')).memberPriceLine, '$48.90');
  assert.equal(cards.find((card) => card.href.includes('screen')).memberPriceVerified, true);
  await page.setContent('<article><a href="/product/loading">Screen</a><div>SYD:In Stock</div><div>Diamond</div><div>$151.00</div><div>+ GST</div><div>Retail Price (Ex. Tax): $151.20</div></article>');
  assert.equal((await extractProductCards(page, { expectedMemberTier: 'Diamond' }))[0].memberPriceVerified, false);
  await page.setContent('<article><a href="/product/promotion">Promotional Battery</a><div>SYD:In Stock</div><div>Diamond</div><div>$1.00</div><div>+ GST</div><div>Was: $4.50</div></article>');
  assert.equal((await extractProductCards(page, { expectedMemberTier: 'Diamond' }))[0].memberPriceVerified, true);
  assert.match(cards[0].syd, /Out of Stock/);
  console.log('PASS: out-of-stock cards without cart buttons, split-decimal member prices, and exclusion of retail-only cards.');
} finally {
  await browser.close();
}
