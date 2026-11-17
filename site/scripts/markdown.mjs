// After `astro build`: write dist/<page>/index.md from each page's <main>, for Accept: text/markdown (functions/[[path]].js).
import { readFile, readdir, writeFile } from 'node:fs/promises';
import TurndownService from 'turndown';

const SITE = 'https://rays.a6n.ai';
// Every HTML page except the 404 and Starlight's search bundle.
const PAGES = (await readdir('dist', { recursive: true })).filter(
	(f) => f.endsWith('index.html') && !f.startsWith('pagefind') && !f.startsWith('_astro'),
);

const td = new TurndownService({ headingStyle: 'atx', codeBlockStyle: 'fenced', bulletListMarker: '-' });
td.remove(['script', 'style', 'svg', 'form', 'button', 'header', 'footer']);
td.addRule('img', { filter: 'img', replacement: () => '' });
td.addRule('hidden', { filter: (n) => n.getAttribute?.('aria-hidden') === 'true', replacement: () => '' });
td.addRule('dt', { filter: 'dt', replacement: (c) => `\n\n**${c.trim()}**: ` });
td.addRule('dd', { filter: 'dd', replacement: (c) => `${c.trim()}\n` });
// The visually hidden hero sentence is the readable version of the word drum; keep it as plain text.
td.addRule('srOnly', { filter: (n) => n.classList?.contains('sr-only'), replacement: (c) => `${c} ` });

for (const page of PAGES) {
	const html = await readFile(`dist/${page}`, 'utf8');
	const main = html.match(/<main[^>]*>([\s\S]*?)<\/main>/)?.[1];
	if (!main) throw new Error(`no <main> in ${page}`);
	const body = td
		.turndown(main)
		.replace(/\]\(\//g, `](${SITE}/`)
		.replace(/\n{3,}/g, '\n\n')
		.trim();
	const md = `${body}\n`;
	await writeFile(`dist/${page.replace(/\.html$/, '.md')}`, md);
	console.log(`markdown: ${page.replace(/\.html$/, '.md')} (${md.length} chars)`);
}
