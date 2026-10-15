// Synthetic data for screenshots. Never points at the real home directory.
import fs from "node:fs"
import path from "node:path"

const dir = process.argv[2]
if (!dir) throw new Error("Usage: node scripts/demo-data.mjs <empty-directory>")
const root = path.resolve(dir)
fs.mkdirSync(root, { recursive: true })
if (fs.readdirSync(root).length) throw new Error("Demo directory must be empty")
const put = (p, data) => {
  const file = path.join(root, p)
  fs.mkdirSync(path.dirname(file), { recursive: true })
  fs.writeFileSync(file, JSON.stringify(data))
}
const a = "aaaaaaaa-0000-4000-8000-000000000001"
const b = "bbbbbbbb-0000-4000-8000-000000000002"
const g = "cccccccc-0000-4000-8000-000000000003"
const org = "00000000-0000-4000-8000-000000000001"
const support = "Library/Application Support"
for (const [data, id] of [["Claude", a], ["Claude", b], ["Claude-3p", g]]) {
  fs.mkdirSync(path.join(root, support, data, "claude-code-sessions", id, org), { recursive: true })
  if (id !== b) put(`${support}/${data}/config.json`, { lastKnownAccountUuid: id })
}
put(".claude.json", { oauthAccount: { accountUuid: b, displayName: "Alex", emailAddress: "alex@example.com" } })
put(`${support}/session-share/settings.json`, {
  v: 1, accounts: { [a]: { remark: "个人账号" } }, projects: {}, terminal: {},
})
const projects = ["website", "notes-app", "design-system", "api-server", "small-tools", "portfolio"]
let number = 0
for (const [i, project] of projects.entries()) {
  for (let k = 0; k < (i % 3) + 2; k++) {
    const n = String(++number).padStart(8, "0")
    const cli = `${n}-1111-4000-8000-000000000000`
    const sid = `local_${n}-2222-4000-8000-000000000000`
    const cwd = `/Users/demo/Projects/${project}`
    const at = Date.now() - i * 3600000 - k * 60000
    put(`${support}/Claude/claude-code-sessions/${i % 2 ? b : a}/${org}/${sid}.json`, {
      sessionId: sid, cliSessionId: cli, cwd, title: `${project} demo ${k + 1}`, lastActivityAt: at, isArchived: false,
    })
    const file = path.join(root, ".claude/projects", project, `${cli}.jsonl`)
    fs.mkdirSync(path.dirname(file), { recursive: true })
    fs.writeFileSync(file, "")
  }
}
for (const [i, project] of projects.entries()) {
  const cli = `eeeeeeee-0000-4000-8000-${String(i).padStart(12, "0")}`
  const cwd = `/Users/demo/Projects/${project}`
  const file = path.join(root, ".claude/projects", project, `${cli}.jsonl`)
  fs.writeFileSync(file, JSON.stringify({
    type: "user", entrypoint: "cli", cwd, sessionId: cli, timestamp: new Date().toISOString(),
    message: { role: "user", content: `Review the ${project} project` },
  }) + "\n")
}
console.log(root)
