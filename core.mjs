// The sync itself: merges the Claude desktop app's per-account Code session
// lists so every account's sidebar shows every session.
//
// Each Code session's transcript lives in ~/.claude/projects, shared by all
// accounts; the sidebar lists it only for the account that made it, through
// a small file per session under
// <data dir>/claude-code-sessions/<account>/<org>/local_<id>.json.
//
// Nothing here reads, copies or changes a sign-in (Cookies, Keychain,
// tokens), and nothing goes over the network. While the app runs, the
// signed-in account's folder is left alone and only the others are written.

import crypto from "node:crypto"
import fs from "node:fs"
import os from "node:os"
import path from "node:path"
import { spawnSync } from "node:child_process"

export const BUNDLE_ID = "com.anthropic.claudefordesktop"
export const DATA_DIRS = ["Claude", "Claude-3p"]
const GATEWAY = "Claude-3p"
const APP_BINARY = "/Applications/Claude.app/Contents/MacOS/Claude"
const IDX = "archived-sessions.idx"
const KEEP_BACKUPS = 3
const LOCK_STALE_MS = 2 * 60 * 1000

// SESSION_SHARE_ROOT stands in a test's folder for the home folder.
export function defaults() {
  const home = process.env.SESSION_SHARE_ROOT || os.homedir()
  const support = path.join(home, "Library", "Application Support")
  return {
    home,
    support,
    projects: path.join(home, ".claude", "projects"),
    state: path.join(support, "session-share"),
  }
}

// A file not in the shape this tool knows: nothing is written.
export class FormatError extends Error {}

function list(dir, test) {
  try {
    return fs.readdirSync(dir).filter(test).sort()
  } catch {
    return []
  }
}

function readJson(file, fallback) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"))
  } catch {
    return fallback
  }
}

const sha = (buf) => crypto.createHash("sha256").update(buf).digest("hex")

// Sessions in a git worktree count as their repository's.
export function projectOf(cwd) {
  if (typeof cwd !== "string" || !cwd) return "(未知文件夹)"
  const i = cwd.indexOf("/.claude/worktrees/")
  return i >= 0 ? cwd.slice(0, i) : cwd
}

// ---- settings -----------------------------------------------------------------

// accounts: per account UUID, the name and email read from Claude Code's
// profile, and the user's own remark; projects: false for a project not to copy; terminal: true for a project
// whose terminal-only sessions to bring in.
export function loadSettings(state) {
  const s = readJson(path.join(state, "settings.json"), {})
  return { v: 1, accounts: {}, projects: {}, terminal: {}, ...s }
}

export function saveSettings(state, settings) {
  fs.mkdirSync(state, { recursive: true })
  writeAtomic(path.join(state, "settings.json"), JSON.stringify(settings, null, 2) + "\n")
}

// Names and emails from the profile Claude Code keeps in ~/.claude.json (and
// in the same file under other config folders). Only the profile is read.
export function learnAccounts(home, settings) {
  const files = [path.join(home, ".claude.json"), ...list(home, (n) => n.startsWith(".claude")).map((n) => path.join(home, n, ".claude.json"))]
  let changed = false
  for (const file of files) {
    const o = readJson(file, null)?.oauthAccount
    if (!o?.accountUuid) continue
    const cur = settings.accounts[o.accountUuid] ?? {}
    const name = o.displayName || o.fullName || ""
    const email = o.emailAddress || ""
    if (cur.name !== name || cur.email !== email) {
      settings.accounts[o.accountUuid] = { ...cur, name, email }
      changed = true
    }
  }
  return changed
}

// The user's remark, else the name Claude Code knows, else the account ID.
export function accountName(f, settings) {
  if (f.data === GATEWAY) return "网关模式"
  const a = settings.accounts[f.account]
  return a?.remark || a?.name || a?.email || `账号 ${f.account.slice(0, 8)}`
}

// The name with the email, or with the ID when there is no email.
export function accountDetail(f, settings) {
  const name = accountName(f, settings)
  if (f.data === GATEWAY) return name
  const email = settings.accounts[f.account]?.email
  const id = f.account.slice(0, 8)
  if (email) return email === name ? name : `${name}（${email}）`
  return name.endsWith(id) ? name : `${name}（${id}）`
}

// ---- reading ----------------------------------------------------------------

