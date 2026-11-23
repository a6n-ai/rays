// WebMCP: lets an AI agent in the browser read install facts without scraping the page.
// No-op in browsers without document.modelContext.
type Tool = {
	name: string;
	description: string;
	inputSchema: object;
	execute: () => Promise<{ content: { type: 'text'; text: string }[] }>;
};
const ctx = (document as unknown as { modelContext?: { registerTool(t: Tool): Promise<unknown> } }).modelContext;

if (ctx) {
	const info = {
		name: 'Rays',
		requires: 'macOS 26 or later',
		dmg: 'https://rays.a6n.ai/download/Rays.dmg?src=agent',
		homebrew: 'brew trust a6n-ai/tap && brew install --cask a6n-ai/tap/rays',
		firstOpen: 'DMG installs: System Settings > Privacy & Security > Open Anyway. Homebrew skips this.',
		cli: 'https://rays.a6n.ai/docs/dl/',
		mcp: 'dl mcp (stdio). Claude Code: claude mcp add rays -- dl mcp',
		releaseNotes: 'https://rays.a6n.ai/releases/',
	};
	ctx
		.registerTool({
			name: 'get_install_options',
			description: 'How to install Rays on a Mac: DMG link, Homebrew command, requirements, CLI and MCP setup.',
			inputSchema: { type: 'object', properties: {} },
			execute: async () => ({ content: [{ type: 'text', text: JSON.stringify(info, null, 2) }] }),
		})
		.catch(() => {});
}
