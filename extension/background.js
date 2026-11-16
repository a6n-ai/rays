const HOST = "ai.a6n.rays";
const MENU_ID = "rays-download";

let clearTimer;
function flash(text, color) {
  clearTimeout(clearTimer);
  chrome.action.setBadgeBackgroundColor({ color });
  chrome.action.setBadgeText({ text });
  clearTimer = setTimeout(() => chrome.action.setBadgeText({ text: "" }), 2000);
}

function sendToRays(urls) {
  return new Promise((resolve, reject) => {
    chrome.runtime.sendNativeMessage(HOST, { urls }, (reply) => {
      if (chrome.runtime.lastError) return reject(new Error(chrome.runtime.lastError.message));
      if (!reply || !reply.ok) return reject(new Error((reply && reply.error) || "no reply from Rays"));
      resolve(reply);
    });
  });
}

async function sendAndReport(urls) {
  try {
    const reply = await sendToRays(urls);
    flash(`+${reply.added}`, "#188038");
    return reply;
  } catch (e) {
    console.error("Rays:", e.message);
    flash("!", "#d93025");
    throw e;
  }
}

chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.create({ id: MENU_ID, title: "Download with Rays", contexts: ["link", "page"] });
});

chrome.contextMenus.onClicked.addListener((info) => {
  if (info.menuItemId !== MENU_ID) return;
  if (!info.linkUrl) return flash("!", "#d93025");
  sendAndReport([info.linkUrl]).catch(() => {});
});

chrome.downloads.onCreated.addListener(async (item) => {
  const { sendAll } = await chrome.storage.local.get("sendAll");
  if (!sendAll) return;
  const url = item.finalUrl || item.url;
  if (!/^https?:/i.test(url) || item.mime === "text/html") return;
  try {
    await sendAndReport([url]);
  } catch {
    return;
  }
  await chrome.downloads.cancel(item.id);
  await chrome.downloads.erase({ id: item.id });
});