function sessionTime(data, file) {
  for (const key of ["lastActivityAt", "createdAt"]) {
    const v = data[key]
    if (Number.isInteger(v) && v > 0) return v
  }
  return Math.floor(fs.statSync(file).mtimeMs)
}

export function readFolder(folder, warnings) {
  const sessions = new Map()
  for (const name of list(folder, (n) => n.startsWith("local_") && n.endsWith(".json"))) {
    const file = path.join(folder, name)
    const sid = name.slice(0, -".json".length)
    let raw, data
    try {
      raw = fs.readFileSync(file)
      data = JSON.parse(raw.toString("utf8"))
    } catch (e) {
      warnings.push(`skipped unreadable ${file}: ${e.message}`)
      continue
    }
    if (!data || typeof data !== "object" || data.sessionId !== sid || typeof data.cliSessionId !== "string") {
      warnings.push(`skipped ${file}: not a session file this tool knows`)
      continue
    }
    sessions.set(sid, {
      raw,
      time: sessionTime(data, file),
      mtime: fs.statSync(file).mtimeMs,
      archived: Boolean(data.isArchived),
      cli: data.cliSessionId,
      project: projectOf(data.cwd),
    })
  }

  const tombstones = new Map()
  for (const name of list(folder, (n) => n.startsWith("deleted_"))) {
    const file = path.join(folder, name)
    const sid = "local_" + name.slice("deleted_".length)
    const ts = Number.parseInt(fs.readFileSync(file, "utf8").trim(), 10)
    tombstones.set(sid, Number.isFinite(ts) ? ts : Math.floor(fs.statSync(file).mtimeMs))
  }

  let archived = null
  const idxFile = path.join(folder, IDX)
  if (fs.existsSync(idxFile)) {
    let idx
    try {
      idx = JSON.parse(fs.readFileSync(idxFile, "utf8"))
    } catch (e) {
      throw new FormatError(`${idxFile} is not JSON: ${e.message}`)
    }
    if (!idx || idx.v !== 1 || !Array.isArray(idx.archived)) throw new FormatError(`${idxFile} has an unknown format (expected v1)`)
    archived = idx.archived
  }
  return { sessions, tombstones, archived }
}

// Every <data dir>/claude-code-sessions/<account>/<org>/ folder.
export function findFolders(support) {
  const out = []
  for (const data of DATA_DIRS) {
    const root = path.join(support, data)
    const base = path.join(root, "claude-code-sessions")
    for (const account of list(base, (n) => fs.statSync(path.join(base, n)).isDirectory())) {
      for (const org of list(path.join(base, account), (n) => fs.statSync(path.join(base, account, n)).isDirectory())) {
        out.push({ root, data, account, key: `${data}/${account}`, path: path.join(base, account, org) })
      }
    }
  }
  return out
}

export function signedInAccount(root) {
  return readJson(path.join(root, "config.json"), {}).lastKnownAccountUuid ?? null
}

export function claudeRunning() {
  const r = spawnSync("osascript", ["-e", `application id "${BUNDLE_ID}" is running`], { encoding: "utf8" })
  return r.stdout.trim() === "true"
}

// The data dirs the running app has open; all of them when unsure.
export function dataDirsInUse(support) {
  const ps = spawnSync("ps", ["-axo", "pid=,comm="], { encoding: "utf8" })
  const pids = ps.stdout
    .split("\n")
    .filter((l) => l.trim().endsWith(APP_BINARY))
    .map((l) => l.trim().split(/\s+/)[0])
  if (!pids.length) return new Set(DATA_DIRS)
  const lsof = spawnSync("lsof", ["-nP", "-Fn", "-p", pids.join(",")], { encoding: "utf8", timeout: 20000 })
  const used = new Set()
  for (const line of (lsof.stdout ?? "").split("\n")) {
    for (const data of DATA_DIRS) if (line.startsWith("n" + path.join(support, data) + "/")) used.add(data)
  }
  return used.size ? used : new Set(DATA_DIRS)
}

