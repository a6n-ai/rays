const HOST = "ai.a6n.rays";
const $ = (id) => document.getElementById(id);

function native(message) {
  return new Promise((resolve) => {
    chrome.runtime.sendNativeMessage(HOST, message, (reply) => {
      const error = chrome.runtime.lastError && chrome.runtime.lastError.message;
      resolve({ reply: reply || {}, error });
    });
  });
}

function show(kind, headline, detail = "") {
  $("dot").className = kind;
  $("headline").textContent = headline;
  $("detail").textContent = detail;
}

async function check() {
  // "urls": [] keeps an older helper, which only adds links, answering ok.
  const { reply, error } = await native({ ping: true, urls: [], version: chrome.runtime.getManifest().version });
  const missing = !!error && /not found/i.test(error);
  $("fix").hidden = !missing;
  if (missing) {
    show("bad", "Rays helper not installed", "Install it from Rays, then open this menu again.");
  } else if (error) {
    show("bad", "Couldn't reach Rays", error);
  } else if (reply.rays === true) {
    const n = reply.active || 0;
    show("ok", "Connected to Rays", n ? `${n} download${n === 1 ? "" : "s"} in progress` : "Right-click a link and choose Download with Rays.");
  } else if (reply.rays === false) {
    show("warn", "Rays isn't open", "Open Rays to download. Links you send open it.");
  } else {
    // An older Rays helper answers without saying whether the app runs.
    show("ok", "Connected to Rays", "Update the Rays app to see downloads in progress here.");
  }
}

// Chrome-family browsers can ask their store now; Firefox checks on its own schedule.
const update = $("update");
$("version").textContent = `v${chrome.runtime.getManifest().version}`;
if (chrome.runtime.requestUpdateCheck) {
  update.hidden = false;
  update.addEventListener("click", async (event) => {
    event.preventDefault();
    update.textContent = "Checking…";
    try {
      const { status, version } = await chrome.runtime.requestUpdateCheck();
      // background.js reloads into the new version as soon as it is downloaded, which closes this popup.
      update.textContent = status === "update_available" ? `Updating to ${version}…`
        : status === "throttled" ? "Try again in a few minutes" : "Up to date";
    } catch {
      update.textContent = "Couldn't check";
    }
  });
}

$("add").addEventListener("submit", async (event) => {
  event.preventDefault();
  const url = $("url").value.trim();
  if (!/^https?:\/\//i.test(url)) return ($("result").textContent = "Paste a link that starts with http:// or https://");
  $("result").textContent = "Sending…";
  const { reply, error } = await native({ urls: [url] });
  if (error || !reply.ok) {
    $("result").textContent = (reply && reply.error) || error || "Rays didn't answer";
  } else if (reply.added) {
    $("result").textContent = "Added to Rays";
    $("url").value = "";
    check();
  } else {
    $("result").textContent = (reply.rejected && reply.rejected[0] && reply.rejected[0].reason) || "Rays didn't add it";
  }
});

chrome.storage.local.get("sendAll").then(({ sendAll }) => { $("sendAll").checked = !!sendAll; });
$("sendAll").addEventListener("change", () => chrome.storage.local.set({ sendAll: $("sendAll").checked }));
// Rays installs the helper for every browser when the browser hands it this link (it asks "Open Rays?" first).
$("install").addEventListener("click", () => {
  chrome.tabs.create({ url: "rays://install-helpers" });
  window.close();
});

check();
