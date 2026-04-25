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
// and never force-pushes. The command below is executed through Pi's normal
// built-in bash tool pipeline, so the bash tool result is recorded normally.
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
echo "Exit code: 0"`;

type RunState = {
	toolCallId: string;
	restoreModel?: Model<any>;
	restoreThinkingLevel: ReturnType<ExtensionAPI["getThinkingLevel"]>;
	restoreTools: string[];
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

			const status = toolResult.isError ? "failed" : "completed";
			const output = textFromContent(toolResult.content);
			const suffix = output ? " The bash output is in the tool result above." : "";
			return streamText(
				model,
				`/push ${status}.${suffix} Current HEAD was pushed with \`git push origin HEAD:main\` only if all preflight checks passed. No force push was attempted.`,
			);
		},
	});

	pi.registerCommand("push", {
		description: "Safely push current HEAD to GitHub origin/main",
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
	});
}
