/* ProView Label — shared core (device app + back-office dashboard)
 * Data model, seed data, allergen detection, expiry rules, CSV, audit, and Supabase sync.
 */
(function (global) {
  'use strict';

  const STORAGE_KEY = 'pvl_state_v3';
  const COLLECTIONS = ['sites', 'categories', 'products', 'rules', 'users', 'labels', 'wastage', 'orders', 'devices', 'audit'];

  // UK FIC 14 major allergens
  const ALLERGENS = ['Celery', 'Cereals', 'Crustaceans', 'Eggs', 'Fish', 'Lupin', 'Milk', 'Molluscs', 'Mustard', 'Nuts', 'Peanuts', 'Sesame', 'Soybeans', 'Sulphites'];
  const ALLERGEN_LABEL = { Cereals: 'Cereals (gluten)', Nuts: 'Tree nuts', Soybeans: 'Soya' };

  // Keyword dictionary used to auto-detect & bold allergens in ingredient text (PPDS / Natasha's Law)
  const ALLERGEN_WORDS = {
    Celery: ['celery', 'celeriac'],
    Cereals: ['wheat', 'rye', 'barley', 'oats', 'oat', 'spelt', 'kamut', 'gluten', 'semolina', 'durum', 'couscous', 'bulgur', 'malted', 'batter', 'battered', 'breadcrumb', 'breadcrumbs', 'crouton', 'croutons', 'beer', 'pasta', 'bread', 'flatbread', 'pitta', 'tortilla', 'noodles', 'brioche', 'pastry', 'scone', 'sourdough', 'baguette', 'ciabatta'],
    Crustaceans: ['crab', 'lobster', 'prawn', 'prawns', 'shrimp', 'crayfish', 'scampi', 'langoustine', 'crustacean', 'crustaceans'],
    Eggs: ['egg', 'eggs', 'mayonnaise', 'mayo', 'albumen', 'aioli', 'hollandaise', 'meringue', 'custard', 'tartare', 'brioche'],
    Fish: ['fish', 'salmon', 'tuna', 'cod', 'haddock', 'anchovy', 'anchovies', 'mackerel', 'sardine', 'sardines', 'trout', 'pollock', 'hake', 'basa', 'sea bass', 'seabass'],
    Lupin: ['lupin', 'lupine'],
    Milk: ['milk', 'cream', 'butter', 'cheese', 'yoghurt', 'yogurt', 'whey', 'lactose', 'casein', 'brie', 'cheddar', 'mozzarella', 'parmesan', 'ghee', 'buttermilk', 'creme', 'crème', 'mascarpone', 'ricotta', 'feta', 'halloumi', 'paneer', 'custard', 'brioche', 'toffee'],
    Molluscs: ['mussel', 'mussels', 'oyster', 'oysters', 'squid', 'clam', 'clams', 'scallop', 'scallops', 'octopus', 'snail', 'whelk', 'calamari', 'mollusc', 'molluscs', 'cuttlefish'],
    Mustard: ['mustard'],
    Nuts: ['almond', 'almonds', 'hazelnut', 'hazelnuts', 'walnut', 'walnuts', 'cashew', 'cashews', 'pecan', 'pecans', 'brazil nut', 'brazil nuts', 'pistachio', 'pistachios', 'macadamia', 'praline', 'marzipan'],
    Peanuts: ['peanut', 'peanuts', 'groundnut', 'groundnuts', 'monkey nuts'],
    Sesame: ['sesame', 'tahini', 'houmous', 'hummus'],
    Soybeans: ['soy', 'soya', 'tofu', 'edamame', 'miso', 'tempeh'],
    Sulphites: ['sulphite', 'sulphites', 'sulfite', 'sulfites', 'sulphur dioxide', 'metabisulphite', 'wine']
  };
  // Phrases that contain an allergen word but are not that allergen
  // phrase -> the part that still counts (e.g. "peanut butter" is peanuts, not milk)
  const ALLERGEN_EXCEPTIONS = { 'buckwheat': '', 'coconut milk': '', 'cocoa butter': '', 'peanut butter': 'peanut', 'shea butter': '', 'butternut': '', 'cream of tartar': '', 'nutmeg': '', 'oat milk': 'oat', 'almond milk': 'almond', 'soya milk': 'soya', 'soy milk': 'soy', 'ice cream': 'cream', 'cream crackers': 'crackers' };

  const CATEGORY_COLOURS = [
    { name: 'Default', colour: null }, { name: 'Red', colour: '#E53935' }, { name: 'Blue', colour: '#1E88E5' },
    { name: 'Purple', colour: '#8E24AA' }, { name: 'Green', colour: '#43A047' }, { name: 'Yellow', colour: '#F4A100' },
    { name: 'Navy', colour: '#1E3A5F' }, { name: 'Teal', colour: '#00897B' }
  ];

  const LABEL_TYPES = [
    { id: 'single', name: 'Single Height (40mm)', description: '40mm label for prep and small ingredient labels. 180 per roll.', perRoll: 180 },
    { id: 'double', name: 'Double Height (80mm)', description: '80mm label for long or complex ingredient labels. 90 per roll.', perRoll: 90 },
    { id: 'easy', name: 'Single Height – Easy Peel (40mm)', description: 'Low-adhesive 40mm label, less residue and tearing on removal.', perRoll: 180 }
  ];

  const WASTE_REASONS = ['Expired', 'Damaged', 'Spoiled / quality', 'Over-production', 'Customer return', 'Temperature breach', 'Dropped / contaminated', 'Other'];
  const ROLES = { master: 'Master', admin: 'Admin', manager: 'Manager', staff: 'Staff' };

  // ---------- utils ----------
  const uid = (p) => (p || '') + Date.now().toString(36) + Math.random().toString(36).slice(2, 7);
  const now = () => new Date().toISOString();
  const pad = (n) => String(n).padStart(2, '0');
  const DAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
  function fmtDate(d, withTime) {
    d = new Date(d);
    if (isNaN(d)) return '';
    const s = pad(d.getDate()) + '/' + pad(d.getMonth() + 1) + '/' + d.getFullYear();
    return withTime ? s + ' ' + pad(d.getHours()) + ':' + pad(d.getMinutes()) : s;
  }
  const fmtDay = (d) => DAYS[new Date(d).getDay()];
  const fmtTime = (d) => { d = new Date(d); return pad(d.getHours()) + ':' + pad(d.getMinutes()); };
  const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const money = (n) => '£' + (Number(n) || 0).toFixed(2);
  const initials = (name) => String(name || '?').split(/[\s@._-]+/).map((w) => w.replace(/[^A-Za-z0-9]/g, '')).filter(Boolean).map((w) => w[0]).join('').slice(0, 2).toUpperCase() || '?';
  const stripHtml = (h) => String(h || '').replace(/<br\s*\/?>/gi, ' ').replace(/<[^>]+>/g, '').replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&');

  // ---------- allergens ----------
  function _scan(text) {
    let t = ' ' + stripHtml(text).toLowerCase() + ' ';
    Object.entries(ALLERGEN_EXCEPTIONS).forEach(([ex, keep]) => { t = t.split(ex).join(' ' + keep + ' '); });
    const found = [];
    for (const a of ALLERGENS) {
      for (const w of ALLERGEN_WORDS[a]) {
        const re = new RegExp('(^|[^a-zà-ÿ])' + w.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '(?=$|[^a-zà-ÿ])', 'i');
        if (re.test(t)) { found.push(a); break; }
      }
    }
    return found;
  }
  function detectAllergens(text) { return _scan(text); }

  /** Bold every allergen word in plain/HTML ingredient text (existing <b> kept). */
  function boldAllergens(text) {
    const plain = stripHtml(text);
    const words = [];
    ALLERGENS.forEach((a) => ALLERGEN_WORDS[a].forEach((w) => words.push(w)));
    words.sort((a, b) => b.length - a.length);
    const re = new RegExp('(^|[^A-Za-zÀ-ÿ])(' + words.map((w) => w.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('|') + ')(?=$|[^A-Za-zÀ-ÿ])', 'gi');
    // protect exceptions
    const masks = [];
    let masked = esc(plain);
    Object.entries(ALLERGEN_EXCEPTIONS).forEach(([ex, keep]) => {
      masked = masked.replace(new RegExp(ex, 'gi'), (m) => {
        const k = keep ? m.toLowerCase().indexOf(keep) : -1;
        masks.push(k >= 0 ? m.slice(0, k) + '<b>' + m.slice(k, k + keep.length) + '</b>' + m.slice(k + keep.length) : m);
        return '\u0000' + (masks.length - 1) + '\u0000';
      });
    });
    masked = masked.replace(re, (m, pre, w) => pre + '<b>' + w + '</b>');
    return masked.replace(/\u0000(\d+)\u0000/g, (m, i) => masks[+i]);
  }

  function productAllergens(p) {
    const set = new Set(p.allergens || []);
    if (p.ingredients) detectAllergens(p.ingredients).forEach((a) => set.add(a));
    return ALLERGENS.filter((a) => set.has(a));
  }

  // ---------- expiry ----------
  function computeExpiry(rule, from) {
    const d = from ? new Date(from) : new Date();
    if (!rule) return d;
    const u = Number(rule.units) || 0;
    if (rule.period === 'hours') d.setTime(d.getTime() + u * 3600e3);
    else if (rule.period === 'months') d.setMonth(d.getMonth() + u);
    else d.setDate(d.getDate() + u);
    return d;
  }
  function expiryStatus(label, at) {
    if (label.status && label.status !== 'active') return label.status;
    const t = (at ? new Date(at) : new Date()).getTime();
    const e = new Date(label.expiry).getTime();
    if (e < t) return 'expired';
    if (e - t < 24 * 3600e3) return 'today';
    return 'ok';
  }
  const ruleText = (r) => r ? '+' + r.units + ' ' + (Number(r.units) === 1 ? r.period.replace(/s$/, '') : r.period) : '';

  // ---------- label codes (scan-to-reprint) ----------
  function labelCode() {
    return 'PV' + Date.now().toString(36).toUpperCase().slice(-7) + Math.floor(Math.random() * 36).toString(36).toUpperCase();
  }

  // Standard storage locations every new business starts with
  const DEFAULT_RULES = [['Fridge', 2, 'days'], ['Freezer', 30, 'days'], ['Ambient', 15, 'days'], ['Hot Holding', 2, 'hours'], ['Chilled Display', 1, 'days'], ['Defrosted', 1, 'days']];
  function ensureRules(orgId) {
    if (!orgId) return 0;
    const s = get(); if (s.rules.some((r) => r.orgId === orgId && !r.deleted)) return 0;
    DEFAULT_RULES.forEach(([name, units, period]) => upsert('rules', { id: 'r_' + uid(''), orgId, name, units, period }));
    return DEFAULT_RULES.length;
  }

  // ---------- seed ----------
  function seed() {
    const t = now();
    const sites = [
      { id: 'site_main', name: 'Chingford Kitchen', address: '1 Station Rd, Chingford, London E4', region: 'North East London' },
      { id: 'site_two', name: 'Walthamstow Café', address: '220 Hoe St, London E17', region: 'North East London' },
      { id: 'site_ley', name: 'Leyton Grill House', address: '512 High Rd, Leyton, London E10', region: 'East London' },
      { id: 'site_ilf', name: 'Ilford Deli', address: '88 Cranbrook Rd, Ilford IG1', region: 'Essex' },
      { id: 'site_enf', name: 'Enfield Bakery', address: '14 Church St, Enfield EN2', region: 'North London' }
    ].map((x) => ({ ...x, updatedAt: t }));
    const SITE_W = [['site_main', 0.34], ['site_two', 0.2], ['site_ley', 0.2], ['site_ilf', 0.14], ['site_enf', 0.12]];
    const rules = [
      { id: 'r_fridge', name: 'Fridge', units: 2, period: 'days' },
      { id: 'r_freezer', name: 'Freezer', units: 30, period: 'days' },
      { id: 'r_ambient', name: 'Ambient', units: 15, period: 'days' },
      { id: 'r_hot', name: 'Hot Holding', units: 2, period: 'hours' },
      { id: 'r_display', name: 'Chilled Display', units: 1, period: 'days' },
      { id: 'r_vac', name: 'Vacuum Packed', units: 5, period: 'days' },
      { id: 'r_defrost', name: 'Defrosted', units: 1, period: 'days' }
    ].map((r) => ({ ...r, updatedAt: t }));
    const cats = [
      { id: 'c_meat', name: 'Meat', type: 'prep', color: '#1E88E5' },
      { id: 'c_dairy', name: 'Dairy', type: 'prep', color: '#8E24AA' },
      { id: 'c_fruit', name: 'Fruit', type: 'prep', color: '#43A047' },
      { id: 'c_fish', name: 'Fish', type: 'prep', color: '#F4A100' },
      { id: 'c_veg', name: 'Veg', type: 'prep', color: '#546E7A' },
      { id: 'c_sauce', name: 'Sauces', type: 'prep', color: '#E53935' },
      { id: 'c_bread', name: 'Bread', type: 'sale', color: '#1E3A5F' },
      { id: 'c_hot', name: 'Hot counter', type: 'sale', color: '#E53935' },
      { id: 'c_sand', name: 'Sandwiches', type: 'sale', color: '#00897B' }
    ].map((c) => ({ ...c, updatedAt: t }));
    let pi = 0;
    const P = (categoryId, name, extra) => ({ id: 'p_' + (++pi), categoryId, name, allergens: [], mayContain: '', customAllergens: '', ingredients: '', price: null, barcode: '', ruleId: null, dateType: 'use-by', prepGuide: '', timesPrinted: 0, approved: true, updatedAt: t, ...extra });
    const products = [
      P('c_meat', 'Chicken breast', { timesPrinted: 4, prepGuide: 'Cook to 75°C core. Cool within 90 mins.' }),
      P('c_meat', 'Red meat', { timesPrinted: 10, allergens: ['Sulphites'] }),
      P('c_meat', 'Beef burger', { timesPrinted: 6, allergens: ['Cereals', 'Eggs', 'Sulphites'] }),
      P('c_meat', 'Pulled pork', { timesPrinted: 3, allergens: ['Mustard', 'Celery'], ruleId: 'r_vac' }),
      P('c_dairy', 'Milk', { timesPrinted: 4, allergens: ['Milk'] }),
      P('c_dairy', 'Brie', { timesPrinted: 10, allergens: ['Milk'] }),
      P('c_dairy', 'Sour creme', { timesPrinted: 6, allergens: ['Milk'] }),
      P('c_fruit', 'Apple', { timesPrinted: 4 }),
      P('c_fruit', 'Strawberry', { timesPrinted: 10 }),
      P('c_fruit', 'Kiwi', { timesPrinted: 6 }),
      P('c_fish', 'Tuna', { timesPrinted: 4, allergens: ['Fish'] }),
      P('c_fish', 'Crab', { timesPrinted: 10, allergens: ['Crustaceans'] }),
      P('c_fish', 'Scampi', { timesPrinted: 6, allergens: ['Crustaceans'], mayContain: 'Fish, Molluscs' }),
      P('c_veg', 'Carrot', { timesPrinted: 4 }),
      P('c_veg', 'Broccoli', { timesPrinted: 10 }),
      P('c_veg', 'Potato', { timesPrinted: 6 }),
      P('c_sauce', 'Garlic mayo', { timesPrinted: 8, allergens: ['Eggs', 'Mustard'] }),
      P('c_sauce', 'Pesto', { timesPrinted: 5, allergens: ['Milk', 'Nuts'] }),
      P('c_bread', 'Sourdough', { timesPrinted: 3, price: 4.5, ingredients: 'Wheat Flour, Water, Salt, Sourdough Starter (Wheat Flour, Water).', barcode: '5012345000017' }),
      P('c_bread', 'Baguette', { timesPrinted: 7, price: 2.2, ingredients: 'Wheat Flour, Water, Salt, Yeast, Sugar.' }),
      P('c_bread', 'Ciabatta', { timesPrinted: 2, price: 2.8, ingredients: 'Wheat flour, Water, Salt, Yeast, Olive oil, Sugar, Preferment.' }),
      P('c_hot', 'Hotdog', { timesPrinted: 4, price: 3.95, dateType: 'use-by', ingredients: 'Pork (76.7%), Water, Pork Fat, Salt, Dextrose, Milk Proteins, Lactose (Milk), Wheat Fibre, Pea Protein Isolate, Yeast, Flavourings, Antioxidant: Sodium Erythorbate, Preservative: Sodium Nitrite, Lactic Acid Culture, Beechwood Smoke.' }),
      P('c_hot', 'Sausage roll', { timesPrinted: 10, price: 2.75, ingredients: 'Wheat Flour [Wheat Flour, Calcium Carbonate, Iron, Niacin, Thiamin], Pork (27%), Water, Palm Oil, Wheat Protein, Onion, Cornflour, Tapioca Starch, Rapeseed Oil, Salt, Dried Skimmed Milk, Sage, Parsley, Nutmeg, Sugar, Black Pepper, Mace, Thyme, White Pepper.' }),
      P('c_hot', 'Steak bake', { timesPrinted: 6, price: 3.4, ingredients: 'Water, Wheat Flour [Wheat Flour, Calcium Carbonate, Iron, Niacin, Thiamin], Beef (22%), Palm Oil, Onion, Cornflour, Salt, Rapeseed Oil, Tomato Purée, Yeast, Malted Barley Extract, Pea Protein, Yeast Extract, Black Pepper, Beef Extract, Glucose Syrup, Sugar, Carrot Extract, Garlic Extract, Thyme Extract, Bay Leaf Extract.' }),
      P('c_sand', 'Egg mayo sandwich', { timesPrinted: 9, price: 3.5, ingredients: 'Wheat Flour, Free Range Egg (30%), Mayonnaise (Rapeseed Oil, Water, Egg Yolk, Spirit Vinegar, Mustard Seed), Water, Cress, Salt, Black Pepper.' }),
      P('c_sand', 'Tuna & sweetcorn', { timesPrinted: 5, price: 3.75, mayContain: 'Sesame', ingredients: 'Malted Wheat Flour, Tuna (Fish) (25%), Sweetcorn, Mayonnaise (Rapeseed Oil, Egg Yolk, Spirit Vinegar), Water, Salt, Black Pepper.' })
    ];
    products.forEach((p) => { if (p.ingredients) p.ingredients = boldAllergens(p.ingredients); });
    const ALL = sites.map((x) => x.id);
    // email/password are back-office demo logins (PINs are for the devices)
    const users = [
      { id: 'u_master', name: 'Altun (Proview)', email: 'altun@proviewtech.co.uk', password: 'proview', role: 'master', pin: '9999', siteIds: ALL },
      { id: 'u_admin', name: 'Priya Shah', email: 'priya@chingfordkitchen.co.uk', password: 'demo', role: 'admin', pin: '1234', siteIds: ['site_main', 'site_two', 'site_enf'] },
      { id: 'u_lt', name: 'Laura Taylor', email: 'laura@chingfordkitchen.co.uk', password: 'demo', role: 'manager', pin: '1111', siteIds: ['site_main', 'site_two'] },
      { id: 'u_jb', name: 'Jamal Brown', role: 'staff', pin: '2222', siteIds: ['site_main'] },
      { id: 'u_sk', name: 'Sara Khan', role: 'staff', pin: '3333', siteIds: ['site_two'] },
      { id: 'u_mo', name: 'Mo Rahman', email: 'mo@leytongrill.co.uk', password: 'demo', role: 'manager', pin: '4444', siteIds: ['site_ley'] },
      { id: 'u_ep', name: 'Elena Popescu', role: 'staff', pin: '5555', siteIds: ['site_ley'] },
      { id: 'u_dp', name: 'Dev Patel', email: 'dev@ilforddeli.co.uk', password: 'demo', role: 'manager', pin: '6666', siteIds: ['site_ilf'] },
      { id: 'u_cw', name: 'Chloe Wright', email: 'chloe@enfieldbakery.co.uk', password: 'demo', role: 'manager', pin: '7777', siteIds: ['site_enf'] }
    ].map((x) => ({ ...x, updatedAt: t }));
    const STAFF = { site_main: ['u_lt', 'u_jb'], site_two: ['u_sk', 'u_lt'], site_ley: ['u_mo', 'u_ep'], site_ilf: ['u_dp'], site_enf: ['u_cw'] };
    const ago = (h) => new Date(Date.now() - h * 3600e3).toISOString();
    const devices = [
      { id: 'dev_1', name: 'Kitchen handheld 1', siteId: 'site_main', battery: 82, labelsLeft: 134, version: '1.0.0', lastSync: t },
      { id: 'dev_3', name: 'Kitchen handheld 2', siteId: 'site_main', battery: 64, labelsLeft: 151, version: '1.0.0', lastSync: ago(0.4) },
      { id: 'dev_2', name: 'Café counter', siteId: 'site_two', battery: 47, labelsLeft: 38, version: '1.0.0', lastSync: ago(3) },
      { id: 'dev_4', name: 'Grill station', siteId: 'site_ley', battery: 91, labelsLeft: 112, version: '1.0.0', lastSync: ago(0.2) },
      { id: 'dev_5', name: 'Deli counter', siteId: 'site_ilf', battery: 23, labelsLeft: 76, version: '1.0.0', lastSync: ago(26) },
      { id: 'dev_6', name: 'Bakery prep', siteId: 'site_enf', battery: 70, labelsLeft: 49, version: '1.0.0', lastSync: ago(1.5) }
    ].map((x) => ({ ...x, updatedAt: t }));

    // history: print log / wastage over last 14 days for realistic reports
    const labels = [], wastage = [], audit = [];
    let rnd = 7;
    const rand = () => { rnd = (rnd * 9301 + 49297) % 233280; return rnd / 233280; };
    const pickSite = () => { let r = rand(), acc = 0; for (const [id, w] of SITE_W) { acc += w; if (r < acc) return id; } return 'site_main'; };
    const pickStaff = (site) => { const a = STAFF[site]; return a[Math.floor(rand() * a.length)]; };
    const devOf = { site_main: 'dev_1', site_two: 'dev_2', site_ley: 'dev_4', site_ilf: 'dev_5', site_enf: 'dev_6' };
    for (let d = 13; d >= 0; d--) {
      const n = 14 + Math.floor(rand() * 18);
      for (let i = 0; i < n; i++) {
        const p = products[Math.floor(rand() * products.length)];
        const cat = cats.find((c) => c.id === p.categoryId);
        const site = pickSite();
        const at = new Date(Date.now() - d * 864e5 - Math.floor(rand() * 10) * 3600e3);
        const ruleId = p.ruleId || (cat.type === 'sale' ? 'r_display' : (p.categoryId === 'c_fish' ? 'r_fridge' : ['r_fridge', 'r_fridge', 'r_freezer', 'r_ambient'][Math.floor(rand() * 4)]));
        const rule = rules.find((r) => r.id === ruleId);
        const exp = computeExpiry(rule, at);
        const old = exp.getTime() < Date.now();
        labels.push({
          id: uid('l_'), code: 'PV' + (100000 + labels.length).toString(36).toUpperCase(), productId: p.id, name: p.name, type: cat.type,
          printedAt: at.toISOString(), expiry: exp.toISOString(), ruleName: rule.name, qty: 1 + Math.floor(rand() * 3),
          batch: rand() < 0.3 ? 'B' + Math.floor(rand() * 900 + 100) : '', useFirst: rand() < 0.15, defrost: rule.id === 'r_freezer' ? false : rand() < 0.08,
          userId: pickStaff(site), siteId: site, deviceId: devOf[site],
          status: old ? (rand() < 0.75 ? 'used' : 'wasted') : 'active', allergens: productAllergens(p), updatedAt: at.toISOString()
        });
      }
      const nw = Math.floor(rand() * 3) + (rand() < 0.6 ? 1 : 0);
      for (let k = 0; k < nw; k++) {
        const p = products[Math.floor(rand() * products.length)];
        const at = new Date(Date.now() - d * 864e5 - (3 + k * 2) * 3600e3);
        const ws = pickSite();
        wastage.push({ id: uid('w_'), productId: p.id, name: p.name, qty: 1 + Math.floor(rand() * 4), unit: 'portion', reason: WASTE_REASONS[Math.floor(rand() * 5)], notes: '', photo: '', cost: Math.round((1 + rand() * 8) * 100) / 100, userId: pickStaff(ws), siteId: ws, at: at.toISOString(), updatedAt: at.toISOString() });
      }
    }
    // a few currently-active items expiring soon
    [['Chicken breast', 'site_main', -3], ['Brie', 'site_main', -6], ['Garlic mayo', 'site_main', -9], ['Crab', 'site_main', -12], ['Pulled pork', 'site_ley', 4], ['Tuna', 'site_ilf', 6], ['Sour creme', 'site_ilf', 3], ['Beef burger', 'site_ley', 2], ['Pesto', 'site_two', -2]].forEach(([nm, site, hoursPastExpiry], i) => {
      const p = products.find((x) => x.name === nm);
      const at = new Date(Date.now() - 2 * 864e5 + (-hoursPastExpiry) * 3600e3);
      labels.push({ id: uid('l_'), code: 'PVA' + i + 'X' + i, productId: p.id, name: p.name, type: 'prep', printedAt: at.toISOString(), expiry: computeExpiry(rules[0], at).toISOString(), ruleName: 'Fridge', qty: 1, batch: '', useFirst: i === 0, defrost: false, userId: pickStaff(site), siteId: site, deviceId: devOf[site], status: 'active', allergens: productAllergens(p), updatedAt: at.toISOString() });
    });
    audit.push({ id: uid('a_'), at: new Date(Date.now() - 2 * 864e5).toISOString(), user: 'Priya Shah', action: 'updated', entity: 'Product', detail: 'Pesto: added allergen Nuts', updatedAt: t });
    audit.push({ id: uid('a_'), at: new Date(Date.now() - 864e5).toISOString(), user: 'Laura Taylor', action: 'created', entity: 'Product', detail: 'Pulled pork (Meat)', updatedAt: t });
    audit.push({ id: uid('a_'), at: new Date(Date.now() - 4 * 3600e3).toISOString(), user: 'Priya Shah', action: 'updated', entity: 'Expiry rule', detail: 'Hot Holding: 1 day → 2 hours', updatedAt: t });
    const orders = [
      { id: uid('o_'), siteId: 'site_two', mode: 'on-demand', labelType: 'single', rolls: 10, delivery: 'Royal Mail 24', status: 'pending', at: new Date(Date.now() - 3 * 3600e3).toISOString(), userId: 'u_sk', updatedAt: t },
      { id: uid('o_'), siteId: 'site_main', mode: 'recurring', labelType: 'double', rolls: 6, delivery: 'Standard (free)', status: 'dispatched', at: new Date(Date.now() - 6 * 864e5).toISOString(), userId: 'u_lt', updatedAt: t },
      { id: uid('o_'), siteId: 'site_enf', mode: 'on-demand', labelType: 'single', rolls: 8, delivery: 'Royal Mail 24', status: 'pending', at: new Date(Date.now() - 1 * 3600e3).toISOString(), userId: 'u_cw', updatedAt: t }
    ];
    // ---- businesses: each has its own sites, catalogue (rules, categories, products) and staff ----
    const orgs = [
      { id: 'org_ckg', name: 'Chingford Kitchen Group', settings: {} },
      { id: 'org_gdc', name: 'Grill & Deli Co', settings: {} }
    ];
    const ORG_OF = { site_main: 'org_ckg', site_two: 'org_ckg', site_enf: 'org_ckg', site_ley: 'org_gdc', site_ilf: 'org_gdc' };
    sites.forEach((x) => { x.orgId = ORG_OF[x.id]; });
    const B = (id) => (id ? id + '_b' : id);
    const cloneFor = (arr, map) => arr.map((x) => ({ ...JSON.parse(JSON.stringify(x)), ...map(x), orgId: 'org_gdc' }));
    rules.forEach((x) => { x.orgId = 'org_ckg'; }); cats.forEach((x) => { x.orgId = 'org_ckg'; }); products.forEach((x) => { x.orgId = 'org_ckg'; });
    rules.push(...cloneFor(rules, (x) => ({ id: B(x.id) })));
    cats.push(...cloneFor(cats.filter((c) => c.orgId === 'org_ckg' && c.id !== 'c_bread'), (x) => ({ id: B(x.id) })));
    products.push(...cloneFor(products.filter((p) => p.orgId === 'org_ckg' && p.categoryId !== 'c_bread'), (x) => ({ id: B(x.id), categoryId: B(x.categoryId), ruleId: B(x.ruleId) })));
    const inB = (siteId) => ORG_OF[siteId] === 'org_gdc';
    const pById = Object.fromEntries(products.map((p) => [p.id, p]));
    labels.forEach((l) => { l.orgId = ORG_OF[l.siteId]; if (inB(l.siteId) && l.productId) l.productId = pById[B(l.productId)] ? B(l.productId) : null; });
    wastage.forEach((w) => { w.orgId = ORG_OF[w.siteId]; if (inB(w.siteId) && w.productId && pById[B(w.productId)]) w.productId = B(w.productId); });
    devices.forEach((d) => { d.orgId = ORG_OF[d.siteId]; });
    orders.forEach((o) => { o.orgId = ORG_OF[o.siteId]; });
    users.forEach((u) => { u.orgId = u.role === 'master' ? null : ORG_OF[(u.siteIds || [])[0]]; });
    audit.forEach((a) => { a.orgId = 'org_ckg'; });
    return {
      version: 3, orgs, company: { name: 'ProView Tech Group' }, currentSiteId: 'site_main', deviceId: 'dev_1', currentUserId: 'u_lt',
      sites, rules, categories: cats, products, users, devices, labels, wastage, orders, audit,
      settings: {
        printer: { mode: 'preview', address: '', port: 9100, name: '' },
        sync: { url: '', key: '', enabled: false, lastSync: null },
        stockLastOrdered: new Date(Date.now() - 6 * 864e5).toISOString(), labelsInStock: 134, avgWeekly: 250,
        support: { phone: '020 8935 5495', email: 'info@proviewtechgroup.co.uk', hours: 'Mon–Fri 9am–5pm' }
      }
    };
  }

  // ---------- store ----------
  // Demo mode keeps the sample data under STORAGE_KEY. Signed-in cloud mode keeps a per-user cache
  // (useStore('cloud:<user id>')) that starts empty and is filled by sync() from the server.
  const listeners = new Set();
  let state = null, storeKey = STORAGE_KEY, storeBlank = false;
  function blank() {
    return { version: 3, cloud: true, orgs: [], company: { name: '' }, currentSiteId: null, deviceId: null, currentUserId: null,
      sites: [], rules: [], categories: [], products: [], users: [], devices: [], labels: [], wastage: [], orders: [], audit: [],
      settings: { printer: { mode: 'preview', address: '', port: 9100, name: '' }, sync: { url: '', key: '', enabled: true, lastSync: null },
        stockLastOrdered: null, labelsInStock: 180, avgWeekly: 250, support: { phone: '020 8935 5495', email: 'info@proviewtechgroup.co.uk', hours: 'Mon–Fri 9am–5pm' } } };
  }
  function useStore(key, opts) { storeKey = key ? STORAGE_KEY + ':' + key : STORAGE_KEY; storeBlank = !!(opts && opts.blank); state = null; return load(); }
  function load() {
    try { const raw = localStorage.getItem(storeKey); if (raw) state = JSON.parse(raw); } catch (e) { state = null; }
    if (!state || state.version !== 3) state = storeBlank ? blank() : seed();
    if (!state.orgs) state.orgs = [];
    return state;
  }
  function save() { try { localStorage.setItem(storeKey, JSON.stringify(state)); } catch (e) { /* storage unavailable */ } listeners.forEach((fn) => fn(state)); }
  function reset() { state = storeBlank ? blank() : seed(); save(); return state; }
  function forget(key) { try { localStorage.removeItem(STORAGE_KEY + ':' + key); } catch (e) {} }
  function get() { return state || load(); }
  function on(fn) { listeners.add(fn); return () => listeners.delete(fn); }

  function upsert(coll, rec) {
    const s = get();
    rec.updatedAt = now(); rec._dirty = true;
    const i = s[coll].findIndex((x) => x.id === rec.id);
    if (i >= 0) s[coll][i] = { ...s[coll][i], ...rec }; else s[coll].push(rec);
    save();
    return rec;
  }
  function remove(coll, id) {
    const s = get();
    const r = s[coll].find((x) => x.id === id);
    if (r) { r.deleted = true; r.updatedAt = now(); r._dirty = true; }
    save();
  }
  const live = (coll) => get()[coll].filter((x) => !x.deleted);
  const byId = (coll, id) => get()[coll].find((x) => x.id === id && !x.deleted);
  function audit(user, action, entity, detail, orgId) {
    if (orgId === undefined) orgId = (get().sites.find((x) => x.id === get().currentSiteId) || {}).orgId || null;
    if (get().cloud && !orgId) return;
    upsert('audit', { id: uid('a_'), at: now(), user, action, entity, detail, orgId });
  }

  // ---------- CSV ----------
  function toCSV(rows, cols) {
    const q = (v) => { v = v == null ? '' : String(v); return /[",\n]/.test(v) ? '"' + v.replace(/"/g, '""') + '"' : v; };
    return [cols.map((c) => q(c.label || c.key)).join(',')].concat(rows.map((r) => cols.map((c) => q(typeof c.get === 'function' ? c.get(r) : r[c.key])).join(','))).join('\n');
  }
  function parseCSV(text) {
    const rows = []; let row = [], f = '', q = false;
    for (let i = 0; i < text.length; i++) {
      const c = text[i];
      if (q) { if (c === '"') { if (text[i + 1] === '"') { f += '"'; i++; } else q = false; } else f += c; }
      else if (c === '"') q = true;
      else if (c === ',') { row.push(f); f = ''; }
      else if (c === '\n' || c === '\r') { if (c === '\r' && text[i + 1] === '\n') i++; row.push(f); rows.push(row); row = []; f = ''; }
      else f += c;
    }
    if (f || row.length) { row.push(f); rows.push(row); }
    const head = (rows.shift() || []).map((h) => h.trim().toLowerCase());
    return rows.filter((r) => r.some((x) => x.trim())).map((r) => Object.fromEntries(head.map((h, i) => [h, (r[i] || '').trim()])));
  }

  // ---------- Menu analyser (dashboard) ----------
  function analyseMenu(text) {
    const lines = String(text).split(/\n+/).map((l) => l.trim()).filter(Boolean);
    const out = [];
    for (const line of lines) {
      if (/^(starters?|mains?|desserts?|sides?|drinks?|menu|breakfast|lunch|dinner)\b[:\s]*$/i.test(line)) continue;
      const m = line.match(/^(.*?)\s*[-–—:|]\s*(.+)$/);
      let name = m ? m[1] : line, desc = m ? m[2] : '';
      const priceM = (desc || name).match(/£?\s?(\d+(?:\.\d{1,2})?)\s*$/);
      let price = null;
      if (priceM) { price = parseFloat(priceM[1]); if (desc) desc = desc.slice(0, priceM.index).trim(); else name = name.slice(0, priceM.index).trim(); }
      name = name.replace(/[.·]+$/, '').trim();
      if (!name) continue;
      out.push({ name, description: desc, price, allergens: detectAllergens(name + ' ' + desc) });
    }
    return out;
  }

  // ---------- Sync (Supabase REST / PostgREST, table pl_records) ----------
  // opts: { url, key, token }  token = the signed-in user's access token (row-level security decides
  // what they can read and write). Records carry orgId (+ siteId for site data).
  // One business per request: changes are sent per business, each request naming it (x-pl-org header).
  // opts.scoped (the Proview master): pull only the All sites list (sites + devices of every business) and,
  // when a business is open (opts.org), that one business's data. Other businesses' data is dropped locally.
  const LIST_KINDS = ['sites', 'devices'];
  const siteOf = (kind, r) => (kind === 'sites' ? r.id : (r.siteId || null));
  // The master's pull: the All sites list (sites + devices of every business) plus the open business, if any.
  async function pullScoped(s, base, headers, org, full) {
    const by = s.settings.sync.lastSyncBy = s.settings.sync.lastSyncBy || {};
    const parts = [{ key: '*', q: '&kind=in.(' + LIST_KINDS.join(',') + ')', h: {} }];
    if (org) parts.push({ key: org, q: '&org_id=eq.' + encodeURIComponent(org), h: { 'x-pl-org': org } });
    let pulled = 0, dropped = 0;
    for (const part of parts) {
      const started = new Date(Date.now() - 5000).toISOString(), since = by[part.key] || '1970-01-01T00:00:00Z';
      for (let offset = 0; ; offset += 1000) {
        const res = await fetch(base + '?select=id,kind,org_id,data,deleted,updated_at&updated_at=gt.' + encodeURIComponent(since) + part.q + '&order=updated_at.asc,id.asc&limit=1000&offset=' + offset, { headers: { ...headers, ...part.h } });
        if (!res.ok) throw new Error('Couldn’t load from the server (' + res.status + ').');
        const rows = await res.json();
        rows.forEach((row) => {
          const coll = s[row.kind]; if (!coll) return;
          const i = coll.findIndex((x) => x.id === row.id);
          const rec = { ...row.data, orgId: row.org_id, deleted: row.deleted, _dirty: false };
          if (i < 0) { coll.push(rec); pulled++; } else if (!coll[i]._dirty) { coll[i] = rec; pulled++; }
        });
        if (rows.length < 1000) break;
      }
      if (full) { // drop clean cached records of this part the server no longer returns
        const seen = new Set();
        for (let off = 0; ; off += 1000) {
          const r3 = await fetch(base + '?select=id' + part.q + '&order=id.asc&limit=1000&offset=' + off, { headers: { ...headers, ...part.h } });
          if (!r3.ok) throw new Error('Couldn’t load from the server (' + r3.status + ').');
          const ids = await r3.json(); ids.forEach((x) => seen.add(x.id));
          if (ids.length < 1000) break;
        }
        COLLECTIONS.forEach((k) => { if (part.key === '*' && !LIST_KINDS.includes(k)) return; const n = s[k].length;
          s[k] = s[k].filter((r) => r._dirty || !r.orgId || seen.has(r.id) || (part.key !== '*' && r.orgId !== part.key)); dropped += n - s[k].length; });
      }
      by[part.key] = started;
    }
    // keep nothing of other businesses but the All sites list (unsent changes stay until they're sent)
    const gone = new Set();
    COLLECTIONS.forEach((k) => { if (LIST_KINDS.includes(k)) return; const n = s[k].length;
      s[k] = s[k].filter((r) => { const keep = r._dirty || !r.orgId || r.orgId === org; if (!keep) gone.add(r.orgId); return keep; }); dropped += n - s[k].length; });
    gone.forEach((id) => { delete by[id]; });
    return { pulled, dropped };
  }
  async function sync(opts) {
    const s = get();
    const o = opts || {};
    const url = o.url || s.settings.sync.url, key = o.key || s.settings.sync.key, token = o.token || key;
    if (!url || !key) return { ok: false, reason: 'Sync not configured' };
    const base = url.replace(/\/$/, '') + '/rest/v1/pl_records';
    const headers = { apikey: key, Authorization: 'Bearer ' + token, 'Content-Type': 'application/json' };
    const since = s.settings.sync.lastSync || '1970-01-01T00:00:00Z';
    let pushed = 0, skipped = 0;
    const dirty = [];
    COLLECTIONS.forEach((k) => s[k].forEach((r) => {
      if (!r._dirty) return;
      if (!r.orgId) { skipped++; return; }
      const d = { ...r }; delete d._dirty; delete d.password;
      dirty.push({ id: r.id, kind: k, org_id: r.orgId, site_id: siteOf(k, r), data: d, deleted: !!r.deleted });
    }));
    const chunks = [];
    [...new Set(dirty.map((d) => d.org_id))].forEach((org) => { const rows = dirty.filter((d) => d.org_id === org); for (let i = 0; i < rows.length; i += 200) chunks.push(rows.slice(i, i + 200)); });
    for (const chunk of chunks) {
      const res = await fetch(base + '?on_conflict=id', { method: 'POST', headers: { ...headers, 'x-pl-org': chunk[0].org_id, Prefer: 'resolution=merge-duplicates,return=minimal' }, body: JSON.stringify(chunk) });
      if (!res.ok) {
        const t = (await res.text()).slice(0, 300);
        if (res.status === 401 || res.status === 403 || /row-level security/i.test(t)) throw new Error('You don’t have permission to change some of these records. Ask an owner or Proview.');
        throw new Error('Couldn’t save to the server (' + res.status + ').');
      }
      chunk.forEach((row) => { const r = s[row.kind].find((x) => x.id === row.id); if (r) r._dirty = false; });
      pushed += chunk.length;
    }
    if (o.scoped) {
      const r = await pullScoped(s, base, headers, o.org || null, !!o.full);
      save();
      return { ok: true, pushed, pulled: r.pulled, skipped, dropped: r.dropped };
    }
    // pull everything newer than the last sync, page by page
    const started = new Date(Date.now() - 5000).toISOString();
    let pulled = 0, offset = 0;
    for (;;) {
      const res2 = await fetch(base + '?select=id,kind,org_id,data,deleted,updated_at&updated_at=gt.' + encodeURIComponent(since) + '&order=updated_at.asc,id.asc&limit=1000&offset=' + offset, { headers });
      if (!res2.ok) throw new Error('Couldn’t load from the server (' + res2.status + ').');
      const rows = await res2.json();
      rows.forEach((row) => {
        const coll = s[row.kind]; if (!coll) return;
        const i = coll.findIndex((x) => x.id === row.id);
        const rec = { ...row.data, orgId: row.org_id, deleted: row.deleted, _dirty: false };
        if (i < 0) { coll.push(rec); pulled++; }
        else if (!coll[i]._dirty) { coll[i] = rec; pulled++; }
      });
      if (rows.length < 1000) break;
      offset += 1000;
    }
    // full: also drop clean cached records the server no longer returns (hard-deleted, or no longer visible
    // to this person). Unsent local edits (_dirty) are kept for the next push.
    let dropped = 0;
    if (o.full) {
      const seen = new Set(); let off = 0;
      for (;;) {
        const r3 = await fetch(base + '?select=id&order=id.asc&limit=1000&offset=' + off, { headers });
        if (!r3.ok) throw new Error('Couldn’t load from the server (' + r3.status + ').');
        const ids = await r3.json(); ids.forEach((x) => seen.add(x.id));
        if (ids.length < 1000) break;
        off += 1000;
      }
      COLLECTIONS.forEach((k) => { const n = s[k].length; s[k] = s[k].filter((r) => r._dirty || !r.orgId || seen.has(r.id)); dropped += n - s[k].length; });
    }
    s.settings.sync.lastSync = started;
    save();
    return { ok: true, pushed, pulled, skipped, dropped };
  }
  // Forget everything cached for businesses outside orgIds (the person's current server access): it is
  // never shown and never uploaded again, even unsent edits (the server would refuse them anyway).
  function prune(orgIds) {
    const s = get(); const ok = new Set(orgIds || []); let n = 0;
    COLLECTIONS.forEach((k) => { const b = s[k].length; s[k] = s[k].filter((r) => !r.orgId || ok.has(r.orgId)); n += b - s[k].length; });
    const ob = (s.orgs || []).length; s.orgs = (s.orgs || []).filter((o) => ok.has(o.id)); n += ob - s.orgs.length;
    if (s.currentSiteId && !s.sites.some((x) => x.id === s.currentSiteId)) s.currentSiteId = null;
    save();
    return n;
  }
  // list the localStorage keys of every per-user cloud cache on this device
  function cloudStores() { const out = []; try { for (let i = 0; i < localStorage.length; i++) { const k = localStorage.key(i); if (k && k.indexOf(STORAGE_KEY + ':cloud:') === 0) out.push(k.slice(STORAGE_KEY.length + 1)); } } catch (e) {} return out; }

  // Offline sync via file: export/import whole dataset (used when no cloud configured)
  function exportJSON() { const s = get(); return JSON.stringify({ exportedAt: now(), ...s }, null, 0); }
  function importJSON(text, mode) {
    const incoming = JSON.parse(text);
    const s = get();
    COLLECTIONS.forEach((k) => {
      (incoming[k] || []).forEach((rec) => {
        const i = s[k].findIndex((x) => x.id === rec.id);
        if (i < 0) s[k].push(rec);
        else if (mode === 'replace' || new Date(rec.updatedAt || 0) >= new Date(s[k][i].updatedAt || 0)) s[k][i] = rec;
      });
    });
    save();
  }

  // product photo: square, centre-cropped, small JPEG (synced to every handheld, so kept ~15 KB)
  function photoFromFile(file, size) {
    size = size || 256;
    return new Promise((resolve, reject) => {
      if (!file || !/^image\//.test(file.type || '')) return reject(new Error('Choose a picture file'));
      const rd = new FileReader();
      rd.onerror = () => reject(new Error('Could not read the picture'));
      rd.onload = () => { const img = new Image(); img.onerror = () => reject(new Error('Could not open the picture'));
        img.onload = () => { const s0 = Math.min(img.width, img.height), c = document.createElement('canvas'); c.width = c.height = size;
          const g = c.getContext('2d'); g.fillStyle = '#fff'; g.fillRect(0, 0, size, size);
          g.drawImage(img, (img.width - s0) / 2, (img.height - s0) / 2, s0, s0, 0, 0, size, size);
          resolve(c.toDataURL('image/jpeg', 0.72)); };
        img.src = rd.result; };
      rd.readAsDataURL(file);
    });
  }

  global.PVL = {
    ALLERGENS, ALLERGEN_LABEL, ALLERGEN_WORDS, CATEGORY_COLOURS, LABEL_TYPES, WASTE_REASONS, ROLES, COLLECTIONS,
    uid, now, fmtDate, fmtDay, fmtTime, esc, money, initials, stripHtml,
    detectAllergens, boldAllergens, productAllergens, computeExpiry, expiryStatus, ruleText, labelCode,
    seed, blank, useStore, forget, load, save, reset, get, on, upsert, remove, live, byId, audit,
    toCSV, parseCSV, analyseMenu, sync, prune, cloudStores, exportJSON, importJSON, ensureRules, DEFAULT_RULES, photoFromFile
  };
})(typeof window !== 'undefined' ? window : globalThis);
