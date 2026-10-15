// The manual used to live under /zc-workstation/zc-workstation/. It now sits
// at the site root, so each old address gets a page that forwards to the new
// one, and links in old READMEs, issues and search results keep working.
import { mkdirSync, readdirSync, writeFileSync } from 'node:fs'
import { dirname, join, relative } from 'node:path'

const site = 'build/site'
const old = join(site, 'zc-workstation')
const base = 'https://zoolcoder.github.io/zc-workstation/'

function pages (dir) {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const path = join(dir, entry.name)
    if (entry.isDirectory()) return entry.name.startsWith('_') || path === old ? [] : pages(path)
    return entry.name.endsWith('.html') && entry.name !== '404.html' ? [path] : []
  })
}

const escape = (s) => s.replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;')

for (const page of pages(site)) {
  const path = relative(site, page)
  const stub = join(old, path)
  const target = escape(relative(dirname(stub), page))
  mkdirSync(dirname(stub), { recursive: true })
  writeFileSync(stub, `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; base-uri 'none'; form-action 'none'">
<meta name="robots" content="noindex">
<meta http-equiv="refresh" content="0; url=${target}">
<link rel="canonical" href="${escape(base + path)}">
<title>Moved</title>
</head>
<body>
<p>This page moved to <a href="${target}">${escape(base + path)}</a>.</p>
</body>
</html>
`)
}
