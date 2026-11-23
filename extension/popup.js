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
  const { reply, error } = await native({ ping: true, urls: [] });
  if (error) {
    show("bad", "Rays helper not installed", "In Rays, open Settings > Browsers and click Install All Helpers.");
  } else if (reply.rays === true) {
    const n = reply.active || 0;
    show("ok", "Connected to Rays", n ? `${n} download${n === 1 ? "" : "s"} in progress` : "Right-click a link and choose Download with Rays.");
  } else if (reply.rays === false) {
    show("warn", "Rays isn't open", "Open Rays to download. Links you send open it.");
  } else {
    show("ok", "Connected to Rays", "Right-click a link and choose Download with Rays.");
  }
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
$("options").addEventListener("click", (event) => { event.preventDefault(); chrome.runtime.openOptionsPage(); });

check();
