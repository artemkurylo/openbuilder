/**
 * openbuilder — pre-tool guardrails
 *
 * Installed as `.omp/hooks/pre/guardrails.ts` for both the laptop (planner /
 * reviewer) and the EC2 box (implementer). It is the last line of defense behind
 * the agent prompts: the prompts say "never merge, never force-push"; this hook
 * makes those sentences enforceable.
 *
 * A `tool_call` handler that returns `{ block: true, reason }` aborts the call and
 * surfaces `reason` to the model as the thrown error text. A handler that throws
 * also fails closed. So a bug here fails safe (over-blocking), never open.
 *
 * Everything is table-driven. Three tables, each auditable at a glance:
 *
 *   1. BASH_RULES  — regexes over a `bash` command string.
 *   2. PATH_RULES  — regexes over filesystem paths extracted from `write` / `edit`.
 *   3. TOOL_RULES  — structured predicates over a specific tool's arguments,
 *                    for prohibitions that have a non-shell spelling.
 *
 * The seven prohibitions, and where each is enforced:
 *
 *   | # | Prohibition                              | Table(s)              |
 *   |---|------------------------------------------|-----------------------|
 *   | 1 | `gh pr merge` (and the merge REST call)  | BASH_RULES            |
 *   | 2 | `git push --force` / `-f` / with-lease   | BASH_RULES, TOOL_RULES|
 *   | 3 | `git push` targeting main/master/HEAD:*  | BASH_RULES            |
 *   | 4 | `git reset --hard` outside the worktree  | BASH_RULES            |
 *   | 5 | `rm -rf /` and `rm -rf ~`                | BASH_RULES            |
 *   | 6 | `aws ec2 terminate-instances`            | BASH_RULES            |
 *   | 7 | any write touching /opt/openbuilder/etc  | BASH_RULES, PATH_RULES|
 *
 * Adding a rule means adding a row. Do not add ad-hoc `if` statements below the
 * tables — the point of the tables is that a reader can audit the complete policy
 * without reading the matching engine.
 */

import type { HookAPI } from "@oh-my-pi/pi-coding-agent/extensibility/hooks";
import { isAbsolute, resolve } from "node:path";

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/**
 * The only tree the remote agent is allowed to destructively reset. Story work
 * happens in `git worktree`s at /opt/openbuilder/work/<owner>__<repo>__<slug>/.
 */
const WORKTREE_ROOT = "/opt/openbuilder/work";

/**
 * The runner's own configuration directory. `openbuilder.env` is rendered by
 * cloud-init and read by every runner script; an agent that can rewrite it can
 * repoint the model, the repo list, or the branch prefix and thereby escape every
 * other control in this file.
 */
const RUNNER_CONFIG_DIR = "/opt/openbuilder/etc";

// ---------------------------------------------------------------------------
// Regex building blocks
//
// Shell command strings routinely contain several commands (`a && b`, `a; b`,
// `a | b`, subshells, `if ... then ...`). Anchoring on `^` would let `true; rm -rf /`
// walk straight past every rule, so each rule anchors on a *command-segment start*
// instead, skips any launcher prefix (`sudo`, `env`, `FOO=bar`), and confines its
// argument scanning to a single segment via [^\n;&|].
// ---------------------------------------------------------------------------

/** Start of a command segment. */
const SEGMENT = String.raw`(?:^|[\n;&|(){]|\bthen\b|\bdo\b|\belse\b)\s*`;

/** Prefixes that delegate to the real command without changing what it does. */
const LAUNCHERS =
  String.raw`(?:(?:[A-Za-z_][A-Za-z0-9_]*=\S*|sudo|doas|env|command|exec|nohup|nice|time|stdbuf|setsid)\s+)*`;

/** Lazy run of arguments that cannot cross into the next command segment. */
const ARGS = String.raw`[^\n;&|]*?`;

/** End of a token: whitespace, end of string, or a segment separator. */
const TOKEN_END = String.raw`(?=\s|$|[;&|)])`;

/** Compose a command-segment-anchored rule pattern. */
function segmentPattern(...parts: readonly string[]): RegExp {
  return new RegExp(SEGMENT + LAUNCHERS + parts.join(""));
}

/** `git` plus any leading global flags (`-C <dir>`, `--git-dir=...`, `-c k=v`). */
const GIT = String.raw`git\b`;

// ---------------------------------------------------------------------------
// Table 1 — bash command rules
// ---------------------------------------------------------------------------

interface BashRule {
  /** Stable id, quoted in the block reason so a human can grep this file. */
  readonly id: string;
  /** What the rule is for, in one line. Kept next to the pattern on purpose. */
  readonly what: string;
  /** Matched against the whole `bash` command string. Must not use the `g` flag. */
  readonly pattern: RegExp;
  /** Message shown to the model. Explains the rule, not just the refusal. */
  readonly reason: string;
  /**
   * Optional escape valve for rules that are only violations in some contexts.
   * Return `true` to allow a command the pattern matched.
   */
  readonly allow?: (command: string, cwd: string) => boolean;
}

