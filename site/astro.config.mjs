import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

export default defineConfig({
	site: 'https://rays.a6n.ai',
	integrations: [
		starlight({
			title: 'Rays',
			description: 'Docs for Rays, the free download manager for Mac that organizes your Downloads folder with on-device AI.',
			logo: { src: './src/assets/icon.png', alt: 'Rays' },
			favicon: '/icon-192.png',
			customCss: ['./src/styles/starlight.css'],
			editLink: { baseUrl: 'https://github.com/a6n-ai/rays/edit/main/site/' },
			lastUpdated: false,
			disable404Route: true,
			head: [
				{ tag: 'script', attrs: { src: '/scripts/open-search.js', defer: true } },
				{ tag: 'link', attrs: { rel: 'apple-touch-icon', href: '/apple-touch-icon.png' } },
				{ tag: 'meta', attrs: { property: 'og:site_name', content: 'Rays' } },
				{ tag: 'meta', attrs: { property: 'og:image', content: 'https://rays.a6n.ai/share.jpg' } },
				{ tag: 'meta', attrs: { property: 'og:image:alt', content: 'Rays, the download manager for Mac that sorts your files' } },
				{ tag: 'meta', attrs: { name: 'twitter:image', content: 'https://rays.a6n.ai/share.jpg' } },
				{ tag: 'meta', attrs: { property: 'og:image:width', content: '1200' } },
				{ tag: 'meta', attrs: { property: 'og:image:height', content: '630' } },
				{ tag: 'meta', attrs: { name: 'twitter:card', content: 'summary_large_image' } },
				{ tag: 'link', attrs: { rel: 'alternate', type: 'text/plain', href: '/llms.txt', title: 'LLM summary' } },
				{
					tag: 'script',
					attrs: { type: 'application/ld+json' },
					content: JSON.stringify({
						'@context': 'https://schema.org',
						'@type': 'SoftwareApplication',
						name: 'Rays',
						applicationCategory: 'UtilitiesApplication',
						operatingSystem: 'macOS 26 or later',
						url: 'https://rays.a6n.ai/',
						downloadUrl: 'https://github.com/a6n-ai/rays/releases/latest/download/Rays.dmg',
						isAccessibleForFree: true,
						offers: { '@type': 'Offer', price: '0', priceCurrency: 'USD' },
						publisher: { '@type': 'Organization', name: 'a6n', url: 'https://a6n.ai' },
					}),
				},
			],
			components: {
				Header: './src/components/docs/Header.astro',
				Sidebar: './src/components/docs/Sidebar.astro',
			},
			sidebar: [
				{
					label: 'Getting started',
					items: [
						{ label: 'Overview', link: '/docs/', attrs: { 'data-icon': 'home' } },
						{ label: 'Feature overview', link: '/docs/features/', attrs: { 'data-icon': 'grid' } },
						{ label: 'Start guide', link: '/docs/getting-started/', attrs: { 'data-icon': 'start' } },
						{ label: 'Install', link: '/docs/install/', attrs: { 'data-icon': 'install' } },
					],
				},
				{
					label: 'Using Rays',
					items: [
						{ label: 'Downloads', link: '/docs/app/downloads/', attrs: { 'data-icon': 'download' } },
						{ label: 'Add downloads', link: '/docs/app/add-links/', attrs: { 'data-icon': 'paste' } },
						{ label: 'Shortcuts and Share menu', link: '/docs/app/shortcuts/', attrs: { 'data-icon': 'share' } },
						{ label: 'Queues', link: '/docs/app/queues/', attrs: { 'data-icon': 'queues' } },
						{ label: 'Speed test', link: '/docs/app/speed/', attrs: { 'data-icon': 'speed' } },
						{ label: 'Stats', link: '/docs/app/stats/', attrs: { 'data-icon': 'chart' } },
						{ label: 'How the engine works', link: '/docs/engine/', attrs: { 'data-icon': 'engine' } },
						{ label: 'S3 buckets', link: '/docs/s3/', attrs: { 'data-icon': 'cloud' } },
						{ label: 'Sorter', link: '/docs/app/sorter/', attrs: { 'data-icon': 'sorter' } },
						{ label: 'Models', link: '/docs/app/models/', attrs: { 'data-icon': 'models' } },
						{ label: 'Browser extension', link: '/docs/app/browser/', attrs: { 'data-icon': 'browser' } },
						{ label: 'Settings', link: '/docs/app/settings/', attrs: { 'data-icon': 'settings' } },
					],
				},
				{
					label: 'Command line and AI',
					items: [
						{ label: 'The dl command', link: '/docs/dl/', attrs: { 'data-icon': 'terminal' } },
						{ label: 'MCP', link: '/docs/mcp/', attrs: { 'data-icon': 'mcp' } },
					],
				},
				{
					label: 'Help',
					items: [
						{ label: 'Troubleshooting', link: '/docs/troubleshooting/', attrs: { 'data-icon': 'help' } },
						{ label: 'Release notes', link: '/releases/', attrs: { 'data-icon': 'notes' } },
						{ label: 'GitHub', link: 'https://github.com/a6n-ai/rays', attrs: { 'data-icon': 'code' } },
						{ label: 'Support', link: '/support/', attrs: { 'data-icon': 'help' } },
						{ label: 'Contact', link: 'mailto:hi@a6n.ai', attrs: { 'data-icon': 'mail' } },
						{ label: 'Privacy policy', link: '/privacy/', attrs: { 'data-icon': 'notes' } },
						{ label: 'Terms of use', link: '/terms/', attrs: { 'data-icon': 'notes' } },
					],
				},
			],
		}),
	],
});
