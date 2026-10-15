import assert from "node:assert/strict"
import fs from "node:fs"
import os from "node:os"
import path from "node:path"
import { afterEach, beforeEach, test } from "node:test"
import { execFileSync } from "node:child_process"

const A = "aaaaaaaa-0000-0000-0000-000000000001"
const B = "bbbbbbbb-0000-0000-0000-000000000002"
const C3 = "cccccccc-0000-0000-0000-000000000003"

let home, support, projects, state, fa, fb
let core

beforeEach(async () => {
  home = fs.mkdtempSync(path.join(os.tmpdir(), "session-share-"))
  process.env.SESSION_SHARE_ROOT = home
  core = await import("./core.mjs")
  ;({ support, projects, state } = core.defaults())
  fs.mkdirSync(path.join(projects, "-proj"), { recursive: true })
  signedIn(A)
  fa = folder(A, "0a")
  fb = folder(B, "0b")
})

afterEach(() => fs.rmSync(home, { recursive: true, force: true }))

function folder(account, org, data = "Claude") {
  const p = path.join(support, data, "claude-code-sessions", account, org)
  fs.mkdirSync(p, { recursive: true })
  return p
}

function signedIn(account, data = "Claude", mode = "1p") {
  const root = path.join(support, data)
  fs.mkdirSync(root, { recursive: true })
  fs.writeFileSync(path.join(root, "config.json"), JSON.stringify({ lastKnownAccountUuid: account }))
  fs.writeFileSync(path.join(root, "claude_desktop_config.json"), JSON.stringify({ deploymentMode: mode }))
}

function session(dir, n, at, { archived = false, title = "t" } = {}) {
  const id = String(n).padStart(8, "0")
  const sid = `local_${id}-0000-0000-0000-000000000000`
  const cli = `${id}-cccc-0000-0000-000000000000`
  fs.writeFileSync(path.join(dir, sid + ".json"), JSON.stringify({ sessionId: sid, cliSessionId: cli, cwd: "/p", title, lastActivityAt: at, isArchived: archived }))
  fs.writeFileSync(path.join(projects, "-proj", cli + ".jsonl"), "")
  return sid
}

const names = (dir) => fs.readdirSync(dir).filter((n) => !n.startsWith(".")).sort()
const load = (file) => JSON.parse(fs.readFileSync(file, "utf8"))
const sync = (o = {}) => core.run({ write: true, running: false, ...o })
const settle = (patch) => core.saveSettings(state, { ...core.loadSettings(state), ...patch })
const cli = (...args) =>
  execFileSync(process.execPath, [path.join(import.meta.dirname, "cli.mjs"), ...args], { env: { ...process.env, SESSION_SHARE_ROOT: home }, encoding: "utf8" })

function transcript(cli, { cwd = "/t", entry = "cli", text = "hello there", title } = {}) {
  const lines = [
    { type: "user", cwd, entrypoint: entry, timestamp: "2026-10-01T00:00:00.000Z", message: { role: "user", content: text } },
    { type: "assistant", cwd, timestamp: "2026-10-01T00:05:00.000Z", message: { role: "assistant", content: [] } },
  ]
  if (title) lines.push({ type: "ai-title", aiTitle: title, sessionId: cli })
  fs.mkdirSync(path.join(projects, "-t"), { recursive: true })
  fs.writeFileSync(path.join(projects, "-t", cli + ".jsonl"), lines.map((l) => JSON.stringify(l)).join("\n") + "\n")
}

test("status writes nothing", () => {
  session(fa, 1, 100)
  const r = core.run({ write: false, running: false })
  assert.equal(r.written, 0)
  assert.deepEqual(names(fb), [])
})

test("sessions are merged both ways", () => {
  const s1 = session(fa, 1, 100)
  const s2 = session(fb, 2, 200)
  sync()
  assert.deepEqual(names(fa), names(fb))
  assert.ok(names(fb).includes(s1 + ".json"))
  assert.ok(names(fa).includes(s2 + ".json"))
})

test("the newer copy wins", () => {
  const sid = session(fa, 1, 100, { title: "old" })
  session(fb, 1, 300, { title: "new" })
  sync()
  assert.equal(load(path.join(fa, sid + ".json")).title, "new")
})

test("the signed-in folder is left alone while the app runs", () => {
  session(fa, 1, 100)
  const s2 = session(fb, 2, 200)
  const r = sync({ running: true, inUse: new Set(["Claude"]) })
  assert.ok(!names(fa).includes(s2 + ".json"))
  assert.equal(names(fb).length, 2)
  assert.equal(r.folders.find((f) => f.active).key, "Claude/" + A)
})

