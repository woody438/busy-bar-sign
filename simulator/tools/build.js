/*
 * Bundles the simulator into one self-contained HTML file (scripts inlined),
 * for sharing or hosting.   node simulator/tools/build.js out.html [--fragment]
 * --fragment drops the <html>/<head>/<body> wrapper, for hosts that add their own.
 */
const fs = require('fs'), path = require('path');
const dir = path.join(__dirname, '..');
let html = fs.readFileSync(path.join(dir, 'index.html'), 'utf8');
for (const f of ['fonts.js', 'engine.js', 'painter.js', 'rules.js', 'day.js']) {
  const tag = `<script src="${f}"></script>`;
  if (!html.includes(tag)) throw new Error('missing ' + tag);
  const code = fs.readFileSync(path.join(dir, f), 'utf8').replace(/<\/script/gi, '<\\/script');
  html = html.replace(tag, () => `<script>\n${code}\n</script>`);
}
if (process.argv.includes('--fragment')) {
  html = html.replace(/<!doctype html>\s*/i, '').replace(/<html[^>]*>\s*/i, '').replace(/<\/html>\s*/i, '')
             .replace(/<head>\s*/i, '').replace(/<\/head>\s*/i, '').replace(/<body>\s*/i, '').replace(/<\/body>\s*/i, '');
}
fs.writeFileSync(process.argv[2], html);
console.log('wrote', process.argv[2], (html.length / 1024).toFixed(0) + ' KB');
