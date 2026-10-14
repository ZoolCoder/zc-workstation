// Reads or rewrites the desktop pictures in the wallpaper store, Index.plist:
// every Space on every display keeps its own. Prints "<showing url> <total>".
// Usage: osascript -l JavaScript store.js read|write STORE URL
ObjC.import('Foundation')
function run(argv) {
  const [mode, store, url] = argv
  const data = $.NSData.dataWithContentsOfFile(store)
  if (data.isNil()) return '0 0'
  const root = $.NSPropertyListSerialization.propertyListWithDataOptionsFormatError(data, 2, null, null)
  const image = 'com.apple.wallpaper.choice.image'
  const config = $.NSPropertyListSerialization.dataWithPropertyListFormatOptionsError(
    $({type: 'imageFile', url: {relative: url}}), 200, 0, null)
  let seen = 0, match = 0
  const shows = c => {
    const cfg = c.objectForKey('Configuration')
    if (cfg.isNil() || c.objectForKey('Provider').js !== image) return false
    const d = $.NSPropertyListSerialization.propertyListWithDataOptionsFormatError(cfg, 0, null, null)
    return !d.isNil() && ObjC.deepUnwrap(d).url?.relative === url
  }
  const desktop = d => {
    const choices = d.objectForKey('Content').objectForKey('Choices')
    if (choices.isNil()) return
    for (let i = 0; i < choices.count; i++) {
      const c = choices.objectAtIndex(i)
      seen++
      if (shows(c)) { match++; continue }
      if (mode !== 'write') continue
      c.setObjectForKey(image, 'Provider')
      c.setObjectForKey(config, 'Configuration')
      c.setObjectForKey($.NSArray.array, 'Files')
    }
  }
  const walk = o => {
    if (o.isKindOfClass($.NSArray)) { for (let i = 0; i < o.count; i++) walk(o.objectAtIndex(i)); return }
    if (!o.isKindOfClass($.NSDictionary)) return
    for (const k of o.allKeys.js) {
      const v = o.objectForKey(k)
      if (k.js === 'Desktop' && v.isKindOfClass($.NSDictionary)) desktop(v); else walk(v)
    }
  }
  walk(root)
  if (mode === 'write' && match < seen)
    $.NSPropertyListSerialization.dataWithPropertyListFormatOptionsError(root, 200, 0, null).writeToFileAtomically(store, true)
  return match + ' ' + seen
}