// Which account each session was made in: the folders holding it when this
// tool first saw it, before it copied it anywhere. Brought-in terminal
// sessions are marked "terminal".
function noteOrigins(state, folders, states) {
  const file = path.join(state, "origins.json")
  const origins = readJson(file, {})
  let changed = false
  const holders = new Map()
  folders.forEach((f, i) => {
    for (const [sid, s] of states[i].sessions) {
      if (!holders.has(sid)) holders.set(sid, new Set(sid === importId(s.cli) ? ["terminal"] : []))
      if (!holders.get(sid).has("terminal")) holders.get(sid).add(f.key)
    }
  })
  for (const [sid, keys] of holders) {
    if (origins[sid]) continue
    origins[sid] = [...keys]
    changed = true
  }
  if (changed) {
    fs.mkdirSync(state, { recursive: true })
    writeAtomic(file, JSON.stringify(origins))
  }
  return origins
}

// ---- terminal sessions --------------------------------------------------------

const HEAD_BYTES = 256 * 1024
const TAIL_BYTES = 64 * 1024
const CHUNK_BYTES = 4 * 1024 * 1024
const TITLES = [
  ["customTitle", Buffer.from('"type":"custom-title"')],
  ["aiTitle", Buffer.from('"type":"ai-title"')],
]

function readAt(fd, pos, len) {
  const buf = Buffer.alloc(len)
  return buf.subarray(0, fs.readSync(fd, buf, 0, len, pos))
}

function parseLine(text) {
  try {
    return JSON.parse(text)
  } catch {
    return null
  }
}

function userText(d) {
  if (d?.type !== "user" || d.isMeta || d.isSidechain) return null
  const c = d.message?.content
  const text = typeof c === "string" ? c : Array.isArray(c) ? c.filter((p) => p?.type === "text").map((p) => p.text).join("\n") : ""
  const t = text.trim()
  // command output and system wrappers start with a tag
  return t && !t.startsWith("<") ? t : null
}

// The last custom or AI title in a transcript, found without parsing every line.
function lastTitle(fd, size) {
  const found = {}
  let carry = Buffer.alloc(0)
  const scan = (body) => {
    for (const [key, marker] of TITLES) {
      const i = body.lastIndexOf(marker)
      if (i < 0) continue
      const start = body.lastIndexOf(10, i) + 1
      const end = body.indexOf(10, i)
      const d = parseLine(body.subarray(start, end < 0 ? body.length : end).toString("utf8"))
      if (d?.[key]) found[key] = d[key]
    }
  }
  for (let pos = 0; pos < size; pos += CHUNK_BYTES) {
    const buf = Buffer.concat([carry, readAt(fd, pos, Math.min(CHUNK_BYTES, size - pos))])
    const cut = buf.lastIndexOf(10)
    if (cut < 0) {
      carry = buf
      continue
    }
    scan(buf.subarray(0, cut))
    carry = buf.subarray(cut + 1)
  }
  scan(carry)
  return found.customTitle || found.aiTitle || null
}

// What the sidebar needs from one transcript, or null for one not to offer:
// sessions the desktop app made itself, and ones with nothing typed in them.
export function readTranscript(file) {
  const fd = fs.openSync(file, "r")
  try {
    const size = fs.fstatSync(fd).size
    let cwd = null, entry = null, first = null, start = null, end = null
    for (const line of readAt(fd, 0, Math.min(HEAD_BYTES, size)).toString("utf8").split("\n")) {
      const d = parseLine(line)
      if (!d) continue
      cwd ??= typeof d.cwd === "string" ? d.cwd : null
      entry ??= d.entrypoint ?? null
      first ??= userText(d)
      if (d.timestamp) start ??= Date.parse(d.timestamp) || null
    }
    if (!cwd || !first || entry === "claude-desktop") return null
    for (const line of readAt(fd, Math.max(0, size - TAIL_BYTES), Math.min(TAIL_BYTES, size)).toString("utf8").split("\n")) {
      const t = parseLine(line)?.timestamp
      if (t) end = Date.parse(t) || end
    }
    const title = lastTitle(fd, size) || first.replace(/\s+/g, " ").slice(0, 50)
    return { cwd, entry, title, createdAt: start ?? end ?? Date.now(), lastActivityAt: end ?? start ?? Date.now() }
  } finally {
    fs.closeSync(fd)
  }
}

