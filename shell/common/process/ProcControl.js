// Release a child process the shell constructed.
//
// A Quickshell Process is a JavaScript-owned object once createObject() hands
// it back: signal(9) asks the child to leave and destroy() removes the object
// so a late exited/finished signal has nowhere to land. The same three steps
// were written in the screenshot service and the annotation editor; a null
// slot is the already-released state and stays a no-op.
//
// Pure JS, pragma library, no Qt imports - the Process is passed in.
.pragma library

function kill(proc) {
  if (proc === null || proc === undefined) return
  proc.signal(9)
  proc.destroy()
}
