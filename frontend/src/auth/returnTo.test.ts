import { describe, expect, it } from 'vitest';
import { loginPath, safeReturnTo } from './returnTo.ts';

describe('safeReturnTo', () => {
  it.each([
    ['/o/org-a', '/o/org-a'],
    ['/o/org-a?page=2#members', '/o/org-a?page=2#members'],
    ['/accounts/some/deep/link', '/accounts/some/deep/link'],
  ])('keeps the application path %s', (value, expected) => {
    expect(safeReturnTo(value)).toBe(expected);
  });

  it.each([
    null,
    '',
    'https://evil.example/',
    '//evil.example/path',
    '/\\evil.example',
    '\\\\evil.example',
    'javascript:alert(1)',
    '/path\twith-tab',
    '/path\nwith-newline',
    'relative/path',
    '/login',
    '/login?returnTo=%2Fo%2Fx',
  ])('falls back to the start page for %j', (value) => {
    expect(safeReturnTo(value)).toBe('/');
  });

  it('builds the login path only with a safe target', () => {
    expect(loginPath('/o/org-a')).toBe('/login?returnTo=%2Fo%2Forg-a');
    expect(loginPath('/')).toBe('/login');
    expect(loginPath('//evil.example')).toBe('/login');
  });
});
