// Shared by capture and publishing so a verification page can never become a price list.
function failure(message, code) {
  const error = new Error(message);
  error.code = code;
  return error;
}

export function assertSupplierPage({ status = 200, title = '', heading = '', text = '', url = '' }) {
  const content = `${title}\n${heading}\n${text}`;
  if (/Error 1015|you are being rate limited|rate limit exceeded/i.test(content)) {
    throw failure('Crazy Parts rate limit (Error 1015). Existing prices were kept.', 'CRAZYPARTS_RATE_LIMIT');
  }
  if (/安全验证|验证您不是|请稍候|正在验证|人机验证|just a moment|checking your browser|verify (?:that )?you are human|performing security verification|security verification|enable javascript and cookies to continue|challenge-platform|cf-chl-/i.test(content)
    || (status === 403 && /cloudflare|ray id/i.test(content))) {
    throw failure('Crazy Parts security verification is required. Run the updater with -Headful and complete verification in its browser window. Existing prices were kept.', 'CRAZYPARTS_VERIFICATION');
  }
  if (status >= 400) {
    throw failure(`Crazy Parts returned HTTP ${status} at ${url}. Existing prices were kept.`, 'CRAZYPARTS_INVALID_PAGE');
  }
  if (/^\s*(?:https?:\/\/)?(?:www\.)?crazyparts\.com\.au\/?\s*$/i.test(heading)
    || /access denied|attention required|temporarily unavailable|bad gateway|page not found/i.test(`${title}\n${heading}`)) {
    throw failure('Crazy Parts returned a verification or error page instead of a model page. Existing prices were kept.', 'CRAZYPARTS_INVALID_PAGE');
  }
}

export function assertProductResult({ heading, text, linkCount, cardCount, expectedCount = 0 }) {
  if (!String(heading || '').trim()) {
    throw failure('The model heading did not load. Existing prices were kept.', 'CRAZYPARTS_INVALID_PAGE');
  }
  if (!cardCount && (linkCount > 0 || expectedCount > 0)) {
    throw failure('Products were listed but member prices could not be read. Existing prices were kept.', 'CRAZYPARTS_INVALID_PAGE');
  }
  if (!cardCount && !/\b0\s+(?:items?|products?|results?)\b|no products (?:found|available)|no results found|暂无商品|没有商品/i.test(text)) {
    throw failure('The page has no readable products and no confirmed empty catalogue message. Existing prices were kept.', 'CRAZYPARTS_INVALID_PAGE');
  }
}

export function assertPublishableRun(data) {
  if (!data.repairRows?.length || !data.sourceRows?.length) {
    throw new Error('Price sync refused: no verified repair prices were captured. Existing prices were kept.');
  }
  if (Number(data.modelsProcessed) !== Number(data.modelsSelected)
    || (data.exceptions || []).some((row) => row.issue === 'Model page failed')) {
    throw new Error('Price sync refused: model pages did not all complete successfully. Existing prices were kept.');
  }
  for (const row of [...data.repairRows, ...data.sourceRows]) {
    assertSupplierPage({ heading: row.model });
  }
  for (const model of data.modelResults || []) {
    assertSupplierPage({ heading: model.heading });
    if (model.validated !== true) throw new Error('Price sync refused: an unvalidated model page was included.');
  }
}
