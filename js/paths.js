// paths.js
//
// Resolves asset URLs relative to the deployed site root instead of the origin root,
// so the site works both at https://<user>.github.io/ and at https://<user>.github.io/<repo>/.
//
// This module always lives at <site-root>/js/paths.js, so '../' relative to its own
// module URL is the site root no matter where the site is mounted (localhost:8000/,
// plynett.github.io/, gutierrad.github.io/celeris/, ...). Because it is derived from
// import.meta.url there is nothing to configure per deployment.

export const SITE_ROOT = new URL('../', import.meta.url);

// asset('textures/turbulence.jpg') -> absolute URL under the site root.
// A leading '/' is tolerated so old-style paths can be passed through unchanged.
export function asset(path) {
    return new URL(String(path).replace(/^\/+/, ''), SITE_ROOT).href;
}
