// Runs only for the HTML pages listed in public/_routes.json; everything else is served as static files.
// Accept: text/markdown gets the prebuilt index.md (scripts/markdown.mjs); browsers get the HTML.
export async function onRequestGet({ request, env, next }) {
	const accept = request.headers.get('accept') ?? '';
	if (!/\btext\/markdown\b/.test(accept)) {
		const res = await next();
		const out = new Response(res.body, res);
		out.headers.append('Vary', 'Accept');
		return out;
	}
	const url = new URL(request.url);
	const dir = url.pathname.endsWith('/') ? url.pathname : `${url.pathname}/`;
	const md = await env.ASSETS.fetch(new URL(`${dir}index.md`, url));
	if (!md.ok) return next();
	const body = await md.text();
	return new Response(body, {
		headers: {
			'Content-Type': 'text/markdown; charset=utf-8',
			'x-markdown-tokens': String(Math.ceil(body.length / 4)), // estimate: about 4 characters per token
			Vary: 'Accept',
			'X-Content-Type-Options': 'nosniff',
		},
	});
}
