# Proview Label

Food labelling for UK kitchens, part of the Proview CRM family (Bookings, Employee, Signage, WiFi).

- **Android app** (`android-app/`) prints prep labels and Natasha's Law (PPDS) sale labels, and tracks expiry, wastage and label orders.
- **Back-office** (`web/`) is hosted at **label.proviewcrm.co.uk**. Use it to manage businesses, sites, menus, allergens, staff and reports.
- **Server**: Supabase project `proview-label` (`fiqoirnlmhjzicvktdwa`, London). It holds the accounts and the data, and row-level security controls who sees what.

## Accounts and who sees what

| Who | Signs in with | Sees |
|---|---|---|
| **Master** (Proview) | Opens a location from the licence portal (**Open in Proview Label** on the location's page) | One business at a time, exactly as its Owner sees it, with a "Viewing <Business> as Proview" bar. Signed in any other way, the master only sees "Open a location from the licence portal". No master view, no Add business or Add location here. |
| **Owner / Admin** | Email or Proview account | Their whole business: all its sites, menu, staff and settings. |
| **Manager** | Email or Proview account | Only their own sites. No Settings page, and can't add sites or logins. |
| **Device staff** | 4-digit PIN on the handheld | Print, scan, log wastage. A device manager can also edit products. |

- The database enforces these rules, not just the screens. The tests in `tests/` check each one against the live server.
- `altun@proviewtech.co.uk` is the master. It's claimed automatically the first time that email signs in.
- "Sign in with Proview account" works like the other apps:
  1. The person signs in at `dashboard.proviewcrm.co.uk`.
  2. The hub's `sso-assert` function sends them back with a signed, single-use token.
  3. Proview Label's `sso-login` function (`supabase/functions/sso-login`) checks the token and signs them in.

### Adding a location
1. In the licence portal: **New location** (the hub's `add_business`). Enter the name, plus the owner's name and email. It makes one business with one location.
   To work inside it, open the location in the portal and press **Open in Proview Label** (sso-assert adds a signed
   `biz` claim; `sso-login` honours it only for the master and replies with `open`; the back-office then sends that
   business in the `x-pl-org` header and keeps it for the tab in sessionStorage `pv_master_open`).
2. The owner signs in, either with "Sign in with Proview account" or "Create a login" using that email. They add their menu, back-office logins and device staff. Owners can't add or delete locations (migration 011): Proview adds them (New location) and links them in the licence portal.
3. On each handheld: open Proview Label. It shows a 6-character pairing code and a QR code. In the back-office go to **Handhelds → + Pair handheld**, enter the code (or scan the QR code with a phone, which opens that dialog with the code filled in), and pick the location, a name and **Easy** or **Detailed** mode. The handheld opens a few seconds later. Products and settings come down to the device. Labels, expiry and wastage go up to the server.
   - No email or password on the handheld. Pairing makes a login used only by that handheld (`supabase/functions/pl-device-pair`, migration `005_device_pairing.sql`). It can only see and change its own location.
   - Mode, name and location can be changed later from the same page; the handheld picks them up within a minute. **Remove** cuts its access at once and it shows a new pairing code.

### Linking locations (migration 011)
- Only the master links locations, in the licence portal (**Link with another location…**). The portal calls `hub_call(token, 'link', {into, from})`: business `from` is merged into `into` (locations, menu, staff, labels, wastage, orders, handhelds, licences, members; a person in both keeps the higher role) and `from` is deleted. Owners and managers of either then see both locations together in that one business.
- **Unlink** (`hub_call(token, 'unlink', {account, site})`) moves one location out into a new business of its own, named after the location: its records, handhelds and licence move, the menu is copied, members are copied. The same action splits a business that already has several locations.
- Licences stay per location and move with it. Both actions are logged in `hub_private.location_links` and are safe to repeat.

### A person in several businesses, and no Locations page (12 Nov 2026)
- **Header dropdown:** business names only, by name. Picking one opens the whole business (all its locations, never two businesses together). With one business it is a disabled box with the business name (the master inside an opened business too).
- **Sign-in** (email, Proview account or invite) opens the business last used, remembered per email in this browser (`pvl-site:<email>`). If it is locked, suspended or has no location this person can open, the next usable business opens instead (not saved over the last used one).
- **No Locations page.** The old *Locations & devices* page is now **Handhelds** (pairing and handhelds only); `#devices` and `#sites` go to the Dashboard. A location's name, address, area and licence (Buy / Renew online; the master: Licence… and Rename business) are in **Settings → This location**, with a location select at the top of Settings when the business has more than one.
- Tests: `node tests/ui/multi_business_ui.js web/site` and `node tests/ui/master_open_ui.js web/site`.

## What's in the box

| Path | What |
|---|---|
| `web/src/` | Source: `dashboard.html` (back-office), `app.html` (device app), `core.js` (data model, allergens, expiry, sync), `cloud.js` (sign-in and Proview account hand-off) |
| `web/site/` | Built back-office (`index.html`) and app (`app.html`) with the live server settings. This folder is what gets hosted. |
| `web/dist/` | Demo builds on sample data, with no server. These are what the Claude previews show. |
| `android-app/` | Capacitor Android project. Includes the Bluetooth and network label-printer plugin (`LabelPrinterPlugin.java`). |
| `supabase/` | Database schema and the `sso-login` function, both already applied to the live project. |
| `hub-changes/` | Two small changes to your Proview account hub so it knows about Label (see below). |
| `.github/workflows/` | `pages.yml` deploys the back-office. `android.yml` builds the APK. |

Build everything with `cd web && npm install && npm run build`. Then build the APK with `cd android-app && npm install && npm run apk`.

## Going live (three steps)
1. **Hosting:** create the GitHub repo `Proview92/proview-label` and push this folder to it. Turn on Pages (source: GitHub Actions). Then add a DNS record: `label.proviewcrm.co.uk  CNAME  proview92.github.io`.
2. **Hub, sign-in function:** deploy `hub-changes/proview-licence-sso-assert.patch` to the `sso-assert` function in the licence project (`bpssjfrinjlrnkzhytfr`). It only adds a `label` entry; the other apps are unchanged.
3. **Hub, sign-in page:** apply `hub-changes/proview-dashboard-names.patch` to `proview-dashboard`. This puts "Proview Label" in the app list on dashboard.proviewcrm.co.uk.

Email and password sign-in works as soon as step 1 is done. "Sign in with Proview account" also needs steps 2 and 3.

## APK
### Updates
- The app checks `label.proviewcrm.co.uk/apk/version.json` when it opens and every 4 hours. Staff can also tap **Menu → Check for updates**.
- When a newer version is out, it downloads the APK and opens Android's installer. Staff tap **Install**.
- To publish a version: copy the CI APK to `web/site/ProviewLabel.apk` and set `version` in `web/site/apk/version.json`.
- Every build must be signed with the Proview Label key, or updates won't install over the top. The key is stored in the repository secrets `LABEL_KEYSTORE_B64`, `LABEL_KEYSTORE_PASSWORD` and `LABEL_KEY_ALIAS`. Keep a copy of the key safe: if it's lost, every handheld has to uninstall and reinstall once.

`ProView-Label-debug.apk` is a debug-signed build (version 1.1.0) for testing and sideloading. For the Play Store, sign a release build with your own key.
