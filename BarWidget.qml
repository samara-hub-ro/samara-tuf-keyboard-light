import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Keyboard backlight control for ASUS laptops.
//
// Two independent pieces of hardware sit behind this one widget:
//
//   * Brightness is a plain kernel LED (0..max_brightness). brightnessctl
//     reaches it through logind's D-Bus, so no root and no udev rule needed.
//   * Colour and effect are the Aura controller, driven by asusd. asusctl
//     talks to the daemon over D-Bus with polkit, so again no root here.
//
// Both are also changed behind our back — the Fn keys move brightness, and
// rog-control-center or `omarchy theme set keyboard` move the colour — so the
// panel reads the real state back rather than trusting its own last write.
Panel {
  id: root
  moduleName: "samara-hub-ro.keyboard-light"
  ipcTarget: "samara-hub-ro.keyboard-light"

  // Panel is a bare Item with no intrinsic size, so the bar would lay this
  // out as 0x0 and the widget would never appear. Take the size from the
  // button, the way the first-party popup widgets do.
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property string ledDir: "/sys/class/leds/asus::kbd_backlight"
  readonly property string themeColourPath: Quickshell.env("HOME") + "/.local/state/omarchy/current/theme/keyboard.rgb"

  // ------------------------------------------------------- external commands
  //
  // Three programs are run, and each is named by its absolute path in a
  // root-owned system directory rather than by a bare name off `PATH`. A bar
  // widget inherits the shell's environment, and the shell inherits the
  // session's; a `PATH` entry earlier than /usr/bin is all it would take for
  // "brightnessctl" to mean something else entirely. A full path cannot be
  // redirected that way.
  //
  // None of them is privileged: brightnessctl reaches the LED through logind,
  // asusctl talks to asusd over D-Bus with polkit, and omarchy-osd is
  // Omarchy's own on-screen display. Nothing here uses sudo, pkexec or a
  // helper, and nothing is run through a shell — the arguments go straight to
  // execve, so there is no string for a colour or a level to be quoted into.

  readonly property string brightnessctlBin: "/usr/bin/brightnessctl"
  readonly property string asusctlBin: "/usr/bin/asusctl"
  readonly property string osdBin: "/usr/bin/omarchy-osd"

  // Built, not inherited. `PATH` is pinned to the system directories, and the
  // rest is the short list these three actually need to find the session:
  // omarchy-osd shells out to jq and omarchy-shell, and both asusctl and
  // brightnessctl need the bus to talk to asusd and logind.
  readonly property var commandEnvironment: {
    var env = { "PATH": "/usr/bin:/bin" }
    var keys = ["HOME", "USER", "LOGNAME", "XDG_RUNTIME_DIR", "XDG_SESSION_ID",
                "XDG_SESSION_TYPE", "XDG_CURRENT_DESKTOP", "WAYLAND_DISPLAY",
                "DBUS_SESSION_BUS_ADDRESS"]
    for (var i = 0; i < keys.length; i++) {
      var value = Quickshell.env(keys[i])
      if (value === undefined || value === null)
        continue
      var text = String(value)
      if (text.length > 0)
        env[keys[i]] = text
    }
    return env
  }

  function runTrusted(argv) {
    Quickshell.execDetached({
      command: argv,
      clearEnvironment: true,
      environment: root.commandEnvironment,
      workingDirectory: "/"
    })
  }

  // ------------------------------------------------------------- input bounds
  //
  // Every file read here belongs to something else — the kernel, asusd, the
  // theme — so each one is capped before it is looked at. The real files are
  // tens of bytes and a couple of kilobytes; anything past these ceilings is
  // not the file this expects and is ignored rather than parsed.
  readonly property int maxSysfsBytes: 64
  readonly property int maxAuraBytes: 131072
  readonly property int maxThemeBytes: 64
  // The longest RON block this walks. asusd's are a few hundred bytes; the cap
  // stops an unbalanced parenthesis from turning the walk into a scan of the
  // whole file.
  readonly property int maxAuraBlockBytes: 8192

  // asusd names its Aura config after the hardware it detected — aura_tuf.ron
  // here, aura_laptop.ron on other ASUS models — so the known keyboard configs
  // are tried in order until one loads. A fixed list rather than a glob: the
  // anime and slash files in the same directory drive auxiliary displays
  // rather than the keyboard, and expanding a wildcard would mean a shell —
  // a whole subprocess, with its inherited environment and its lifetime to
  // manage, bought for the sake of four filenames. Every path here is a
  // literal, so there is nothing to traverse and nothing to point elsewhere.
  readonly property var auraCandidates: [
    "/etc/asusd/aura_tuf.ron",
    "/etc/asusd/aura_laptop.ron",
    "/etc/asusd/aura_scsi.ron",
    "/etc/asusd/aura_ally.ron"
  ]
  // Index into the list while the chain is walking it, or the one that
  // answered; -1 when nothing did. Empty path until then, and the widget runs
  // brightness-only.
  property int auraCandidate: -1
  property string auraConfigPath: ""

  property int brightness: 0
  property int maxBrightness: 3
  // Remembered so the right-click toggle can restore the previous level
  // instead of always snapping back to full.
  property int lastLitBrightness: 3
  property bool ledPresent: false

  property string mode: "Static"
  property string colour: "ffffff"
  property string colour2: "0000ff"
  // asusd takes the speed argument but always persists `Med` back to its own
  // config on this TUF, so reading it back would snap this control to Medium
  // after every change. Keep it as the widget's own setting instead.
  property string speed: setting("speed", "Med")
  property string themeColour: ""
  property bool auraPresent: false

  property real wheelAccumulator: 0
  // asusd and the LED node are both polled, and a poll that lands between our
  // write and the daemon's rewrite would snap the UI back to the old value.
  // Ignore what we read for a moment after every local change.
  property double suppressSyncUntil: 0
  property string focusSection: "brightness"
  property bool cursorActive: false

  readonly property bool lit: brightness > 0
  readonly property bool scrollToAdjust: setting("scrollToAdjust", true)
  readonly property bool hideWhenUnsupported: setting("hideWhenUnsupported", true)
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.45)
  readonly property color background: bar ? bar.background : Color.background
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // RainbowCycle paints its own colours, so the swatches mean nothing there.
  readonly property bool modeUsesColour: mode !== "RainbowCycle"
  readonly property bool modeUsesSecondColour: mode === "Breathe"
  readonly property bool modeUsesSpeed: mode === "Breathe" || mode === "RainbowCycle"

  readonly property var effectOptions: [
    { value: "Static", label: "Static" },
    { value: "Breathe", label: "Breathe" },
    { value: "RainbowCycle", label: "Rainbow" },
    { value: "Pulse", label: "Pulse" }
  ]

  readonly property var speedOptions: [
    { value: "Low", label: "Slow" },
    { value: "Med", label: "Medium" },
    { value: "High", label: "Fast" }
  ]

  // The active theme's keyboard colour leads the row when the theme ships one,
  // so the keyboard can be matched to the desktop in one click.
  readonly property var swatches: {
    var list = []
    if (themeColour !== "")
      list.push({ hex: themeColour, name: "Theme colour" })
    var presets = [
      ["ffffff", "White"], ["ff0000", "Red"], ["ff5f00", "Orange"],
      ["ffd000", "Amber"], ["00ff00", "Green"], ["00ffd0", "Teal"],
      ["00a0ff", "Blue"], ["4000ff", "Indigo"], ["ff00ff", "Magenta"],
      ["ff0060", "Pink"]
    ]
    for (var i = 0; i < presets.length; i++) {
      if (themeColour.toLowerCase() === presets[i][0])
        continue
      list.push({ hex: presets[i][0], name: presets[i][1] })
    }
    return list
  }

  function swatchesWith(active) {
    var list = swatches.slice()
    var wanted = String(active).toLowerCase()
    for (var i = 0; i < list.length; i++) {
      if (list[i].hex.toLowerCase() === wanted)
        return list
    }
    return [{ hex: wanted, name: "Current colour" }].concat(list)
  }

  function clampBrightness(value) {
    return Math.max(0, Math.min(maxBrightness, Math.round(value)))
  }

  function brightnessPercent() {
    return maxBrightness > 0 ? Math.round(brightness * 100 / maxBrightness) : 0
  }

  function setBrightness(value, showOsd) {
    var next = clampBrightness(value)
    if (next === brightness)
      return next
    if (brightness > 0)
      lastLitBrightness = brightness
    brightness = next
    suppressSyncUntil = Date.now() + 1200
    runTrusted([brightnessctlBin, "-d", "asus::kbd_backlight", "set", String(next)])
    if (showOsd)
      runTrusted([osdBin, "-i", "keyboard", "-p", String(brightnessPercent())])
    return next
  }

  function toggleLight() {
    setBrightness(lit ? 0 : Math.max(1, lastLitBrightness), true)
  }

  // asusctl's speed argument is lowercase; asusd's config file capitalises it.
  function speedArg() {
    return String(speed).toLowerCase()
  }

  function applyEffect() {
    if (!auraPresent)
      return
    var args = [asusctlBin, "aura", "effect"]
    if (mode === "Static")
      args = args.concat(["static", "-c", colour])
    else if (mode === "Pulse")
      args = args.concat(["pulse", "-c", colour])
    else if (mode === "Breathe")
      args = args.concat(["breathe", "--colour", colour, "--colour2", colour2, "--speed", speedArg()])
    else if (mode === "RainbowCycle")
      args = args.concat(["rainbow-cycle", "--speed", speedArg()])
    else
      return
    suppressSyncUntil = Date.now() + 1200
    runTrusted(args)
  }

  function setMode(next) {
    if (next === mode)
      return
    mode = next
    // Each mode carries its own colours and speed in asusd's config; adopt the
    // stored ones so switching modes does not silently rewrite them.
    adoptModeState(next)
    applyEffect()
  }

  function setColour(hex) {
    if (hex === colour)
      return
    colour = hex
    applyEffect()
  }

  function setSecondColour(hex) {
    if (hex === colour2)
      return
    colour2 = hex
    applyEffect()
  }

  function setSpeed(next) {
    if (next === speed)
      return
    speed = next
    settings = Object.assign({}, settings, { speed: next })
    if (bar && bar.shell)
      bar.shell.updateEntryInline(moduleName, settings)
    applyEffect()
  }

  property var auraState: ({ current: "Static", modes: {} })

  function adoptModeState(name) {
    var stored = auraState.modes ? auraState.modes[name] : null
    if (!stored)
      return
    colour = stored.colour1
    colour2 = stored.colour2
  }

  function hexByte(value) {
    var text = Math.max(0, Math.min(255, parseInt(value, 10) || 0)).toString(16)
    return text.length < 2 ? "0" + text : text
  }

  function colourFrom(block, key) {
    var match = new RegExp(key + ":\\s*\\(\\s*r:\\s*(\\d+),\\s*g:\\s*(\\d+),\\s*b:\\s*(\\d+)").exec(block)
    if (!match)
      return "ffffff"
    return hexByte(match[1]) + hexByte(match[2]) + hexByte(match[3])
  }

  // asusd stores its state as RON. Rather than pull in a parser, walk the
  // parentheses of each builtin block and pick the fields out with regexes —
  // the shapes involved are fixed and shallow.
  function parseAura(text) {
    var parsed = { current: "Static", modes: {} }
    var current = /current_mode:\s*([A-Za-z]+)/.exec(text)
    if (current)
      parsed.current = current[1]

    var names = ["Static", "Breathe", "RainbowCycle", "Pulse"]
    for (var i = 0; i < names.length; i++) {
      var hit = new RegExp("\\b" + names[i] + ":\\s*\\(").exec(text)
      if (!hit)
        continue
      var start = hit.index + hit[0].length
      var depth = 1
      var end = start
      // Bounded by the block ceiling as well as by the text: an unbalanced
      // parenthesis must cost one short scan, not a walk to the end.
      var stop = Math.min(text.length, start + root.maxAuraBlockBytes)
      while (end < stop && depth > 0) {
        var ch = text.charAt(end)
        if (ch === "(")
          depth++
        else if (ch === ")")
          depth--
        end++
      }
      if (depth > 0)
        continue
      var block = text.substring(start, end)
      var storedSpeed = /speed:\s*([A-Za-z]+)/.exec(block)
      parsed.modes[names[i]] = {
        colour1: colourFrom(block, "colour1"),
        colour2: colourFrom(block, "colour2"),
        speed: storedSpeed ? storedSpeed[1] : "Med"
      }
    }
    return parsed
  }

  function loadAura(text) {
    if (!text || text.trim() === "")
      return
    // asusd's own file is under two kilobytes. Anything past the ceiling is
    // not it, and is not walked with regexes to find out.
    if (text.length > root.maxAuraBytes) {
      console.warn("keyboard-light: " + root.auraConfigPath + " is larger than "
        + Math.round(root.maxAuraBytes / 1024) + " KiB, ignoring it")
      return
    }
    auraState = parseAura(text)
    auraPresent = true
    // Keep the parsed per-mode colours either way: switching modes needs them
    // even while our own write is still settling.
    if (Date.now() < suppressSyncUntil)
      return
    mode = auraState.current
    adoptModeState(mode)
  }

  function stepBrightness(delta) {
    setBrightness(brightness + delta, true)
  }

  Component.onCompleted: {
    maxFile.reload()
    brightnessFile.reload()
    discoverAuraConfig()
  }

  onOpenedChanged: {
    if (opened) {
      cursorActive = false
      focusSection = "brightness"
      brightnessFile.reload()
      if (auraConfigPath === "")
        discoverAuraConfig()
      else
        auraFile.reload()
      themeFile.reload()
    }
  }

  // Walking the candidate list is the whole of the discovery: point the view
  // at the first one, and let each failure move it to the next. No process, so
  // nothing to give an environment to, nothing to put a deadline on and
  // nothing left running when the widget goes away.
  function discoverAuraConfig() {
    root.auraCandidate = 0
    if (root.auraConfigPath === root.auraCandidates[0])
      auraFile.reload()
    else
      root.auraConfigPath = root.auraCandidates[0]
  }

  function nextAuraCandidate() {
    if (root.auraCandidate < 0)
      return
    var next = root.auraCandidate + 1
    if (next >= root.auraCandidates.length) {
      // Nothing on this machine: brightness-only, and the panel says so.
      root.auraCandidate = -1
      root.auraConfigPath = ""
      root.auraPresent = false
      return
    }
    root.auraCandidate = next
    root.auraConfigPath = root.auraCandidates[next]
  }

  FileView {
    id: maxFile
    path: root.ledDir + "/max_brightness"
    watchChanges: false
    printErrors: false
    onLoaded: {
      var raw = String(text() || "")
      if (raw.length > root.maxSysfsBytes)
        return
      var value = parseInt(raw.trim(), 10)
      if (isFinite(value) && value > 0) {
        root.maxBrightness = value
        root.ledPresent = true
        if (root.lastLitBrightness > value)
          root.lastLitBrightness = value
      }
    }
  }

  // sysfs attributes do not deliver inotify events, so this is polled while the
  // panel is open rather than watched.
  FileView {
    id: brightnessFile
    path: root.ledDir + "/brightness"
    watchChanges: false
    printErrors: false
    onLoaded: {
      var raw = String(text() || "")
      if (raw.length > root.maxSysfsBytes)
        return
      var value = parseInt(raw.trim(), 10)
      if (!isFinite(value))
        return
      root.ledPresent = true
      if (Date.now() < root.suppressSyncUntil)
        return
      root.brightness = root.clampBrightness(value)
      if (root.brightness > 0)
        root.lastLitBrightness = root.brightness
    }
  }

  // asusd rewrites this file atomically (write + rename), which replaces the
  // inode and slips past an inotify watch on the path, so it is polled below
  // rather than watched.
  FileView {
    id: auraFile
    path: root.auraConfigPath
    watchChanges: false
    printErrors: false
    onLoaded: root.loadAura(String(text() || ""))
    // A candidate that is not there, or not readable, is the ordinary case on
    // every machine but one — move to the next rather than treat it as an
    // error.
    onLoadFailed: root.nextAuraCandidate()
  }

  FileView {
    id: themeFile
    path: root.themeColourPath
    watchChanges: true
    printErrors: false
    onLoaded: {
      var raw = String(text() || "")
      if (raw.length > root.maxThemeBytes) {
        root.themeColour = ""
        return
      }
      var value = raw.trim().replace(/^#/, "")
      root.themeColour = /^[0-9A-Fa-f]{6}$/.test(value) ? value.toLowerCase() : ""
    }
  }

  // Everything here can also be changed from outside — the Fn keys,
  // rog-control-center, `omarchy theme set keyboard` — so the real state is read
  // back rather than assumed. The bar icon carries brightness too (it dims when
  // the light is off), so brightness keeps being polled while the panel is shut,
  // just slowly. The Aura config only feeds panel content and is left alone
  // until something is actually looking at it.
  Timer {
    interval: root.opened ? 1000 : 5000
    running: root.ledPresent
    repeat: true
    onTriggered: {
      brightnessFile.reload()
      if (root.opened && root.auraConfigPath !== "")
        auraFile.reload()
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\udb80\udf0c"
    concealed: root.hideWhenUnsupported && !root.ledPresent
    dimmed: !root.lit
    tooltipText: root.ledPresent
      ? (root.lit ? "Keyboard light " + root.brightnessPercent() + "%" : "Keyboard light off")
      : "No keyboard backlight"
    onPressed: function(b) {
      if (!root.ledPresent)
        return
      if (b === Qt.RightButton)
        root.toggleLight()
      else
        root.toggle()
    }
    onWheelMoved: function(delta) {
      if (!root.ledPresent || !root.scrollToAdjust)
        return
      var wheel = Util.wheelSteps(root.wheelAccumulator, delta)
      root.wheelAccumulator = wheel.remainder
      if (wheel.steps === 0)
        return
      root.stepBrightness(wheel.steps)
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened && root.ledPresent
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (dx !== 0)
          root.stepBrightness(dx)
      }
      onActivateRequested: root.toggleLight()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        // ---------- Hero: glyph · title/state · level ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, heroLevel.implicitHeight)

          Text {
            id: heroIcon
            textFormat: Text.PlainText
            text: "\udb80\udf0c"
            color: root.lit ? root.foreground : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter

            Behavior on color { ColorAnimation { duration: 200 } }
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: heroLevel.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: "Asus TUF/ROG Keyboard Light"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              textFormat: Text.PlainText
              text: root.auraPresent
                ? (root.lit ? root.modeLabel().toUpperCase() : "OFF")
                : (root.lit ? "ON" : "OFF")
              color: Qt.darker(root.foreground, 1.4)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
              width: parent.width
            }
          }

          Text {
            id: heroLevel
            textFormat: Text.PlainText
            text: root.brightness + "/" + root.maxBrightness
            color: root.lit ? root.foreground : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.displayLarge
            font.bold: true
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter

            Behavior on color { ColorAnimation { duration: 200 } }
          }
        }

        // ---------- Brightness ----------
        Item {
          width: parent.width
          implicitHeight: Style.spacing.controlHeight

          PanelSlider {
            anchors.fill: parent
            bar: root.bar
            minimum: 0
            maximum: root.maxBrightness
            step: 1
            integer: true
            tickCount: root.maxBrightness + 1
            value: root.brightness
            onMoved: function(v) { root.setBrightness(v, false) }
            onRightClicked: root.toggleLight()
          }
        }

        PanelSeparator { width: parent.width }

        // ---------- Effect ----------
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: root.auraPresent

          PanelSectionHeader {
            text: "EFFECT"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          ButtonGroup {
            options: root.effectOptions
            value: root.mode
            foreground: root.foreground
            background: root.background
            fontFamily: root.fontFamily
            onChanged: function(v) { root.setMode(v) }
          }
        }

        // ---------- Colour ----------
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: root.auraPresent && root.modeUsesColour

          PanelSectionHeader {
            text: root.modeUsesSecondColour ? "FIRST COLOUR" : "COLOUR"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Flow {
            width: parent.width
            spacing: Style.space(8)

            Repeater {
              model: root.swatchesWith(root.colour)
              delegate: Rectangle {
                required property var modelData
                readonly property bool selected: root.colour.toLowerCase() === modelData.hex.toLowerCase()
                width: Style.space(26)
                height: Style.space(26)
                radius: Style.cornerRadius
                color: "#" + modelData.hex
                border.width: selected ? 2 : 1
                border.color: selected
                  ? root.foreground
                  : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.25)

                MouseArea {
                  id: swatchMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.setColour(modelData.hex)
                }

                PanelToolTip {
                  text: modelData.name
                  visible: swatchMouse.containsMouse
                }
              }
            }
          }
        }

        // ---------- Second colour (breathe fades between two) ----------
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: root.auraPresent && root.modeUsesSecondColour

          PanelSectionHeader {
            text: "SECOND COLOUR"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Flow {
            width: parent.width
            spacing: Style.space(8)

            Repeater {
              model: root.swatchesWith(root.colour2)
              delegate: Rectangle {
                required property var modelData
                readonly property bool selected: root.colour2.toLowerCase() === modelData.hex.toLowerCase()
                width: Style.space(26)
                height: Style.space(26)
                radius: Style.cornerRadius
                color: "#" + modelData.hex
                border.width: selected ? 2 : 1
                border.color: selected
                  ? root.foreground
                  : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.25)

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.setSecondColour(modelData.hex)
                }
              }
            }
          }
        }

        // ---------- Speed ----------
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: root.auraPresent && root.modeUsesSpeed

          PanelSectionHeader {
            text: "SPEED"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          ButtonGroup {
            options: root.speedOptions
            value: root.speed
            foreground: root.foreground
            background: root.background
            fontFamily: root.fontFamily
            onChanged: function(v) { root.setSpeed(v) }
          }
        }

        // ---------- Fallback note when asusd is not around ----------
        Text {
          width: parent.width
          visible: !root.auraPresent
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          text: "Brightness only. Install asusctl and start asusd for colour and effects."
          color: Qt.darker(root.foreground, 1.4)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }

  function modeLabel() {
    for (var i = 0; i < effectOptions.length; i++) {
      if (effectOptions[i].value === mode)
        return effectOptions[i].label
    }
    return mode
  }
}
