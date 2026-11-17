// On docs pages: /docs/#search (from the home page Search button) opens Starlight's search dialog.
if (location.hash === '#search') {
	const open = () => {
		const button = document.querySelector('site-search button[data-open-modal]');
		if (!button || button.disabled) return requestAnimationFrame(open);
		history.replaceState(null, '', location.pathname);
		button.click();
	};
	open();
}
