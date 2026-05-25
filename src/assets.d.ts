/// <reference types="vite/client" />

// Vite serves imported `.svg` paths as URL strings — give TypeScript a
// matching declaration so `import logoUrl from './foo.svg'` typechecks.

declare module "*.svg" {
  const src: string;
  export default src;
}

// material-icon-theme ships an untyped JSON manifest; declare it so default
// imports resolve to `unknown` (we cast to a richer interface in fileIcons).
declare module "material-icon-theme/dist/material-icons.json" {
  const manifest: unknown;
  export default manifest;
}
