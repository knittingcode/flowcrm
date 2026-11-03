const BASE = 'https://flowcrm.invalid';

/**
 * The page to go to after the login: only a path of this application. An
 * absolute URL, a protocol-relative one (//host), a backslash (which
 * browsers read as a slash), control characters or the login page itself
 * give the start page instead, so a crafted link cannot redirect elsewhere.
 */
export function safeReturnTo(value: string | null): string {
  // eslint-disable-next-line no-control-regex -- control characters are exactly what is refused here
  if (value === null || !value.startsWith('/') || value.startsWith('//') || /[\\\u0000-\u001f\u007f]/.test(value)) {
    return '/';
  }
  let url: URL;
  try {
    url = new URL(value, BASE);
  } catch {
    return '/';
  }
  if (url.origin !== BASE || url.pathname === '/login') {
    return '/';
  }
  return url.pathname + url.search + url.hash;
}

/** The login page that leads back to `path` afterwards. */
export function loginPath(path: string): string {
  const target = safeReturnTo(path);
  return target === '/' ? '/login' : `/login?returnTo=${encodeURIComponent(target)}`;
}
