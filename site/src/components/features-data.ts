// What Rays does, grouped as in docs/features.md. The home page grid and /features/ both read this.
export interface Item {
	icon: string;
	title: string;
	text: string;
	href?: string;
}

export interface Group {
	id: string;
	title: string;
	icon: string;
	href: string;
	summary: string;
	short: string[];
	items: Item[];
}

export const GROUPS: Group[] = [
	{
		id: 'download',
		title: 'Download',
		icon: 'download',
		href: '/docs/app/downloads/',
		summary: 'Full line speed from links, text, the clipboard and your browser.',
		short: ['Paste anything', 'Up to 16 connections per file', 'Resume after a crash', 'Speed limit', 'Safe names'],
		items: [
			{ icon: 'paste', title: 'Paste anything', text: 'Links one per line, separated by commas, a whole CSV or text with links in it. Drop links and .webloc files on the window.' },
			{ icon: 'grid', title: 'The add bar and its + menu', text: 'The + menu lists everything you can add: links, links on a page, a cloud bucket, a Hugging Face model, and a checksum or mirror. A line above the bar shows what Rays found as you type.', href: '/docs/app/downloads/' },
			{ icon: 'split', title: 'Smart splitting', text: 'Big files start on 4 connections and double, up to 16, only while each step makes the file faster.', href: '/docs/engine/' },
			{ icon: 'resume', title: 'Pause, resume, quit', text: 'Downloads continue from the bytes already saved, after a pause, a quit or a crash.' },
			{ icon: 'engine', title: 'Speed limit', text: 'Cap the speed and choose how many files download at once, from 1 to 10.' },
			{ icon: 'search', title: 'Find links on a page', text: 'Paste a page link and pick which of its files to download.', href: '/docs/app/downloads/' },
			{ icon: 'split', title: 'Mirrors', text: 'Give one file several links. Each connection uses the fastest, and a link that fails is dropped.', href: '/docs/app/downloads/' },
			{ icon: 'resume', title: 'Expired links', text: 'When a link stops working partway, paste a fresh one and Rays continues from the bytes it has.', href: '/docs/app/downloads/' },
			{ icon: 'verify', title: 'Checksums', text: 'Paste a SHA-256 next to a link and Rays checks the file when it finishes.', href: '/docs/app/downloads/' },
			{ icon: 'share', title: 'Share menu', text: 'Send links to Rays from the Share menu in Safari and other apps. They wait in the add bar until you press Download.', href: '/docs/app/downloads/' },
			{ icon: 'link', title: 'Copied links', text: 'Copy a download link anywhere on your Mac and Rays offers to download it.' },
			{ icon: 'filter', title: 'Filter and sort', text: 'Filter the list by status or type. Remove Missing clears finished downloads whose file is gone.' },
			{ icon: 'grid', title: 'Pages everywhere', text: 'Every long list has pages, with 25, 50, 100 or 200 per page.', href: '/docs/app/downloads/' },
			{ icon: 'refresh', title: 'Undo', text: 'After you remove a download or move it to the Trash, a pill at the top offers Undo, or press Command-Z.', href: '/docs/app/downloads/' },
			{ icon: 'shield', title: 'Safe names', text: "The server's suggested name is cleaned, so a file can never land outside your folder." },
			{ icon: 'share', title: 'Share', text: 'Send finished downloads with AirDrop or the Share menu, or drag them out of the window.' },
		],
	},
	{
		id: 'sort',
		title: 'Sort',
		icon: 'sorter',
		href: '/docs/app/sorter/',
		summary: 'Files move into a folder that fits, sorted on your Mac.',
		short: ['On-device AI sorting', 'Renames from contents', 'Your folders, your rules', 'Works without AI'],
		items: [
			{ icon: 'sorter', title: 'Sorted on your Mac', text: 'Rays watches Downloads and any folder you add, and moves new files into folders that fit. Apple on-device AI reads them; nothing is uploaded.' },
			{ icon: 'rename', title: 'Rename from contents', text: 'Rays can name a file from what is inside it. Turn that off to keep every original name.' },
			{ icon: 'folder', title: 'Your folders, your rules', text: 'Send any category where you want it, for example Work to a folder in Documents.' },
			{ icon: 'check', title: 'Works without AI too', text: 'Disk images go to Installers and screenshots to Images even on a Mac without Apple Intelligence.' },
			{ icon: 'eye', title: 'See where it went', text: "A sorted file's row in the Downloads list shows its new folder." },
		],
	},
	{
		id: 'models',
		title: 'Models',
		icon: 'models',
		href: '/docs/app/models/',
		summary: 'Find a Hugging Face model, download one quantization, and check it.',
		short: ['Search and trending', 'Filter by type', 'One quantization', 'Save to LM Studio', 'Verify offline'],
		items: [
			{ icon: 'search', title: 'Search Hugging Face', text: 'Search by name, repo or link, or browse trending models as cards with a type colour and icon.' },
			{ icon: 'filter', title: 'Filter by type', text: 'Text, Vision, Image, Audio and Embeddings.' },
			{ icon: 'models', title: 'One quantization', text: 'Pick the quantization or weights format you need and download only that.' },
			{ icon: 'folder', title: 'Save to LM Studio', text: "Save a model straight into LM Studio's models folder." },
			{ icon: 'verify', title: 'Verify downloaded models', text: "Each file's size and SHA-256 are checked offline, and only the bad files are downloaded again." },
		],
	},
	{
		id: 'queues',
		title: 'Queues & schedules',
		icon: 'queues',
		href: '/docs/app/queues/',
		summary: 'Group downloads, run them when you want, and choose what the Mac does next.',
		short: ['Queues with their own limits', 'Schedules', 'Wi-Fi, charging or idle', 'When finished', 'Wake the Mac'],
		items: [
			{ icon: 'queues', title: 'Queues', text: 'A download starts right away unless you pick a queue. Add queues, each with its own icon, colour, speed limit and number of files at a time.' },
			{ icon: 'calendar', title: 'Schedules', text: 'Run once, every day or on chosen days, with a start time and an optional stop time.' },
			{ icon: 'wifi', title: 'Conditions', text: 'Run only on Wi-Fi (not a hotspot), while charging, or when the Mac is idle.' },
			{ icon: 'clock', title: 'Activity history', text: 'A history of what your queues have done.' },
			{ icon: 'power', title: 'When finished', text: 'Play a sound, quit, sleep, lock, shut down, or run a command.' },
			{ icon: 'moon', title: 'Wake the Mac', text: 'Optionally wake a sleeping Mac for a scheduled queue. It asks for your admin password once.' },
		],
	},
	{
		id: 'speed',
		title: 'Speed test & best time',
		icon: 'speed',
		href: '/docs/app/speed/',
		summary: 'Measure your connection, learn its fastest hours, and download big files then.',
		short: ['10 second speed test', 'Fastest hours of the day', 'At best time', 'Stays on your Mac'],
		items: [
			{ icon: 'speed', title: 'Speed test', text: 'Measure your download speed in about 10 seconds, with the last result in the sidebar.', href: '/docs/app/speed/' },
			{ icon: 'chart', title: 'Best time', text: 'After 7 days, Rays shows the hours your connection is usually fastest, learned from your downloads and tests.', href: '/docs/app/speed/' },
			{ icon: 'moon', title: 'At best time', text: 'Send a download to the Best time queue and it waits for that window.', href: '/docs/app/speed/' },
		],
	},
	{
		id: 'cloud',
		title: 'Cloud (S3)',
		icon: 'cloud',
		href: '/docs/s3/',
		summary: 'Buckets download with the same engine.',
		short: ['Amazon S3, R2, B2, Wasabi, MinIO', 'Browse like Finder', 'Keys stay in your Keychain'],
		items: [
			{ icon: 'cloud', title: 'Any S3-compatible service', text: 'Amazon S3, Cloudflare R2, Backblaze B2, Wasabi, MinIO and the rest.' },
			{ icon: 'folder', title: 'Browse like Finder', text: 'Providers, buckets and folders, as icons or a list.' },
			{ icon: 'verify', title: 'Keys stay safe', text: 'Use an AWS CLI profile or your cf login, so Rays stores no secret. Keys you add yourself stay in the macOS Keychain.' },
		],
	},
	{
		id: 'browser',
		title: 'Browser extension',
		icon: 'browser',
		href: '/docs/app/browser/',
		summary: 'Send a link to Rays from the browser you already use.',
		short: ['Right-click to download', 'Toolbar popup', 'Hand over every download'],
		items: [
			{ icon: 'browser', title: 'Right-click to download', text: 'Chrome, Brave, Edge, Firefox and Zen add Download with Rays to the right-click menu.' },
			{ icon: 'link', title: 'Toolbar popup', text: 'Shows whether Rays is connected, lets you paste a link, and updates itself with the store.' },
			{ icon: 'settings', title: 'Set up from Settings', text: 'The Browsers page lists every browser on your Mac and sets up any built on Chromium or Firefox.' },
			{ icon: 'download', title: 'Hand over every download', text: "Optionally give every browser download to Rays. The browser's copy is cancelled only after Rays accepts the link." },
		],
	},
	{
		id: 'agents',
		title: 'Agents & CLI',
		icon: 'mcp',
		href: '/docs/mcp/',
		summary: 'AI assistants and Terminal can drive Rays.',
		short: ['MCP for AI assistants', 'Command line', 'Queues and model checks'],
		items: [
			{ icon: 'mcp', title: 'MCP for AI assistants', text: 'Assistants like Claude can add downloads to a queue, find the files on a page, list queues, start and stop them, and verify a model.', href: '/docs/mcp/' },
			{ icon: 'grid', title: 'Shortcuts, Spotlight and Siri', text: 'Seven actions with no setup: Add download, Start queue, Stop queue, Run speed test, Pause all, Resume all and Download copied link.', href: '/docs/app/downloads/' },
			{ icon: 'terminal', title: 'Command line', text: 'Add downloads, work with queues, and sort or watch folders from Terminal.', href: '/docs/dl/' },
		],
	},
	{
		id: 'app',
		title: 'The app',
		icon: 'home',
		href: '/docs/install/',
		summary: 'Free, open source and made for macOS 26.',
		short: [],
		items: [
			{ icon: 'clock', title: 'Activity in the sidebar', text: 'A dot on Downloads while something downloads, and a card with the files, speed and time left.', href: '/docs/app/downloads/' },
			{ icon: 'check', title: 'Notifications', text: 'A notification when downloads finish or fail, with Open, Show in Finder and Retry right on the notification.' },
			{ icon: 'menubar', title: 'Menu bar and Dock', text: 'Show the download speed and a badge with the downloads running. The menu bar panel adds links, opens queues, schedules, the speed test and Shortcuts. Close the window and Rays keeps downloading.' },
			{ icon: 'refresh', title: 'Updates itself', text: 'Click Update and Rays replaces itself and reopens, also on a Mac where you are not an administrator.' },
			{ icon: 'install', title: 'Install and uninstall', text: 'Use the DMG or Homebrew. Uninstall from Settings, which also removes the sorter, browser helpers and the command line.' },
			{ icon: 'settings', title: 'Light, dark or system', text: 'Pick the appearance that suits you.' },
			{ icon: 'heart', title: 'Free and open', text: 'AGPL-3.0, no account, no ads and no analytics.' },
		],
	},
];

export const OVERVIEW = GROUPS.filter((g) => ['download', 'sort', 'models', 'queues', 'speed', 'agents'].includes(g.id));
