// Copy buttons: put the target's text on the clipboard; if the clipboard is blocked, select the text instead.
for (const button of document.querySelectorAll<HTMLButtonElement>('[data-copy]')) {
	const target = document.getElementById(button.dataset.copy ?? '');
	const status = button.parentElement?.querySelector<HTMLElement>('[data-copy-status]');
	if (!target) continue;
	let timer = 0;
	button.addEventListener('click', async () => {
		let message = 'Copied';
		try {
			await navigator.clipboard.writeText(target.textContent ?? '');
		} catch {
			getSelection()?.selectAllChildren(target);
			message = 'Selected. Press Command C to copy.';
		}
		button.textContent = message === 'Copied' ? 'Copied' : 'Selected';
		if (status) status.textContent = message;
		clearTimeout(timer);
		timer = window.setTimeout(() => {
			button.textContent = 'Copy';
			if (status) status.textContent = '';
		}, 2000);
	});
}
