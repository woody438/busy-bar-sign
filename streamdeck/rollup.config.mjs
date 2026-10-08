// Bundles the plugin, the Stream Deck SDK and the bar's engine into one file
// in the plugin folder, as Elgato's own template does.
import commonjs from '@rollup/plugin-commonjs';
import nodeResolve from '@rollup/plugin-node-resolve';

const sdPlugin = 'com.woodall.busybarsign.sdPlugin';

export default {
  input: 'src/plugin.js',
  output: { file: `${sdPlugin}/bin/plugin.js` },
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
