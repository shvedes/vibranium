// Compare the serialized observation records from the two isolated trees.
// Only the three observation points count; process markers and run metadata
// are deliberately excluded. Parses the raw qmlprobe output.
import fs from 'node:fs'

const [baselinePath, candidatePath] = process.argv.slice(2)
if (!baselinePath || !candidatePath) {
  console.error('usage: node compare-observations.mjs <baseline.kv.txt> <candidate.kv.txt> [prefix ...]')
  process.exit(2)
}

function parse(path) {
  const out = {}
  for (const line of fs.readFileSync(path, 'utf8').split('\n')) {
    const at = line.indexOf('##KV## ')
    if (at < 0) continue
    const record = line.slice(at + '##KV## '.length)
    const eq = record.indexOf('=')
    if (eq < 0) continue
    out[record.slice(0, eq)] = record.slice(eq + 1)
  }
  return out
}

const a = parse(baselinePath)
const b = parse(candidatePath)
const supplied = process.argv.slice(4)
const points = supplied.length > 0
  ? supplied
  : ['before_load.', 'adopted_no_resolve.', 'after_first_resolve.']
const keys = (o) => Object.keys(o).filter((k) => points.some((p) => k.startsWith(p))).sort()

const ak = keys(a)
const bk = keys(b)
const mismatches = []
for (const key of new Set([...ak, ...bk])) {
  if (!(key in a) || !(key in b) || a[key] !== b[key]) {
    mismatches.push({ key, baseline: key in a ? a[key] : '<missing>', candidate: key in b ? b[key] : '<missing>' })
  }
}

console.log(JSON.stringify({
  baselineKeys: ak.length,
  candidateKeys: bk.length,
  equalKeySets: JSON.stringify(ak) === JSON.stringify(bk),
  mismatches,
  equal: mismatches.length === 0 && JSON.stringify(ak) === JSON.stringify(bk),
}, null, 2))
process.exit(mismatches.length === 0 && JSON.stringify(ak) === JSON.stringify(bk) ? 0 : 1)
