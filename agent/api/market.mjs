// Price tools for the Node agent: poe.ninja price lookups and read-only searches on the official trade site.
// Requests carry a generic User-Agent and no account details; nothing here performs a trade action.
const UA = "Mozilla/5.0 (PoB build tool)";
const NINJA = "https://poe.ninja/poe1/api/economy/stash/current";
const TRADE = "https://www.pathofexile.com/api/trade";
const CACHE_MS = 5 * 60 * 1000;
const MAX_WAIT_S = 60;
const PRICE_SAMPLE = 10;

const NINJA_ITEM_TYPES = ["UniqueWeapon", "UniqueArmour", "UniqueAccessory", "UniqueJewel", "UniqueFlask", "SkillGem"];
const NINJA_CURRENCY_TYPES = ["Currency", "Fragment"];
const INFLUENCES = { shaper: "shaper_item", elder: "elder_item", crusader: "crusader_item", redeemer: "redeemer_item", hunter: "hunter_item", warlord: "warlord_item" };
// Stat types in the order a mod text is looked up when the caller doesn't name one
const STAT_TYPES = ["explicit", "implicit", "fractured", "crafted", "enchant", "pseudo"];

const cache = new Map();
async function cached(key, ttl, load) {
  const hit = cache.get(key);
  if (hit && Date.now() - hit.time < ttl) return hit.value;
  const value = await load();
  cache.set(key, { time: Date.now(), value });
  return value;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const round = (n) => (n == null ? null : Math.round(n * 100) / 100);

function request(url, init = {}) {
  return fetch(url, { ...init, headers: { "User-Agent": UA, Accept: "application/json", ...init.headers } });
}

// Trade requests run one at a time, and each policy (search, fetch, exchange) waits out its own rate-limit window
const blockedUntil = new Map();
let tradeQueue = Promise.resolve();

function noteRateLimits(key, res) {
  const rules = (res.headers.get("x-rate-limit-rules") || "").toLowerCase().split(",").filter(Boolean);
  let wait = 0;
  for (const rule of rules) {
    const limits = (res.headers.get(`x-rate-limit-${rule}`) || "").split(",");
    const states = (res.headers.get(`x-rate-limit-${rule}-state`) || "").split(",");
    limits.forEach((l, i) => {
      const [max, period] = l.split(":").map(Number);
      const [hits, , restricted] = (states[i] || "").split(":").map(Number);
      if (restricted > 0) wait = Math.max(wait, restricted);
      else if (hits >= max) wait = Math.max(wait, period);
    });
  }
  if (wait) blockedUntil.set(key, Date.now() + wait * 1000);
}

function tradeRequest(path, body) {
  const run = async () => {
    const key = path.split("/")[0];
    const wait = (blockedUntil.get(key) ?? 0) - Date.now();
    if (wait > MAX_WAIT_S * 1000) throw new Error(`Trade API rate limit: retry in about ${Math.ceil(wait / 1000)}s`);
    if (wait > 0) await sleep(wait);
    const res = await request(`${TRADE}/${path}`, body ? { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) } : {});
    noteRateLimits(key, res);
    if (res.status === 429) {
      const secs = Number(res.headers.get("retry-after")) || 60;
      blockedUntil.set(key, Date.now() + secs * 1000);
      throw new Error(`Trade API rate limit hit: retry in ${secs}s`);
    }
    const text = await res.text();
    let json;
    try { json = JSON.parse(text); } catch { throw new Error(`Trade API returned ${res.status} with a non-JSON body`); }
    if (!res.ok) throw new Error(`Trade API ${res.status}: ${json.error?.message ?? text.slice(0, 200)}`);
    return json;
  };
  const next = tradeQueue.then(run, run);
  tradeQueue = next.catch(() => {});
  return next;
}

async function currentLeague() {
  return cached("league", 60 * 60 * 1000, async () => {
    const { result } = await tradeRequest("data/leagues");
    const league = result.find((l) => l.realm === "pc" && !/standard|hardcore|^hc |ruthless|ssf/i.test(l.id));
    if (!league) throw new Error("Could not find the current challenge league; pass `league`");
    return league.id;
  });
}

// poe.ninja

async function ninjaFetch(kind, type, league) {
  return cached(`ninja:${kind}:${type}:${league}`, CACHE_MS, async () => {
    const res = await request(`${NINJA}/${kind}/overview?league=${encodeURIComponent(league)}&type=${type}`);
    if (!res.ok) throw new Error(`poe.ninja ${type} returned ${res.status}`);
    return res.json();
  });
}

// Chaos value of one unit of each trade currency id, plus the Divine Orb rate
async function currencyRates(league) {
  return cached(`rates:${league}`, CACHE_MS, async () => {
    const data = await ninjaFetch("currency", "Currency", league);
    const rates = { chaos: 1 };
    for (const d of data.currencyDetails) {
      const line = data.lines.find((l) => l.currencyTypeName === d.name);
      if (line && d.tradeId) rates[d.tradeId] = line.chaosEquivalent;
    }
    if (!rates.divine) throw new Error("poe.ninja has no Divine Orb rate for this league");
    return rates;
  });
}

