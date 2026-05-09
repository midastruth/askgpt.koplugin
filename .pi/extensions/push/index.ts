import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import {
	createAssistantMessageEventStream,
	type Api,
	type AssistantMessage,
	type AssistantMessageEventStream,
	type Context,
	type Model,
	type SimpleStreamOptions,
} from "@mariozechner/pi-ai";

const PROVIDER = "pi-push-extension";
const MODEL_ID = "push-command-runner";
const USER_MESSAGE = "Please push this worktree to GitHub main.";

// /push pushes the current HEAD to origin/main, refuses dirty worktrees,
// never force-pushes, and then creates a GitHub release from the pushed HEAD.
// The command below is executed through Pi's normal built-in bash tool pipeline,
// so the bash tool result is recorded normally. If it fails, this extension
// restores the user's model and asks it to explain the failure and suggest fixes.
const PUSH_COMMAND = `set -euo pipefail

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Error: not inside a Git worktree." >&2
  exit 1
fi

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

REMOTE_URL="$(git remote get-url origin 2>/dev/null || true)"
if [ -z "$REMOTE_URL" ]; then
  echo "Error: no origin remote configured." >&2
  exit 1
fi

case "$REMOTE_URL" in
  *github.com*) ;;
  *)
    echo "Error: origin does not appear to be a GitHub remote: $REMOTE_URL" >&2
    exit 1
    ;;
esac

BRANCH="$(git branch --show-current || true)"
echo "Worktree: $ROOT"
echo "Current branch: \${BRANCH:-detached HEAD}"
echo "Origin: $REMOTE_URL"
echo

echo "Git status:"
git status --short
echo

if [ -n "$(git status --porcelain)" ]; then
  echo "Error: worktree has uncommitted changes. Commit or stash them before /push." >&2
  exit 1
fi

echo "Fetching origin main..."
git fetch origin main

echo "Pushing current HEAD to origin/main..."
git push origin HEAD:main

echo "Push complete."
echo

echo "Preparing GitHub release..."
if ! command -v gh >/dev/null 2>&1; then
  echo "Error: GitHub CLI (gh) is required to create the release." >&2
  exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
  echo "Error: GitHub CLI is not authenticated. Run: gh auth login" >&2
  exit 1
fi

COMMIT_FULL="$(git rev-parse HEAD)"
COMMIT_SHORT="$(git rev-parse --short HEAD)"
VERSION=""

if [ -f _meta.lua ]; then
  VERSION="$(sed -nE 's/.*version[[:space:]]*=[[:space:]]*"([^"]+)".*/\\1/p' _meta.lua | head -n 1)"
fi

if [ -z "$VERSION" ] && [ -f package.json ]; then
  VERSION="$(python3 - <<'PY' 2>/dev/null || true
import json
with open('package.json', 'r', encoding='utf-8') as f:
    print(json.load(f).get('version', ''))
PY
)"
fi

if [ -z "$VERSION" ]; then
  VERSION="$(date -u +%Y%m%d%H%M%S)-$COMMIT_SHORT"
fi

case "$VERSION" in
  v*)
    TAG="$VERSION"
    RELEASE_VERSION="\${VERSION#v}"
    ;;
  *)
    TAG="v$VERSION"
    RELEASE_VERSION="$VERSION"
    ;;
esac

echo "Release tag: $TAG"

if gh release view "$TAG" >/dev/null 2>&1; then
  echo "Error: GitHub release $TAG already exists. Bump the project version or delete the existing release before running /push again." >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
cleanup_release_tmp() {
  rm -rf "$TMP_DIR"
}
trap cleanup_release_tmp EXIT

NOTES_PATH="$TMP_DIR/release-notes.md"
ASSET_PATH=""
ASSET_SHA=""

if [ -f _meta.lua ] && [ -f main.lua ]; then
  if ! command -v python3 >/dev/null 2>&1; then
    echo "Error: python3 is required to build the KOReader plugin release zip." >&2
    exit 1
  fi

  PLUGIN_NAME="$(basename "$ROOT")"
  ASSET_NAME="$PLUGIN_NAME-$RELEASE_VERSION-$COMMIT_SHORT.zip"
  ASSET_PATH="$TMP_DIR/$ASSET_NAME"

  echo "Building release asset: $ASSET_NAME"
  python3 - "$ASSET_PATH" "$PLUGIN_NAME" <<'PY'
import pathlib
import subprocess
import sys
import zipfile

out = pathlib.Path(sys.argv[1])
plugin_name = sys.argv[2]
tracked = subprocess.check_output(['git', 'ls-files'], text=True).splitlines()
files = []
for name in tracked:
    path = pathlib.PurePosixPath(name)
    if not name.endswith('.lua'):
        continue
    if len(path.parts) == 1 or path.parts[0] == 'askgpt':
        files.append(name)
if not files:
    raise SystemExit('No plugin Lua files found for release asset')
with zipfile.ZipFile(out, 'w', compression=zipfile.ZIP_DEFLATED) as z:
    for name in sorted(files):
        z.write(name, f'{plugin_name}/{name}')
PY

  ASSET_SHA="$(sha256sum "$ASSET_PATH" | awk '{print $1}')"
  cat > "$NOTES_PATH" <<EOF
Automated release for commit $COMMIT_FULL.

## Asset SHA256

\`\`\`
$ASSET_SHA  $ASSET_NAME
\`\`\`
EOF

  echo "Creating GitHub release $TAG with asset $ASSET_NAME..."
  gh release create "$TAG" "$ASSET_PATH" --target main --title "$TAG" --notes-file "$NOTES_PATH"
else
  cat > "$NOTES_PATH" <<EOF
Automated release for commit $COMMIT_FULL.
EOF

  echo "Creating GitHub release $TAG..."
  gh release create "$TAG" --target main --title "$TAG" --notes-file "$NOTES_PATH"
fi

RELEASE_URL="$(gh release view "$TAG" --json url --jq .url 2>/dev/null || true)"
if [ -n "$RELEASE_URL" ]; then
  echo "Release created: $RELEASE_URL"
else
  echo "Release created: $TAG"
fi

echo "Exit code: 0"`;

