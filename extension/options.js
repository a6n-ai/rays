const box = document.getElementById("sendAll");
chrome.storage.local.get("sendAll").then(({ sendAll }) => { box.checked = !!sendAll; });
box.addEventListener("change", () => chrome.storage.local.set({ sendAll: box.checked }));
