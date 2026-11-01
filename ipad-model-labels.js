// Display labels for the existing price-list model keys. Values stay unchanged
// so quotes and repair prices continue to match their stored model names.
// Source: https://support.apple.com/en-au/108043 (Identify your iPad model).
(function (root) {
  'use strict';

  const numbersByModel = {
    'iPad 10 (2022)': 'A2696 A2757 A2777 A3162',
    'iPad 2 (2011)': 'A1395 A1396 A1397',
    'iPad 2/3/4': 'A1395 A1396 A1397 A1416 A1430 A1403 A1458 A1459 A1460',
    'iPad 3 (2012)': 'A1416 A1430 A1403',
    'iPad 4 (2012)': 'A1458 A1459 A1460',
    'iPad 5 (2017)': 'A1822 A1823',
    'iPad 6 (2018)': 'A1893 A1954',
    'iPad 7 (2019)': 'A2197 A2200 A2198',
    'iPad 8 (2020)': 'A2270 A2428 A2429 A2430',
    'iPad 9 (2021)': 'A2602 A2604 A2603 A2605',
    'IPAD A16 (2025)': 'A3354 A3355 A3356',
    'iPad AIR (2013)': 'A1474 A1475 A1476',
    'iPad AIR (9.7)': 'A1474 A1475 A1476 A1566 A1567',
    'iPad AIR 11 (2024)': 'A2902 A2903 A2904',
    'iPad Air 11 (2025)': 'A3266 A3267 A3270',
    'iPad Air 11 (2026)': 'A3459 A3460 A3463',
    'iPad AIR 13 (2024)': 'A2898 A2899 A2900',
    'iPad Air 13 (2025)': 'A3268 A3269 A3271',
    'iPad Air 13 (2026)': 'A3461 A3462 A3464',
    'iPad Air 2 (2014)': 'A1566 A1567',
    'iPad Air 3 (2019)': 'A2152 A2123 A2153 A2154',
    'iPad Air 4 (2020)': 'A2316 A2324 A2325 A2072',
    'iPad Air 5 (2022)': 'A2588 A2589 A2591',
    // The catalogue's old A2786/A2787/A2788 suffix belongs to Mac Pro.
    // Its generic Air 6 option covers both 2024 M2 sizes.
    'iPad AIR 6 (2024)': 'A2902 A2903 A2904 A2898 A2899 A2900',
    'iPad Mini (2012)': 'A1432 A1454 A1455',
    'iPad MINI 1/2/3': 'A1432 A1454 A1455 A1489 A1490 A1491 A1599 A1600',
    'iPad Mini 2 (2013)': 'A1489 A1490 A1491',
    'iPad Mini 3 (2014)': 'A1599 A1600',
    'iPad MINI 4': 'A1538 A1550',
    'iPad Mini 4 (2015)': 'A1538 A1550',
    'iPad Mini 5 (2019)': 'A2133 A2124 A2126 A2125',
    'iPad Mini 6 (2022)': 'A2567 A2568 A2569',
    'iPad mini 7 (2024)': 'A2993 A2995 A2996',
    'iPad Pro 10.5 (2017)': 'A1701 A1709 A1852',
    'iPad Pro 11 (2018)': 'A1980 A2013 A1934 A1979',
    'iPad Pro 11 (2020)': 'A2228 A2068 A2230 A2231',
    'iPad Pro 11 (2021)': 'A2377 A2459 A2301 A2460',
    'iPad Pro 11 (2022)': 'A2759 A2761 A2435 A2762',
    'iPad Pro 11 (2024)': 'A2836 A2837 A3006',
    'iPad Pro 11 (2025)': 'A3357 A3358 A3359',
    'iPad Pro 12.9 (2015)': 'A1584 A1652',
    'iPad Pro 12.9 (2017)': 'A1670 A1671 A1821',
    'iPad Pro 12.9 (2018)': 'A1876 A2014 A1895 A1983',
    'iPad Pro 12.9 (2020)': 'A2229 A2069 A2232 A2233',
    'iPad Pro 12.9 (2021)': 'A2378 A2461 A2379 A2462',
    'iPad Pro 12.9 (2022)': 'A2436 A2437 A2764 A2766',
    'iPad Pro 13 (2024)': 'A2925 A2926 A3007',
    'iPad Pro 13 (2025)': 'A3360 A3361 A3362',
    'iPad Pro 9.7 (2015)': 'A1673 A1674 A1675'
  };
  const normalized = new Map(Object.entries(numbersByModel)
    .map(([name, numbers]) => [name.toLowerCase(), numbers]));

  function label(model) {
    const original = String(model || '');
    const base = original.replace(/\s*\((?:A\d{4}\s*)+\)$/i, '').trim();
    const numbers = normalized.get(base.toLowerCase());
    return numbers ? `${base} (${numbers})` : original;
  }

  root.Techm8IpadModelLabels = { label };
  if (typeof module !== 'undefined' && module.exports) module.exports = { label };
})(typeof window !== 'undefined' ? window : globalThis);
