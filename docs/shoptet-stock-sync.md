# Shoptet jako zdroj pravdy pro skladové zásoby — brainstorm

**Status:** návrh, není implementováno. Účelem je rozhodnout, jestli (a jak) propojit `objednavky` s e-shopem `divokefarmy.cz` (běží na Shoptetu), aby se dostupnost a skladové množství neudržovaly ručně dvakrát.

## Současný stav

- Katalog produktů je hardcodované pole `P[]` v `js/app.js` (~60 položek).
- Stav skladu (`avail`, `stockQty`, `prodOverrides`, `archived`, `deleted`, `customProds`) se ukládá jako jeden řádek v Supabase `product_state` (id=1) a edituje se ručně přes admin overlay.
- Shoptet (`divokefarmy.cz`) má vlastní katalog se svým vlastním stavem skladu, který se mění pokaždé, když přijde objednávka přes e-shop.

Důsledek: dvě nezávislé pravdy. Když se na e-shopu vyprodá vepřový párek, v B2B objednávkovém formuláři je pořád "skladem", dokud to admin ručně nepřepne.

## Co Shoptet nabízí (3 cesty od nejjednodušší)

### A) Veřejné XML feedy (Heureka / Zboží.cz)

Shoptet automaticky generuje feedy na URL typu:
- `https://www.divokefarmy.cz/export/heureka.xml`
- `https://www.divokefarmy.cz/export/google.xml`

**Plusy:** žádná autentikace, snadno parsovatelný XML, obsahuje `<DELIVERY_DATE>` (0 = skladem, 7 = do týdne, atd.) a často i `<ITEM_ID>` / `<PRODUCTNO>` jako stabilní SKU.
**Minusy:** přesný zbývající počet kusů ve feedu obvykle není (jen "skladem / do X dní"). Aktualizace má prodlevu (typicky ~1 hod). Feedy jsou dělané pro srovnávače, ne pro inventory sync — Shoptet je může změnit.

### B) Shoptet REST API

Shoptet má oficiální API (vyžaduje registraci doplňku v Shoptet partner programu). Klíčové endpointy:
- `GET /api/products` — kompletní katalog vč. `stockQuantity`, `availabilityId`, ceny, SKU
- `GET /api/stocks` — přímo zásoby
- `POST /api/orders` — vytvoření objednávky (důležité pro obousměrný sync, viz níže)

**Plusy:** přesné množství, real-time (oproti hodinovému feedu), strukturovaná data, podpora webhooků (`order/create`, `stock/change`).
**Minusy:** vyžaduje přihlášení Shoptet účtu jako partner a vytvoření doplňku (i když je privátní pro sebe), OAuth-style flow, API klíč patří do GH Secrets stejně jako ostatní.

### C) Scraping HTML

Poslední možnost. Křehké. Zmínit jen pro úplnost — nedělat.

## Co bych navrhl udělat (postupné kroky)

### Krok 1 (rychlá výhra, ~půl dne práce)

1. Do `P[]` v `app.js` přidat pole `sku` u každé položky (jednorázové ruční mapování proti Shoptet katalogu — odpovídající `<PRODUCTNO>` z Heureka feedu).
2. Nová Supabase tabulka `shoptet_stock`: `sku text primary key`, `availability text`, `delivery_days int`, `updated_at timestamptz`.
3. Nový GH Actions workflow `.github/workflows/shoptet-sync.yml`:
   - Cron každých 30 minut (`schedule: - cron: '*/30 * * * *'`).
   - Stáhne `https://www.divokefarmy.cz/export/heureka.xml`.
   - Naparsuje XML (např. `xml2js` v Node skriptu).
   - Upsertne do `shoptet_stock` přes Supabase service-role klíč (nový secret `SUPABASE_SERVICE_ROLE_KEY` — **nikdy** v `js/config.js`, jen v secrets workflowu).
4. Klient (`app.js`) v `_applyState()` načte i `shoptet_stock` a překryje `avail`/`stockQty` podle SKU. Admin overlay si nech jako manuální override pro výjimky.

Výsledek: B2B formulář ukazuje stejnou dostupnost jako e-shop, bez ručního udržování.

### Krok 2 (pořádně, později)

Zaregistrovat privátní Shoptet doplněk a přejít z feedu na API:
- místo cron-pull každých 30 min použít Shoptet webhook → cloud function (Supabase Edge Function nebo malá Netlify/Cloudflare worker) → upsert do `shoptet_stock`. Skoro real-time.
- API dává i přesný `stockQuantity`, takže `stockQty` v admin overlay přestane být potřeba pro produkty existující v Shoptetu.

### Krok 3 (volitelné, větší rozhodnutí)

Obousměrnost: když přijde objednávka přes tenhle B2B formulář, POSTnout ji i do Shoptetu jako `order` (s B2B cenovou hladinou), aby Shoptet sám decrementoval sklad. Bez toho je "Shoptet jako single source of truth" jen iluze — přijaté B2B objednávky tady sklad ve Shoptetu nesníží a mezi syncy se může něco dvakrát prodat.

## Co by se mělo *vyjasnit dřív*, než se začne psát kód

1. **Mají všechny položky z `P[]` ekvivalent ve Shoptetu?** Některé B2B-only položky (vážené klobásy, baleni "200–250 g") možná v retail e-shopu vůbec nejsou. Tyhle položky musí zůstat ručně spravované — sync se na ně nesmí vztahovat.
2. **Cena.** Shoptet cena = retail s DPH. Tahle aplikace pracuje s `voc` = velkoobchodní bez DPH. **Ceny nesynchronizovat.** Jen dostupnost a sklad.
3. **Custom produkty** přidané přes admin (`customProds`) nemají SKU → sync je musí ignorovat (filtrovat podle `_custom: true` nebo absence `sku`).
4. **Konflikt s ručním overridem.** Když admin v overlay nastaví `avail=true`, ale Shoptet hlásí "není skladem", co vyhraje? Návrh: `prodOverrides` zůstává explicitní override s nejvyšší prioritou; sync zapisuje do separátního pole, klient řeší prioritu při čtení.
5. **Ověření feed URL.** Výše uvádím `/export/heureka.xml` jako typické umístění — před implementací ověřit, že to na `divokefarmy.cz` opravdu existuje a co všechno obsahuje (SKU? availability? množství?). To rozhodne, jestli stačí krok 1 nebo se musí rovnou na API.

## Risks / red flags

- Veřejný feed nemusí mít stabilní SKU. Pokud `<PRODUCTNO>` chybí nebo se mění, mapování přestane fungovat tichounko. Sync skript musí mít alarm (Slack/email) když SKU přestane matchovat.
- Cron v GH Actions není garantovaný real-time — může nastat až ~10min lag i u `*/30`. Pro B2B to obvykle stačí, ale pokud někdo právě vyprázdní zásobu na e-shopu, B2B uživatel může 30 min vidět "skladem". S API + webhookem tento problém zmizí.
- Service-role Supabase klíč v GH Actions = pozor, ať se nedostane do logů (`echo`, `set -x`) ani do artefaktů. Použít `::add-mask::` nebo nikdy neechovat.
