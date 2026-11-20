// CLA 检查的入口，由 .github/workflows/cla.yml 调用。逻辑在 lib.mjs，这里只做 GitHub API 的读写。
//
// 环境变量：
//   GITHUB_TOKEN          本仓库的 token（读 PR、写评论与 commit status）
//   CLA_SIGNATURES_TOKEN  能写签名仓库的 token（fine-grained PAT，只给签名仓库 Contents 读写）
//   CLA_SIGNATURES_REPO   签名仓库，如 uozi-tech/cla-signatures（私有）
//   CLA_SIGNATURES_PATH   签名文件路径，如 signatures/cla-v1.json
//   CLA_DOCUMENT_URL      协议全文的链接
// 不要在这里 checkout 或执行 PR 里的代码：pull_request_target 带着 secrets。
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import * as cla from "./lib.mjs";

const env = (k) => {
  const v = process.env[k];
  if (!v) throw new Error(`缺环境变量 ${k}`);
  return v;
};

async function api(token, method, path, body) {
  const res = await fetch(`https://api.github.com${path}`, {
    method,
    headers: {
      authorization: `Bearer ${token}`,
      accept: "application/vnd.github+json",
      "x-github-api-version": "2022-11-28",
      ...(body ? { "content-type": "application/json" } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  if (res.status === 404 && method === "GET") return null;
  if (!res.ok) {
    const err = new Error(`${method} ${path} → ${res.status} ${await res.text()}`);
    err.status = res.status;
    throw err;
  }
  return res.status === 204 ? null : res.json();
}

async function paginate(token, path) {
  const out = [];
  for (let page = 1; ; page++) {
    const sep = path.includes("?") ? "&" : "?";
    const batch = await api(token, "GET", `${path}${sep}per_page=100&page=${page}`);
    out.push(...batch);
    if (batch.length < 100) return out;
  }
}

async function loadSignatures(token, repo, path) {
  const file = await api(token, "GET", `/repos/${repo}/contents/${path}`);
  if (!file) return { signatures: [], sha: undefined };
  return { signatures: JSON.parse(Buffer.from(file.content, "base64").toString("utf8")), sha: file.sha };
}

/** 追加一条签名并提交到签名仓库；别人同时在写（409 / 422）就重读再试。 */
async function recordSignature(token, repo, path, record) {
  for (let attempt = 0; attempt < 5; attempt++) {
    const { signatures, sha } = await loadSignatures(token, repo, path);
    const next = cla.addSignature(signatures, record);
    if (next === signatures) return signatures;
    try {
      await api(token, "PUT", `/repos/${repo}/contents/${path}`, {
        message: `CLA ${record.claVersion}: @${record.login} 签署（${record.repo}#${record.pr}）`,
        content: Buffer.from(JSON.stringify(next, null, 2) + "\n").toString("base64"),
        ...(sha ? { sha } : {}),
      });
      return next;
    } catch (e) {
      if (e.status !== 409 && e.status !== 422) throw e;
      await new Promise((r) => setTimeout(r, 500 * (attempt + 1)));
    }
  }
  throw new Error("签名文件一直在被别人改，写入失败");
}

async function upsertComment(token, repo, pr, body, { createIfMissing }) {
  const comments = await paginate(token, `/repos/${repo}/issues/${pr}/comments`);
  const mine = comments.find((c) => cla.isBot(c.user) && c.body?.includes(cla.MARKER));
  if (mine) {
    if (mine.body !== body) await api(token, "PATCH", `/repos/${repo}/issues/comments/${mine.id}`, { body });
  } else if (createIfMissing) {
    await api(token, "POST", `/repos/${repo}/issues/${pr}/comments`, { body });
  }
}

export async function main() {
  const event = JSON.parse(readFileSync(env("GITHUB_EVENT_PATH"), "utf8"));
  const eventName = env("GITHUB_EVENT_NAME");
  const repo = env("GITHUB_REPOSITORY");
  const token = env("GITHUB_TOKEN");
  const sigToken = env("CLA_SIGNATURES_TOKEN");
  const sigRepo = env("CLA_SIGNATURES_REPO");
  const sigPath = env("CLA_SIGNATURES_PATH");
  const documentUrl = env("CLA_DOCUMENT_URL");

  let pr;
  let signComment = null;
  if (eventName === "issue_comment") {
    if (!event.issue?.pull_request || cla.isBot(event.comment?.user)) return;
    const body = event.comment?.body;
    if (cla.isSignComment(body)) signComment = event.comment;
    else if (!cla.isRecheckComment(body)) return;
    pr = event.issue.number;
  } else if (eventName === "pull_request_target") {
    pr = event.pull_request.number;
  } else {
    return;
  }

  const allowlist = cla.parseAllowlist(
    readFileSync(fileURLToPath(new URL("./allowlist.txt", import.meta.url)), "utf8"),
  );
  let { signatures } = await loadSignatures(sigToken, sigRepo, sigPath);

  if (signComment) {
    // 任何人贴出签署语句都记下（也允许先签后提 PR）；以评论为证，记评论链接与时间。
    signatures = await recordSignature(sigToken, sigRepo, sigPath, {
      id: signComment.user.id,
      login: signComment.user.login,
      claVersion: cla.CLA_VERSION,
      signedAt: signComment.created_at,
      repo,
      pr,
      commentId: signComment.id,
      commentUrl: signComment.html_url,
    });
  }

  const pull = await api(token, "GET", `/repos/${repo}/pulls/${pr}`);
  const commits = await paginate(token, `/repos/${repo}/pulls/${pr}/commits`);
  const result = cla.evaluate({ commits, allowlist, signatures });

  await api(token, "POST", `/repos/${repo}/statuses/${pull.head.sha}`, {
    context: "cla",
    target_url: documentUrl,
    ...cla.statusFor(result),
  });
  await upsertComment(token, repo, pr, cla.renderComment({ result, documentUrl }), { createIfMissing: !result.ok });

  console.log(
    `PR #${pr}：需签 ${result.required.map((p) => p.login).join(", ") || "（无）"}；` +
      `未签 ${result.unsigned.map((p) => p.login).join(", ") || "（无）"}；邮箱未关联 ${result.unlinked.length} 个`,
  );
  // 不用失败的退出码表达「没签」：签完后旧的那次运行会一直红着。合并门禁只看 commit status「cla」。
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch((e) => {
    console.error(e);
    process.exit(2);
  });
}
