/**
 * coolmac purchasing — download-first.
 *
 * These are macOS apps, so the website never charges. Any "buy"/"download"
 * trigger (a .dmg link, a legacy [data-buy], or [data-download]) becomes:
 *   • on a Mac  → download the right .dmg
 *   • elsewhere → a "this is a Mac app, get the link on your Mac" modal
 *                 (copy link / email it to yourself) — no wasted mobile sale.
 * Payment happens inside the app, after the user has seen the value.
 */
(function () {
  var DMG = {
    beacon:  "https://github.com/Cool-Mac-Tools/Beacon/releases/latest/download/Beacon.dmg",
    reclaim: "https://github.com/Cool-Mac-Tools/reclaim/releases/latest/download/Reclaim.dmg"
  };
  var pageDefault = /reclaim/i.test(location.hostname) ? "reclaim" : "beacon";
  var ua = navigator.userAgent || "";
  // iPadOS reports "Macintosh" but has touch points and can't run Mac apps.
  var isMac = /Macintosh|Mac OS X/.test(ua) && (navigator.maxTouchPoints || 0) === 0;

  function appFor(el) {
    var s = ((el.getAttribute("data-app") || el.getAttribute("href") || "") + " " + (el.textContent || ""));
    if (/reclaim/i.test(s) && !/beacon/i.test(s)) return "reclaim";
    if (/beacon/i.test(s) && !/reclaim/i.test(s)) return "beacon";
    return pageDefault;
  }
  function isTrigger(el) {
    if (!el || !el.getAttribute) return false;
    var href = el.getAttribute("href") || "";
    return el.hasAttribute("data-buy") || el.hasAttribute("data-download") || /\.dmg(\?|$)/i.test(href);
  }

  function macModal(app) {
    var name = app === "reclaim" ? "Reclaim" : "Beacon";
    var url = DMG[app];
    var ov = document.createElement("div");
    ov.setAttribute("style", "position:fixed;inset:0;z-index:9999;background:rgba(0,0,0,.45);display:flex;align-items:center;justify-content:center;padding:20px");
    ov.innerHTML =
      '<div style="background:#fff;max-width:430px;width:100%;border-radius:18px;padding:30px;text-align:center;font-family:-apple-system,system-ui,sans-serif;color:#1d1d1f">' +
      '<h3 style="margin:0 0 8px;font-size:22px;letter-spacing:-.01em">' + name + ' is a Mac app</h3>' +
      '<p style="color:#6e6e73;line-height:1.5;margin:0 0 20px;font-size:15px">Open this on your Mac to download and install ' + name + '. It’s free to try — you only pay inside the app.</p>' +
      '<div style="display:flex;gap:8px;justify-content:center;flex-wrap:wrap">' +
      '<button id="cm-copy" style="border:none;cursor:pointer;background:#0071e3;color:#fff;border-radius:980px;padding:11px 20px;font:inherit;font-weight:600">Copy link</button>' +
      '<a id="cm-email" href="#" style="text-decoration:none;border:1px solid rgba(0,113,227,.4);color:#0071e3;border-radius:980px;padding:11px 20px;font-weight:600">Email it to me</a>' +
      '</div>' +
      '<p style="margin:16px 0 0"><a id="cm-close" href="#" style="color:#6e6e73;font-size:13px;text-decoration:none">Close</a></p>' +
      '</div>';
    document.body.appendChild(ov);
    ov.querySelector("#cm-email").href =
      "mailto:?subject=" + encodeURIComponent("Download " + name + " for Mac") +
      "&body=" + encodeURIComponent("Download " + name + " on your Mac:\n" + url + "\n\ncoolmac.tools");
    var copyBtn = ov.querySelector("#cm-copy");
    copyBtn.addEventListener("click", function () {
      navigator.clipboard.writeText(url).then(function () {
        copyBtn.textContent = "Copied ✓";
        setTimeout(function () { copyBtn.textContent = "Copy link"; }, 2000);
      });
    });
    function close(e) { if (e) e.preventDefault(); ov.remove(); }
    ov.querySelector("#cm-close").addEventListener("click", close);
    ov.addEventListener("click", function (e) { if (e.target === ov) close(); });
  }

  document.addEventListener("click", function (e) {
    var el = e.target.closest ? e.target.closest("a,button") : null;
    if (!isTrigger(el)) return;
    e.preventDefault();
    var app = appFor(el);
    if (isMac) {
      var href = el.getAttribute("href") || "";
      window.location.href = /\.dmg(\?|$)/i.test(href) ? href : DMG[app];
    } else {
      macModal(app);
    }
  }, true);
})();
