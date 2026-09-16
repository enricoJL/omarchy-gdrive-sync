import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "com.github.enricojl.gdrive-sync"
  ipcTarget: "com.github.enricojl.gdrive-sync"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color accent: Color.accent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  property bool cursorActive: false
  property int actionIndex: 0
  property int browseIndex: -1
  property double nowMs: Date.now()

  readonly property string state: sync.state
  readonly property bool problem: sync.problem
  readonly property color stateColor: problem ? urgent : (sync.running ? accent : (state === "paused" ? dim : foreground))
  readonly property color barIconColor: problem ? urgent : (state === "paused" || !sync.status.loaded ? Qt.darker(barForeground, 1.55) : barForeground)
  readonly property color dotColor: problem ? urgent : (sync.running ? accent : dim)
  readonly property bool dotVisible: problem || sync.running || state === "paused"

  readonly property var errors: sync.running && sync.status.current ? (sync.status.current.errors || []) : (sync.lastRun ? (sync.lastRun.errors || []) : [])
  readonly property var warnings: sync.lastRun ? (sync.lastRun.warnings || []) : []
  readonly property var recentFiles: {
    var source = sync.running && sync.status.current ? (sync.status.current.files || []) : (sync.lastRun ? (sync.lastRun.files || []) : [])
    var out = []
    for (var i = source.length - 1; i >= 0 && out.length < 10; i--) out.push(source[i])
    return out
  }
  readonly property var history: sync.status.history || []

  readonly property var actions: {
    var list = []
    var canSync = sync.usable && sync.status.localDirExists && !sync.running && !sync.busy
    if (sync.running) list.push({ key: "cancel", icon: "", label: "Annuler la synchronisation", hint: "c", enabled: !sync.busy })
    else list.push({ key: "sync", icon: "", label: "Synchroniser maintenant", hint: "s", enabled: canSync })
    if (!sync.running && (sync.needsResync || state === "error")) {
      list.push({ key: "resync", icon: "", label: "Resynchroniser (--resync)", hint: "r", enabled: canSync })
    }
    list.push({ key: "open", icon: "", label: "Ouvrir le dossier local", hint: "o", enabled: sync.status.localDirExists })
    list.push({ key: "folder", icon: "", label: "Choisir le dossier à synchroniser…", hint: "f", enabled: !sync.busy })
    return list
  }

  readonly property string problemTitle: {
    switch (state) {
    case "unavailable": return "rclone est introuvable"
    case "unconfigured": return "Distant « " + sync.remote + " » absent de la configuration rclone"
    case "missing-folder": return "Le dossier local n'existe pas"
    case "needs-resync": return "Resynchronisation requise"
    case "error": return "La dernière synchronisation a échoué"
    default: return ""
    }
  }
  readonly property string problemDetail: {
    switch (state) {
    case "unavailable": return "Installez-le avec : omarchy pkg add rclone"
    case "unconfigured": return "Lancez « rclone config » dans un terminal pour créer le distant Google Drive."
    case "missing-folder": return Model.shortenPath(sync.configuredDir, sync.home) + " — choisissez un autre dossier ou créez-le."
    case "needs-resync":
      return "rclone bisync doit reconstruire ses listes (première synchronisation, changement de dossier ou erreur critique). " +
             "La resynchronisation fusionne les deux côtés : les fichiers présents d'un seul côté sont copiés, le plus récent l'emporte en cas de différence."
    case "error": return sync.lastRun && sync.lastRun.headline ? sync.lastRun.headline : ""
    default: return ""
    }
  }

  function ensureCursor() {
    if (sync.browsing) {
      var max = sync.browse.dirs ? sync.browse.dirs.length - 1 : -1
      if (browseIndex > max) browseIndex = max
      if (browseIndex < -1) browseIndex = -1
    } else {
      if (actionIndex >= actions.length) actionIndex = Math.max(0, actions.length - 1)
      if (actionIndex < 0) actionIndex = 0
    }
  }

  function moveCursor(dy) {
    cursorActive = true
    ensureCursor()
    if (dy === 0) return
    if (sync.browsing) {
      var max = sync.browse.dirs ? sync.browse.dirs.length - 1 : -1
      var min = sync.browse.parent ? -1 : 0
      browseIndex = Math.max(min, Math.min(max, browseIndex + dy))
      scrollCursorIntoView()
    } else {
      actionIndex = Math.max(0, Math.min(actions.length - 1, actionIndex + dy))
    }
  }

  function activateCursor() {
    ensureCursor()
    if (sync.browsing) {
      if (browseIndex === -1) sync.browseUp()
      else if (sync.browse.dirs && sync.browse.dirs[browseIndex]) {
        sync.loadDirs(sync.browse.dirs[browseIndex].path)
        browseIndex = -1
      }
      return
    }
    if (actions[actionIndex]) runAction(actions[actionIndex].key)
  }

  function runAction(key) {
    switch (key) {
    case "sync": sync.syncNow(); break
    case "cancel": sync.cancel(); break
    case "resync": sync.resync(); break
    case "open": sync.openFolder(); break
    case "folder": browseIndex = -1; sync.startBrowse(); break
    }
  }

  function scrollItemIntoView(item) {
    if (!panelFlick || !item) return
    Qt.callLater(function() {
      if (!item) return
      var margin = Style.space(6)
      var point = item.mapToItem(panelFlick.contentItem, 0, 0)
      var top = point.y
      var bottom = top + item.height
      var viewTop = panelFlick.contentY
      var viewBottom = viewTop + panelFlick.height
      var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      if (top < viewTop + margin) panelFlick.contentY = Math.max(0, top - margin)
      else if (bottom > viewBottom - margin) panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
    })
  }

  function scrollCursorIntoView() {
    if (!sync.browsing || !dirColumn) return
    var idx = browseIndex + 1
    if (idx >= 0 && idx < dirColumn.children.length) scrollItemIntoView(dirColumn.children[idx])
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    cursorActive = false
    nowMs = Date.now()
    if (panelFlick) panelFlick.contentY = 0
    sync.refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  } else {
    sync.stopBrowse()
  }

  Service {
    id: sync
    settings: root.settings
    moduleName: root.moduleName
    panelOpen: root.opened
    onStatusChanged: root.nowMs = Date.now()
    onBrowsingChanged: {
      root.browseIndex = -1
      if (panelFlick) panelFlick.contentY = 0
      if (!browsing) Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    }
  }

  Timer {
    interval: 20000
    repeat: true
    running: root.opened
    onTriggered: root.nowMs = Date.now()
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { sync.refresh(); return "ok" }
    function syncNow(): string { sync.syncNow(); return "ok" }
    function resync(): string { sync.resync(); return "ok" }
    function pause(): string { sync.pause(); return "ok" }
    function resume(): string { sync.resume(); return "ok" }
    function status(): string { return root.state + " · " + Model.headline(sync.status, Date.now()) }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: Model.tooltip(sync.status, root.nowMs)
    iconComponent: Component {
      Item {
        DriveIcon {
          id: barIcon
          anchors.centerIn: parent
          iconSize: Style.space(12)
          color: root.barIconColor
          dotVisible: root.dotVisible
          dotColor: root.dotColor

          SequentialAnimation on opacity {
            running: sync.running
            loops: Animation.Infinite
            NumberAnimation { to: 0.35; duration: 700; easing.type: Easing.InOutQuad }
            NumberAnimation { to: 1.0; duration: 700; easing.type: Easing.InOutQuad }
            onRunningChanged: if (!running) barIcon.opacity = 1.0
          }
        }
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) sync.syncNow()
      else if (buttonCode === Qt.MiddleButton) sync.openFolder()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight((sync.browsing ? browseColumn.implicitHeight : column.implicitHeight), Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; root.ensureCursor(); return }
        root.moveCursor(dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: sync.browsing ? sync.stopBrowse() : root.close()
      onDeleteRequested: if (sync.browsing) sync.browseUp()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        var k = String(t).toLowerCase()
        if (sync.browsing) {
          if (k === "u") sync.chooseFolder(sync.browse.path)
          return
        }
        if (k === "s" && !sync.running) sync.syncNow()
        else if (k === "c" && sync.running) sync.cancel()
        else if (k === "r" && !sync.running && (sync.needsResync || root.state === "error")) sync.resync()
        else if (k === "p") sync.toggleTimer()
        else if (k === "o") sync.openFolder()
        else if (k === "f") root.runAction("folder")
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: sync.browsing ? browseColumn.implicitHeight : column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        // ------------------------------------------------------------ main view
        Column {
          id: column
          visible: !sync.browsing
          width: panelFlick.width
          spacing: Style.space(12)

          PanelHero {
            id: hero
            width: parent.width
            title: "Google Drive"
            meta: Model.headline(sync.status, root.nowMs)
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: sync.timerEnabled || sync.running ? 1.0 : 0.5
            iconComponent: Component {
              DriveIcon {
                iconSize: Style.font.display
                color: root.stateColor
              }
            }
            trailingControl: Component {
              ToggleSwitch {
                id: timerSwitch
                visible: sync.status.loaded && sync.usable
                checked: sync.timerEnabled
                busy: sync.busy
                foreground: hero.foreground
                onToggled: sync.toggleTimer()

                PanelToolTip {
                  visible: timerSwitch.containsMouse
                  text: sync.timerEnabled ? "Mettre en pause la synchronisation automatique" : "Reprendre la synchronisation automatique"
                  fontFamily: hero.fontFamily
                }
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: sync.actionStatus !== "" || sync.helperError !== ""
            width: parent.width
            text: sync.actionStatus !== "" ? sync.actionStatus : sync.helperError
            color: sync.helperError !== "" && sync.actionStatus === "" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.Wrap
          }

          // Problem banner
          Rectangle {
            visible: root.problem
            width: parent.width
            implicitHeight: problemColumn.implicitHeight + Style.space(20)
            radius: Style.cornerRadius
            color: Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.12)
            border.width: 1
            border.color: Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.5)

            Column {
              id: problemColumn
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.margins: Style.space(10)
              spacing: Style.space(6)

              RowLayout {
                width: parent.width
                spacing: Style.space(8)
                Text {
                  text: ""
                  color: root.urgent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.icon
                }
                Text {
                  Layout.fillWidth: true
                  textFormat: Text.PlainText
                  text: root.problemTitle
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.subtitle
                  font.bold: true
                  wrapMode: Text.Wrap
                }
              }

              Text {
                visible: root.problemDetail !== ""
                width: parent.width
                textFormat: Text.PlainText
                text: root.problemDetail
                color: root.foreground
                opacity: 0.8
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.Wrap
              }

              Button {
                visible: root.state === "needs-resync" || root.state === "error"
                text: root.state === "needs-resync" ? "Resynchroniser maintenant" : "Réessayer"
                iconText: ""
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                enabled: !sync.running && !sync.busy
                onClicked: root.state === "needs-resync" ? sync.resync() : sync.syncNow()
              }

              Button {
                visible: root.state === "missing-folder"
                text: "Choisir un dossier…"
                iconText: ""
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.runAction("folder")
              }
            }
          }

          // Live progress
          Column {
            visible: sync.running
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              text: sync.status.current && sync.status.current.resync ? "RESYNCHRONISATION EN COURS" : "SYNCHRONISATION EN COURS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Rectangle {
              width: parent.width
              height: Style.space(6)
              radius: height / 2
              color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.15)
              Rectangle {
                height: parent.height
                radius: parent.radius
                color: root.accent
                width: sync.progress && sync.progress.totalBytes > 0
                       ? parent.width * Model.progressFraction(sync.progress)
                       : parent.width * 0.25
                x: sync.progress && sync.progress.totalBytes > 0 ? 0 : scanPos.pos
                Behavior on width { NumberAnimation { duration: 400 } }
              }
              Item {
                id: scanPos
                property real pos: 0
                SequentialAnimation on pos {
                  running: sync.running && !(sync.progress && sync.progress.totalBytes > 0)
                  loops: Animation.Infinite
                  NumberAnimation { from: 0; to: panelFlick.width * 0.75; duration: 1200; easing.type: Easing.InOutQuad }
                  NumberAnimation { from: panelFlick.width * 0.75; to: 0; duration: 1200; easing.type: Easing.InOutQuad }
                }
              }
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: {
                var p = sync.progress
                var elapsed = sync.status.current ? Model.formatDuration(sync.status.current.elapsedSec) : ""
                if (!p) return "Analyse des deux côtés… · " + elapsed
                var parts = []
                if (p.totalBytes > 0) parts.push(Model.formatBytes(p.bytes) + " / " + Model.formatBytes(p.totalBytes))
                if (p.totalTransfers > 0) parts.push(p.transfers + "/" + p.totalTransfers + " fichiers")
                if (p.totalChecks > 0) parts.push(p.checks + "/" + p.totalChecks + " vérifiés")
                if (p.speed > 0) parts.push(Model.formatSpeed(p.speed))
                var eta = Model.formatEta(p.eta)
                if (eta) parts.push(eta)
                if (p.errors > 0) parts.push(p.errors + " erreur" + (p.errors > 1 ? "s" : ""))
                parts.push(elapsed)
                return parts.join(" · ")
              }
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.Wrap
            }

            Repeater {
              model: sync.progress ? sync.progress.transferring : []
              delegate: RowLayout {
                required property var modelData
                width: parent.width
                spacing: Style.space(8)
                Text {
                  Layout.fillWidth: true
                  textFormat: Text.PlainText
                  text: modelData.name
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideMiddle
                }
                Text {
                  textFormat: Text.PlainText
                  text: (modelData.percentage || 0) + " %" + (modelData.speed > 0 ? " · " + Model.formatSpeed(modelData.speed) : "")
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }

          // Info
          Column {
            visible: sync.status.loaded
            width: parent.width
            spacing: Style.spacing.labelGap

            InfoPair { label: "Dossier local"; value: Model.shortenPath(sync.configuredDir, sync.home) }
            InfoPair { label: "Distant"; value: sync.status.config && sync.status.config.remote ? sync.status.config.remote : sync.remote }
            InfoPair { label: "Intervalle"; value: "toutes les " + Model.formatDuration(sync.status.config && sync.status.config.intervalSec ? sync.status.config.intervalSec : sync.intervalSec) }
            InfoPair {
              visible: sync.timerEnabled && !sync.running
              label: "Prochaine synchro"
              value: sync.status.nextRunAt ? Model.inTime(sync.status.nextRunAt, root.nowMs) : "en attente"
            }
            InfoPair {
              visible: !!sync.lastRun
              label: "Dernière synchro"
              value: sync.lastRun ? Model.formatClock(sync.lastRun.endedAt) + " · " + Model.formatDuration(sync.lastRun.durationSec) + " · " + (sync.lastRun.ok ? Model.countsSummary(sync.lastRun.counts) : "échec") : ""
            }
          }

          PanelSeparator { foreground: root.foreground }

          // Actions
          Column {
            width: parent.width
            spacing: Style.space(4)

            Repeater {
              model: root.actions
              delegate: ActionRow {
                required property var modelData
                required property int index
                width: parent.width
                action: modelData
                rowIndex: index
              }
            }
          }

          // Errors
          Column {
            visible: root.errors.length > 0
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              text: "PROBLÈMES (" + root.errors.length + ")"
              foreground: root.urgent
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.errors.slice(0, 8)
              delegate: Text {
                required property var modelData
                width: parent.width
                textFormat: Text.PlainText
                text: "• " + Model.errorText(modelData)
                color: root.foreground
                opacity: 0.85
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.Wrap
                maximumLineCount: 3
                elide: Text.ElideRight
              }
            }

            Text {
              visible: root.errors.length > 8
              width: parent.width
              textFormat: Text.PlainText
              text: "… et " + (root.errors.length - 8) + " autres (voir " + (sync.lastRun ? Model.shortenPath(sync.lastRun.log, sync.home) : "le journal") + ")"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.Wrap
            }
          }

          // Warnings
          Column {
            visible: root.warnings.length > 0 && !sync.running
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              text: "AVERTISSEMENTS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.warnings.slice(0, 3)
              delegate: Text {
                required property var modelData
                width: parent.width
                textFormat: Text.PlainText
                text: "• " + Model.errorText(modelData)
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.Wrap
                maximumLineCount: 3
                elide: Text.ElideRight
              }
            }
          }

          // Recent files
          Column {
            visible: root.recentFiles.length > 0
            width: parent.width
            spacing: Style.space(4)

            PanelSectionHeader {
              text: sync.running ? "FICHIERS TRAITÉS" : "DERNIERS FICHIERS SYNCHRONISÉS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.recentFiles
              delegate: RowLayout {
                required property var modelData
                width: parent.width
                spacing: Style.space(8)
                Text {
                  textFormat: Text.PlainText
                  text: modelData.direction === "down" ? "" : ""
                  color: modelData.action.indexOf("Deleted") === 0 ? root.urgent : root.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  Layout.preferredWidth: Style.space(12)
                }
                ColumnLayout {
                  Layout.fillWidth: true
                  spacing: 0
                  Text {
                    Layout.fillWidth: true
                    textFormat: Text.PlainText
                    text: Model.basename(modelData.path)
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    elide: Text.ElideMiddle
                  }
                  Text {
                    Layout.fillWidth: true
                    textFormat: Text.PlainText
                    text: Model.actionLabel(modelData.action) + (Model.dirname(modelData.path) !== "/" ? " · " + Model.dirname(modelData.path) : "")
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideMiddle
                  }
                }
              }
            }
          }

          // History
          Column {
            visible: root.history.length > 0
            width: parent.width
            spacing: Style.space(4)

            PanelSectionHeader {
              text: "HISTORIQUE"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.history.slice(0, 6)
              delegate: RowLayout {
                required property var modelData
                width: parent.width
                spacing: Style.space(8)
                Text {
                  textFormat: Text.PlainText
                  text: modelData.ok ? "" : ""
                  color: modelData.ok ? root.accent : root.urgent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  Layout.preferredWidth: Style.space(12)
                }
                Text {
                  textFormat: Text.PlainText
                  text: Model.formatClock(modelData.endedAt)
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
                Text {
                  Layout.fillWidth: true
                  textFormat: Text.PlainText
                  text: (modelData.resync ? "resync · " : "") + Model.formatDuration(modelData.durationSec) + " · "
                        + (modelData.ok ? Model.countsSummary(modelData.counts) : (modelData.headline || "échec"))
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }
            }
          }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: "s synchroniser · p pause/reprise · o ouvrir · f dossier" + (sync.needsResync || root.state === "error" ? " · r resync" : "")
            color: root.dim
            opacity: 0.7
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
          }
        }

        // ------------------------------------------------------------ folder chooser
        Column {
          id: browseColumn
          visible: sync.browsing
          width: panelFlick.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: "CHOISIR LE DOSSIER À SYNCHRONISER"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          TextField {
            id: pathField
            width: parent.width
            text: sync.browse.path || ""
            placeholderText: "/chemin/du/dossier"
            foreground: root.foreground
            font.family: root.fontFamily
            onAccepted: sync.chooseFolder(text)
            Keys.onEscapePressed: sync.stopBrowse()
          }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: "Entrez un chemin puis Entrée, ou naviguez ci-dessous. Le dossier est créé s'il n'existe pas."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.Wrap
          }

          Column {
            id: dirColumn
            width: parent.width
            spacing: Style.space(2)

            DirRow {
              visible: sync.browse.parent !== ""
              width: parent.width
              name: ".. (dossier parent)"
              glyph: ""
              rowIndex: -1
              onActivated: sync.browseUp()
            }

            Repeater {
              model: sync.browse.dirs || []
              delegate: DirRow {
                required property var modelData
                required property int index
                width: parent.width
                name: modelData.name
                glyph: ""
                rowIndex: index
                onActivated: { root.browseIndex = -1; sync.loadDirs(modelData.path) }
              }
            }

            Text {
              visible: (!sync.browse.dirs || sync.browse.dirs.length === 0) && !sync.browseLoading
              width: parent.width
              textFormat: Text.PlainText
              text: "Aucun sous-dossier"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignHCenter
            }
          }

          RowLayout {
            width: parent.width
            spacing: Style.space(8)

            Button {
              Layout.fillWidth: true
              text: "Utiliser " + (sync.browse.path ? Model.basename(sync.browse.path) || "/" : "ce dossier")
              iconText: ""
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              enabled: !sync.busy && sync.browse.path !== ""
              onClicked: sync.chooseFolder(sync.browse.path)
            }

            Button {
              text: "Annuler"
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: sync.stopBrowse()
            }
          }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: "Changer de dossier entraîne une resynchronisation (--resync) au prochain passage."
            color: root.dim
            opacity: 0.7
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.Wrap
          }
        }
      }
    }
  }

  component InfoPair: RowLayout {
    property string label: ""
    property string value: ""
    width: parent.width
    spacing: Style.space(8)

    Text {
      textFormat: Text.PlainText
      text: label
      color: root.foreground
      opacity: 0.6
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
    Item { Layout.fillWidth: true }
    Text {
      Layout.maximumWidth: panelFlick.width * 0.65
      textFormat: Text.PlainText
      text: value
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideMiddle
      horizontalAlignment: Text.AlignRight
    }
  }

  component ActionRow: CursorSurface {
    id: actionRow
    property var action: null
    property int rowIndex: 0
    readonly property bool actionEnabled: action ? action.enabled !== false : false

    hasCursor: root.cursorActive && !sync.browsing && root.actionIndex === rowIndex
    foreground: root.foreground
    opacity: actionEnabled ? 1.0 : 0.45
    implicitHeight: actionContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: actionRow.actionEnabled ? Qt.PointingHandCursor : Qt.ArrowCursor
      onEntered: { root.cursorActive = true; root.actionIndex = actionRow.rowIndex }
      onClicked: if (actionRow.actionEnabled) root.runAction(actionRow.action.key)
    }

    RowLayout {
      id: actionContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(10)

      Text {
        textFormat: Text.PlainText
        text: actionRow.action ? actionRow.action.icon : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.preferredWidth: Style.space(18)
        horizontalAlignment: Text.AlignHCenter
      }
      Text {
        Layout.fillWidth: true
        textFormat: Text.PlainText
        text: actionRow.action ? actionRow.action.label : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }
      Text {
        textFormat: Text.PlainText
        text: actionRow.action ? actionRow.action.hint : ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }

  component DirRow: CursorSurface {
    id: dirRow
    property string name: ""
    property string glyph: ""
    property int rowIndex: 0
    signal activated()

    hasCursor: root.cursorActive && sync.browsing && root.browseIndex === rowIndex
    foreground: root.foreground
    implicitHeight: dirContent.implicitHeight + Style.space(8)

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: { root.cursorActive = true; root.browseIndex = dirRow.rowIndex }
      onClicked: dirRow.activated()
    }

    RowLayout {
      id: dirContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        text: dirRow.glyph
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
      Text {
        Layout.fillWidth: true
        textFormat: Text.PlainText
        text: dirRow.name
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
      }
    }
  }
}
