function defaultStatus() {
  return {
    ok: true,
    loaded: false,
    now: 0,
    rcloneInstalled: false,
    remoteConfigured: false,
    remotes: [],
    config: {},
    localDirExists: false,
    unitsInstalled: false,
    timerEnabled: false,
    timerActive: false,
    serviceState: "",
    running: false,
    current: null,
    lastRun: null,
    needsResync: false,
    nextRunAt: null,
    history: []
  }
}

function parseStatus(raw) {
  var text = String(raw || "").trim()
  if (text === "") return null
  try {
    var parsed = JSON.parse(text)
    if (!parsed || typeof parsed !== "object" || parsed.ok !== true) return null
    var base = defaultStatus()
    for (var key in parsed) base[key] = parsed[key]
    base.loaded = true
    return base
  } catch (e) {
    return null
  }
}

function stateOf(s) {
  if (!s || !s.loaded) return "loading"
  if (!s.rcloneInstalled) return "unavailable"
  if (!s.remoteConfigured) return "unconfigured"
  if (!s.localDirExists) return "missing-folder"
  if (s.running) return s.current && s.current.resync ? "resyncing" : "running"
  if (s.needsResync) return "needs-resync"
  if (s.lastRun && !s.lastRun.ok) return "error"
  if (!s.timerEnabled) return "paused"
  if (!s.lastRun) return "never"
  if (s.lastRun.errors && s.lastRun.errors.length > 0) return "warning"
  return "ok"
}

function isProblem(state) {
  return state === "unavailable" || state === "unconfigured" || state === "missing-folder"
      || state === "needs-resync" || state === "error"
}

function headline(s, nowMs) {
  var state = stateOf(s)
  switch (state) {
  case "loading": return "Lecture de l'état…"
  case "unavailable": return "rclone n'est pas installé"
  case "unconfigured": return "Distant rclone non configuré"
  case "missing-folder": return "Dossier local introuvable"
  case "resyncing": return "Resynchronisation en cours…"
  case "running": return runningLine(s)
  case "needs-resync": return "Resynchronisation requise"
  case "error": return "Dernière synchronisation échouée"
  case "paused": return "Synchronisation en pause"
  case "never": return "Aucune synchronisation encore"
  case "warning": return "Synchronisé avec avertissements · " + relativeTime(s.lastRun.endedAt, nowMs)
  default: return "À jour · " + relativeTime(s.lastRun.endedAt, nowMs)
  }
}

function runningLine(s) {
  var p = s.current ? s.current.progress : null
  if (!p) return "Synchronisation en cours… (analyse)"
  var parts = []
  var active = p.transferring ? p.transferring.length : 0
  if (active > 0) parts.push(active + (active > 1 ? " fichiers" : " fichier"))
  if (p.speed > 0) parts.push(formatSpeed(p.speed))
  if (parts.length === 0) return "Synchronisation en cours… (comparaison)"
  return "Transfert · " + parts.join(" · ")
}

function tooltip(s, nowMs) {
  return "Google Drive · " + headline(s, nowMs)
}

function formatBytes(bytes) {
  var value = Number(bytes || 0)
  if (!isFinite(value) || value <= 0) return "0 o"
  var units = ["o", "ko", "Mo", "Go", "To"]
  var index = 0
  while (value >= 1000 && index < units.length - 1) {
    value = value / 1000
    index++
  }
  var decimals = value >= 100 || index === 0 ? 0 : (value >= 10 ? 1 : 2)
  return value.toFixed(decimals).replace(".", ",").replace(/,0+$/, "").replace(/(,\d)0$/, "$1") + " " + units[index]
}

function formatSpeed(bytesPerSec) {
  return formatBytes(bytesPerSec) + "/s"
}

function formatDuration(sec) {
  var s = Math.max(0, Math.round(Number(sec || 0)))
  if (s < 60) return s + " s"
  var m = Math.floor(s / 60)
  s = s % 60
  if (m < 60) return m + " min" + (s > 0 ? " " + (s < 10 ? "0" : "") + s + " s" : "")
  var h = Math.floor(m / 60)
  m = m % 60
  return h + " h " + (m < 10 ? "0" : "") + m
}

