-- Replace the broken manufacturer image and refresh verified WDC-195 specifications.
update public.products
set image_url = 'https://oztechm8.com.au/assets/products/accessories/wekome-wdc-195-aux-cable.jpg',
    supplier_image_url = 'https://wekome.co.kr/web/product/big/202506/085adc656f02d19b7e800159999d87eb.jpg',
    short_description = '1m 3.5mm AUX audio cable with enamelled wire and aluminium connector shells.',
    description = 'Connect devices with 3.5mm audio ports using the WEKOME WDC-195 AUX cable. It has a 1 metre (1000mm) length, enamelled wire and aluminium connector shells. The cable weighs approximately 10g. Devices without a 3.5mm audio port need a compatible adapter, sold separately.',
    detail_html = '<h3>Product specifications</h3><ul><li>Model: WEKOME WDC-195</li><li>Connection: 3.5mm AUX audio</li><li>Cable length: 1m (1000mm)</li><li>Materials: enamelled wire and aluminium connector shells</li><li>Product weight: approximately 10g</li></ul>',
    seo_description = 'Shop the WEKOME WDC-195 1m 3.5mm AUX audio cable with aluminium connector shells at TechM8.',
    updated_at = timezone('utc'::text, now())
where sku = 'TM8-WEKOME-WDC-195';
