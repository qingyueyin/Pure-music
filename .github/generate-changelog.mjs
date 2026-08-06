/**
 * 从 GitHub Releases 生成 page/docs/guide/changelog.md
 * 并从最新正式版写入 update/version.json（应用内检查更新用）
 *
 * 环境变量:
 *   GITHUB_TOKEN / GH_TOKEN  — 可选，提高 API 限额
 *   GITHUB_REPOSITORY        — owner/repo，默认 qingyueyin/Pure-music
 *   MIN_TAG                  — 收录的最低版本，默认 v2.0.0
 */
import { writeFileSync, mkdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const __dirname = dirname(fileURLToPath(import.meta.url))
const root = join(__dirname, '..')
const changelogPath = join(root, 'page/docs/guide/changelog.md')
const versionJsonPath = join(root, 'update/version.json')
const latestReleasePath = join(
  root,
  'page/docs/public/latest-release.json',
)

const repo = process.env.GITHUB_REPOSITORY || 'qingyueyin/Pure-music'
const giteeRepo =
  process.env.GITEE_REPOSITORY ||
  process.env.GITEE_REPO ||
  'qingyueyin/Pure-music'
const minTag = (process.env.MIN_TAG || 'v2.0.0').trim()
const token = process.env.GITHUB_TOKEN || process.env.GH_TOKEN || ''

function parseVersion(tag) {
  const raw = String(tag || '')
    .trim()
    .replace(/^v/i, '')
  // 2.0.0 / 2.0.0-preview / 2.1.5
  let m = raw.match(/^(\d+)\.(\d+)\.(\d+)/)
  if (m) return [Number(m[1]), Number(m[2]), Number(m[3])]
  // 仅主版本如 v1 → 当作 1.0.0，便于比较后仍可按 MIN_TAG 过滤掉
  m = raw.match(/^(\d+)(?:\.(\d+))?$/)
  if (m) return [Number(m[1]), Number(m[2] || 0), 0]
  return null
}

function cmpVersion(a, b) {
  const pa = parseVersion(a)
  const pb = parseVersion(b)
  if (!pa && !pb) return 0
  // 无法解析的版本沉底，绝不当「最新」
  if (!pa) return -1
  if (!pb) return 1
  for (let i = 0; i < 3; i++) {
    if (pa[i] !== pb[i]) return pa[i] - pb[i]
  }
  return 0
}

function meetsMinTag(tag) {
  const p = parseVersion(tag)
  const min = parseVersion(minTag)
  if (!p || !min) return false
  return cmpVersion(tag, minTag) >= 0
}

function displayVersion(tag, name) {
  const fromTag = String(tag || '').replace(/^v/i, '').trim()
  const fromName = String(name || '').replace(/^v/i, '').trim()
  if (fromName && /^\d+\.\d+/.test(fromName)) return fromName.split(/\s/)[0]
  return fromTag || fromName || tag
}

/** 把 Release body 收成折叠块内可用的 Markdown（避免 ### 进目录） */
function bodyToFoldedMarkdown(body) {
  if (!body || !String(body).trim()) {
    return '\n_本版本未填写详细说明，请查看 GitHub Release 页面。_\n'
  }

  let text = String(body)
    .replace(/\r\n/g, '\n')
    // 去掉首行重复的「更新日志 vX.Y.Z」类标题
    .replace(/^#+\s*更新日志[^\n]*\n+/i, '')
    .replace(/^#+\s*v?\d+\.\d+[^\n]*\n+/i, '')

  const lines = text.split('\n')
  const out = []

  for (const line of lines) {
    const h = line.match(/^(#{1,6})\s+(.+)$/)
    if (h) {
      const title = h[2].trim()
      // 跳过整页级大标题
      if (/^更新日志/i.test(title) || /^v?\d+\.\d+/.test(title)) continue
      out.push('')
      out.push(`**${title}**`)
      out.push('')
      continue
    }
    out.push(line)
  }

  let result = out.join('\n').replace(/\n{3,}/g, '\n\n').trim()
  if (!result) result = '_本版本未填写详细说明。_'
  return `\n${result}\n`
}

function extraNote(tag, name) {
  const t = String(tag || '')
  const notes = []
  if (/preview/i.test(t) || /preview/i.test(String(name || ''))) {
    notes.push('发布标签含 preview')
  }
  if (/pre/i.test(t) && !/preview/i.test(t)) {
    notes.push('预发布')
  }
  return notes.length ? `（${notes.join(' · ')}）` : ''
}

function buildChangelogMarkdown(releases) {
  const blocks = releases.map((r) => {
    const ver = displayVersion(r.tag_name, r.name)
    const note = extraNote(r.tag_name, r.name)
    const body = bodyToFoldedMarkdown(r.body)
    return [
      '<details>',
      `<summary><strong>${ver}</strong>${note}</summary>`,
      body,
      '</details>',
      '',
    ].join('\n')
  })

  const latest = releases[0]
  const latestLabel = latest
    ? displayVersion(latest.tag_name, latest.name)
    : '—'

  return `---
outline: false
---

# 更新日志

从 **${minTag.replace(/^v/i, '')}** 起。每个版本默认折叠，点版本号展开。最新：**${latestLabel}**。

完整发布页：[GitHub](https://github.com/${repo}/releases) · [Gitee 镜像](https://gitee.com/${giteeRepo})（同步常滞后）

${blocks.join('\n')}
---

更早版本见 [GitHub Releases](https://github.com/${repo}/releases)。下载见 [下载页](/download)。
`
}

async function fetchAllReleases() {
  const headers = {
    Accept: 'application/vnd.github+json',
    'User-Agent': 'pure-music-changelog',
    'X-GitHub-Api-Version': '2022-11-28',
  }
  if (token) headers.Authorization = `Bearer ${token}`

  const all = []
  let page = 1
  while (page <= 20) {
    const url = `https://api.github.com/repos/${repo}/releases?per_page=100&page=${page}`
    const res = await fetch(url, { headers })
    if (!res.ok) {
      const text = await res.text()
      throw new Error(`GitHub API ${res.status}: ${text.slice(0, 200)}`)
    }
    const batch = await res.json()
    if (!Array.isArray(batch) || batch.length === 0) break
    all.push(...batch)
    if (batch.length < 100) break
    page += 1
  }
  return all
}

function pickReleases(raw) {
  return raw
    .filter((r) => !r.draft)
    .filter((r) => meetsMinTag(r.tag_name))
    .sort((a, b) => cmpVersion(b.tag_name, a.tag_name))
}

function pickLatestStable(releases) {
  const stable = releases.filter(
    (r) =>
      !r.prerelease &&
      !/preview/i.test(r.tag_name || '') &&
      !/preview/i.test(r.name || '') &&
      parseVersion(r.tag_name),
  )
  return stable[0] || releases.find((r) => parseVersion(r.tag_name)) || null
}

function writeVersionJson(release) {
  if (!release) return
  const githubUrl =
    release.html_url ||
    `https://github.com/${repo}/releases/tag/${release.tag_name}`
  const payload = {
    tag_name: release.tag_name,
    name: release.name || release.tag_name,
    body:
      (release.body && String(release.body).trim()) ||
      '## 更新内容\n\n请前往 GitHub Releases 查看完整更新日志',
    // 应用内「获取更新」优先打开 GitHub；访问慢时可改用文档站上的 Gitee 镜像说明
    html_url: githubUrl,
  }
  mkdirSync(dirname(versionJsonPath), { recursive: true })
  writeFileSync(versionJsonPath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8')
  console.log(`wrote ${versionJsonPath} -> ${payload.tag_name}`)
}

/** 文档站下载卡片用：最新版号 + GitHub / Gitee 入口 */
function writeLatestReleaseJson(release) {
  if (!release) return
  const ver = displayVersion(release.tag_name, release.name)
  const payload = {
    tag_name: release.tag_name,
    name: release.name || release.tag_name,
    version: ver,
    github_releases_url: `https://github.com/${repo}/releases`,
    github_release_url:
      release.html_url ||
      `https://github.com/${repo}/releases/tag/${release.tag_name}`,
    gitee_repo_url: `https://gitee.com/${giteeRepo}`,
    gitee_releases_url: `https://gitee.com/${giteeRepo}/releases`,
    // Gitee 镜像同步常滞后，前端可展示提示
    gitee_may_lag: true,
    generated_at: new Date().toISOString(),
  }
  mkdirSync(dirname(latestReleasePath), { recursive: true })
  writeFileSync(
    latestReleasePath,
    `${JSON.stringify(payload, null, 2)}\n`,
    'utf8',
  )
  console.log(`wrote ${latestReleasePath} -> ${payload.version}`)
}

async function main() {
  console.log(`repo=${repo} gitee=${giteeRepo} minTag=${minTag}`)
  const raw = await fetchAllReleases()
  const releases = pickReleases(raw)
  if (releases.length === 0) {
    throw new Error(`No releases >= ${minTag}`)
  }

  const md = buildChangelogMarkdown(releases)
  mkdirSync(dirname(changelogPath), { recursive: true })
  writeFileSync(changelogPath, md, 'utf8')
  console.log(`wrote ${changelogPath} (${releases.length} versions)`)

  const latest = pickLatestStable(releases)
  writeVersionJson(latest)
  writeLatestReleaseJson(latest)
}

main().catch((err) => {
  console.error(err)
  process.exit(1)
})
