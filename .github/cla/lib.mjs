// CLA 检查的纯逻辑：不碰网络，run.mjs 负责调 GitHub API。规则见 CONTRIBUTING.md。

export const CLA_VERSION = "1.0";
export const SIGN_PHRASE = "I have read the uozi Contributor License Agreement and I hereby sign it.";
export const RECHECK = "recheck";
export const MARKER = "<!-- uozi-cla -->";

const norm = (s) => String(s ?? "").trim().replace(/\s+/g, " ").toLowerCase();

/** 评论正文是不是签署语句（忽略首尾空白、大小写、连续空白；必须整条就是这句话）。 */
export function isSignComment(body) {
  return norm(body) === norm(SIGN_PHRASE);
}

export function isRecheckComment(body) {
  return norm(body) === RECHECK;
}

export function isBot(user) {
  return !!user && (user.type === "Bot" || /\[bot\]$/i.test(user.login ?? ""));
}

/** allowlist.txt：每行一个 GitHub 登录名，`#` 起注释，`*` 作通配。 */
export function parseAllowlist(text) {
  return String(text ?? "")
    .split("\n")
    .map((l) => l.replace(/#.*/, "").trim())
    .filter(Boolean)
    .map((p) => new RegExp("^" + p.replace(/[.+?^${}()|[\]\\]/g, "\\$&").replace(/\*/g, ".*") + "$", "i"));
}

const allowed = (login, allowlist) => allowlist.some((rx) => rx.test(login));

/** GitHub noreply 邮箱（`12345+login@users.noreply.github.com` 或 `login@users.noreply.github.com`）→ 登录名。 */
export function loginFromNoreply(email) {
  const m = /^(?:\d+\+)?([^@]+)@users\.noreply\.github\.com$/i.exec(String(email ?? "").trim());
  return m ? m[1] : null;
}

/** 提交信息里的 `Co-authored-by: Name <email>` 尾注。 */
export function coAuthors(message) {
  const out = [];
  for (const m of String(message ?? "").matchAll(/^co-authored-by:\s*(.+?)\s*<([^>]+)>\s*$/gim)) {
    out.push({ name: m[1], email: m[2] });
  }
  return out;
}

/**
 * 这个 PR 需要谁签。
 * - 提交作者有关联的 GitHub 账号：按账号（id 为准，登录名会改）。
 * - 作者邮箱没关联任何账号：记进 unlinked，没法判断是谁，挡住合并，要作者把邮箱关联到账号。
 * - Co-authored-by：noreply 邮箱能认出登录名的按登录名要求签；认不出的进 unlinked。
 * - 机器人与 allowlist 里的人不用签。
 * @returns {{ people: Map<string, {id?: number, login: string}>, unlinked: {name: string, email: string, sha: string}[] }}
 *          people 的键是小写登录名。
 */
export function requiredSigners(commits, allowlist = []) {
  const people = new Map();
  const unlinked = [];
  const need = (person) => {
    if (isBot(person) || allowed(person.login, allowlist)) return;
    const key = person.login.toLowerCase();
    if (!people.has(key) || (person.id && !people.get(key).id)) people.set(key, person);
  };
  for (const c of commits) {
    const sha = (c.sha ?? "").slice(0, 7);
    if (c.author?.login) need({ id: c.author.id, login: c.author.login, type: c.author.type });
    else {
      const login = loginFromNoreply(c.commit?.author?.email);
      if (login) need({ login });
      else unlinked.push({ name: c.commit?.author?.name ?? "?", email: c.commit?.author?.email ?? "?", sha });
    }
    for (const co of coAuthors(c.commit?.message)) {
      const login = loginFromNoreply(co.email);
      if (login) need({ login });
      else if (!/\[bot\]/i.test(co.name)) unlinked.push({ ...co, sha });
    }
  }
  return { people, unlinked };
}

/** 签名记录 → 是否已签（同一 CLA 版本；按 id 匹配，没有 id 时按登录名）。 */
export function hasSigned(person, signatures, version = CLA_VERSION) {
  return signatures.some(
    (s) =>
      s.claVersion === version &&
      ((person.id && s.id === person.id) || s.login.toLowerCase() === person.login.toLowerCase()),
  );
}

export function evaluate({ commits, allowlist, signatures, version = CLA_VERSION }) {
  const { people, unlinked } = requiredSigners(commits, allowlist);
  const unsigned = [...people.values()].filter((p) => !hasSigned(p, signatures, version));
  return { required: [...people.values()], unsigned, unlinked, ok: unsigned.length === 0 && unlinked.length === 0 };
}

/** 加一条签名；已签过同一版本就原样返回（不重复记）。 */
export function addSignature(signatures, record) {
  if (hasSigned(record, signatures, record.claVersion)) return signatures;
  return [...signatures, record];
}

export function renderComment({ result, documentUrl }) {
  const lines = [MARKER];
  if (result.ok) {
    lines.push("**CLA** ✅ 本 PR 的所有贡献者都已签署贡献者许可协议。All contributors have signed the CLA.");
    return lines.join("\n");
  }
  lines.push(
    "**CLA** — 感谢贡献！合并之前，每位贡献者需要签署一次[贡献者许可协议（CLA）](" + documentUrl + ")，" +
      "之后在 uozi 的所有项目里都不用再签。",
    "Thanks for your contribution! Before we can merge, each contributor needs to sign our " +
      "[Contributor License Agreement](" + documentUrl + ") once; it then covers all uozi projects.",
    "",
    "读完协议后，**在本 PR 下单独发一条评论**，内容只写下面这句 / After reading it, post a comment containing only:",
    "",
    "```",
    SIGN_PHRASE,
    "```",
  );
  if (result.unsigned.length) {
    lines.push("", "还没签 / Not signed yet: " + result.unsigned.map((p) => "@" + p.login).join(" "));
  }
  if (result.unlinked.length) {
    lines.push(
      "",
      "下面这些提交的作者邮箱没有关联任何 GitHub 账号，无法确认是谁。请把邮箱加到自己的 GitHub 账号" +
        "（Settings → Emails）后评论 `recheck`，或改用账号关联的邮箱重写提交。",
      "These commit authors' emails aren't linked to a GitHub account. Add the email to your account " +
        "(Settings → Emails) and comment `recheck`, or rewrite the commits with a linked email:",
      ...result.unlinked.map((u) => "- `" + u.sha + "` " + u.name + " <" + u.email + ">"),
    );
  }
  lines.push("", "<sub>签署后会自动重新检查；也可以评论 `recheck` 手动触发。Signing re-runs the check automatically; comment `recheck` to re-run it.</sub>");
  return lines.join("\n");
}

export function statusFor(result) {
  if (result.ok) return { state: "success", description: "All contributors have signed the CLA" };
  const n = result.unsigned.length + result.unlinked.length;
  return { state: "failure", description: `${n} contributor(s) still need to sign the CLA` };
}
