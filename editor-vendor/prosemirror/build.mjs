import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import * as esbuild from 'esbuild';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, '../..');
const vendorOut = path.join(repoRoot, 'app/Sources/Fastra/Resources/MarkdownVendor');
const outFile = path.join(vendorOut, 'visual-editor.js');
const licenseOut = path.join(repoRoot, 'app/Sources/Fastra/Resources/MarkdownVendor/LICENSE-ProseMirror.txt');

/**
 * Selbstprüfender Build-Patch für `prosemirror-view`: ersetzt synthetische
 * `.ProseMirror-separator`-Hilfsknoten von `IMG` auf `WBR`, damit DOM-Abfragen
 * wie `document.querySelector('img')` ausschließlich echte Dokumentbilder treffen.
 */
let appliedSeparatorPatch = false;
const patchProseMirrorSeparatorPlugin = {
  name: 'fastra-patch-prosemirror-separator',
  setup(build) {
    build.onLoad({ filter: /prosemirror-view\/dist\/index\.js$/ }, async args => {
      let source = await fs.promises.readFile(args.path, 'utf8');
      const replacements = [
        ['get ignoreForCoords() { return this.dom.nodeName == "IMG"; }', 'get ignoreForCoords() { return this.dom.nodeName == "WBR"; }', 1],
        ['updater.addHackNode("IMG", updater.top);', 'updater.addHackNode("WBR", updater.top);', 1],
        ['this.addHackNode("IMG", parent);', 'this.addHackNode("WBR", parent);', 1],
        ['if (nodeName == "IMG") {\n                dom.className = "ProseMirror-separator";', 'if (nodeName == "WBR") {\n                dom.className = "ProseMirror-separator";', 1],
        ['let dom = document.createElement("img");\n        dom.className = "ProseMirror-separator";', 'let dom = document.createElement("wbr");\n        dom.className = "ProseMirror-separator";', 1]
      ];
      for (const [needle, next, expectedCount] of replacements) {
        const count = source.split(needle).length - 1;
        if (count !== expectedCount) {
          throw new Error(`ProseMirror-separator patch mismatch for ${JSON.stringify(needle)}: expected ${expectedCount}, found ${count}`);
        }
        source = source.replaceAll(needle, next);
      }
      appliedSeparatorPatch = true;
      return { contents: source, loader: 'js' };
    });
  }
};

const bundle = await esbuild.build({
  entryPoints: [path.join(__dirname, 'src/index.js')],
  bundle: true,
  format: 'iife',
  platform: 'browser',
  target: ['safari16', 'chrome110'],
  minify: false,
  legalComments: 'none',
  plugins: [patchProseMirrorSeparatorPlugin],
  outfile: outFile,
  write: false,
  banner: {
    js: '/* Fastras lokale WYSIWYG-Schicht auf ProseMirror-Basis (MIT). Originalquellen bleiben im geschlossenen Editorzustand. */'
  }
});

if (!appliedSeparatorPatch) throw new Error('ProseMirror-separator patch did not run');

// Lizenztext reproduzierbar aus den installierten Laufzeit-Abhängigkeiten erzeugen.
const lock = JSON.parse(fs.readFileSync(path.join(__dirname, 'package-lock.json'), 'utf8'));
const runtimePackages = Object.entries(lock.packages || {})
  .filter(([pkgPath, info]) => pkgPath && !info.dev)
  .sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0);

const sections = [
  'Fastra bundles the following MIT-licensed ProseMirror packages and runtime dependencies in visual-editor.js:',
  ''
];

for (const [pkgPath, info] of runtimePackages) {
  const pkgName = pkgPath.replace(/^node_modules\//, '');
  const pkgDir = path.join(__dirname, pkgPath);
  const candidates = ['LICENSE', 'LICENSE.md', 'LICENSE.txt', 'LICENCE'];
  let licenseText = '';
  for (const candidate of candidates) {
    const full = path.join(pkgDir, candidate);
    if (fs.existsSync(full)) {
      licenseText = fs.readFileSync(full, 'utf8').trim();
      break;
    }
  }
  sections.push(`=== ${pkgName} ${info.version} (${info.license || 'MIT'}) ===`);
  if (!licenseText) throw new Error('Missing license text for ' + pkgName);
  sections.push(licenseText);
  sections.push('');
}

fs.writeFileSync(outFile, bundle.outputFiles[0].contents);
fs.writeFileSync(licenseOut, sections.join('\n'), 'utf8');
console.log(`Built ${path.relative(repoRoot, outFile)} (${fs.statSync(outFile).size} bytes)`);
console.log(`Wrote ${path.relative(repoRoot, licenseOut)} (${runtimePackages.length} packages)`);