const priceOf = (chaos, divineRate) => ({ chaos: round(chaos), divine: round(chaos / divineRate) });

function ninjaRows(name, spec, data, kind) {
  const wanted = name.toLowerCase();
  if (kind === "currency") {
    return data.lines.filter((l) => l.currencyTypeName.toLowerCase() === wanted).map((l) => ({
      name: l.currencyTypeName, chaos: l.chaosEquivalent, listings: l.receive?.listing_count ?? 0,
    }));
  }
  let rows = data.lines.filter((l) => l.name.toLowerCase() === wanted);
  const filters = [
    ["links", (l) => (l.links ?? 0) === spec.links],
    ["level", (l) => l.gemLevel === spec.level],
    ["quality", (l) => (l.gemQuality ?? 0) === spec.quality],
    ["corrupted", (l) => !!l.corrupted === spec.corrupted],
    ["variant", (l) => (l.variant ?? "").toLowerCase().includes(spec.variant?.toLowerCase())],
  ];
  for (const [field, test] of filters) if (spec[field] != null) rows = rows.filter(test);
  return rows.map((l) => ({
    name: l.name, variant: l.variant, links: l.links, level: l.gemLevel, quality: l.gemQuality, corrupted: l.corrupted,
    chaos: l.chaosValue, listings: l.listingCount ?? l.count ?? 0,
  }));
}

async function exchangeFallback(name, league, rates) {
  const { result: groups } = await cached("static", 60 * 60 * 1000, async () => (await request(`${TRADE}/data/static`)).json());
  const entry = groups.flatMap((g) => g.entries).find((e) => e.text.toLowerCase() === name.toLowerCase());
  if (!entry) return null;
  const sent = await tradeRequest(`exchange/${encodeURIComponent(league)}`, {
    query: { status: { option: "online" }, have: ["chaos", "divine"], want: [entry.id] }, sort: { have: "asc" }, engine: "new",
  });
  const prices = [];
  for (const listing of Object.values(sent.result ?? {})) {
    for (const offer of listing.listing.offers) {
      const rate = rates[offer.exchange.currency];
      if (rate) prices.push((offer.exchange.amount * rate) / offer.item.amount);
    }
  }
  prices.sort((a, b) => a - b);
  return { name: entry.text, entry, prices: prices.slice(0, PRICE_SAMPLE), listings: sent.total ?? prices.length };
}

function basis(prices, divineRate) {
  if (!prices.length) return {};
  const mid = Math.floor(prices.length / 2);
  const median = prices.length % 2 ? prices[mid] : (prices[mid - 1] + prices[mid]) / 2;
  return { cheapest: priceOf(prices[0], divineRate), median: priceOf(median, divineRate), sampled: prices.length };
}

export async function priceLookup({ names, league }) {
  league ||= await currentLeague();
  const rates = await currencyRates(league);
  const divineRate = rates.divine;
  const sources = [
    ...NINJA_CURRENCY_TYPES.map((t) => ["currency", t]),
    ...NINJA_ITEM_TYPES.map((t) => ["item", t]),
  ];
  const datasets = await Promise.all(sources.map(async ([kind, type]) => [kind, await ninjaFetch(kind, type, league)]));
  const results = [];
  for (const entry of names) {
    const spec = typeof entry === "string" ? { name: entry } : entry;
    const rows = datasets.flatMap(([kind, data]) => ninjaRows(spec.name, spec, data, kind));
    if (rows.length) {
      rows.sort((a, b) => b.listings - a.listings);
      results.push({
        name: spec.name, source: "poe.ninja",
        matches: rows.slice(0, 8).map(({ chaos, ...row }) => ({ ...row, ...priceOf(chaos, divineRate) })),
        ...(rows.length > 8 ? { note: `${rows.length} variants match; showing the 8 with the most listings. Narrow with links, level, quality, corrupted or variant.` } : {}),
      });
      continue;
    }
    const wasFiltered = Object.keys(spec).length > 1;
    const unfiltered = wasFiltered ? datasets.flatMap(([kind, data]) => ninjaRows(spec.name, {}, data, kind)) : [];
    if (unfiltered.length) {
      results.push({
        name: spec.name, source: "poe.ninja", matches: [],
        note: "poe.ninja lists no entry with those filters.",
        available: unfiltered.slice(0, 8).map(({ chaos, ...row }) => ({ ...row, ...priceOf(chaos, divineRate) })),
      });
      continue;
    }
    const fallback = await exchangeFallback(spec.name, league, rates);
    if (!fallback) results.push({ name: spec.name, error: "Not found on poe.ninja or as a tradeable currency on the trade site." });
    else results.push({ name: fallback.name, source: "trade currency exchange", listings: fallback.listings, ...basis(fallback.prices, divineRate) });
  }
  return { league, divineInChaos: round(divineRate), results };
}

// Trade search

