// Bundles the plugin, the Stream Deck SDK and the bar's engine into one file
// in the plugin folder, as Elgato's own template does. Its first line says
// the version it was built as, from the manifest, so the app can tell when
// Stream Deck has the new manifest over older code (Sources/UpdateCheck.swift).
import { readFileSync } from 'node:fs';
import commonjs from '@rollup/plugin-commonjs';
import nodeResolve from '@rollup/plugin-node-resolve';

const sdPlugin = 'com.woodall.busybarsign.sdPlugin';
const manifest = JSON.parse(readFileSync(`${sdPlugin}/manifest.json`, 'utf8'));

export default {
  input: 'src/plugin.js',
  output: { file: `${sdPlugin}/bin/plugin.js`, banner: `/* ${manifest.UUID} ${manifest.Version} */` },
  plugins: [
    nodeResolve({ browser: false, exportConditions: ['node'], preferBuiltins: true }),
    commonjs(),
    {
      name: 'emit-module-package-file',
      generateBundle() {
        this.emitFile({ fileName: 'package.json', source: '{ "type": "module" }', type: 'asset' });
      }
    }
  ]
};
