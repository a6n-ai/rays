// Before build/dev: render the repo's CHANGELOG.md as the Starlight page /releases/.
import { readFile, writeFile } from 'node:fs/promises';

const log = await readFile('../CHANGELOG.md', 'utf8');
// The newest OPEN versions stay open as headings; each older one folds into a <details> row. CHANGELOG.md stays the source.
const OPEN = 4;
const versions = log.replace(/^# .*\n+/, '').split(/^(?=## )/m).filter((v) => v.trim());
const open = versions.slice(0, OPEN).join('');
const older = versions
	.slice(OPEN)
	.map((v) => {
		const [head, ...rest] = v.trimEnd().split('\n');
		const title = head.replace(/^## /, '');
		const id = 'v' + title.split(' ')[0].replaceAll('.', '-');
		return `<details class="release" id="${id}">\n<summary>${title}</summary>\n${rest.join('\n')}\n\n</details>\n\n`;
	})
	.join('');
const body = `${open}${older ? `## Earlier versions\n\n${older}` : ''}`;
const page = `---\ntitle: Release notes\ndescription: Release notes for Rays, the free download manager for Mac with AI file sorting. New features and fixes in every version, newest first.\ntableOfContents:\n  maxHeadingLevel: 2\n---\n\n<!-- Generated from CHANGELOG.md by scripts/changelog.mjs. Edit CHANGELOG.md instead. -->\n\n[Download the latest version](https://rays.a6n.ai/download/Rays.dmg?src=docs) or run \`brew upgrade --cask rays\`.\n\n${body}`;
await writeFile('src/content/docs/releases.md', page);
