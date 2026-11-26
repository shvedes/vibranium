// Paired launch statistic for Gate 4. Not run in this environment: the host
// cannot provide the isolated compositor/socket or the live-shell launch
// authorization. Kept here so the gate is fully specified for a real harness.
//
// Input JSON on stdin or as argv[2]:
// {
//   "endpoint": "powerProfile.status",
//   "mode": "cold",
//   "resolutionMs": 1,
//   "pairs": [
//     { "baseline": 123, "candidate": 124,
//       "baselineCensored": false, "candidateCensored": false }
//   ]
// }
//
// A censored observation is a non-start, timeout or wrong-instance result and
// is excluded from the paired duration set. The gate requires >=20 complete
// pairs, resolution <=5ms, censoring <=10% and no censored candidate without a
// matching censored baseline. The effect is nearest-rank p95(candidate) minus
// p95(baseline); the 95% interval resamples WHOLE pairs and recomputes BOTH
// percentiles in every sample. Pass only when the upper limit is <= +5ms.
import fs from 'node:fs'

const raw = process.argv[2] || fs.readFileSync(0, 'utf8')
const input = JSON.parse(raw)
const pairs = input.pairs || []

function fail(reason) {
  console.log(JSON.stringify({ verdict: 'INCONCLUSIVE', reason }, null, 2))
  process.exit(2)
}

if (!(input.endpoint === 'powerProfile.status' || input.endpoint === 'appLauncher.status')) {
  fail('endpoint must be powerProfile.status or appLauncher.status')
}
if (input.mode !== 'cold' && input.mode !== 'warm') fail('mode must be cold or warm')
if (!(typeof input.resolutionMs === 'number') || input.resolutionMs > 5 || input.resolutionMs < 0) {
  fail(`observation resolution ${input.resolutionMs}ms exceeds 5ms`)
}
if (pairs.length < 20) fail(`only ${pairs.length} pairs, need at least 20`)

const usable = pairs.filter((p) => p.baselineCensored !== true && p.candidateCensored !== true)
const censored = pairs.length - usable.length
if (censored / pairs.length > 0.10) fail(`censoring ${censored}/${pairs.length} exceeds 10%`)
const unmatched = pairs.filter((p) => p.candidateCensored === true && p.baselineCensored !== true)
if (unmatched.length > 0) fail(`${unmatched.length} censored candidate observations without a matching baseline`)

function nearestRankP95(values) {
  if (values.length === 0) return null
  const sorted = values.slice().sort((a, b) => a - b)
  return sorted[Math.ceil(0.95 * sorted.length) - 1]
}

function makeRandom(seed) {
  let s = (seed >>> 0) || 1
  return function () {
    s = (s * 1664525 + 1013904223) >>> 0
    return s / 4294967296
  }
}

const baseline = usable.map((p) => p.baseline)
const candidate = usable.map((p) => p.candidate)
const estimate = nearestRankP95(candidate) - nearestRankP95(baseline)

const samples = []
const rand = makeRandom(input.seed || 0x5050494c)
for (let i = 0; i < 10000; i++) {
  const bSample = []
  const cSample = []
  for (let j = 0; j < usable.length; j++) {
    const at = Math.floor(rand() * usable.length)
    bSample.push(usable[at].baseline)
    cSample.push(usable[at].candidate)
  }
  samples.push(nearestRankP95(cSample) - nearestRankP95(bSample))
}
samples.sort((a, b) => a - b)
function percentile(values, p) {
  const at = Math.ceil(p * values.length) - 1
  return values[Math.max(0, at)]
}

const lower = percentile(samples, 0.025)
const upper = percentile(samples, 0.975)
console.log(JSON.stringify({
  verdict: upper <= 5 ? 'PASS' : 'FAIL',
  endpoint: input.endpoint,
  mode: input.mode,
  pairs: pairs.length,
  completePairs: usable.length,
  censored,
  censoringRatio: censored / pairs.length,
  resolutionMs: input.resolutionMs,
  p95Baseline: nearestRankP95(baseline),
  p95Candidate: nearestRankP95(candidate),
  effectMs: estimate,
  interval95: [lower, upper],
  bootstrapSamples: samples.length,
}, null, 2))
