import { createClient } from 'npm:@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-api-key',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
}

const PRODUCT_IMAGE_BUCKET = 'product-images'
const DEFAULT_PAGE_SIZE = 200
const MAX_PAGE_SIZE = 500

type JsonRecord = Record<string, unknown>

type ProductRow = {
  id: number
  sku: string | null
  slug: string | null
  name: string | null
  upc: string | null
  cost_price: number | string | null
  retail_price: number | string | null
  compare_at_price: number | string | null
  image_url: string | null
  stock_quantity: number | null
  updated_at: string | null
  is_visible: boolean | null
  is_pos_visible: boolean | null
  product_group_id: number | null
  variant_name: string | null
  variant_color: string | null
  source_system: string | null
  source_external_id: string | null
  pos_category_id: number | null
  pos_sort_order: number | null
  pos_category_taxonomy: {
    id: number
    category_name: string
    subcategory_name: string
  } | null
  categories: {
    id: number | null
    slug: string | null
    name: string | null
  } | null
}

type ProductGroupRow = {
  id: number
  code: string
  slug: string
  name: string
  product_family: string
  main_image_url: string | null
  is_pos_visible: boolean
  is_visible: boolean
  pos_category_id: number | null
  pos_sort_order: number | null
  pos_category_taxonomy: {
    id: number
    category_name: string
    subcategory_name: string
  } | null
  product_fit_profiles: {
    code: string
    display_name: string
    review_status: string
    product_fit_profile_devices: Array<{
      device_models: {
        code: string
        display_name: string
      } | null
    }>
  } | null
}

type ProductImageRow = {
  product_id: number
  image_url: string | null
  alt_text: string | null
  sort_order: number | null
}

type InventoryRow = {
  product_id: number
  quantity: number | null
  shelf_location: string | null
  stores: {
    slug: string | null
    name: string | null
  } | null
}

function jsonResponse(payload: JsonRecord, status = 200) {
  return Response.json(payload, { status, headers: corsHeaders })
}

function getAuthToken(req: Request) {
  const apiKey = req.headers.get('x-api-key') ?? ''
  if (apiKey.trim()) return apiKey.trim()

  const authorization = req.headers.get('authorization') ?? ''
  if (!authorization.toLowerCase().startsWith('bearer ')) return ''
  return authorization.slice(7).trim()
}

function clampPositiveInteger(value: unknown, fallback: number, max: number) {
  const numberValue = Number(value)
  if (!Number.isFinite(numberValue) || numberValue < 1) return fallback
  return Math.min(max, Math.floor(numberValue))
}

function normalizeNullableString(value: unknown) {
  const text = String(value ?? '').trim()
  return text ? text : null
}

function normalizeNumber(value: unknown) {
  if (value === null || value === undefined || value === '') return null
  const numberValue = Number(value)
  return Number.isFinite(numberValue) ? numberValue : null
}

async function readRequestInput(req: Request) {
  const url = new URL(req.url)
  const input: JsonRecord = {}

  for (const [key, value] of url.searchParams.entries()) {
    input[key] = value
  }

  if (req.method === 'POST') {
    const contentType = req.headers.get('content-type') ?? ''
    if (contentType.includes('application/json')) {
      const body = await req.json().catch(() => ({}))
      if (body && typeof body === 'object') Object.assign(input, body)
    }
  }

  return input
}

function buildThumbnailUrl(imageUrl: string | null, supabaseUrl: string) {
  const sourceUrl = buildPublicImageUrl(imageUrl, supabaseUrl)
  if (!sourceUrl) return null

  try {
    const source = new URL(sourceUrl)
    const project = new URL(supabaseUrl)
    const publicPrefix = `/storage/v1/object/public/${PRODUCT_IMAGE_BUCKET}/`

    if (source.origin === project.origin && source.pathname.startsWith(publicPrefix)) {
      const storagePath = source.pathname.slice(publicPrefix.length)
      const thumbnail = new URL(`${project.origin}/storage/v1/render/image/public/${PRODUCT_IMAGE_BUCKET}/${storagePath}`)
      thumbnail.searchParams.set('width', '160')
      thumbnail.searchParams.set('height', '160')
      thumbnail.searchParams.set('resize', 'contain')
      thumbnail.searchParams.set('quality', '70')
      return thumbnail.toString()
    }
  } catch {
    return sourceUrl
  }

  return sourceUrl
}