function formatEta(sec) {
  if (sec === null || sec === undefined) return ""
  var s = Number(sec)
  if (!isFinite(s) || s < 0) return ""
  return "≈ " + formatDuration(s)
}

function relativeTime(timestampSec, nowMs) {
  var ts = Number(timestampSec || 0)
  if (!isFinite(ts) || ts <= 0) return "jamais"
  var now = nowMs === undefined ? Date.now() : Number(nowMs)
  var diff = Math.max(0, Math.floor((now - ts * 1000) / 1000))
  if (diff < 45) return "à l'instant"
  var minutes = Math.round(diff / 60)
  if (minutes < 60) return "il y a " + minutes + " min"
  var hours = Math.floor(minutes / 60)
  if (hours < 24) return "il y a " + hours + " h"
  var days = Math.floor(hours / 24)
  if (days < 30) return "il y a " + days + " j"
  return "il y a " + Math.floor(days / 30) + " mois"
}

function inTime(timestampSec, nowMs) {
  var ts = Number(timestampSec || 0)
  if (!isFinite(ts) || ts <= 0) return ""
  var now = nowMs === undefined ? Date.now() : Number(nowMs)
  var diff = Math.round((ts * 1000 - now) / 1000)
  if (diff <= 5) return "imminente"
  return "dans " + formatDuration(diff)
}

function formatClock(timestampSec) {
  var ts = Number(timestampSec || 0)
  if (!isFinite(ts) || ts <= 0) return ""
  var d = new Date(ts * 1000)
  var hh = d.getHours()
  var mm = d.getMinutes()
  return (hh < 10 ? "0" : "") + hh + ":" + (mm < 10 ? "0" : "") + mm
}

function basename(path) {
  var value = String(path || "")
  var trimmed = value.replace(/\/+$/, "")
  var index = trimmed.lastIndexOf("/")
  return index >= 0 ? trimmed.substring(index + 1) : trimmed
}

function dirname(path) {
  var value = String(path || "").replace(/\/+$/, "")
  var index = value.lastIndexOf("/")
  return index > 0 ? value.substring(0, index) : "/"
}

function shortenPath(path, home) {
  var value = String(path || "")
  if (home && value.indexOf(home) === 0) return "~" + value.substring(home.length)
  return value
}

function fileLabel(file) {
  if (!file) return ""
  var parts = []
  if (file.direction === "down") parts.push("↓")
  else if (file.direction === "up") parts.push("↑")
  return parts.join("")
}

function actionLabel(action) {
  var a = String(action || "")
  if (a.indexOf("Copied (new)") === 0) return "nouveau"
  if (a.indexOf("Copied") === 0) return "mis à jour"
  if (a.indexOf("Deleted") === 0 || a.indexOf("Removed") === 0) return "supprimé"
  if (a.indexOf("Updated modification time") === 0) return "date modifiée"
  if (a.indexOf("Moved") === 0 || a.indexOf("Renamed") === 0) return "déplacé"
  return a
}

function countsSummary(counts) {
  if (!counts) return ""
  var parts = []
  if (counts.uploaded) parts.push("↑ " + counts.uploaded)
  if (counts.downloaded) parts.push("↓ " + counts.downloaded)
  if (counts.deleted) parts.push("✕ " + counts.deleted)
  return parts.length ? parts.join("  ") : "aucun changement"
}

function errorText(err) {
  if (!err) return ""
  var msg = String(err.msg || "").replace(/\s+/g, " ").trim()
  var obj = String(err.object || "")
  var count = Number(err.count || 1)
  var suffix = count > 1 ? " (×" + count + ")" : ""
  if (obj !== "" && count === 1) return obj + " — " + msg
  return msg + suffix
}

function progressFraction(p) {
  if (!p) return 0
  var total = Number(p.totalBytes || 0)
  if (total <= 0) return 0
  return Math.max(0, Math.min(1, Number(p.bytes || 0) / total))
}
