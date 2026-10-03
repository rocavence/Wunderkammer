// Save to Wunderkammer: hands the page, link, image or selection to the app
// through its wunderkammer://capture link. Nothing is sent anywhere else.

const MENU = "wunderkammer-save";

function captureURL(params) {
  const query = Object.entries(params)
    .filter(([, value]) => value)
    .map(([key, value]) => `${key}=${encodeURIComponent(value)}`)
    .join("&");
  return `wunderkammer://capture?${query}`;
}

function send(tab, params) {
  // Opening the link hands it to the app; the page itself stays where it is.
  chrome.tabs.update(tab.id, { url: captureURL(params) });
}

chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.create({
    id: MENU,
    title: "收進 Wunderkammer",
    contexts: ["page", "link", "image", "selection"],
  });
});

chrome.contextMenus.onClicked.addListener((info, tab) => {
  if (info.menuItemId !== MENU || !tab) return;
  if (info.mediaType === "image" && info.srcUrl) {
    send(tab, { image: info.srcUrl, url: tab.url, title: tab.title });
  } else if (info.selectionText) {
    send(tab, { text: info.selectionText, url: tab.url });
  } else if (info.linkUrl) {
    send(tab, { url: info.linkUrl });
  } else {
    send(tab, { url: tab.url, title: tab.title });
  }
});

chrome.action.onClicked.addListener((tab) => {
  send(tab, { url: tab.url, title: tab.title });
});