function buildPublicImageUrl(imageUrl: string | null, supabaseUrl: string) {
  const sourceUrl = String(imageUrl ?? '').trim()
  if (!sourceUrl) return null
  if (sourceUrl.startsWith('//')) return `https:${sourceUrl}`

  try {
    const url = new URL(sourceUrl)
    if (url.protocol === 'http:') url.protocol = 'https:'
    return url.toString()
  } catch {
    if (sourceUrl.startsWith('/')) {
      return new URL(sourceUrl, Deno.env.get('PUBLIC_SITE_URL') ?? 'https://www.techm8australia.com').toString()
    }
    return sourceUrl
  }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  if (req.method !== 'GET' && req.method !== 'POST') {
    return jsonResponse({ ok: false, error: 'Method not allowed.' }, 405)
  }

  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? ''
    const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    const expectedApiKey = Deno.env.get('INTERNAL_PRODUCTS_API_KEY') ?? ''

    if (!supabaseUrl || !serviceRoleKey) {
      return jsonResponse({ ok: false, error: 'Supabase service is not configured.' }, 500)
    }

    if (!expectedApiKey) {
      return jsonResponse({ ok: false, error: 'Internal products API key is not configured.' }, 500)
    }

    const token = getAuthToken(req)
    if (!token || token !== expectedApiKey) {
      return jsonResponse({ ok: false, error: 'Unauthorized.' }, 401)
    }

    const input = await readRequestInput(req)
    const pageSize = clampPositiveInteger(input.limit ?? input.page_size, DEFAULT_PAGE_SIZE, MAX_PAGE_SIZE)
    const page = clampPositiveInteger(input.page, 1, 100000)
    const from = (page - 1) * pageSize
    const to = from + pageSize - 1
    const updatedSince = normalizeNullableString(input.updated_since)
    const onlineVisibleOnly = input.online_visible_only === true || String(input.online_visible_only ?? '').toLowerCase() === 'true'
    const includePosHidden = input.include_pos_hidden === true || String(input.include_pos_hidden ?? '').toLowerCase() === 'true'
    const storeSlug = normalizeNullableString(input.store_slug)

    const supabaseAdmin = createClient(supabaseUrl, serviceRoleKey, {
      auth: { persistSession: false },
    })

    let productsQuery = supabaseAdmin
      .from('products')
      .select('id, sku, slug, name, upc, cost_price, retail_price, compare_at_price, image_url, stock_quantity, updated_at, is_visible, is_pos_visible, product_group_id, variant_name, variant_color, source_system, source_external_id, pos_category_id, pos_sort_order, pos_category_taxonomy(id, category_name, subcategory_name), categories(id, slug, name)', { count: 'exact' })
      .order('updated_at', { ascending: false })
      .order('id', { ascending: false })
      .range(from, to)

    if (onlineVisibleOnly) productsQuery = productsQuery.eq('is_visible', true)
    if (!includePosHidden) productsQuery = productsQuery.eq('is_pos_visible', true)
    if (updatedSince) productsQuery = productsQuery.gte('updated_at', updatedSince)

    const { data: products, error: productsError, count } = await productsQuery
    if (productsError) {
      console.error(productsError)
      return jsonResponse({ ok: false, error: 'Products could not be loaded.' }, 500)
    }

    const productRows = (products ?? []) as ProductRow[]
    const productIds = productRows.map((product) => product.id)
    const productGroupIds = Array.from(new Set(
      productRows.map((product) => product.product_group_id).filter((id): id is number => Number.isInteger(id))
    ))

    const { data: posCategories, error: posCategoriesError } = await supabaseAdmin
      .from('pos_category_taxonomy')
      .select('id, category_name, subcategory_name, category_sort, subcategory_sort')
      .eq('active', true)
      .order('category_sort', { ascending: true })
      .order('subcategory_sort', { ascending: true })

    if (posCategoriesError) {
      console.error(posCategoriesError)
      return jsonResponse({ ok: false, error: 'POS categories could not be loaded.' }, 500)
    }

    const [
      { data: images, error: imagesError },
      { data: inventory, error: inventoryError },
      { data: productGroups, error: productGroupsError },
    ] = await Promise.all([
      productIds.length
        ? supabaseAdmin
            .from('product_images')
            .select('product_id, image_url, alt_text, sort_order')
            .in('product_id', productIds)
            .order('sort_order', { ascending: true })
            .order('id', { ascending: true })
        : Promise.resolve({ data: [] as ProductImageRow[], error: null }),
      productIds.length
        ? supabaseAdmin
            .from('product_store_inventory')
            .select('product_id, quantity, shelf_location, stores!inner(slug, name)')
            .in('product_id', productIds)
            .order('store_id', { ascending: true })
        : Promise.resolve({ data: [] as InventoryRow[], error: null }),
      productGroupIds.length
        ? supabaseAdmin
            .from('product_groups')
            .select('id, code, slug, name, product_family, main_image_url, is_pos_visible, is_visible, pos_category_id, pos_sort_order, pos_category_taxonomy(id, category_name, subcategory_name), product_fit_profiles(code, display_name, review_status, product_fit_profile_devices(device_models(code, display_name)))')
            .in('id', productGroupIds)
        : Promise.resolve({ data: [] as ProductGroupRow[], error: null }),
    ])

    if (imagesError) {
      console.error(imagesError)
      return jsonResponse({ ok: false, error: 'Product images could not be loaded.' }, 500)
    }

    if (inventoryError) {
      console.error(inventoryError)
      return jsonResponse({ ok: false, error: 'Inventory could not be loaded.' }, 500)
    }

    if (productGroupsError) {
      console.error(productGroupsError)
      return jsonResponse({ ok: false, error: 'Product groups could not be loaded.' }, 500)
    }

    const galleryImagesByProductId = new Map<number, Array<{
      image_url: string
      thumbnail_url: string | null
      alt_text: string | null
      sort_order: number
    }>>()
    const firstImageByProductId = new Map<number, string>()
    ;((images ?? []) as ProductImageRow[]).forEach((image) => {
      if (!image.product_id || !image.image_url) return
      const publicUrl = buildPublicImageUrl(image.image_url, supabaseUrl)
      if (!publicUrl) return
      if (!galleryImagesByProductId.has(image.product_id)) galleryImagesByProductId.set(image.product_id, [])
      galleryImagesByProductId.get(image.product_id)!.push({
        image_url: publicUrl,
        thumbnail_url: buildThumbnailUrl(publicUrl, supabaseUrl),
        alt_text: image.alt_text,
        sort_order: Number(image.sort_order) || 0,
      })
      if (!firstImageByProductId.has(image.product_id)) firstImageByProductId.set(image.product_id, publicUrl)
    })

    const inventoryByProductId = new Map<number, InventoryRow[]>()
    ;((inventory ?? []) as InventoryRow[]).forEach((row) => {
      const currentStoreSlug = row.stores?.slug ?? null
      if (storeSlug && currentStoreSlug !== storeSlug) return
      if (!inventoryByProductId.has(row.product_id)) inventoryByProductId.set(row.product_id, [])
      inventoryByProductId.get(row.product_id)!.push(row)
    })

    const productGroupsById = new Map<number, ProductGroupRow>()
    ;((productGroups ?? []) as ProductGroupRow[]).forEach((group) => {
      productGroupsById.set(group.id, group)
    })

    const rows = productRows.map((product) => {
      const productGroup = product.product_group_id
        ? productGroupsById.get(product.product_group_id) ?? null
        : null
      const fitProfile = productGroup?.product_fit_profiles ?? null
      const posCategory = productGroup?.pos_category_taxonomy ?? product.pos_category_taxonomy ?? null
      const compatibleDevices = (fitProfile?.product_fit_profile_devices ?? [])
        .map((mapping) => mapping.device_models)
        .filter((device): device is { code: string; display_name: string } => Boolean(device))
      const groupImageUrl = buildPublicImageUrl(productGroup?.main_image_url ?? null, supabaseUrl)
      const fallbackImageUrl = buildPublicImageUrl(product.image_url, supabaseUrl)
      const imageUrl = firstImageByProductId.get(product.id) ?? fallbackImageUrl ?? null
      const galleryImages = [...(galleryImagesByProductId.get(product.id) ?? [])]
      if (imageUrl && !galleryImages.some((image) => image.image_url === imageUrl)) {
        galleryImages.unshift({
          image_url: imageUrl,
          thumbnail_url: buildThumbnailUrl(imageUrl, supabaseUrl),
          alt_text: product.name,
          sort_order: 0,
        })
      }
      const storeInventory = (inventoryByProductId.get(product.id) ?? []).map((row) => ({
        store_slug: row.stores?.slug ?? null,
        store_name: row.stores?.name ?? null,
        quantity: Number(row.quantity) || 0,
        shelf_location: row.shelf_location,
      }))

      return {
        id: product.id,
        sku: product.sku,
        slug: product.slug,
        name: product.name,
        category: product.categories
          ? {
              id: product.categories.id,
              slug: product.categories.slug,
              name: product.categories.name,
            }
          : null,
        category_id: product.categories?.id ?? null,
        category_slug: product.categories?.slug ?? null,
        category_name: product.categories?.name ?? null,
        pos_category: posCategory
          ? {
              id: posCategory.id,
              category_name: posCategory.category_name,
              subcategory_name: posCategory.subcategory_name,
            }
          : null,
        pos_category_id: posCategory?.id ?? null,
        pos_category_name: posCategory?.category_name ?? null,
        pos_subcategory_name: posCategory?.subcategory_name ?? null,
        pos_sort_order: productGroup?.pos_sort_order ?? product.pos_sort_order ?? null,
        cost_price: normalizeNumber(product.cost_price),
        sale_price: normalizeNumber(product.retail_price),
        compare_at_price: normalizeNumber(product.compare_at_price),
        barcode: product.upc,
        variant_name: product.variant_name,
        variant_color: product.variant_color,
        source_system: product.source_system,
        source_external_id: product.source_external_id,
        product_group: productGroup
          ? {
              id: productGroup.id,
              code: productGroup.code,
              slug: productGroup.slug,
              name: productGroup.name,
              product_family: productGroup.product_family,
              image_url: groupImageUrl,
              is_pos_visible: productGroup.is_pos_visible,
              is_visible: productGroup.is_visible,
              pos_sort_order: productGroup.pos_sort_order,
            }
          : null,
        product_group_id: productGroup?.id ?? null,
        product_group_code: productGroup?.code ?? null,
        product_group_name: productGroup?.name ?? null,
        product_group_image_url: groupImageUrl,
        fit_profile: fitProfile
          ? {
              code: fitProfile.code,
              display_name: fitProfile.display_name,
              review_status: fitProfile.review_status,
              compatible_devices: compatibleDevices,
            }
          : null,
        total_stock: Number(product.stock_quantity) || 0,
        is_pos_visible: product.is_pos_visible !== false,
        store_inventory: storeInventory,
        image_url: imageUrl,
        thumbnail_url: buildThumbnailUrl(imageUrl, supabaseUrl),
        gallery_images: galleryImages,
        images: galleryImages,
        updated_at: product.updated_at,
      }
    })

    return jsonResponse({
      ok: true,
      rows,
      page,
      page_size: pageSize,
      total: count ?? rows.length,
      has_more: from + rows.length < (count ?? rows.length),
      pos_categories: posCategories ?? [],
    })
  } catch (error) {
    console.error(error)
    return jsonResponse({ ok: false, error: 'Server error while loading internal products.' }, 500)
  }
})
