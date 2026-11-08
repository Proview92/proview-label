# Proview Label

Food labelling for UK kitchens, part of the Proview CRM family (Bookings, Employee, Signage, WiFi).

- **Android app** (`android-app/`) prints prep labels and Natasha's Law (PPDS) sale labels, and tracks expiry, wastage and label orders.
- **Back-office** (`web/`) is hosted at **label.proviewcrm.co.uk**. Use it to manage businesses, sites, menus, allergens, staff and reports.
- **Server**: Supabase project `proview-label` (`fiqoirnlmhjzicvktdwa`, London). It holds the accounts and the data, and row-level security controls who sees what.

## Accounts and who sees what

| Who | Signs in with | Sees |
|---|---|---|
| **Master** (Proview) | Email, or "Sign in with Proview account" | Every business. A picker under the logo switches between all businesses, one business, or one site. Can add businesses. |
| **Owner / Admin** | Email or Proview account | Their whole business: all its sites, menu, staff and settings. |
| **Manager** | Email or Proview account | Only their own sites. No Settings page, and can't add sites or logins. |
| **Device staff** | 4-digit PIN on the handheld | Print, scan, log wastage. A device manager can also edit products. |

- The database enforces these rules, not just the screens. The tests in `tests/` check each one against the live server.
- `altun@proviewtech.co.uk` is the master. It's claimed automatically the first time that email signs in.
- "Sign in with Proview account" works like the other apps:
  1. The person signs in at `dashboard.proviewcrm.co.uk`.
  2. The hub's `sso-assert` function sends them back with a signed, single-use token.
  3. Proview Label's `sso-login` function (`supabase/functions/sso-login`) checks the token and signs them in.

### Adding a customer
1. As master: **Locations → + Add business**. Enter the name, plus the owner's name and email.
2. The owner signs in, either with "Sign in with Proview account" or "Create a login" using that email. They add their sites, menu, back-office logins and device staff.
3. On each handheld: **Menu → Settings → Connect to Proview Label**. Sign in with a back-office login, pick the site, then set your own name and PIN. Products, staff and settings come down to the device. Labels, expiry and wastage go up to the server.

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
`ProView-Label-debug.apk` is a debug-signed build (version 1.1.0) for testing and sideloading. For the Play Store, sign a release build with your own key.
