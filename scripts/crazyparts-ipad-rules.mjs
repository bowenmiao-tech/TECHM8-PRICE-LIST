export function ipadKey(name) {
  const text = String(name).toLowerCase().replace(/ipad\s*/g, '').replace(/\s+/g, ' ').trim();
  const family = text.match(/^(pro|air|mini)\b/)?.[1];
  if (!family) return '';
  let size = text.match(/^(?:pro|air|mini)\s*(\d+(?:\.\d+)?)/)?.[1];
  if (!size && family === 'air') size = '1';
  if (!size && family === 'mini') size = '1';
  const year = text.match(/\b(20\d{2})\b/)?.[1];
  if (family === 'mini' || (family === 'air' && Number(size) <= 5)) return `${family}:${size}`;
  return size && year ? `${family}:${size}:${year}` : '';
}

export function protectedIpad(name) {
  const key = ipadKey(name);
  return /^(?:pro:(?:9\.7|10\.5):|air:[1-5]$|mini:[1-3]$)/.test(key)
    || /ipad\s*(?:mini\s*1\/2\/3|air\s*\(9\.7\))/i.test(name);
}

export function ipadCategory(name) {
  const text = String(name).toLowerCase();
  if (/replacement battery|battery replacement/.test(text) && !/connector|tester|cover|board/.test(text)) return 'battery';
  if (/protector|tempered|adhesive|sticker|fpc connector|on (?:the )?motherboard|tester|test cable|ic chip/.test(text)) return null;
  if (/touch panel|front glass|glass only|outer glass|lens glass|with oca/.test(text)) return null;
  if (/touch screen digitizer/.test(text) && !/lcd|oled/.test(text)) return null;
  if (/lcd|oled|screen replacement|display assembly/.test(text) && !/flex cable|backlight|polariz|frame only/.test(text)) return 'screen';
  if (/battery/.test(text) && !/connector|cover|cable|board|tester/.test(text)) return 'battery';
  if (/charging port|charge port|charging connector|dock connector|usb.c port/.test(text)) {
    if (/no solder|without solder|non.solder|plug.and.play|with (?:circuit )?board/.test(text)) return 'ipad_port_plug';
    if (/solder|welding/.test(text)) return 'ipad_port_solder';
    return null; // Unspecified repair method must not be guessed from price or model age.
  }
  if (/front camera/.test(text) && !/glass|lens|bracket|cover/.test(text)) return 'ipad_front_camera';
  if (/rear camera|back camera/.test(text) && !/glass|lens|bracket|cover/.test(text)) return 'ipad_rear_camera';
  if (/speaker/.test(text) && !/mesh|adhesive|connector|cable/.test(text)) return 'speaker';
  return null;
}

export function ipadLabour(type) {
  if (type === 'Screen' || type === 'Battery') return 150;
  if (type === 'Charging Port (Soldering)') return 199;
  if (type === 'Charging Port (Plug-in)') return 159;
  return 120;
}

export function ipadPlan(raw, siteRows) {
  const updates = [];
  const issues = { Screen: 'Screen Replacement', Battery: 'Battery (ORIGINAL )', 'Front Camera': 'Front Camera', 'Rear Camera': 'Rear Camera', Speaker: 'Speaker', 'Charging Port (Soldering)': 'Charging Socket/Microphone', 'Charging Port (Plug-in)': 'Charging Socket/Microphone' };
  for (const row of raw.repairRows || []) {
    if (!/^ipad /i.test(row.family) || protectedIpad(row.model)) continue;
    const key = ipadKey(row.model);
    if (!key || !issues[row.repairType]) continue;
    const candidates = [...new Set(siteRows.filter((item) => ipadKey(item.model) === key).map((item) => item.model))];
    candidates.sort((a,b) => b.length-a.length);
    const model = candidates[0] || row.model;
    if (protectedIpad(model)) throw new Error(`Protected iPad model matched: ${model}`);
    const defaults = { Screen: ['LCD Replacement (Complete Assembly)', 'LCD Replacement'], Battery: ['Battery', 'Battery (ORIGINAL )'], 'Charging Port (Soldering)': ['Charging Port', 'Charging Socket'], 'Charging Port (Plug-in)': ['Charging Port', 'Charging Socket'] };
    const preferred = defaults[row.repairType] || [issues[row.repairType]];
    const issue = preferred.find((issue) => siteRows.some((item) => item.model === model && item.issue === issue)) || preferred[0];
    const existing = siteRows.find((item) => item.model === model && item.issue === issue);
    const price = (cost) => Math.ceil((Math.round(cost * 100) * 11 + ipadLabour(row.repairType) * 1000) / 5000) * 5;
    const min = price(row.minPartPrice), max = price(row.maxPartPrice);
    updates.push({ brand: 'Apple iPad', model, issue, newPrice: min === max ? String(min) : `${min} - ${max}`, oldPrice: existing?.price ?? null });
  }
  if (!updates.length) throw new Error('No eligible iPad prices. Existing prices were kept.');
  const deleteKeys = siteRows.filter((row) => !protectedIpad(row.model) && /^pro:/.test(ipadKey(row.model))
    && updates.some((update) => update.model === row.model && /LCD Replacement/.test(update.issue))
    && (/Touch|Digitizer|Glass/i.test(row.issue)
      || (row.issue === 'LCD Replacement' && updates.some((update) => update.model === row.model && update.issue === 'LCD Replacement (Complete Assembly)'))))
    .map(({brand,model,issue}) => ({brand,model,issue}));
  return { updates, deleteKeys, unmatched: [], obsoleteModels: [], replaceBrands: [], supplierModels: new Set(updates.map((row) => row.model)).size };
}
