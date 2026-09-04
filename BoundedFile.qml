import QtQuick
import Quickshell
import Quickshell.Io

// A bounded read of a file this plugin does not own.
//
// FileView is the obvious way to read a file from QML and the wrong way to
// read this one: it opens the path and materialises all of it before QML sees
// a byte, so a length check on the result is not a boundary at all. A FIFO
// left in place of the file blocks the read; an oversized regular file is
// already in memory by the time anything could reject it. The boundary has to
// be on the producing side, and QML has no syscall surface to put it there —
// no O_NOFOLLOW, no fstat, no read limit, no access to the descriptor. So it
// is produced by two coreutils invocations instead:
//
//   1. `stat` — which uses lstat, so a symlink reports as `symbolic link` and
//      a FIFO as `fifo`. Anything that is not a regular file is refused, as is
//      an owner outside `allowedOwners`, as is a size already over the limit.
//      This is the type, ownership and size check.
//
//   2. `dd` with `iflag=nofollow,nonblock` — O_NOFOLLOW refuses a symlink at
//      open time and O_NONBLOCK makes a FIFO return EAGAIN rather than block,
//      so neither substitution survives the window between the two calls.
//      `bs=limit+1 count=1` is exactly one read of at most limit+1 bytes: a
//      file that grew past the limit in that window comes back one byte too
//      long and is rejected on what arrived rather than on a stale size.
//
// Both run under `timeout` with a kill-after, with a built environment rather
// than the inherited one, and with no shell — the path is an argument, never
// part of a command line. Both are stopped by a watchdog past the deadline and
// when this object is destroyed, so nothing is left running behind the widget.
//
// The exit codes are deliberately not consulted: `stat` that fails prints
// nothing parseable and `dd` that fails returns no bytes, both of which are
// already failures here. That keeps the logic independent of whether `exited`
// arrives before or after the collector finishes.
Item {
  id: reader

  // The file to read, and the most it is ever allowed to be.
  property string path: ""
  property int limit: 65536
  // Seconds. Generous for a local read; the point is that there is one.
  property int deadline: 2
  // Usernames allowed to own the file. Empty means the user running the shell,
  // which is the right answer for anything under $HOME; a file that is meant
  // to be root's says so instead.
  property var allowedOwners: []
  property bool printErrors: false

  // `text` is at most `limit` bytes and came from a regular file owned by
  // someone in `allowedOwners`.
  signal loaded(string text)
  // `reason` is "missing" when the file is simply not there, which is an
  // ordinary state rather than an error for most callers.
  signal failed(string reason)

  readonly property string statBin: "/usr/bin/stat"
  readonly property string ddBin: "/usr/bin/dd"
  readonly property string timeoutBin: "/usr/bin/timeout"

  readonly property string currentUser: String(Quickshell.env("USER") || Quickshell.env("LOGNAME") || "")
  readonly property var commandEnvironment: ({ "PATH": "/usr/bin:/bin", "LC_ALL": "C" })

  readonly property bool busy: statProc.running || readProc.running

  // The path this run is about, captured when it starts: a path changed
  // mid-flight must not make the answer to one question land as the answer to
  // another.
  property string activePath: ""
  property int activeSize: 0

  // Starting a read cancels one already in flight rather than being dropped:
  // the caller has just said which file it wants, and an answer about the
  // previous one is no longer an answer to anything.
  function reload() {
    reader.abort()
    var target = String(reader.path || "")
    // Set first, so a failure is reported against the file that was asked for
    // rather than against whatever the last one happened to be.
    reader.activePath = target
    if (target.length === 0) {
      reader.report("missing")
      return
    }
    reader.activeSize = 0
    statProc.command = [reader.timeoutBin, "-k", "1", String(reader.deadline),
                        reader.statBin, "-c", "%F|%U|%s", "--", target]
    statProc.running = true
  }

  function abort() {
    watchdog.stop()
    statProc.running = false
    readProc.running = false
  }

  function report(reason) {
    watchdog.stop()
    // "missing" is not worth a line: it is the first-run state, it is every
    // candidate in a search but one, and it is the half-second in which
    // somebody else's non-atomic rewrite has the file unlinked. The reasons
    // that mean something — a type, an owner, a size, a deadline — are the
    // ones printed.
    if (reader.printErrors && reason !== "missing")
      console.warn("bounded-read: " + reader.activePath + ": " + reason)
    reader.failed(reason)
  }

  function ownerAllowed(owner) {
    var allowed = reader.allowedOwners || []
    if (allowed.length === 0)
      return reader.currentUser.length === 0 || owner === reader.currentUser
    return allowed.indexOf(owner) !== -1
  }

  function onStatFinished(output) {
    var fields = String(output || "").replace(/\s+$/, "").split("|")
    if (fields.length < 3) {
      // A stat that says nothing is a file that is not there, or one whose
      // directory we cannot search. Either way there is nothing to read.
      reader.report("missing")
      return
    }
    var kind = fields[0]
    if (kind !== "regular file" && kind !== "regular empty file") {
      reader.report("not a regular file: " + kind)
      return
    }
    if (!reader.ownerAllowed(fields[1])) {
      reader.report("owned by " + fields[1])
      return
    }
    var size = parseInt(fields[2], 10)
    if (!isFinite(size) || size < 0) {
      reader.report("unreadable size")
      return
    }
    if (size > reader.limit) {
      reader.report("larger than " + reader.limit + " bytes")
      return
    }
    reader.activeSize = size
    if (size === 0) {
      // Nothing to read, and dd on an empty file would only tell us so.
      watchdog.stop()
      reader.loaded("")
      return
    }
    readProc.command = [reader.timeoutBin, "-k", "1", String(reader.deadline),
                        reader.ddBin, "if=" + reader.activePath,
                        "iflag=nofollow,nonblock", "bs=" + String(reader.limit + 1),
                        "count=1", "status=none"]
    readProc.running = true
  }

  function onReadFinished(output) {
    watchdog.stop()
    var text = String(output || "")
    if (text.length === 0) {
      // stat said there were bytes and the read produced none: the open was
      // refused, or what is there now is not what was measured.
      reader.report("unreadable")
      return
    }
    if (text.length > reader.limit) {
      reader.report("larger than " + reader.limit + " bytes")
      return
    }
    reader.loaded(text)
  }

  Process {
    id: statProc
    clearEnvironment: true
    environment: reader.commandEnvironment
    workingDirectory: "/"
    onRunningChanged: if (statProc.running) watchdog.restart()
    stdout: StdioCollector {
      id: statOut
      waitForEnd: true
      onStreamFinished: reader.onStatFinished(statOut.text)
    }
  }

  Process {
    id: readProc
    clearEnvironment: true
    environment: reader.commandEnvironment
    workingDirectory: "/"
    onRunningChanged: if (readProc.running) watchdog.restart()
    stdout: StdioCollector {
      id: readOut
      waitForEnd: true
      onStreamFinished: reader.onReadFinished(readOut.text)
    }
  }

  // `timeout` is the deadline that actually binds; this is the one that
  // belongs to the widget, and it also covers a process that never starts.
  Timer {
    id: watchdog
    interval: (reader.deadline + 1) * 1000
    repeat: false
    onTriggered: {
      statProc.running = false
      readProc.running = false
      reader.failed("timed out")
    }
  }

  // A path change is a read request. It goes through a zero-interval timer so
  // the new run never starts from inside the previous run's own handler —
  // `failed` handlers that pick the next path are the ordinary case.
  onPathChanged: pathChanged.restart()

  Timer {
    id: pathChanged
    interval: 0
    repeat: false
    onTriggered: reader.reload()
  }

  Component.onDestruction: reader.abort()
}
