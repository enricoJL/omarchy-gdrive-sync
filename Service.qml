import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

Item {
  id: root

  property var settings: ({})
  property string moduleName: ""
  property bool panelOpen: false

  readonly property string home: Quickshell.env("HOME")
  readonly property string helperPath: Qt.resolvedUrl("gdrive-sync.py").toString().replace(/^file:\/\//, "")

  readonly property string remote: strSetting("remote", "gdrive:")
  readonly property string localDir: expandHome(strSetting("localDir", "~/GoogleDrive"))
  readonly property int intervalSec: intSetting("intervalSec", 60, 30, 3600)
  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 15, 5, 300)

  property var status: Model.defaultStatus()
  property string helperError: ""
  property string actionStatus: ""
  property bool refreshing: false

  // Folder chooser state
  property bool browsing: false
  property var browse: ({ path: "", parent: "", dirs: [] })
  property bool browseLoading: false

  readonly property string state: Model.stateOf(status)
  readonly property bool running: status.running === true
  readonly property bool needsResync: status.needsResync === true
  readonly property bool timerEnabled: status.timerEnabled === true
  readonly property bool problem: Model.isProblem(state)
  readonly property bool usable: status.loaded && status.rcloneInstalled && status.remoteConfigured
  readonly property bool busy: controlProcess.running || applyProcess.running || setFolderProcess.running
  readonly property var progress: status.current ? status.current.progress : null
  readonly property var lastRun: status.lastRun
  readonly property string configuredDir: status.config && status.config.localDir ? status.config.localDir : localDir

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null || value === "" ? fallback : value
  }

  function strSetting(name, fallback) {
    return String(setting(name, fallback)).trim() || fallback
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    if (n < min) n = min
    if (n > max) n = max
    return n
  }

  function expandHome(path) {
    var value = String(path || "")
    if (value === "~") return home
    if (value.indexOf("~/") === 0) return home + value.substring(1)
    return value
  }

  function elide(text) {
    var value = String(text || "").replace(/\s+/g, " ").trim()
    return value.length > 160 ? value.substring(0, 157) + "…" : value
  }

  function flash(text) {
    actionStatus = text
    actionStatusTimer.restart()
  }

  // ---------------------------------------------------------------- status

  function refresh() {
    if (statusProcess.running) return
    refreshing = true
    statusProcess.command = ["python3", helperPath, "status"]
    statusProcess.running = true
  }

  function applyStatus(raw) {
    var parsed = Model.parseStatus(raw)
    if (!parsed) {
      helperError = "Could not read sync status"
      return
    }
    status = parsed
    helperError = ""
  }

  // ---------------------------------------------------------------- settings → runner config

  function applySettings() {
    if (applyProcess.running) { applyPending = true; return }
    applyProcess.command = [
      "python3", helperPath, "apply-settings",
      "--remote", remote,
      "--local-dir", localDir,
      "--interval", String(intervalSec)
    ]
    applyProcess.running = true
  }
  property bool applyPending: false

  onSettingsChanged: applySettings()
  Component.onCompleted: applySettings()

  // ---------------------------------------------------------------- actions

  function control(action, label) {
    if (controlProcess.running) return
    controlProcess.action = action
    controlProcess.command = ["python3", helperPath, action]
    controlProcess.running = true
    if (label) flash(label)
  }

  function syncNow() { control("sync-now", "Sync started") }
  function resync() { control("resync", "Resync started") }
  function cancel() { control("cancel", "Cancelling…") }
  function pause() { control("pause", "Sync paused") }
  function resume() { control("resume", "Sync resumed") }
  function toggleTimer() { timerEnabled ? pause() : resume() }

  function openFolder() {
    if (!status.localDirExists) return
    Quickshell.execDetached(["uwsm-app", "--", "nautilus", configuredDir])
  }

  // ---------------------------------------------------------------- folder chooser

  function startBrowse() {
    browsing = true
    loadDirs(status.localDirExists ? configuredDir : home)
  }

  function stopBrowse() {
    browsing = false
  }

  function loadDirs(path) {
    if (dirsProcess.running) { dirsPending = path; return }
    browseLoading = true
    dirsProcess.command = ["python3", helperPath, "dirs", path]
    dirsProcess.running = true
  }
  property string dirsPending: ""

  function browseUp() {
    if (browse.parent) loadDirs(browse.parent)
  }

  function chooseFolder(path) {
    if (setFolderProcess.running) return
    var target = String(path || browse.path)
    if (target === "") return
    setFolderProcess.target = target
    setFolderProcess.command = ["python3", helperPath, "set-folder", target, "--create"]
    setFolderProcess.running = true
  }

  // ---------------------------------------------------------------- timers

  Timer {
    id: refreshTimer
    interval: (root.running || root.panelOpen) ? 1500 : root.refreshIntervalSec * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    id: delayedRefresh
    interval: 800
    repeat: false
    onTriggered: root.refresh()
  }

  Timer {
    id: actionStatusTimer
    interval: 2500
    repeat: false
    onTriggered: root.actionStatus = ""
  }

  // ---------------------------------------------------------------- processes

  Process {
    id: statusProcess
    running: false
    command: []
    stdout: StdioCollector { id: statusStdout; waitForEnd: true }
    stderr: StdioCollector { id: statusStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.refreshing = false
      if (exitCode === 0) root.applyStatus(statusStdout.text)
      else root.helperError = root.elide(statusStderr.text || statusStdout.text || "Failed to read status")
    }
  }

  Process {
    id: applyProcess
    running: false
    command: []
    stdout: StdioCollector { id: applyStdout; waitForEnd: true }
    stderr: StdioCollector { id: applyStderr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) root.applyStatus(applyStdout.text)
      else root.helperError = root.elide(applyStderr.text || "Failed to apply settings")
      if (root.applyPending) {
        root.applyPending = false
        root.applySettings()
      }
    }
  }

  Process {
    id: controlProcess
    property string action: ""
    running: false
    command: []
    stdout: StdioCollector { id: controlStdout; waitForEnd: true }
    stderr: StdioCollector { id: controlStderr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.helperError = root.elide(controlStderr.text || controlStdout.text || "Command failed")
        root.flash(root.helperError)
      }
      delayedRefresh.restart()
    }
  }

  Process {
    id: dirsProcess
    running: false
    command: []
    stdout: StdioCollector { id: dirsStdout; waitForEnd: true }
    onExited: function(exitCode) {
      root.browseLoading = false
      if (exitCode === 0) {
        try {
          var parsed = JSON.parse(String(dirsStdout.text || ""))
          if (parsed && typeof parsed === "object") root.browse = parsed
        } catch (e) {}
      }
      if (root.dirsPending !== "") {
        var next = root.dirsPending
        root.dirsPending = ""
        root.loadDirs(next)
      }
    }
  }

  Process {
    id: setFolderProcess
    property string target: ""
    running: false
    command: []
    stdout: StdioCollector { id: setFolderStdout; waitForEnd: true }
    stderr: StdioCollector { id: setFolderStderr; waitForEnd: true }
    onExited: function(exitCode) {
      var out = String(setFolderStdout.text || "")
      if (exitCode === 0) {
        root.applyStatus(out)
        root.browsing = false
        root.flash("Folder: " + Model.shortenPath(setFolderProcess.target, root.home))
        persistProcess.command = ["omarchy", "bar", "set", root.moduleName, "localDir", setFolderProcess.target]
        persistProcess.running = root.moduleName !== ""
      } else {
        var message = "Could not select this folder"
        try { message = JSON.parse(out).error || message } catch (e) {}
        root.flash(message)
      }
    }
  }

  Process {
    id: persistProcess
    running: false
    command: []
    stderr: StdioCollector { id: persistStderr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) root.helperError = root.elide("Setting not persisted to shell.json: " + persistStderr.text)
    }
  }
}