// Every transcript in ~/.claude/projects worth offering; results are cached
// by size and modification time, since some transcripts run to hundreds of MB.
export function scanTerminal(projects, state) {
  const cacheFile = path.join(state, "terminal-cache.json")
  const cache = readJson(cacheFile, {})
  const next = {}
  const out = []
  for (const dir of list(projects, () => true)) {
    for (const name of list(path.join(projects, dir), (n) => n.endsWith(".jsonl"))) {
      const file = path.join(projects, dir, name)
      let st
      try {
        st = fs.statSync(file)
      } catch {
        continue
      }
      let hit = cache[file]
      if (!hit || hit.size !== st.size || hit.mtimeMs !== st.mtimeMs) {
        let info = null
        try {
          info = readTranscript(file)
        } catch {}
        hit = { size: st.size, mtimeMs: st.mtimeMs, info }
      }
      next[file] = hit
      if (hit.info) out.push({ ...hit.info, cli: name.slice(0, -".jsonl".length), project: projectOf(hit.info.cwd) })
    }
  }
  if (JSON.stringify(next) !== JSON.stringify(cache)) {
    fs.mkdirSync(state, { recursive: true })
    writeAtomic(cacheFile, JSON.stringify(next))
  }
  return out
}

// The same sidebar id for a transcript in every folder and on every run.
export function importId(cli) {
  const h = crypto.createHash("sha1").update("session-share:" + cli).digest("hex")
  const variant = ((Number.parseInt(h[16], 16) & 3) | 8).toString(16)
  return `local_${h.slice(0, 8)}-${h.slice(8, 12)}-5${h.slice(13, 16)}-${variant}${h.slice(17, 20)}-${h.slice(20, 32)}`
}

function importRecord(sid, t) {
  const data = {
    sessionId: sid,
    cliSessionId: t.cli,
    cwd: t.cwd,
    originCwd: t.cwd,
    title: t.title,
    titleSource: "auto",
    createdAt: t.createdAt,
    lastActivityAt: t.lastActivityAt,
    isArchived: false,
    permissionMode: "default",
  }
  return { raw: Buffer.from(JSON.stringify(data)), time: t.lastActivityAt, mtime: 0, archived: false, cli: t.cli, project: t.project, imported: true }
}

// ---- merging ----------------------------------------------------------------

// The newest copy of every session, and the sessions deleted for good.
export function merge(states) {
  const winners = new Map()
  for (const st of states) {
    for (const [sid, s] of st.sessions) {
      const best = winners.get(sid)
      if (!best || s.time > best.time || (s.time === best.time && s.mtime > best.mtime)) winners.set(sid, s)
    }
  }
  const deleted = new Map()
  for (const st of states) for (const [sid, ts] of st.tombstones) deleted.set(sid, Math.max(ts, deleted.get(sid) ?? 0))
  // a session used again after it was deleted somewhere stays
  for (const [sid, ts] of deleted) if (winners.has(sid) && winners.get(sid).time > ts) deleted.delete(sid)
  for (const sid of deleted.keys()) winners.delete(sid)
  return { winners, deleted }
}

// The writes that bring one folder up to the merged list. allow(session)
// says whether a session the folder lacks may be added; sessions it has are
// kept up to date either way.
export function planFolder(folder, state, winners, deleted, allow = () => true) {
  const ops = []
  const present = []
  for (const sid of [...winners.keys()].sort()) {
    const w = winners.get(sid)
    const have = state.sessions.get(sid)
    if (!have) {
      if (!allow(w)) continue
      ops.push({ kind: "add", file: path.join(folder.path, sid + ".json"), body: w.raw })
    } else if (!have.raw.equals(w.raw)) ops.push({ kind: "update", file: path.join(folder.path, sid + ".json"), body: w.raw })
    present.push(sid)
  }
  for (const sid of [...deleted.keys()].sort()) {
    if (state.sessions.has(sid)) ops.push({ kind: "remove", file: path.join(folder.path, sid + ".json") })
    if (!state.tombstones.has(sid))
      ops.push({ kind: "tombstone", file: path.join(folder.path, "deleted_" + sid.slice("local_".length)), body: Buffer.from(String(deleted.get(sid))) })
  }
  const want = present.filter((sid) => winners.get(sid).archived)
  const have = [...(state.archived ?? [])].sort()
  if (JSON.stringify(want) !== JSON.stringify(have) && (want.length || state.archived !== null)) {
    ops.push({ kind: "archive-index", file: path.join(folder.path, IDX), body: Buffer.from(JSON.stringify({ v: 1, archived: want })) })
  }
  return ops
}

