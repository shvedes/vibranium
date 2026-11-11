// Shared verdicts over a registry job's terminal payload.
//
// A job settles with { code, exitCode, timedOut, cancelled, destroyed }, or is
// destroyed before it can be read at all. "Succeeded" is the full terminal
// verdict - a timed-out, cancelled or destroyed child never did its work - and
// a cancel is only meaningful while the job is still live. Both rules were
// restated identically in the wallpaper, inhibitor, privacy and picker code;
// this is their one home. Pure JS, pragma library, no Qt imports, so the rules
// are unit-drivable.
.pragma library

function succeeded(result) {
  if (result === null || result === undefined) return false
  return String(result.code) === "ok" && Number(result.exitCode) === 0
    && result.timedOut !== true && result.cancelled !== true
    && result.destroyed !== true
}

// The stable refusal code for a child that did not report success: derived
// from the job's own terminal code, so a new terminal state becomes a new code
// instead of collapsing into a success.
function failedCode(result) {
  if (result === null || result === undefined) return "unavailable"
  const code = String(result.code)
  return code === "ok" ? "" : code
}

// Cancel a live registry job and answer whether the cancel reached it. A
// settled or unreadable job is left alone, and a cancel that throws because
// the job died between the two reads is not an error. `reason` is the
// registry's own cancellation label.
function cancelLive(job, reason) {
  if (job === null || job === undefined) return false
  try {
    if (String(job.state) === "settled") return false
  } catch (ignored) {
    return false
  }
  try {
    job.cancel(String(reason))
    return true
  } catch (ignored) {
    return false
  }
}

// Cancel a live registry job when the caller has no use for the verdict.
function stopJob(job, reason) {
  cancelLive(job, reason)
}