const BASH_RULES: readonly BashRule[] = [
  {
    id: "no-merge",
    what: "`gh pr merge` in any form",
    pattern: segmentPattern(String.raw`gh\b`, ARGS, String.raw`\bpr\s+merge\b`),
    reason:
      "Blocked by openbuilder guardrail 'no-merge': agents never merge. A pull " +
      "request is merged by a human, after the reviewer has set the " +
      "openbuilder:approved label. Push your commits to openbuilder/work/<slug> " +
      "and stop there.",
  },
  {
    id: "no-merge-api",
    what: "the merge REST endpoint — the same prohibition, spelled through `gh api`",
    pattern: segmentPattern(
      String.raw`gh\b`,
      ARGS,
      String.raw`\bapi\b`,
      ARGS,
      String.raw`\bpulls/\d+/merge\b`,
    ),
    reason:
      "Blocked by openbuilder guardrail 'no-merge-api': PUT /repos/.../pulls/N/merge " +
      "is `gh pr merge` by another name. Merging is a human action; see guardrail " +
      "'no-merge'.",
  },
  {
    id: "no-force-push",
    what: "`git push --force`, `-f`, `--force-with-lease`, and `+refspec`",
    pattern: segmentPattern(
      GIT,
      ARGS,
      String.raw`\bpush\b`,
      ARGS,
      String.raw`\s(?:--force(?:-with-lease)?(?:=\S*)?|-f|\+[^\s;&|]+)`,
      TOKEN_END,
    ),
    reason:
      "Blocked by openbuilder guardrail 'no-force-push': the work branch's commit " +
      "history is the audit trail of an unattended agent, and the reviewer's line " +
      "comments are anchored to its commit SHAs. Rewriting it destroys both. Add a " +
      "new commit instead — `+refspec` and `--force-with-lease` are force pushes too.",
  },
  {
    id: "no-default-branch-push",
    what: "`git push` whose destination ref is main or master (including `HEAD:main`)",
    pattern: segmentPattern(
      GIT,
      ARGS,
      String.raw`\bpush\b`,
      ARGS,
      String.raw`\s(?:[^\s;&|]*:)?(?:refs/heads/)?(?:main|master)`,
      TOKEN_END,
    ),
    reason:
      "Blocked by openbuilder guardrail 'no-default-branch-push': the only branch " +
      "this agent may push is openbuilder/work/<slug>. A default branch is reached " +
      "exclusively through a reviewed, human-merged pull request — that includes " +
      "refspec forms such as `HEAD:main` and `work:refs/heads/master`.",
  },
  {
    id: "no-reset-hard-outside-worktree",
    what: "`git reset --hard` on any tree other than this job's worktree",
    pattern: segmentPattern(GIT, ARGS, String.raw`\breset\b`, ARGS, String.raw`\s--hard\b`),
    allow: (command, cwd) => gitTargetsWorktree(command, cwd),
    reason:
      `Blocked by openbuilder guardrail 'no-reset-hard-outside-worktree': ` +
      `\`git reset --hard\` discards uncommitted work irrecoverably, and this ` +
      `command is not scoped to a worktree under ${WORKTREE_ROOT}/. It is allowed ` +
      `only when the working directory is inside that tree, or when it is scoped ` +
      `there explicitly with \`git -C ${WORKTREE_ROOT}/<job> ...\`. The runner's ` +
      `clones in /opt/openbuilder/src and /opt/openbuilder/repo are shared state ` +
      `and must never be reset by a job.`,
  },
  {
    id: "no-recursive-root-delete",
    what: "`rm -rf /` and `rm -rf ~` (also /*, ~/, ~/*, $HOME)",
    pattern: segmentPattern(
      String.raw`rm\b`,
      // Require both a recursive and a force flag somewhere in this segment, so
      // `-rf`, `-fr`, `-r -f` and `--recursive --force` are all caught.
      String.raw`(?=[^\n;&|]*?\s-{1,2}[A-Za-z-]*r)`,
      String.raw`(?=[^\n;&|]*?\s-{1,2}[A-Za-z-]*f)`,
      ARGS,
      String.raw`\s(?:/|~|\$HOME|"\$HOME"|\$\{HOME\})(?:/\*?|\*)?`,
      TOKEN_END,
    ),
    reason:
      "Blocked by openbuilder guardrail 'no-recursive-root-delete': this deletes " +
      "the filesystem root or the openbuilder home directory (/opt/openbuilder), " +
      "taking the runner scripts, the systemd units, the git clones and the state " +
      "directory with it. There is no legitimate reason for a story to do this. " +
      "Delete specific paths inside your worktree instead.",
  },
  {
    id: "no-instance-termination",
    what: "`aws ec2 terminate-instances`",
    pattern: segmentPattern(
      String.raw`aws\b`,
      ARGS,
      String.raw`\bec2\s+terminate-instances\b`,
    ),
    reason:
      "Blocked by openbuilder guardrail 'no-instance-termination': terminating the " +
      "instance destroys the root volume — every worktree, every unpushed commit, " +
      "the state directory and the log. The instance profile intentionally grants " +
      "ec2:StopInstances and not ec2:TerminateInstances; `ob-idle-stop` stops the " +
      "box, and Terraform is the only thing that may replace it.",
  },
  {
    id: "no-runner-config-redirect",
    what: `shell redirection into ${RUNNER_CONFIG_DIR}`,
    pattern: new RegExp(
      String.raw`(?:\d?>>?|>\|)\s*(?:["']?)` + escapeRegExp(RUNNER_CONFIG_DIR) + String.raw`(?:/|\b)`,
    ),
    reason:
      `Blocked by openbuilder guardrail 'no-runner-config-redirect': ` +
      `${RUNNER_CONFIG_DIR} holds openbuilder.env, which every runner script sources ` +
      `and which defines the model, the repo allow-list, the branch prefix and the ` +
      `attempt ceiling. It is owned by cloud-init and Terraform. An agent that can ` +
      `rewrite it can escape every other guardrail, so writes here are refused ` +
      `unconditionally — change infra/ and re-apply instead.`,
  },
  {
    id: "no-runner-config-mutate",
    what: `mutating commands aimed at ${RUNNER_CONFIG_DIR}`,
    pattern: new RegExp(
      String.raw`\b(?:tee|sed\s+-i\S*|perl\s+-\S*i\S*|truncate|dd|install|chmod|chown|chgrp|rm|rmdir|mkdir|touch|ln|mv|cp|shred|sponge)\b[^\n;&|]*` +
        escapeRegExp(RUNNER_CONFIG_DIR) +
        String.raw`(?:/|\b)`,
    ),
    reason:
      `Blocked by openbuilder guardrail 'no-runner-config-mutate': ` +
      `${RUNNER_CONFIG_DIR} is runner configuration owned by cloud-init and ` +
      `Terraform, not by a story. Creating, editing, moving, deleting or re-permissioning ` +
      `anything under it — including moving it out of the way — is refused. Reading ` +
      `it is fine; use \`cat\` or the read tool.`,
  },
];