// ---- writing ----------------------------------------------------------------

function writeAtomic(file, body) {
  const tmp = path.join(path.dirname(file), `.session-share-${process.pid}-${Date.now()}`)
  try {
    fs.writeFileSync(tmp, body, { mode: 0o600 })
    fs.chmodSync(tmp, 0o600)
    fs.renameSync(tmp, file)
  } catch (e) {
    fs.rmSync(tmp, { force: true })
    throw e
  }
}

function backup(support, state) {
  const dir = path.join(state, "backups")
  fs.mkdirSync(dir, { recursive: true })
  const stamp = new Date().toISOString().replace(/[-:]/g, "").replace("T", "-").replace(".", "-").slice(0, 19)
  const file = path.join(dir, `sessions-${stamp}.tar.gz`)
  const parts = DATA_DIRS.filter((d) => fs.existsSync(path.join(support, d, "claude-code-sessions"))).map((d) => path.join(d, "claude-code-sessions"))
  const r = spawnSync("tar", ["-czf", file, "-C", support, ...parts], { encoding: "utf8" })
  if (r.status !== 0) throw new Error(`backup failed: ${r.stderr.trim()}`)
  for (const old of list(dir, (n) => n.startsWith("sessions-") && n.endsWith(".tar.gz")).slice(0, -KEEP_BACKUPS)) fs.rmSync(path.join(dir, old))
  return file
}

// One writer at a time.
function lock(state) {
  fs.mkdirSync(state, { recursive: true })
  const file = path.join(state, "lock")
  try {
    fs.writeFileSync(file, String(process.pid), { flag: "wx" })
  } catch {
    const age = Date.now() - fs.statSync(file).mtimeMs
    if (age < LOCK_STALE_MS) return null
    fs.writeFileSync(file, String(process.pid))
  }
  return () => fs.rmSync(file, { force: true })
}

// ---- the run ----------------------------------------------------------------

// run merges every folder and writes what it may.
//   write:         false for a dry run
//   includeActive: write the signed-in account's folder too (the app is closed)
//   running/inUse: given by tests; otherwise asked of the system
// It returns a report:
//   sessions, deleted, written, backup, warnings, missing, imports
//   folders:  [{key, data, account, name, detail, signedIn, have, active, counts}]
//   projects: Map project -> {sessions, latest, from: Map(origin -> n), terminal, terminalLatest}
//   settings
export function run(opts = {}) {
  const o = { ...defaults(), ...opts }
  const { support, projects, state } = o
  const write = opts.write ?? false
  const settings = loadSettings(state)
  if (learnAccounts(o.home, settings)) saveSettings(state, settings)
  const report = { sessions: 0, deleted: 0, folders: [], written: 0, backup: null, warnings: [], missing: 0, imports: 0, projects: new Map(), settings }
  const folders = findFolders(support)
  if (!folders.length) return report

  const running = opts.running ?? claudeRunning()
  if (write && opts.includeActive && running) throw new Error("Claude 还在运行，请先退出")

  const states = folders.map((f) => readFolder(f.path, report.warnings))
  const { winners, deleted } = merge(states)
  const origins = noteOrigins(state, folders, states)
  const group = (p) => {
    if (!report.projects.has(p)) report.projects.set(p, { sessions: 0, latest: 0, from: new Map(), terminal: 0, terminalLatest: 0 })
    return report.projects.get(p)
  }
  for (const [sid, w] of winners) {
    const g = group(w.project)
    g.sessions++
    g.latest = Math.max(g.latest, w.time)
    for (const k of origins[sid] ?? []) g.from.set(k, (g.from.get(k) ?? 0) + 1)
  }

  // terminal-only sessions, for the projects ticked for them
  const known = new Set(states.flatMap((st) => [...st.sessions.values()].map((s) => s.cli)))
  for (const t of scanTerminal(projects, state)) {
    const sid = importId(t.cli)
    if (known.has(t.cli) || deleted.has(sid) || winners.has(sid)) continue
    const g = group(t.project)
    g.terminal++
    g.terminalLatest = Math.max(g.terminalLatest, t.lastActivityAt)
    if (settings.terminal[t.project] !== true) continue
    winners.set(sid, importRecord(sid, t))
    report.imports++
  }

  report.sessions = winners.size
  report.deleted = deleted.size
  const transcripts = new Set(list(projects, () => true).flatMap((d) => list(path.join(projects, d), (n) => n.endsWith(".jsonl")).map((n) => n.slice(0, -6))))
  for (const w of winners.values()) if (!transcripts.has(w.cli)) report.missing++

  const allow = (w) => w.imported || settings.projects[w.project] !== false
  const inUse = running && !opts.includeActive ? opts.inUse ?? dataDirsInUse(support) : new Set()
  const todo = []
  for (let i = 0; i < folders.length; i++) {
    const f = folders[i]
    const signedIn = f.account === signedInAccount(f.root)
    const active = inUse.has(f.data) && signedIn
    const ops = planFolder(f, states[i], winners, deleted, allow)
    const counts = {}
    for (const op of ops) counts[op.kind] = (counts[op.kind] ?? 0) + 1
    report.folders.push({ key: f.key, data: f.data, account: f.account, name: accountName(f, settings), detail: accountDetail(f, settings), signedIn, have: states[i].sessions.size, active, counts })
    if (!active) todo.push(...ops)
  }
  if (!write || !todo.length) return report

  const release = lock(state)
  if (!release) {
    report.warnings.push("another sync is running; skipped")
    return report
  }
  try {
    report.backup = backup(support, state)
    // what each touched file holds afterwards, for undo
    const ops = todo.map((op) => ({ file: path.relative(support, op.file), after: op.kind === "remove" ? null : sha(op.body) }))
    writeAtomic(path.join(state, "last-run.json"), JSON.stringify({ at: Date.now(), backup: report.backup, ops }))
    for (const op of todo) {
      if (op.kind === "remove") fs.rmSync(op.file, { force: true })
      else writeAtomic(op.file, op.body)
    }
    report.written = todo.length
  } finally {
    release()
  }
  return report
}

