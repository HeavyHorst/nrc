import type { PluginAPI, PluginCommandContext, PluginThread, ThreadID } from '@ampcode/plugin'

export const description = 'Distills the active or another accessible Amp thread into compact, searchable NRC room memory.'

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

	amp.registerCommand(
		'nrc-memory.learn-thread-by-id',
		{
			title: 'Learn thread by ID',
			category: 'NRC Memory',
			description: 'Ask the current agent to import and distill another accessible Amp thread into NRC memory.',
		},
		async (ctx) => {
			await askCurrentAgentToLearnAnotherThread(amp, ctx)
		},
	)
}

async function askCurrentAgentToLearnThread(ctx: PluginCommandContext) {
	if (!ctx.thread) {
		await ctx.ui.notify('NRC Memory: no active Amp thread.')
		return
	}

	const threadURL = new URL(`/threads/${ctx.thread.id}`, ctx.system.ampURL).toString()
	const prompt = buildMemoryPrompt(threadURL, await threadTitle(ctx.thread))

	await ctx.thread.appendUserMessage(
		{
			type: 'user-message',
			content: prompt,
		},
		{ steer: true },
	)

	await ctx.ui.notify('NRC Memory: asked the current agent to learn this thread.')
}

async function askCurrentAgentToLearnAnotherThread(amp: PluginAPI, ctx: PluginCommandContext) {
	if (!ctx.thread) {
		await ctx.ui.notify('NRC Memory: no active Amp thread.')
		return
	}

	const input = await ctx.ui.input({
		title: 'Learn another Amp thread',
		helpText: 'Enter an Amp thread ID or URL. The current agent will read that thread and update NRC memory.',
		fieldName: 'AMP_THREAD_ID_OR_URL',
		submitButtonText: 'Learn thread',
	})
	if (input === undefined) {
		return
	}

	const threadID = parseThreadID(input)
	if (threadID === null) {
		await ctx.ui.notify('NRC Memory: expected a thread ID or URL containing T-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx.')
		return
	}

	const sourceThread = amp.threads.get(threadID)
	try {
		await sourceThread.messages({ from: 'end', limit: 1 })
	} catch {
		await ctx.ui.notify(`NRC Memory: thread ${threadID} is unavailable or inaccessible.`)
		return
	}

	const threadURL = new URL(`/threads/${threadID}`, ctx.system.ampURL).toString()
	const prompt = buildMemoryPrompt(threadURL, await threadTitle(sourceThread), true)
	await ctx.thread.appendUserMessage(
		{
			type: 'user-message',
			content: prompt,
		},
		{ steer: true },
	)

	await ctx.ui.notify(`NRC Memory: asked the current agent to learn ${threadID}.`)
}

// An NRC record's Amp-thread ledger prints the link text, not the URL, so the
// source line has to carry the thread's name: a bare URL would only ever read as
// its thread id.
async function threadTitle(thread: PluginThread): Promise<string> {
	try {
		const title = await thread.title.get()
		return typeof title === 'string' ? title.trim() : ''
	} catch {
		return ''
	}
}

function parseThreadID(input: string): ThreadID | null {
	const match = input.trim().match(/\b(T-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\b/i)
	return match ? match[1] as ThreadID : null
}

function buildMemoryPrompt(threadURL: string, title: string, imported = false): string {
	const source = title
		? `\`Source: [${title}](${threadURL})\``
		: `a titled markdown link to ${threadURL} — this thread has no title yet, so name its subject as the link text`
	const subject = imported
		? `Before writing, use the read_thread tool to read the source thread at ${threadURL}. Distill that imported source thread, not this command thread.`
		: 'Distill this thread into durable NRC notes.'

	return `Use the maintaining-room-memory skill.

${subject}

Update existing canonical notes where appropriate; create new notes for distinct durable concepts.

Follow the skill's Writing Workflow: choose keep, reconcile, condense, or create; no write is a valid outcome. For each update, identify what it supersedes and what evidence must survive. Replace superseded checkpoints rather than prepending another status banner.

Preserve scope and meaning. Distinguish explicit rules from observations and inferences; never turn example inputs into prerequisites. Preserve applicable exceptions. Make the current guidance clear; retain older guidance only when it remains applicable or provides important decision context. Limit supersession to its stated scope.

Preview the operations and check the draft against its sources before writing. Record the source thread as a titled source link only when permitted by the skill's private-source provenance rules: ${source}. Otherwise omit identifying provenance and retain only the authorized, safely generalized finding.

After writing, verify content and discoverability with an exact identifier when available and a likely natural-language query. Treat search ranking and index freshness separately from factual correctness.`
}
