// Counts a download, then sends it on to the GitHub release file. No cookies, no IP address stored.
// /download/Rays.dmg goes to the latest release; /download/Rays-0.1.16.zip to that version's release.
const ASSET = /^Rays(?:-(\d+\.\d+\.\d+))?\.(dmg|zip)$/;
const SOURCES = new Set(['site', 'docs', 'brew', 'update', 'agent', 'github']);
const RELEASES = 'https://github.com/a6n-ai/rays/releases';

export function target(asset) {
	const m = ASSET.exec(asset);
	if (!m) return null;
	const [, version, kind] = m;
	return {
		url: version ? `${RELEASES}/download/v${version}/${asset}` : `${RELEASES}/latest/download/${asset}`,
		version: version ?? 'latest',
		kind,
	};
}

export function source(param, userAgent) {
	if (SOURCES.has(param)) return param;
	return /homebrew/i.test(userAgent ?? '') ? 'brew' : 'direct';
}

export async function onRequestGet({ request, params, env }) {
	const t = target(params.asset);
	if (!t) return new Response('Not found', { status: 404 });
	const url = new URL(request.url);
	const src = source(url.searchParams.get('src'), request.headers.get('user-agent'));
	// Analytics Engine writes don't block the response; a missing binding (local dev) only skips the count.
	env.DOWNLOADS?.writeDataPoint({
		blobs: [params.asset, src, t.version, t.kind, request.cf?.country ?? ''],
		indexes: [src],
	});
	return Response.redirect(t.url, 302);
}