type RunState = {
	toolCallId: string;
	restoreModel?: Model<any>;
	restoreThinkingLevel: ReturnType<ExtensionAPI["getThinkingLevel"]>;
	restoreTools: string[];
	failureOutput?: string;
};

function createAssistant(model: Model<Api>, stopReason: AssistantMessage["stopReason"]): AssistantMessage {
	return {
		role: "assistant",
		content: [],
		api: model.api,
		provider: model.provider,
		model: model.id,
		usage: {
			input: 0,
			output: 0,
			cacheRead: 0,
			cacheWrite: 0,
			totalTokens: 0,
			cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
		},
		stopReason,
		timestamp: Date.now(),
	};
}

function textFromContent(content: unknown): string {
	if (typeof content === "string") return content;
	if (!Array.isArray(content)) return "";
	return content
		.map((block) => {
			if (block && typeof block === "object" && (block as any).type === "text") {
				return String((block as any).text ?? "");
			}
			return "";
		})
		.join("\n")
		.trim();
}

function findRunToolResult(context: Context, toolCallId: string): any | undefined {
	for (let i = context.messages.length - 1; i >= 0; i--) {
		const message = context.messages[i] as any;
		if (message?.role === "toolResult" && message.toolCallId === toolCallId) {
			return message;
		}
	}
	return undefined;
}

function streamText(model: Model<Api>, text: string): AssistantMessageEventStream {
	const stream = createAssistantMessageEventStream();
	const output = createAssistant(model, "stop");
	output.content.push({ type: "text", text });

	queueMicrotask(() => {
		stream.push({ type: "start", partial: output });
		stream.push({ type: "text_start", contentIndex: 0, partial: output });
		stream.push({ type: "text_delta", contentIndex: 0, delta: text, partial: output });
		stream.push({ type: "text_end", contentIndex: 0, content: text, partial: output });
		stream.push({ type: "done", reason: "stop", message: output });
		stream.end();
	});

	return stream;
}

function streamPushToolCall(model: Model<Api>, toolCallId: string): AssistantMessageEventStream {
	const stream = createAssistantMessageEventStream();
	const output = createAssistant(model, "toolUse");
	const toolCall = {
		type: "toolCall" as const,
		id: toolCallId,
		name: "bash",
		arguments: {},
	};
	output.content.push(toolCall);

	queueMicrotask(() => {
		stream.push({ type: "start", partial: output });
		stream.push({ type: "toolcall_start", contentIndex: 0, partial: output });
		const args = { command: PUSH_COMMAND, timeout: 300 };
		toolCall.arguments = args;
		stream.push({ type: "toolcall_delta", contentIndex: 0, delta: JSON.stringify(args), partial: output });
		stream.push({ type: "toolcall_end", contentIndex: 0, toolCall, partial: output });
		stream.push({ type: "done", reason: "toolUse", message: output });
		stream.end();
	});

	return stream;
}

