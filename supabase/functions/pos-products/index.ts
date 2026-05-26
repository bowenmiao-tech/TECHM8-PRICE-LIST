const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-staff-session",
  "Access-Control-Allow-Methods": "GET, OPTIONS",
};

type JsonRecord = Record<string, unknown>;

function jsonResponse(body: JsonRecord, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
      "Content-Type": "application/json; charset=utf-8",
    },
  });
}

async function verifyStaffSession(sessionToken: string): Promise<boolean> {
  const supabaseUrl = Deno.env.get("STAFF_AUTH_SUPABASE_URL")
    || Deno.env.get("SUPABASE_URL")
    || "";
  const supabaseAnonKey = Deno.env.get("STAFF_AUTH_SUPABASE_ANON_KEY")
    || Deno.env.get("SUPABASE_ANON_KEY")
    || "";

  if (!supabaseUrl || !supabaseAnonKey) {
    throw new Error("Supabase environment is not configured.");
  }

  const response = await fetch(`${supabaseUrl}/rest/v1/rpc/verify_staff_session`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      apikey: supabaseAnonKey,
      Authorization: `Bearer ${supabaseAnonKey}`,
    },
    body: JSON.stringify({ session_token: sessionToken }),
  });

  if (!response.ok) return false;

  const result = await response.json().catch(() => null);
  if (Array.isArray(result)) {
    return Boolean((result[0] as JsonRecord | undefined)?.ok);
  }
  return Boolean((result as JsonRecord | null)?.ok);
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders });
  }

  if (request.method !== "GET") {
    return jsonResponse({ ok: false, message: "Method not allowed." }, 405);
  }

  const sessionToken = request.headers.get("x-staff-session") || "";
  if (!sessionToken) {
    return jsonResponse({ ok: false, message: "Staff session is required." }, 401);
  }

  let isStaff = false;
  try {
    isStaff = await verifyStaffSession(sessionToken);
  } catch (error) {
    console.error(error);
    return jsonResponse({ ok: false, message: "Unable to verify staff session." }, 500);
  }

  if (!isStaff) {
    return jsonResponse({ ok: false, message: "Invalid or expired staff session." }, 401);
  }

  const upstreamEndpoint = Deno.env.get("INTERNAL_PRODUCTS_ENDPOINT")
    || "https://fwlronvmgqzkleofriis.supabase.co/functions/v1/internal-products";
  const upstreamApiKey = Deno.env.get("INTERNAL_PRODUCTS_API_KEY") || "";

  if (!upstreamApiKey) {
    return jsonResponse({ ok: false, message: "Internal products API key is not configured." }, 500);
  }

  const inputUrl = new URL(request.url);
  const upstreamUrl = new URL(upstreamEndpoint);
  upstreamUrl.searchParams.set("page", inputUrl.searchParams.get("page") || "1");
  upstreamUrl.searchParams.set("limit", inputUrl.searchParams.get("limit") || "500");

  const search = inputUrl.searchParams.get("search");
  const category = inputUrl.searchParams.get("category");
  if (search) upstreamUrl.searchParams.set("search", search);
  if (category) upstreamUrl.searchParams.set("category", category);

  try {
    const response = await fetch(upstreamUrl.toString(), {
      method: "GET",
      headers: {
        Accept: "application/json",
        "x-api-key": upstreamApiKey,
      },
    });

    const body = await response.text();
    return new Response(body, {
      status: response.status,
      headers: {
        ...corsHeaders,
        "Content-Type": response.headers.get("Content-Type") || "application/json; charset=utf-8",
      },
    });
  } catch (error) {
    console.error(error);
    return jsonResponse({ ok: false, message: "Product API request failed." }, 502);
  }
});