// ---- undo -------------------------------------------------------------------

export function lastRun(opts = {}) {
  const { state } = { ...defaults(), ...opts }
  const last = readJson(path.join(state, "last-run.json"), null)
  return last && fs.existsSync(last.backup) ? last : null
}

// undo puts back what the last merge changed, from the backup it took first.
// A file changed again since then is left as it is. The app must be closed.
export function undo(opts = {}) {
  const { support, state } = { ...defaults(), ...opts }
  if (opts.running ?? claudeRunning()) throw new Error("Claude 还在运行，请先退出")
  const last = lastRun(opts)
  if (!last) throw new Error("没有可以撤销的合并")
  const release = lock(state)
  if (!release) throw new Error("另一个合并正在进行")
  const tmp = fs.mkdtempSync(path.join(state, "undo-"))
  try {
    const r = spawnSync("tar", ["-xzf", last.backup, "-C", tmp], { encoding: "utf8" })
    if (r.status !== 0) throw new Error(`读取备份失败：${r.stderr.trim()}`)
    const safety = backup(support, state)
    let restored = 0, kept = 0
    for (const op of last.ops) {
      const file = path.join(support, op.file)
      const now = fs.existsSync(file) ? sha(fs.readFileSync(file)) : null
      if (now !== op.after) {
        kept++
        continue
      }
      const before = path.join(tmp, op.file)
      if (fs.existsSync(before)) writeAtomic(file, fs.readFileSync(before))
      else fs.rmSync(file, { force: true })
      restored++
    }
    fs.rmSync(path.join(state, "last-run.json"), { force: true })
    return { restored, kept, backup: safety }
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true })
    release()
  }
}

// showAll quits the app, writes every folder, and opens it again.
export async function showAll(opts = {}) {
  if (claudeRunning()) {
    spawnSync("osascript", ["-e", `tell application id "${BUNDLE_ID}" to quit`])
    let i = 0
    while (claudeRunning()) {
      if (++i > 60) throw new Error("Claude 没有退出，没有写入任何文件")
      await new Promise((r) => setTimeout(r, 500))
    }
    await new Promise((r) => setTimeout(r, 1000))
  }
  try {
    return run({ ...opts, write: true, includeActive: true, running: false })
  } finally {
    spawnSync("open", ["-b", BUNDLE_ID])
  }
}
