// Copies the built app into www/ and bundles Poppins so the app works fully offline.
const fs = require('fs'), path = require('path');
const src = process.argv[2] || path.join(__dirname, '../web/site/app.html');
fs.mkdirSync(path.join(__dirname, 'www/fonts'), { recursive: true });
let css = '';
for (const w of [400, 500, 600, 700, 800]) {
  const f = `inter-latin-${w}-normal.woff2`;
  fs.copyFileSync(path.join(__dirname, 'node_modules/@fontsource/inter/files', f), path.join(__dirname, 'www/fonts', f));
  css += `@font-face{font-family:Inter;font-style:normal;font-weight:${w};font-display:swap;src:url(fonts/${f}) format('woff2')}\n`;
}
let h = fs.readFileSync(src, 'utf8');
h = h.replace(/<link rel="preconnect"[^>]*>\s*<link href="https:\/\/fonts\.googleapis\.com[^>]*>/, '<style>' + css + '</style>');
fs.writeFileSync(path.join(__dirname, 'www/index.html'), h);
console.log('www/index.html ready', (h.length / 1024).toFixed(0) + ' KB');
