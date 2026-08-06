import { mkdir, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";

const repository = process.env.GITHUB_REPOSITORY ?? process.argv[2];
const token = process.env.GITHUB_TOKEN ?? process.env.GH_TOKEN;

if (!repository || !/^[^/]+\/[^/]+$/.test(repository)) {
  throw new Error("Pass the repository as OWNER/REPO.");
}

const [owner, name] = repository.split("/");
const apiHeaders = {
  Accept: "application/vnd.github.star+json",
  "User-Agent": "star-history-generator",
  "X-GitHub-Api-Version": "2022-11-28",
};

if (token) {
  apiHeaders.Authorization = `Bearer ${token}`;
}

async function request(path) {
  const response = await fetch(`https://api.github.com${path}`, {
    headers: apiHeaders,
  });

  if (!response.ok) {
    const body = await response.text();
    throw new Error(`GitHub API request failed (${response.status}): ${body}`);
  }

  return response.json();
}

async function loadStargazers() {
  const stargazers = [];

  for (let page = 1; ; page += 1) {
    const batch = await request(
      `/repos/${encodeURIComponent(owner)}/${encodeURIComponent(name)}/stargazers?per_page=100&page=${page}`,
    );
    stargazers.push(...batch);

    if (batch.length < 100) {
      return stargazers;
    }
  }
}

function escapeXml(value) {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&apos;");
}

function formatDate(timestamp) {
  const date = new Date(timestamp);
  const year = date.getUTCFullYear();
  const month = String(date.getUTCMonth() + 1).padStart(2, "0");
  return `${year}-${month}`;
}

const fontStack =
  '-apple-system, BlinkMacSystemFont, "Segoe UI", "Noto Sans", Roboto, "Helvetica Neue", Arial, sans-serif';

function seededRandom(seed) {
  let state = seed >>> 0;
  return () => {
    state = (state * 1664525 + 1013904223) >>> 0;
    return state / 4294967296;
  };
}

function handStar(cx, cy, r, seed) {
  const rand = seededRandom(seed);
  const rotation = (rand() - 0.5) * 0.6;
  let d = "";
  for (let i = 0; i < 10; i += 1) {
    const angle = rotation + (i * Math.PI) / 5 - Math.PI / 2;
    const radius = (i % 2 === 0 ? r : r * 0.42) * (0.88 + rand() * 0.24);
    d += `${i === 0 ? "M" : "L"} ${(cx + radius * Math.cos(angle)).toFixed(2)} ${(cy + radius * Math.sin(angle)).toFixed(2)} `;
  }
  return `${d}Z`;
}

function buildSvg(repo, stargazers) {
  const width = 960;
  const height = 480;
  const plot = { left: 72, top: 96, right: 928, bottom: 400 };
  const plotWidth = plot.right - plot.left;
  const plotHeight = plot.bottom - plot.top;
  const createdAt = Date.parse(repo.created_at);
  const generatedAt = Date.now();
  const endAt = Math.max(generatedAt, createdAt + 86_400_000);
  const events = stargazers
    .map((item) => Date.parse(item.starred_at))
    .filter(Number.isFinite)
    .sort((a, b) => a - b);
  const starCount = events.length;
  const yTickCount = Math.min(4, Math.max(1, starCount));
  const yStep = Math.max(1, Math.ceil(starCount / yTickCount));
  const yMax = yStep * yTickCount;
  const xFor = (timestamp) =>
    plot.left + ((timestamp - createdAt) / (endAt - createdAt)) * plotWidth;
  const yFor = (count) => plot.bottom - (count / yMax) * plotHeight;

  const vertices = [{ x: plot.left, y: plot.bottom }];
  const starPoints = [];

  events.forEach((timestamp, index) => {
    const x = xFor(Math.min(Math.max(timestamp, createdAt), endAt));
    const y = yFor(index + 1);
    vertices.push({ x, y });
    starPoints.push(handStar(x, y, 5, 0x5100 + index));
  });

  vertices.push({ x: plot.right, y: vertices[vertices.length - 1].y });

  const rand = seededRandom(0x5a17);
  const jitter = 1.3;
  let linePath = "";
  vertices.forEach((v, i) => {
    const x = v.x + (rand() - 0.5) * 2 * jitter;
    const y = v.y + (rand() - 0.5) * 2 * jitter;
    linePath += `${i === 0 ? "M" : "L"} ${x.toFixed(2)} ${y.toFixed(2)} `;
  });
  const areaPath = `${linePath}L ${plot.right.toFixed(2)} ${plot.bottom.toFixed(2)} Z`;
  const yGrid = [];

  for (let tick = 0; tick <= yTickCount; tick += 1) {
    const value = tick * yStep;
    const y = yFor(value);
    yGrid.push(
      `<line class="grid" x1="${plot.left}" y1="${y.toFixed(2)}" x2="${plot.right}" y2="${y.toFixed(2)}" />`,
      `<text class="axis-label" x="56" y="${(y + 4).toFixed(2)}" text-anchor="end">${value}</text>`,
    );
  }

  const xTickCount = 4;
  const xLabels = [];

  for (let tick = 0; tick <= xTickCount; tick += 1) {
    const ratio = tick / xTickCount;
    const x = plot.left + ratio * plotWidth;
    const timestamp = createdAt + ratio * (endAt - createdAt);
    const anchor = tick === 0 ? "start" : tick === xTickCount ? "end" : "middle";
    xLabels.push(
      `<text class="axis-label" x="${x.toFixed(2)}" y="${plot.bottom + 28}" text-anchor="${anchor}">${formatDate(timestamp)}</text>`,
    );
  }

  const [owner, name] = repo.full_name.split("/");
  const safeOwner = escapeXml(owner);
  const safeName = escapeXml(name);
  const sinceLabel = formatDate(createdAt);
  const pillWidth = Math.round(Math.max(48, 34 + String(starCount).length * 8 + 12));
  const pillX = plot.right - pillWidth;

  return `<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}" role="img" aria-labelledby="title description">
  <title id="title">Star history for ${safeOwner}/${safeName}</title>
  <desc id="description">${starCount === 1 ? "1 star" : `${starCount} stars`} since ${sinceLabel}</desc>
  <defs>
    <linearGradient id="lineGrad" x1="${plot.left}" y1="0" x2="${plot.right}" y2="0" gradientUnits="userSpaceOnUse">
      <stop offset="0" class="grad-a" />
      <stop offset="1" class="grad-b" />
    </linearGradient>
    <linearGradient id="areaGrad" x1="0" y1="${plot.top}" x2="0" y2="${plot.bottom}" gradientUnits="userSpaceOnUse">
      <stop offset="0" class="grad-a" stop-opacity="0.1" />
      <stop offset="1" class="grad-a" stop-opacity="0" />
    </linearGradient>
  </defs>
  <style>
    :root { color-scheme: light dark; }
    .grad-a { stop-color: #bda12f; }
    .grad-b { stop-color: #8b7a1e; }
    .background { fill: #ffffff; }
    .eyebrow { fill: #8b7a1e; font: 700 10px ${fontStack}; letter-spacing: 2.5px; }
    .owner { fill: #8a8578; font: 700 20px ${fontStack}; }
    .title { fill: #14140d; font: 700 20px ${fontStack}; }
    .axis-label { fill: #8a8578; font: 500 11px ${fontStack}; }
    .grid { stroke: #14140d; stroke-opacity: 0.09; stroke-width: 1.2; stroke-dasharray: 2 5; }
    .area { fill: url(#areaGrad); }
    .sketch { fill: none; stroke: url(#lineGrad); stroke-width: 5; stroke-linecap: round; stroke-linejoin: round; opacity: 0.2; }
    .line { fill: none; stroke: url(#lineGrad); stroke-width: 2.2; stroke-linecap: round; stroke-linejoin: round; }
    .point { fill: #bda12f; }
    .pill-bg { fill: rgba(189, 161, 47, 0.08); stroke: rgba(139, 122, 30, 0.5); stroke-width: 1.2; stroke-dasharray: 3 3; }
    .pill-text { fill: #8b7a1e; font: 700 13px ${fontStack}; }
    .wave { fill: none; stroke: #8b7a1e; stroke-opacity: 0.5; stroke-width: 1.6; stroke-linecap: round; }
    @media (prefers-color-scheme: dark) {
      .grad-a { stop-color: #d4b85c; }
      .grad-b { stop-color: #bda12f; }
      .background { fill: #14140d; }
      .eyebrow { fill: #d4b85c; }
      .owner { fill: rgba(245, 240, 232, 0.55); }
      .title { fill: #f5f0e8; }
      .axis-label { fill: rgba(245, 240, 232, 0.5); }
      .grid { stroke: #f5f0e8; stroke-opacity: 0.1; }
      .point { fill: #d4b85c; }
      .pill-bg { fill: rgba(189, 161, 47, 0.12); stroke: rgba(212, 184, 92, 0.5); }
      .pill-text { fill: #d4b85c; }
      .wave { stroke: #d4b85c; }
    }
  </style>
  <rect class="background" width="${width}" height="${height}" />
  <text class="eyebrow" x="${plot.left}" y="36">STAR HISTORY</text>
  <text x="${plot.left}" y="66">
    <tspan class="owner">${safeOwner}/</tspan><tspan class="title">${safeName}</tspan>
  </text>
  <path class="wave" d="M ${plot.left} 84 Q 92 78 112 84 T 152 84 T 192 84 T 232 84 T 272 84" />
  <g>
    <rect class="pill-bg" x="${pillX}" y="49" width="${pillWidth}" height="30" rx="15" />
    <text class="pill-text" x="${pillX + 14}" y="69">★ ${starCount}</text>
  </g>
  ${yGrid.join("\n  ")}
  ${xLabels.join("\n  ")}
  <path class="area" d="${areaPath}" />
  <path class="sketch" d="${linePath}" />
  <path class="line" d="${linePath}" />
  ${starPoints.map((d) => `<path class="point" d="${d}" />`).join("\n  ")}
</svg>
`;
}

const repo = await request(`/repos/${encodeURIComponent(owner)}/${encodeURIComponent(name)}`);
const stargazers = await loadStargazers();
const outputPath = resolve("assets/star-history.svg");

await mkdir(dirname(outputPath), { recursive: true });
await writeFile(outputPath, buildSvg(repo, stargazers), "utf8");
console.log(`Generated ${outputPath} with ${stargazers.length} stars.`);
