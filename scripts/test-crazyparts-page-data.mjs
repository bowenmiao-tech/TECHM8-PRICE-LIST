import assert from 'node:assert/strict';
import { readEmbeddedCollection, productsFromCollection, stockLabel } from './crazyparts-page-data.mjs';

const branches = (syd, mel) => [
  { branch_id: 295, branch_name: 'CP Repair', branch_code: null, inventory: 99 },
  { branch_id: 319, branch_name: 'Sydney Warehouse', branch_code: 'syd', inventory: syd },
  { branch_id: 320, branch_name: 'Melbourne Warehouse', branch_code: 'mel', inventory: mel },
];
const items = [
  {
    id: 1001,
    name: 'OLED Screen "Black" (AMPLUS)',
    branch_inventory: branches(9, 0),
    variants: [{
      id: 2001,
      retail_price_ex_tax: 80,
      business_account_price_ex_tax: { 10007: 30, 10008: 25, 10009: 20, 10010: 15 },
      branch_inventory: branches(9, 0),
    }],
  },
  {
    id: 1002,
    name: 'Battery',
    branch_inventory: branches(62, 11),
    variants: [{ id: 2002, retail_price_ex_tax: 10, business_account_price_ex_tax: { 10007: 5 } }],
  },
];
// A joined flight stream: the product list sits between other rendered components.
const flight = `0:["$","div",null,{"effectiveQuery":{"per_page":36},"initialItems":${JSON.stringify(items)},"initialTotal":47,"page":1,"perPage":36,"columns":4}]\n55:["$","a",{"href":"/collection/x"}]`;

const collection = readEmbeddedCollection(flight);
assert.equal(collection.items.length, 2);
assert.equal(collection.total, 47);
assert.equal(collection.perPage, 36);
assert.equal(readEmbeddedCollection('no product data here'), null);

const products = productsFromCollection(collection, '10009', { 2001: '/product/oled-screen-1001?variant_id=2001' });
assert.equal(products[0].title, 'OLED Screen "Black" (AMPLUS)');
assert.equal(products[0].href, '/product/oled-screen-1001?variant_id=2001');
assert.equal(products[0].memberPrice, 20);
assert.equal(products[0].retailPrice, 80);
assert.equal(products[0].syd, 'SYD:Low Stock');
assert.equal(products[0].mel, 'MEL:Out of Stock');
assert.equal(products[0].promotional, false);
assert.equal(productsFromCollection({ items: [{ ...items[0], variants: [{ ...items[0].variants[0], promotion_id: 50 }] }] }, '10009')[0].promotional, true);
// Missing tier price is reported as null, falling back to the item's stock.
assert.equal(products[1].memberPrice, null);
assert.equal(products[1].href, '/product/1002?variant_id=2002');
assert.equal(products[1].syd, 'SYD:In Stock');
assert.equal(products[1].mel, 'MEL:In Stock');

assert.equal(stockLabel(0), 'Out of Stock');
assert.equal(stockLabel(1), 'Low Stock');
assert.equal(stockLabel(10), 'Low Stock');
assert.equal(stockLabel(11), 'In Stock');

assert.throws(() => productsFromCollection(collection, ''), { code: 'CRAZYPARTS_TIER_MISMATCH' });
assert.throws(
  () => productsFromCollection({ items: [{ id: 1, name: 'X', variants: [{ id: 2 }] }] }, '10009'),
  { code: 'CRAZYPARTS_PRICES_UNAVAILABLE' },
);

console.log('Crazy Parts page data checks passed.');
