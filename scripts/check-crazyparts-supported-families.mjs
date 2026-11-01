import fs from 'node:fs/promises';
import { launchBrowser, login, discoverModels, scrapeModel, isEligibleRepairModel } from './crazyparts-price-monitor.mjs';

const config = JSON.parse(await fs.readFile('crazyparts-price-monitor.config.json', 'utf8'));
const email = process.env.CRAZYPARTS_EMAIL;
const password = process.env.CRAZYPARTS_PASSWORD;
if (!email || !password) throw new Error('Load the encrypted Crazy Parts credential before running the family check.');
const browser = await launchBrowser(config, false);
const results = [];
try {
  const page = await browser.newPage({ locale: 'en-AU', timezoneId: 'Australia/Brisbane' });
  await login(page, config, email, password);
  const models = await discoverModels(page, config);
  const families = ['Oppo','Huawei','Xiaomi','Redmi','Motorola','Nokia','Oneplus','Realme','Vivo','Sony','iMac','Macbook Pro','Macbook Air','Macbook'];
  for (const family of families) {
    const candidates = models.filter((model) => model.family === family && isEligibleRepairModel(model));
    const model = (family === 'Macbook Pro' && candidates.find((model) => model.name.includes('A1990')))
      || (family === 'Macbook Air' && candidates.find((model) => model.name.includes('A2337')))
      || candidates[0];
    try {
      if (!model) throw new Error('No model menu entries found.');
      const result = await scrapeModel(page, model, config);
      const parts = result.products.filter((product) => product.category && product.available);
      if (!parts.length || parts.some((product) => !product.memberPriceVerified)) throw new Error('No verified available repair parts were found.');
      results.push({ family, model: result.heading, menuModels: candidates.length, productsRead: result.products.length, verifiedRepairParts: parts.length, categories: [...new Set(parts.map((product) => product.category))], passed: true });
      console.log(`PASS ${family}: ${result.heading}; ${result.products.length} products, ${parts.length} verified repair parts.`);
    } catch (error) {
      results.push({ family, model: model?.name, passed: false, message: error.message });
      console.error(`FAIL ${family}: ${error.message}`);
    }
    await new Promise((resolve) => setTimeout(resolve, config.pageDelayMs));
  }
} finally {
  await browser.close();
}
await fs.writeFile('outputs/crazyparts-price-monitor/supported-family-check.json', JSON.stringify({ checkedAt: new Date().toISOString(), results }, null, 2));
if (results.some((result) => !result.passed)) process.exitCode = 1;
