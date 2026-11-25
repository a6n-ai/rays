// One icon set (24px grid, 1.75 stroke) for docs cards and the sidebar.
export const ICONS: Record<string, string> = {
	home: 'M4 11l8-7 8 7 M6 9v11h12V9',
	start: 'M5 21V4 M5 4h11l-2 4 2 4H5',
	install: 'M3 7l9-4 9 4-9 4-9-4z M3 7v10l9 4 9-4V7 M12 11v10',
	download: 'M12 3v12 M7 10l5 5 5-5 M5 21h14',
	queues: 'M8 6h13 M8 12h13 M8 18h13 M3 6h.01 M3 12h.01 M3 18h.01',
	engine: 'M4 17a8 8 0 1 1 16 0 M12 17l4-5 M4 21h16',
	chart: 'M4 20V10 M10 20V4 M16 20v-7 M3 20h18',
	cloud: 'M7 18h10a4 4 0 0 0 .5-7.97A6 6 0 0 0 6.1 9.1 4.5 4.5 0 0 0 7 18z',
	sorter: 'M12 3l1.8 4.7 4.7 1.8-4.7 1.8L12 16l-1.8-4.7-4.7-1.8 4.7-1.8z M19 15l.8 2.2 2.2.8-2.2.8L19 21l-.8-2.2-2.2-.8 2.2-.8z',
	models: 'M12 2l9 5v10l-9 5-9-5V7z M3 7l9 5 9-5 M12 12v10',
	browser: 'M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18z M3 12h18 M12 3a14 14 0 0 1 0 18 M12 3a14 14 0 0 0 0 18',
	settings: 'M4 6h9 M17 6h3 M4 12h3 M11 12h9 M4 18h11 M19 18h1 M15 4v4 M9 10v4 M17 16v4',
	terminal: 'M3 5h18v14H3z M7 9l3 3-3 3 M12 15h5',
	mcp: 'M9 2v5 M15 2v5 M6 7h12v4a6 6 0 0 1-12 0z M12 17v5',
	help: 'M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18z M12 16a4 4 0 1 0 0-8 4 4 0 0 0 0 8z M5.6 5.6l3.6 3.6 M14.8 14.8l3.6 3.6 M18.4 5.6l-3.6 3.6 M9.2 14.8l-3.6 3.6',
	notes: 'M7 3h7l5 5v13H7z M14 3v5h5 M10 13h6 M10 17h6',
	code: 'M8 7l-5 5 5 5 M16 7l5 5-5 5',
	mail: 'M3 6h18v12H3z M3 7l9 6 9-6',
};

export const svg = (name: string, size = 16) =>
	`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="${size}" height="${size}" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="${ICONS[name] ?? ''}"/></svg>`;

export const maskUrl = (name: string) =>
	`url("data:image/svg+xml,${encodeURIComponent(svg(name).replace('currentColor', '#000'))}")`;
