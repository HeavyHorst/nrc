import type { PluginAPI, PluginCommandContext } from '@ampcode/plugin'

export const description = 'Distills the active Amp thread into compact, searchable NRC room memory.'

// NRC memory shortcut plugin.
//
// Command: "NRC Memory: Learn current thread"
//
// This intentionally does not analyze or write NRC notes itself. It appends a
// canonical instruction to the current Amp thread so the current agent can use
// its full context plus the maintaining-room-memory skill.

export default function (amp: PluginAPI) {
	amp.logger.log('NRC memory shortcut plugin initialized')

	amp.registerCommand(
		'nrc-memory.learn-current-thread',
		{
			title: 'Learn current thread',
			category: 'NRC Memory',
			description: 'Ask the current agent to distill this thread into durable NRC notes using the room memory skill.',
		},
		async (ctx) => {
			await askCurrentAgentToLearnThread(ctx)
		},
	)
}

async function askCurrentAgentToLearnThread(ctx: PluginCommandContext) {
	if (!ctx.thread) {
		await ctx.ui.notify('NRC Memory: no active Amp thread.')
		return
	}

	const threadURL = new URL(`/threads/${ctx.thread.id}`, ctx.system.ampURL).toString()
	const prompt = buildMemoryPrompt(threadURL, await threadTitle(ctx))

	await ctx.thread.appendUserMessage(
		{
			type: 'user-message',
			content: prompt,
		},
		{ steer: true },
	)

	await ctx.ui.notify('NRC Memory: asked the current agent to learn this thread.')
}

// An NRC record's Amp-thread ledger prints the link text, not the URL, so the
// source line has to carry the thread's name: a bare URL would only ever read as
// its thread id.
async function threadTitle(ctx: PluginCommandContext): Promise<string> {
	try {
		const title = await ctx.thread?.title?.get()
		return typeof title === 'string' ? title.trim() : ''
	} catch {
		return ''
	}
}

function buildMemoryPrompt(threadURL: string, title: string): string {
	const source = title
		? `\`Source: [${title}](${threadURL})\``
		: `a titled markdown link to ${threadURL} — this thread has no title yet, so name its subject as the link text`

	return `Use the maintaining-room-memory skill to distill this thread into durable NRC notes. Update existing canonical notes where appropriate; create new notes for distinct durable concepts.

Preserve scope and meaning. Distinguish explicit rules from observations and inferences; never turn example inputs into prerequisites. Preserve applicable exceptions. Make the current guidance clear; retain older guidance only when it remains applicable or provides important decision context. Limit supersession to its stated scope.

Preview the operations and check the draft against its sources before writing. Record this thread as a titled source link in the note body: ${source}.

After writing, verify content and discoverability with an exact identifier when available and a likely natural-language query. Treat search ranking and index freshness separately from factual correctness.`
}