function normalizeStatText(text) {
  return text.toLowerCase().replace(/\(\d+(\.\d+)?-\d+(\.\d+)?\)|\d+(\.\d+)?/g, "#").replace(/\+/g, "").replace(/ support$/, "").replace(/\s+/g, " ").trim();
}

async function statIndex() {
  return cached("stats", 60 * 60 * 1000, async () => {
    const { result } = await tradeRequest("data/stats");
    return result.flatMap((g) => g.entries.map((e) => ({ ...e, norm: normalizeStatText(e.text) })));
  });
}

function findStat(index, mod) {
  const query = normalizeStatText(mod.text);
  const order = mod.type ? [mod.type] : /\b(total|pseudo)\b/.test(query) ? ["pseudo"] : STAT_TYPES.slice(0, -1);
  const rank = (e) => order.indexOf(e.type);
  const pool = index.filter((e) => rank(e) >= 0).sort((a, b) => rank(a) - rank(b));
  const tokens = query.split(" ").filter((t) => t !== "#" && t !== "to" && t !== "total");
  // Several stat ids can share one text (e.g. an old and a new id for the same support gem mod), so any exact match counts
  const exact = pool.filter((e) => e.norm === query && e.type === pool.find((p) => p.norm === query)?.type);
  const matches = exact.length ? exact : pool.filter((e) => tokens.every((t) => e.norm.includes(t))).sort((a, b) => a.norm.length - b.norm.length).slice(0, 1);
  if (!matches.length) throw new Error(`No trade stat matches "${mod.text}". Use the wording shown in game, or pass type: pseudo for totals (e.g. "total fire resistance").`);
  return matches;
}

function buildQuery({ base, category, influences, corrupted, stats, status }) {
  const query = { status: { option: status }, stats, filters: {} };
  if (base) query.type = base;
  if (category) query.filters.type_filters = { filters: { category: { option: category } } };
  const misc = {};
  if (influences) for (const [name, id] of Object.entries(INFLUENCES)) misc[id] = { option: String(influences.map((i) => i.toLowerCase()).includes(name)) };
  if (corrupted != null) misc.corrupted = { option: String(corrupted) };
  if (Object.keys(misc).length) query.filters.misc_filters = { filters: misc };
  return { query, sort: { price: "asc" } };
}

function describeListing(item, price, rates, divineRate) {
  const rate = rates[price.currency];
  const chaos = rate ? price.amount * rate : null;
  const mods = (key) => (item[key] ?? []).map((m) => (m.description ?? m).replace(/\[(?:[^\]|]*\|)?([^\]]*)\]/g, "$1"));
  return {
    name: item.name || undefined, baseType: item.baseType, rarity: item.rarity, ilvl: item.ilvl,
    corrupted: item.corrupted || undefined, influences: item.influences ? Object.keys(item.influences) : undefined,
    price: { listed: `${price.amount} ${price.currency}`, ...(chaos == null ? {} : priceOf(chaos, divineRate)) },
    implicit: mods("implicitMods"), enchant: mods("enchantMods"), fractured: mods("fracturedMods"),
    explicit: mods("explicitMods"), crafted: mods("craftedMods"),
  };
}

export async function tradeSearch({ base, category, mods = [], influences, corrupted, league, limit = 5 }) {
  if (!base && !category) throw new Error("Give a base type (e.g. 'Vaal Axe') or a category (e.g. 'weapon.twosword').");
  league ||= await currentLeague();
  const index = mods.length ? await statIndex() : [];
  const mapped = [];
  const stats = [{ type: "and", filters: [] }];
  for (const mod of mods) {
    const matches = findStat(index, mod);
    const value = {};
    if (mod.min != null) value.min = mod.min;
    if (mod.max != null) value.max = mod.max;
    mapped.push({ text: mod.text, statIds: matches.map((s) => s.id), statText: matches[0].text });
    const filters = matches.map((s) => ({ id: s.id, value }));
    if (filters.length === 1) stats[0].filters.push(filters[0]);
    else stats.push({ type: "count", value: { min: 1 }, filters });
  }
  // "securable" is the instant-buyout listing status
  const body = buildQuery({ base, category, influences, corrupted, stats, status: "securable" });
  const key = `trade:${league}:${JSON.stringify(body)}`;
  const found = await cached(key, CACHE_MS, async () => {
    const search = await tradeRequest(`search/${encodeURIComponent(league)}`, body);
    const ids = search.result.slice(0, PRICE_SAMPLE);
    const fetched = ids.length ? await tradeRequest(`fetch/${ids.join(",")}?query=${search.id}`) : { result: [] };
    return { total: search.total, listings: fetched.result.filter((r) => r?.listing?.price) };
  });
  const rates = await currencyRates(league);
  const rows = found.listings.map((r) => describeListing(r.item, r.listing.price, rates, rates.divine));
  const prices = rows.map((r) => r.price.chaos).filter((c) => c != null).sort((a, b) => a - b);
  return {
    league, status: "instant buyout", total: found.total, mapped,
    ...basis(prices, rates.divine),
    listings: rows.slice(0, Math.min(limit, PRICE_SAMPLE)),
  };
}
