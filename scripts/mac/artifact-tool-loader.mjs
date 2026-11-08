// Node --import hook used only on the Mac. The @oai/artifact-tool copy in this
// repo's node_modules was installed on Windows (Windows skia binary, incomplete
// walnut wasm files), so Mac runs load a complete macOS copy kept outside the repo.
import { register } from 'node:module';
import { existsSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

const entry = process.env.CRAZYPARTS_ARTIFACT_TOOL_ENTRY;
if (entry && existsSync(entry)) {
  register('data:text/javascript,' + encodeURIComponent(`
    const target = ${JSON.stringify(pathToFileURL(entry).href)};
    export async function resolve(specifier, context, next) {
      if (specifier === '@oai/artifact-tool') return { url: target, shortCircuit: true };
      return next(specifier, context);
    }
  `));
}
