// Discord #bug-reports forum -> GitHub issues. Run by .github/workflows/discord-issues.yml (Node 20, no packages).
// A forum post becomes a GitHub issue once a moderator gives it the tag "confirmed". The issue links back to the
// post, and the bot answers in the post with the issue's link. Player names are not copied.
// Needs: DISCORD_BOT_TOKEN (a bot in the server with View Channel, Read Message History, Send Messages in Threads,
// and the Message Content intent), GITHUB_TOKEN, GITHUB_REPOSITORY, DISCORD_GUILD_ID, DISCORD_FORUM_ID.
const { DISCORD_BOT_TOKEN: BOT, GITHUB_TOKEN: GH, GITHUB_REPOSITORY: REPO, DISCORD_GUILD_ID: GUILD, DISCORD_FORUM_ID: FORUM } = process.env;
const TRIGGER_TAG = (process.env.TRIGGER_TAG || "confirmed").toLowerCase();
const DRY = process.env.DRY_RUN === "1";
if (!BOT) { console.log("DISCORD_BOT_TOKEN is not set: nothing to do."); process.exit(0); }
for (const [k, v] of Object.entries({ GH, REPO, GUILD, FORUM })) if (!v) { console.error(`missing ${k}`); process.exit(1); }

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function api(base, path, token, scheme, init = {}) {
  for (let attempt = 0; attempt < 4; attempt++) {
    const r = await fetch(base + path, { ...init, headers: { Authorization: `${scheme} ${token}`, "Content-Type": "application/json",
      "User-Agent": "manor-lords-coop-issue-bridge", Accept: "application/json", ...(init.headers || {}) } });
    if (r.status === 429) { const j = await r.json().catch(() => ({})); await sleep(Math.ceil((j.retry_after || 2) * 1000)); continue; }
    if (!r.ok) throw new Error(`${init.method || "GET"} ${path}: ${r.status} ${(await r.text()).slice(0, 200)}`);
    return r.status === 204 ? null : r.json();
  }
  throw new Error(`${path}: rate limited four times`);
}
const discord = (p, init) => api("https://discord.com/api/v10", p, BOT, "Bot", init);
const github = (p, init) => api("https://api.github.com", p, GH, "Bearer", init);

// text from a stranger: no mentions, no markup that could run, bounded
function safe(text, max) {
  return String(text || "").replace(/\r/g, "").replace(/@/g, "@​").replace(/<!--/g, "< !--").replace(/<(\/?)(script|img|iframe|a)\b/gi, "&lt;$1$2").slice(0, max);
}

const forum = await discord(`/channels/${FORUM}`);
const tagName = new Map((forum.available_tags || []).map((t) => [t.id, t.name.toLowerCase()]));
const active = await discord(`/guilds/${GUILD}/threads/active`);
const posts = (active.threads || []).filter((t) => t.parent_id === FORUM && !((t.flags || 0) & 2));   // flag 2 = pinned
let made = 0;
for (const t of posts) {
  const tags = (t.applied_tags || []).map((id) => tagName.get(id)).filter(Boolean);
  if (!tags.includes(TRIGGER_TAG)) continue;
  const marker = `Discord post id: ${t.id}`;
  const found = await github(`/search/issues?q=${encodeURIComponent(`repo:${REPO} is:issue in:body "${marker}"`)}`);
  if (found.total_count > 0) continue;
  let first = null;
  try { first = await discord(`/channels/${t.id}/messages/${t.id}`); } catch (e) { console.log(`post ${t.id}: first message not readable (${e.message})`); }
  const files = (first?.attachments || []).map((a) => a.filename);
  const labels = ["from-discord", "bug"];
  if (tags.includes("crash")) labels.push("crash");
  if (tags.includes("sync")) labels.push("desync");
  if (!files.some((f) => /\.zip$/i.test(f))) labels.push("needs-logs");
  const link = `https://discord.com/channels/${GUILD}/${t.id}`;
  const body = [
    `Reported in the Discord bug forum: ${link}`,
    `Tags there: ${tags.join(", ") || "none"}`,
    files.length ? `Files attached to the Discord post (open them there): ${files.map((f) => "`" + safe(f, 80) + "`").join(", ")}` : "No report zip is attached to the Discord post.",
    "",
    "What the player wrote:",
    "",
    safe(first?.content || "(the text could not be read)", 6000).split("\n").map((l) => "> " + l).join("\n"),
    "",
    marker,
  ].join("\n");
  if (DRY) { console.log(`would open: ${t.name} [${labels.join(", ")}]`); continue; }
  const issue = await github(`/repos/${REPO}/issues`, { method: "POST", body: JSON.stringify({ title: safe(t.name, 200), body, labels }) });
  made++;
  console.log(`post ${t.id} -> issue #${issue.number}`);
  try { await discord(`/channels/${t.id}/messages`, { method: "POST", body: JSON.stringify({ content: `Tracked on GitHub: ${issue.html_url}`, allowed_mentions: { parse: [] } }) }); }
  catch (e) { console.log(`post ${t.id}: could not answer in Discord (${e.message})`); }
}
console.log(`${posts.length} forum post(s) looked at, ${made} issue(s) opened.`);
