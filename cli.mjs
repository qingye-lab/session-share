#!/usr/bin/env node
// The sync by hand, and the app's worker. For people:
//   node cli.mjs status     what a merge would change (writes nothing)
//   node cli.mjs sync       update every folder the app isn't using
//   node cli.mjs show-all   quit Claude, update every folder, open Claude again
//   node cli.mjs undo       put back what the last merge changed (Claude closed)
// For the menu bar app (JSON on stdout, errors on stderr):
//   state                         accounts, projects and what a merge would change
//   sync-all                      merge every folder; Claude must be closed
//   set desktop|terminal <path> on|off
//                                 sync a project's sessions / bring in its terminal sessions
//   remark <uuid> [text]          set an account's remark (empty clears it)
import { claudeRunning, defaults, lastRun, loadSettings, run, saveSettings, showAll, undo } from "./core.mjs"

const KIND_WORDS = { add: "补", update: "更新", remove: "删", tombstone: "删除标记", "archive-index": "归档索引" }

const changes = (r) => r.folders.reduce((n, f) => n + Object.values(f.counts).reduce((a, b) => a + b, 0), 0)

function counts(f) {
  return ["add", "update", "remove"].filter((k) => f.counts[k]).map((k) => `${KIND_WORDS[k]} ${f.counts[k]} 个`).join("，")
}

function originName(r, key) {
  if (key === "terminal") return "终端"
  const f = r.folders.find((x) => x.key === key)
  return f ? f.name : `账号 ${key.split("/")[1].slice(0, 8)}`
}

// Short names for project folders: the last part, or the last two when two
// projects share it.
function shortNames(paths) {
  const home = defaults().home
  const last = (p, n) => p.split("/").filter(Boolean).slice(-n).join("/") || p
  const out = new Map()
  for (const p of paths) {
    if (p === home) out.set(p, "~")
    else out.set(p, paths.filter((q) => last(q, 1) === last(p, 1)).length > 1 ? last(p, 2) : last(p, 1))
  }
  return out
}

function planText(r) {
  const s = r.settings
  const lines = []
  if (!changes(r)) lines.push(`所有账号都能看到全部 ${r.sessions} 个会话。`)
  lines.push("各账号的侧边栏：")
  for (const f of r.folders) {
    const tag = f.signedIn && f.data === "Claude" ? " · 当前登录" : ""
    lines.push(`· ${f.detail}${tag}：已有 ${f.have} 个${counts(f) ? "，" + counts(f) : ""}`)
  }
  const groups = [...r.projects.entries()]
  const off = groups.filter(([p, g]) => g.sessions && s.projects[p] === false).length
  const on = groups.filter(([p, g]) => g.sessions && s.projects[p] !== false).length
  lines.push(`项目：同步 ${on} 个${off ? `，不同步 ${off} 个` : ""}。`)
  const waiting = groups.reduce((n, [p, g]) => n + (s.terminal[p] === true ? 0 : g.terminal), 0)
  if (r.imports || waiting) lines.push(`终端会话：这次导入 ${r.imports} 个${waiting ? `，另有 ${waiting} 个没勾选` : ""}。`)
  if (r.missing) lines.push(`注意：${r.missing} 个会话找不到对话文件，会显示但可能打不开。`)
  for (const w of r.warnings) lines.push("注意：" + w)
  return lines.join("\n")
}

// one line for a notification
function summary(r) {
  const head = `${r.folders.length} 个账号都能看到 ${r.sessions} 个会话`
  if (!r.written) return `${head}，无需改动`
  return `${head}（写入 ${r.written} 处${r.imports ? `，导入 ${r.imports} 个终端会话` : ""}）`
}

function describe(r, write) {
  const lines = [planText(r)]
  if (r.written) lines.push(`已写入 ${r.written} 处改动。备份：${r.backup}`)
  else if (!write && changes(r)) lines.push("预演，没有写入任何文件。")
  return lines.join("\n")
}

