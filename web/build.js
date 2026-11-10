// Builds Proview Label:
//   dist/app.html, dist/dashboard.html  demo builds (sample data, no server) – used for previews
//   site/index.html (+ CNAME)           hosted back-office for label.proviewcrm.co.uk (live accounts)
//   site/app.html                       the device app with the live connection (copied into the Android project)
const fs = require('fs');
const R = (f) => fs.readFileSync(__dirname + '/' + f, 'utf8');
const core = R('src/core.js'), cloud = R('src/cloud.js'), hub = R('src/hub.js'), i18n = R('src/i18n.js');
const jsb = R('node_modules/jsbarcode/dist/barcodes/JsBarcode.code128.min.js');
const supa = R('node_modules/@supabase/supabase-js/dist/umd/supabase.js');
const CONFIG = { SUPABASE_URL: 'https://fiqoirnlmhjzicvktdwa.supabase.co', SUPABASE_KEY: 'sb_publishable_j7p5qB-D6FMOV4B6zLiN_w_7xmfKLRM' };
const uri = (f) => 'data:image/png;base64,' + fs.readFileSync(__dirname + '/assets/' + f).toString('base64');
const assets = { '%%LOGO%%': uri('logo.png'), '%%LOGO_WHITE%%': uri('logo-white.png'), '%%MARK_SM%%': uri('mark-sm.png'), '%%MARK_LG%%': uri('mark-lg.png'), '%%MARK%%': uri('mark.png'), '%%APP_ICON%%': uri('app-icon.png') };
const js = (code) => '<script>\n' + code.replace(/<\/script/gi, '<\\/script') + '\n</script>';
function build(file, live) {
  let h = R('src/' + file);
  h = h.replace('<script>/*CORE*/</script>', () => js(core));
  h = h.replace('<script>/*JSBARCODE*/</script>', () => js(jsb));
  h = h.replace('<script>/*CLOUD*/</script>', () => js(cloud));
  h = h.replace('<script>/*HUB*/</script>', () => js(hub));   // shared Proview header tray (same file as Proview Signage)
  h = h.replace('<script>/*I18N*/</script>', () => js(i18n));   // on-screen language (prints stay English)
  h = h.replace('<script>/*SUPABASE*/</script>', () => (live ? js(supa) : ''));
  h = h.replace('<script>/*CONFIG*/</script>', () => (live ? js('window.PVL_CONFIG=' + JSON.stringify(CONFIG) + ';') : ''));
  for (const [k, v] of Object.entries(assets)) h = h.split(k).join(v);
  return h;
}
fs.mkdirSync(__dirname + '/dist', { recursive: true }); fs.mkdirSync(__dirname + '/site', { recursive: true });
const out = (p, h) => { fs.writeFileSync(__dirname + '/' + p, h); console.log('built ' + p, (h.length / 1024).toFixed(0) + ' KB'); };
out('dist/app.html', build('app.html', false));
out('dist/dashboard.html', build('dashboard.html', false));
out('site/index.html', build('dashboard.html', true));
out('site/app.html', build('app.html', true));
fs.writeFileSync(__dirname + '/site/CNAME', 'label.proviewcrm.co.uk\n');