test("a data dir the app hasn't open is written while it runs", () => {
  const f3 = folder(C3, "00000000-0000-4000-8000-000000000001", "Claude-3p")
  signedIn(C3, "Claude-3p")
  const sid = session(fa, 1, 100)
  sync({ running: true, inUse: new Set(["Claude"]) })
  assert.ok(names(f3).includes(sid + ".json"))
})

test("a deletion spreads", () => {
  const sid = session(fa, 1, 100)
  fs.writeFileSync(path.join(fb, "deleted_" + sid.slice(6)), "500")
  sync()
  assert.ok(!names(fa).includes(sid + ".json"))
  assert.ok(names(fa).includes("deleted_" + sid.slice(6)))
})

test("a session used after its deletion stays", () => {
  const sid = session(fa, 1, 900)
  fs.writeFileSync(path.join(fb, "deleted_" + sid.slice(6)), "500")
  sync()
  assert.ok(names(fa).includes(sid + ".json"))
})

test("the archive index follows the sessions", () => {
  const sid = session(fa, 1, 100, { archived: true })
  fs.writeFileSync(path.join(fa, "archived-sessions.idx"), `{"v":1,"archived":["${sid}"]}`)
  sync()
  assert.equal(fs.readFileSync(path.join(fb, "archived-sessions.idx"), "utf8"), `{"v":1,"archived":["${sid}"]}`)
})

test("an unknown index format stops everything", () => {
  session(fa, 1, 100)
  fs.writeFileSync(path.join(fa, "archived-sessions.idx"), '{"v":2,"items":[]}')
  assert.throws(() => sync(), core.FormatError)
  assert.deepEqual(names(fb), [])
})

test("foreign files are skipped", () => {
  fs.writeFileSync(path.join(fa, "local_bad.json"), "{not json")
  const r = sync()
  assert.match(r.warnings[0], /skipped unreadable/)
  assert.deepEqual(names(fb), [])
})

test("other files are untouched", () => {
  session(fa, 1, 100)
  fs.writeFileSync(path.join(fa, "scheduled-tasks.json"), "{}")
  sync()
  assert.ok(!names(fb).includes("scheduled-tasks.json"))
})

test("a second sync changes nothing and one backup is kept", () => {
  session(fa, 1, 100, { archived: true })
  session(fb, 2, 200)
  sync()
  assert.equal(sync().written, 0)
  assert.equal(fs.readdirSync(path.join(state, "backups")).length, 1)
})

test("written files are private", () => {
  const sid = session(fa, 1, 100)
  sync()
  assert.equal(fs.statSync(path.join(fb, sid + ".json")).mode & 0o777, 0o600)
})

test("the app's runner merges every folder, the signed-in one too", () => {
  const s2 = session(fb, 2, 200)
  const runner = path.join(import.meta.dirname, "app", "run.sh")
  const out = execFileSync(runner, ["sync-all", "--assume-closed"], { env: { ...process.env, SESSION_SHARE_ROOT: home }, encoding: "utf8" })
  assert.ok(names(fa).includes(s2 + ".json"))
  assert.match(out, /2 个账号都能看到 1 个会话/)
})

test("a dry run of every folder works while the app runs", () => {
  const s2 = session(fb, 2, 200)
  const r = core.run({ write: false, includeActive: true, running: true })
  assert.equal(r.folders.find((f) => f.key === "Claude/" + A).counts.add, 1)
  assert.ok(!names(fa).includes(s2 + ".json"))
})

test("an unticked project isn't copied, but copies it already has stay current", () => {
  const sid = session(fa, 1, 100, { title: "old" })
  settle({ projects: { "/p": false } })
  sync()
  assert.ok(!names(fb).includes(sid + ".json"))
  session(fb, 1, 300, { title: "new" })
  sync()
  assert.equal(load(path.join(fa, sid + ".json")).title, "new")
})

test("the archive index lists only the sessions a folder has", () => {
  const sid = session(fa, 1, 100, { archived: true })
  session(fb, 2, 200)
  settle({ projects: { "/p": false } })
  sync()
  assert.ok(!names(fb).includes("archived-sessions.idx"))
  assert.equal(load(path.join(fa, "archived-sessions.idx")).archived[0], sid)
})

test("terminal sessions come in only for ticked projects, under one id everywhere", () => {
  transcript("11111111-0000-0000-0000-000000000000", { title: "终端里的活" })
  sync()
  assert.deepEqual(names(fa), [])
  settle({ terminal: { "/t": true } })
  const r = sync()
  assert.equal(r.imports, 1)
  const sid = core.importId("11111111-0000-0000-0000-000000000000")
  assert.deepEqual(names(fa), [sid + ".json"])
  assert.deepEqual(names(fb), [sid + ".json"])
  const rec = load(path.join(fa, sid + ".json"))
  assert.equal(rec.title, "终端里的活")
  assert.equal(rec.cwd, "/t")
  assert.equal(rec.lastActivityAt, Date.parse("2026-10-01T00:05:00.000Z"))
  assert.equal(sync().written, 0)
})