// ---------------------------------------------------------------------------
// Table 2 — filesystem path rules (write / edit tools)
// ---------------------------------------------------------------------------

interface PathRule {
  readonly id: string;
  readonly what: string;
  /** Matched against the resolved absolute path. Must not use the `g` flag. */
  readonly pattern: RegExp;
  readonly reason: string;
}

const PATH_RULES: readonly PathRule[] = [
  {
    id: "no-runner-config-write",
    what: `any write or edit whose target is under ${RUNNER_CONFIG_DIR}`,
    pattern: new RegExp(String.raw`^` + escapeRegExp(RUNNER_CONFIG_DIR) + String.raw`(?:/|$)`),
    reason:
      `Blocked by openbuilder guardrail 'no-runner-config-write': ` +
      `${RUNNER_CONFIG_DIR} is the runner's own configuration (openbuilder.env), ` +
      `rendered by cloud-init from Terraform variables and sourced by every runner ` +
      `script. It is not part of any target repository and no story may change it. ` +
      `Edit infra/ and re-apply Terraform if the configuration is genuinely wrong.`,
  },
];

// ---------------------------------------------------------------------------
// Table 3 — structured tool-argument rules
//
// For prohibitions with a non-shell spelling. omp's `github` tool runs
// `git push --force-with-lease` itself when `pr_push` is given
// `forceWithLease: true`, which never appears in a bash command string and so is
// invisible to BASH_RULES.
// ---------------------------------------------------------------------------

interface ToolRule {
  readonly id: string;
  readonly what: string;
  /** Tool this rule applies to. */
  readonly toolName: string;
  /** Return `true` when the arguments violate the rule. */
  readonly violates: (input: Readonly<Record<string, unknown>>) => boolean;
  readonly reason: string;
}

const TOOL_RULES: readonly ToolRule[] = [
  {
    id: "no-force-push-via-github-tool",
    what: "`github` op pr_push with forceWithLease — a force push without a shell",
    toolName: "github",
    violates: (input) => input.op === "pr_push" && input.forceWithLease === true,
    reason:
      "Blocked by openbuilder guardrail 'no-force-push-via-github-tool': " +
      "`pr_push` with forceWithLease runs `git push --force-with-lease`, which " +
      "rewrites the work branch's published history. See guardrail 'no-force-push'. " +
      "Retry with forceWithLease omitted; if the push is rejected, fetch and add a " +
      "new commit rather than rewriting.",
  },
];

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function escapeRegExp(literal: string): string {
  return literal.replace(/[.*+?^${}()|[\]\\]/g, String.raw`\$&`);
}

