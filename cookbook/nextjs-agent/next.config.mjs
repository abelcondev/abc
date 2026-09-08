import { fileURLToPath } from 'node:url'

const cookbook = fileURLToPath(new URL('..', import.meta.url))
export default {
  turbopack: { root: cookbook },
  outputFileTracingRoot: cookbook,
}
