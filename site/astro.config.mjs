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
			social: [{ icon: 'github', label: 'GitHub', href: 'https://github.com/a6n-ai/rays' }],
			editLink: { baseUrl: 'https://github.com/a6n-ai/rays/edit/main/site/' },
			lastUpdated: false,
			disable404Route: true,
			sidebar: [
				{ label: 'Getting started', items: ['docs', 'docs/install'] },
				{ label: 'Using Rays', items: ['docs/app/downloads', 'docs/app/sorter', 'docs/app/browser', 'docs/app/settings'] },
				{ label: 'Command line and AI', items: ['docs/dl', 'docs/mcp'] },
				{ label: 'Help', items: ['docs/troubleshooting', { label: 'Release notes', link: '/releases/' }] },
			],
		}),
	],
});
