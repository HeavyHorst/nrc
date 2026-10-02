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

	return `Use the maintaining-room-memory skill.

Distill this thread into durable NRC notes. Prefer updating existing notes over creating duplicates. Create new notes only for stable concepts with distinct future retrieval intent. Keep the result compact: normally 1-3 notes. Do not create one note per implementation step, prompt tweak, or transient error. Give a distinct incident, decision, or troubleshooting conclusion its own canonical note instead of burying it late in a broader note.

Make future retrieval deliberate: put stable identifiers and distinctive names people will search for—such as media/product numbers, ticket IDs, service names, producers, or customers—in the title when they identify the concept, otherwise in the opening metadata or finding. Add useful edges to existing and new notes. Record the thread as a titled markdown link in the note body, never as a bare URL: ${source}. NRC's Amp-thread ledger shows the link text, so the title is what future readers see.

Preview the note and edge operations before writing anything. After writing, verify discoverability with at least one exact-identifier query when an identifier exists and one likely natural-language query. If either does not surface the canonical note near the top, improve the note rather than merely reporting the weak result.`
}
