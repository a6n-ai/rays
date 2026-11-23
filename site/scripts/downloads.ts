// Prints Rays download counts from Workers Analytics Engine (written by functions/download/[asset].js).
// Usage: CLOUDFLARE_ACCOUNT_ID=… CLOUDFLARE_API_TOKEN=… node scripts/downloads.ts [days]
// The token needs Account > Account Analytics > Read.
const account = process.env.CLOUDFLARE_ACCOUNT_ID;
const token = process.env.CLOUDFLARE_API_TOKEN;
if (!account || !token) {
	console.error('Set CLOUDFLARE_ACCOUNT_ID and CLOUDFLARE_API_TOKEN.');
	process.exit(1);
}
const days = Number.parseInt(process.argv[2] ?? '30', 10);
if (!Number.isInteger(days) || days < 1 || days > 90) {
	console.error('days must be 1 to 90 (Analytics Engine keeps three months).');
	process.exit(1);
}

async function query(sql: string): Promise<Record<string, string>[]> {
	const res = await fetch(`https://api.cloudflare.com/client/v4/accounts/${account}/analytics_engine/sql`, {
		method: 'POST',
		headers: { Authorization: `Bearer ${token}` },
		body: sql,
	});
	if (!res.ok) throw new Error(`Analytics Engine: ${res.status} ${await res.text()}`);
	return (await res.json()).data;
}

// Each download is one row with sample_interval 1 at this volume; SUM keeps counts right if Cloudflare samples.
const since = `timestamp > NOW() - INTERVAL '${days}' DAY`;
const bySource = await query(
	`SELECT blob2 AS source, SUM(_sample_interval) AS downloads FROM rays_downloads WHERE ${since} GROUP BY source ORDER BY downloads DESC`,
);
const byVersion = await query(
	`SELECT blob3 AS version, blob4 AS kind, SUM(_sample_interval) AS downloads FROM rays_downloads WHERE ${since} GROUP BY version, kind ORDER BY downloads DESC`,
);
const byCountry = await query(
	`SELECT blob5 AS country, SUM(_sample_interval) AS downloads FROM rays_downloads WHERE ${since} GROUP BY country ORDER BY downloads DESC LIMIT 10`,
);

console.log(`Rays downloads, last ${days} days\n`);
console.log('By source');
console.table(bySource);
console.log('By version');
console.table(byVersion);
console.log('Top countries');
console.table(byCountry);