function failureAdvicePrompt(output: string): string {
	return `The /push extension failed while trying to push the current worktree to GitHub main and create a GitHub release.

Please read the recorded bash output below, then explain the likely cause and give concise, actionable next steps for the user. Do not rerun commands unless the user asks.

Bash output:
\`\`\`
${output || "(no output captured)"}
\`\`\``;
}

export default function pushExtension(pi: ExtensionAPI) {
	let activeRun: RunState | undefined;

	pi.registerProvider(PROVIDER, {
		baseUrl: "http://localhost/pi-push-extension",
		apiKey: "pi-push-extension-local",
		api: "pi-push-extension-api",
		models: [
			{
				id: MODEL_ID,
				name: "Pi /push Command Runner",
				reasoning: false,
				input: ["text"],
				cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
				contextWindow: 8192,
				maxTokens: 1024,
			},
		],
		streamSimple(model, context, _options?: SimpleStreamOptions) {
			if (!activeRun) {
				return streamText(model, "This synthetic model is only used internally by the /push command.");
			}

			const toolResult = findRunToolResult(context, activeRun.toolCallId);
			if (!toolResult) {
				return streamPushToolCall(model, activeRun.toolCallId);
			}

			const output = textFromContent(toolResult.content);
			if (toolResult.isError) {
				activeRun.failureOutput = output;
				const suffix = output ? " The bash output is in the tool result above." : "";
				return streamText(
					model,
					`/push failed.${suffix} I will restore your selected model and ask it for troubleshooting suggestions. No force push was attempted.`,
				);
			}

			const suffix = output ? " The bash output is in the tool result above." : "";
			return streamText(
				model,
				`/push completed and the GitHub release was created.${suffix} Current HEAD was pushed with \`git push origin HEAD:main\`. No force push was attempted.`,
			);
		},
	});

	pi.registerCommand("push", {
		description: "Safely push current HEAD to GitHub origin/main and create a GitHub release",
		handler: async (_args, ctx) => {
			if (!ctx.isIdle()) {
				ctx.ui.notify("/push can only start when Pi is idle.", "warning");
				return;
			}
			if (activeRun) {
				ctx.ui.notify("/push is already running.", "warning");
				return;
			}
			if (!ctx.model) {
				ctx.ui.notify("Select a model before /push so Pi can restore it afterward.", "warning");
				return;
			}

			const syntheticModel = ctx.modelRegistry.find(PROVIDER, MODEL_ID);
			if (!syntheticModel) {
				ctx.ui.notify("/push synthetic provider was not registered. Try /reload.", "error");
				return;
			}

			const previousTools = pi.getActiveTools();
			if (!previousTools.includes("bash")) {
				pi.setActiveTools([...previousTools, "bash"]);
				if (!pi.getActiveTools().includes("bash")) {
					pi.setActiveTools(previousTools);
					ctx.ui.notify("/push requires the built-in bash tool, but it is not available.", "error");
					return;
				}
			}

			activeRun = {
				toolCallId: `push-${Date.now().toString(36)}`,
				restoreModel: ctx.model,
				restoreThinkingLevel: pi.getThinkingLevel(),
				restoreTools: previousTools,
			};

			const switched = await pi.setModel(syntheticModel);
			if (!switched) {
				pi.setActiveTools(previousTools);
				activeRun = undefined;
				ctx.ui.notify("/push could not switch to its synthetic command runner.", "error");
				return;
			}

			pi.sendUserMessage(USER_MESSAGE);
		},
	});

	pi.on("agent_end", async () => {
		if (!activeRun) return;

		const run = activeRun;
		activeRun = undefined;
		pi.setActiveTools(run.restoreTools);

		if (run.restoreModel) {
			await pi.setModel(run.restoreModel);
			pi.setThinkingLevel(run.restoreThinkingLevel);
		}

		if (run.failureOutput !== undefined) {
			pi.sendUserMessage(failureAdvicePrompt(run.failureOutput), { deliverAs: "followUp" });
		}
	});
}
