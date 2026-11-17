// Before build/dev: render the repo's CHANGELOG.md as the Starlight page /releases/.
import { readFile, writeFile } from 'node:fs/promises';

const log = await readFile('../CHANGELOG.md', 'utf8');
const body = log.replace(/^# .*\n+/, ''); // the page title comes from frontmatter
const page = `---\ntitle: Release notes\ndescription: What changed in each version of Rays.\ntableOfContents:\n  maxHeadingLevel: 2\n---\n\n<!-- Generated from CHANGELOG.md by scripts/changelog.mjs. Edit CHANGELOG.md instead. -->\n\n[Download the latest version](https://github.com/a6n-ai/rays/releases/latest/download/Rays.dmg) or run \`brew upgrade --cask rays\`.\n\n${body}`;
await writeFile('src/content/docs/releases.md', page);
