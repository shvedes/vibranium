.pragma library
.import "Units.catalog.js" as Units

// Narrow Boot-local descriptor adapter. It only turns catalog data into
// descriptors with late wrappers; it imports no provider, registers nothing,
// runs no validation at library load and has no Qt dependency.
//
// Each wrapper captures its own id, so mapping the whole catalog cannot leave
// every closure pointing at the last row of a loop.

function descriptor(row, boot) {
  var id = row.id

  // Bind the intended id in a fresh scope for every generated function.
  var resolveFn = (function (boundId) {
    return function () { return boot._resolveDescriptor(boundId) }
  })(id)

  var out = {
    id: id,
    provider: row.provider,
    phase: row.phase,
    activation: row.activation,
    criticality: row.criticality,
    dependencies: row.dependencies.slice(),
    retry: {
      maxAttempts: row.retry.maxAttempts,
      backoffMs: row.retry.backoffMs,
      maxBackoffMs: row.retry.maxBackoffMs
    },
    resolver: resolveFn
  }

  // Absent means absent: UnitGate treats a missing ready/teardown differently
  // from a null one. Only attach these members when the old literal declared
  // the function.
  if (row.hasReady === true) {
    out.ready = (function (boundId) {
      return function () { return boot._unitReady(boundId) }
    })(id)
  }
  if (row.hasTeardown === true) {
    out.teardown = (function (boundId) {
      return function () { boot._unitTeardown(boundId) }
    })(id)
  }

  return out
}

function descriptors(boot) {
  var rows = Units.rows()
  var out = []
  for (var i = 0; i < rows.length; i++) out.push(descriptor(rows[i], boot))
  return out
}
