import {existsSync} from 'node:fs';
import {fileURLToPath, pathToFileURL} from 'node:url';

const root = new URL('../../', import.meta.url);

/** Resolves "@/x" like tsconfig paths, and extensionless package subpaths such as next/server (bundler style). */
export async function resolve(specifier, context, nextResolve) {
  if (specifier.startsWith('@/')) {
    const target = fileURLToPath(new URL(specifier.slice(2), root));
    const file = [target, `${target}.ts`, `${target}.tsx`].find((candidate) => existsSync(candidate));
    if (file) return nextResolve(pathToFileURL(file).href, context);
  }
  try {
    return await nextResolve(specifier, context);
  } catch (error) {
    if (
      error?.code === 'ERR_MODULE_NOT_FOUND' &&
      !specifier.startsWith('.') &&
      !/\.[cm]?js$/.test(specifier)
    ) {
      return nextResolve(`${specifier}.js`, context);
    }
    throw error;
  }
}