test("transcripts the desktop app made, or with nothing typed, are not offered", () => {
  transcript("22222222-0000-0000-0000-000000000000", { entry: "claude-desktop" })
  transcript("33333333-0000-0000-0000-000000000000", { text: "<command-name>/clear</command-name>" })
  settle({ terminal: { "/t": true } })
  assert.equal(sync().imports, 0)
})

test("a brought-in session deleted in the app stays deleted", () => {
  transcript("44444444-0000-0000-0000-000000000000")
  settle({ terminal: { "/t": true } })
  sync()
  const sid = core.importId("44444444-0000-0000-0000-000000000000")
  fs.rmSync(path.join(fa, sid + ".json"))
  fs.writeFileSync(path.join(fa, "deleted_" + sid.slice(6)), String(Date.now()))
  sync()
  assert.ok(!names(fb).includes(sid + ".json"))
  assert.ok(!names(fa).includes(sid + ".json"))
})

test("undo puts back the last merge and keeps what changed since", () => {
  const s1 = session(fa, 1, 100)
  const s2 = session(fb, 2, 200)
  sync()
  // s1's copy in fb is used afterwards
  fs.writeFileSync(path.join(fb, s1 + ".json"), JSON.stringify({ sessionId: s1, cliSessionId: "x", cwd: "/p", lastActivityAt: 999 }))
  const u = core.undo({ running: false })
  assert.equal(u.kept, 1)
  assert.ok(!names(fa).includes(s2 + ".json"))
  assert.ok(names(fb).includes(s1 + ".json"))
  assert.equal(core.lastRun(), null)
  assert.throws(() => core.undo({ running: false }), /没有可以撤销/)
})

test("three backups are kept", () => {
  for (let i = 1; i <= 5; i++) {
    session(fa, i, 100 * i)
    sync()
  }
  assert.equal(fs.readdirSync(path.join(state, "backups")).length, 3)
})

test("accounts are named from Claude Code's profile; the gateway folder is named for what it is", () => {
  fs.writeFileSync(path.join(home, ".claude.json"), JSON.stringify({ oauthAccount: { accountUuid: A, displayName: "Tang", emailAddress: "t@example.com" } }))
  folder(C3, "00000000-0000-4000-8000-000000000001", "Claude-3p")
  const r = core.run({ write: false, running: false })
  const by = Object.fromEntries(r.folders.map((f) => [f.account, f.detail]))
  assert.equal(by[A], "Tang（t@example.com）")
  assert.equal(by[B], "账号 bbbbbbbb")
  core.saveSettings(state, { ...core.loadSettings(state), accounts: { ...core.loadSettings(state).accounts, [B]: { remark: "工作号" } } })
  const again = core.run({ write: false, running: false })
  assert.equal(again.folders.find((f) => f.account === B).detail, "工作号（bbbbbbbb）")
  assert.equal(by[C3], "网关模式")
})

test("the menu bar app's commands: state, set, remark", () => {
  fs.writeFileSync(path.join(home, ".claude.json"), JSON.stringify({ oauthAccount: { accountUuid: A, displayName: "Tang", emailAddress: "t@example.com" } }))
  session(fa, 1, 100)
  session(fb, 2, 200)
  transcript("55555555-0000-0000-0000-000000000000")
  const st = () => JSON.parse(cli("state"))

  let s = st()
  assert.equal(s.changes, 2)
  assert.equal(s.lastRun, null)
  assert.deepEqual(
    s.accounts.map((a) => [a.name, a.email, a.signedIn, a.have, a.add]),
    [["Tang", "t@example.com", true, 1, 1], ["账号 bbbbbbbb", "", false, 1, 1]],
  )
  assert.deepEqual(s.projects, [{ path: "/p", name: "p", count: 2, latest: 200, on: true, from: [{ name: "Tang", count: 1 }, { name: "账号 bbbbbbbb", count: 1 }] }])
  assert.deepEqual(s.terminal.map((t) => [t.path, t.count, t.on]), [["/t", 1, false]])

  cli("set", "desktop", "/p", "off")
  cli("set", "terminal", "/t", "on")
  s = st()
  assert.equal(s.projects[0].on, false)
  assert.equal(s.terminal[0].on, true)
  assert.equal(s.imports, 1)

  cli("remark", B, "工作号")
  assert.equal(st().accounts[1].name, "工作号")
  assert.equal(st().accounts[1].remark, "工作号")
  cli("remark", B, "")
  assert.equal(st().accounts[1].name, "账号 bbbbbbbb")
  assert.throws(() => cli("set", "desktop", "/p", "maybe"))
})