function asString(value: unknown): string {
  return typeof value === "string" ? value : "";
}

function stripQuotes(token: string): string {
  const first = token.charAt(0);
  if ((first === '"' || first === "'") && token.endsWith(first) && token.length > 1) {
    return token.slice(1, -1);
  }
  return token;
}

/** Expand `~`, then resolve relative paths against the session cwd. */
function toAbsolute(raw: string, cwd: string): string {
  const cleaned = stripQuotes(raw.trim());
  if (cleaned === "") return "";
  const expanded = cleaned === "~" || cleaned.startsWith("~/")
    ? (process.env.HOME ?? "/root") + cleaned.slice(1)
    : cleaned;
  return isAbsolute(expanded) ? resolve(expanded) : resolve(cwd, expanded);
}

/** Trees under this prefix are the only ones a job may reset. */
const WORKTREE_PREFIX = `${WORKTREE_ROOT}/`;

/**
 * Decide whether a `git` command is confined to this job's worktree.
 *
 * If the command names a tree explicitly (`-C <dir>`, `--git-dir=...`,
 * `--work-tree=...`), every named tree must live under WORKTREE_ROOT. If it names
 * none, git operates on the working directory, so the cwd must live there instead.
 */
function gitTargetsWorktree(command: string, cwd: string): boolean {
  const explicit = [
    ...command.matchAll(
      /(?:-C|--git-dir|--work-tree)(?:[=\s]+)("[^"]*"|'[^']*'|[^\s;&|]+)/g,
    ),
  ].map((match) => toAbsolute(match[1] ?? "", cwd));

  const trees = explicit.length > 0 ? explicit : [toAbsolute(cwd, cwd)];
  return trees.every(
    (dir) => dir === WORKTREE_ROOT || dir.startsWith(WORKTREE_PREFIX),
  );
}

/**
 * Paths a `write` or `edit` call would modify.
 *
 * `write` carries a single `path`. `edit` carries a hashline payload whose section
 * headers are `[PATH#TAG]`, plus optional `MV <dest>` relocation targets. Only
 * these structural positions are inspected — never free-form body text, so a doc
 * that merely *mentions* the protected directory is still editable.
 */
function extractWritePaths(toolName: string, input: Readonly<Record<string, unknown>>): string[] {
  if (toolName === "write") {
    return [asString(input.path)].filter((value) => value !== "");
  }
  if (toolName === "edit") {
    const payload = asString(input.input);
    const sections = [...payload.matchAll(/^[ \t]*\[([^\]\n]+?)#[0-9A-Fa-f]{4}\][ \t]*$/gm)].map(
      (match) => match[1] ?? "",
    );
    const moves = [...payload.matchAll(/^[ \t]*MV[ \t]+("[^"]+"|'[^']+'|\S+)[ \t]*$/gm)].map(
      (match) => match[1] ?? "",
    );
    return [...sections, ...moves].filter((value) => value !== "");
  }
  return [];
}

// ---------------------------------------------------------------------------
// Hook
// ---------------------------------------------------------------------------

export default function guardrails(pi: HookAPI): void {
  pi.on("tool_call", (event, ctx) => {
    const input: Readonly<Record<string, unknown>> = event.input ?? {};
    // `ctx` is always supplied by the runtime, but a throwing handler makes the
    // tool wrapper fail closed and block EVERY call — so degrade, never throw.
    const cwd = typeof ctx?.cwd === "string" && ctx.cwd !== "" ? ctx.cwd : process.cwd();

    // Table 3 — structured arguments.
    for (const rule of TOOL_RULES) {
      if (event.toolName === rule.toolName && rule.violates(input)) {
        return { block: true, reason: rule.reason };
      }
    }

    // Table 1 — shell commands.
    if (event.toolName === "bash") {
      const command = asString(input.command);
      if (command !== "") {
        for (const rule of BASH_RULES) {
          if (!rule.pattern.test(command)) continue;
          if (rule.allow?.(command, cwd)) continue;
          return { block: true, reason: rule.reason };
        }
      }
    }

    // Table 2 — write/edit targets.
    for (const candidate of extractWritePaths(event.toolName, input)) {
      const absolute = toAbsolute(candidate, cwd);
      if (absolute === "") continue;
      for (const rule of PATH_RULES) {
        if (rule.pattern.test(absolute)) {
          return { block: true, reason: rule.reason };
        }
      }
    }

    return undefined;
  });
}
