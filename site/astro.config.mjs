import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

export default defineConfig({
	site: 'https://rays.a6n.ai',
	integrations: [
		starlight({
			title: 'Rays docs',
			description: 'Install and use Rays, the download manager for Mac that sorts your downloads.',
			logo: { src: './src/assets/icon.png', alt: 'Rays' },
			favicon: '/favicon.png',
			customCss: ['./src/styles/starlight.css'],
			editLink: { baseUrl: 'https://github.com/a6n-ai/rays/edit/main/site/' },
			lastUpdated: false,
			disable404Route: true,
			head: [{ tag: 'script', attrs: { src: '/scripts/open-search.js', defer: true } }],
			components: {
				Header: './src/components/docs/Header.astro',
				Sidebar: './src/components/docs/Sidebar.astro',
			},
			sidebar: [
				{
					label: 'Getting started',
					items: [
						{ label: 'Overview', link: '/docs/', attrs: { 'data-icon': 'home' } },
						{ label: 'Start guide', link: '/docs/getting-started/', attrs: { 'data-icon': 'start' } },
						{ label: 'Install', link: '/docs/install/', attrs: { 'data-icon': 'install' } },
					],
				},
				{
					label: 'Using Rays',
					items: [
						{ label: 'Downloads', link: '/docs/app/downloads/', attrs: { 'data-icon': 'download' } },
						{ label: 'Sorter', link: '/docs/app/sorter/', attrs: { 'data-icon': 'sorter' } },
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
						{ label: 'Contact', link: 'mailto:hi@a6n.ai', attrs: { 'data-icon': 'mail' } },
					],
				},
			],
		}),
	],
});