// Everything the menu bar app shows.
function snapshot(r) {
  const s = r.settings
  const groups = [...r.projects.entries()]
  const names = shortNames(groups.map(([p]) => p))
  const last = lastRun()
  const desktop = groups.filter(([, g]) => g.sessions).sort((a, b) => b[1].latest - a[1].latest)
  const terminal = groups.filter(([, g]) => g.terminal).sort((a, b) => b[1].terminalLatest - a[1].terminalLatest)
  return {
    sessions: r.sessions,
    changes: changes(r),
    imports: r.imports,
    missing: r.missing,
    warnings: r.warnings,
    lastRun: last ? { at: last.at, changes: last.ops.length } : null,
    accounts: r.folders.map((f) => {
      const a = f.data === "Claude-3p" ? {} : s.accounts[f.account] ?? {}
      return {
        key: f.key,
        id: f.account,
        gateway: f.data === "Claude-3p",
        name: f.name,
        email: a.email ?? "",
        remark: a.remark ?? "",
        signedIn: f.signedIn && f.data === "Claude",
        have: f.have,
        add: f.counts.add ?? 0,
        update: f.counts.update ?? 0,
        remove: f.counts.remove ?? 0,
      }
    }),
    projects: desktop.map(([p, g]) => ({
      path: p,
      name: names.get(p),
      count: g.sessions,
      latest: g.latest,
      on: s.projects[p] !== false,
      from: [...g.from.entries()].sort((a, b) => b[1] - a[1]).map(([k, n]) => ({ name: originName(r, k), count: n })),
    })),
    terminal: terminal.map(([p, g]) => ({ path: p, name: names.get(p), count: g.terminal, latest: g.terminalLatest, on: s.terminal[p] === true })),
  }
}

const [cmd, ...args] = process.argv.slice(2)
const flags = args.filter((a) => a.startsWith("--"))
const words = args.filter((a) => !a.startsWith("--"))
// tests: act as if Claude were closed
const assumeClosed = flags.includes("--assume-closed")

try {
  const { state } = defaults()
  if (cmd === "status") console.log(describe(run({ write: false }), false))
  else if (cmd === "sync") console.log(describe(run({ write: true }), true))
  else if (cmd === "show-all") console.log(describe(await showAll(), true))
  else if (cmd === "sync-all") {
    if (!assumeClosed && claudeRunning()) throw new Error("Claude 还在运行，请先退出")
    console.log(summary(run({ write: true, includeActive: true, running: false })))
  } else if (cmd === "state") {
    console.log(JSON.stringify(snapshot(run({ write: false, includeActive: true, running: false }))))
  } else if (cmd === "undo") {
    const u = undo({ running: assumeClosed ? false : undefined })
    console.log(`已撤销上次合并：恢复 ${u.restored} 处${u.kept ? `，${u.kept} 处之后又被改过，保留现状` : ""}`)
  } else if (cmd === "set") {
    const [kind, project, value] = words
    if (!["desktop", "terminal"].includes(kind) || !project || !["on", "off"].includes(value)) throw new Error("用法：node cli.mjs set desktop|terminal <文件夹> on|off")
    const s = loadSettings(state)
    s[kind === "terminal" ? "terminal" : "projects"][project] = value === "on"
    saveSettings(state, s)
  } else if (cmd === "remark") {
    const [uuid, ...rest] = words
    if (!/^[0-9a-f-]{36}$/.test(uuid ?? "")) throw new Error("用法：node cli.mjs remark <账号 UUID> [备注]")
    const remark = rest.join(" ").trim()
    const s = loadSettings(state)
    const { remark: _, ...a } = s.accounts[uuid] ?? {}
    s.accounts[uuid] = remark ? { ...a, remark } : a
    saveSettings(state, s)
  } else {
    console.log("用法：node cli.mjs status | sync | show-all | undo（其余命令供菜单栏程序使用，见文件开头）")
    process.exitCode = 2
  }
} catch (e) {
  console.error(e.message)
  process.exitCode = 1
}
