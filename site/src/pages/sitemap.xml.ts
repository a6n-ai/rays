import { execFileSync } from 'node:child_process';
import { getCollection } from 'astro:content';

// Last commit date of the given files; empty outside git (the page is then listed without lastmod).
function lastmod(files: string[]): string {
	try {
		return execFileSync('git', ['log', '-1', '--format=%cs', '--', ...files], { encoding: 'utf8' }).trim();
	} catch {
		return '';
	}
}

// Home plus every Starlight page (docs and release notes).
export async function GET({ site }: { site: URL }) {
	const docs = await getCollection('docs');
	const pages = [
		{ path: '/', files: ['src/pages/index.astro', 'src/components'] },
		...docs.map((d) => ({ path: `/${d.id === 'index' ? '' : `${d.id}/`}`, files: [d.filePath!] })),
	];
	const urls = pages
		.map(({ path, files }) => {
			const date = lastmod(files);
			return `  <url><loc>${new URL(path, site).href}</loc>${date ? `<lastmod>${date}</lastmod>` : ''}</url>`;
		})
		.join('\n');
	const xml = `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${urls}\n</urlset>\n`;
	return new Response(xml, { headers: { 'Content-Type': 'application/xml' } });
}
