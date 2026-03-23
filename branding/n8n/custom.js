(function () {
  var CHAT_URL = "/chat/";
  var scheduled = false;

  function isVisible(node) {
    if (!node || !node.getBoundingClientRect) return false;
    var rect = node.getBoundingClientRect();
    return rect.width >= 120 && rect.height >= 24;
  }

  function buildChatLink() {
    var link = document.createElement("a");
    link.className = "chutes-crosslink";
    link.href = CHAT_URL;
    link.innerHTML =
      '<span class="chutes-crosslink-mark">' +
      '<img class="chutes-crosslink-logo chutes-crosslink-logo-chutes" src="/n8n/static/chutes-logo.svg" alt="Chutes" />' +
      "</span>" +
      '<span class="chutes-crosslink-copy">' +
      '<span class="chutes-crosslink-meta">Chutes</span>' +
      '<span class="chutes-crosslink-label">Open Chat</span>' +
      "</span>";
    return link;
  }

  function updateCompactState(link, sideMenu) {
    var compact = !!sideMenu && sideMenu.getBoundingClientRect().width < 112;
    link.classList.toggle("is-compact", compact);
    link.setAttribute("aria-label", "Open Chat");
  }

  function cleanupDuplicateSlots(keepSlot) {
    Array.prototype.forEach.call(
      document.querySelectorAll('[data-chutes-nav-slot="chat"]'),
      function (slot) {
        if (slot !== keepSlot) {
          slot.remove();
        }
      },
    );
  }

  function findFooterAnchor(sideMenu, slot) {
    var children = Array.prototype.slice
      .call(sideMenu.children)
      .filter(function (child) {
        return child !== slot && isVisible(child);
      });

    if (!children.length) return null;
    return children[children.length - 1];
  }

  function ensureSidebarLink() {
    var sideMenu = document.getElementById("side-menu");
    if (!sideMenu) return;

    var slot = sideMenu.querySelector('[data-chutes-nav-slot="chat"]');
    if (!slot) {
      slot = document.createElement("div");
      slot.setAttribute("data-chutes-nav-slot", "chat");
    }

    var link = slot.querySelector(".chutes-crosslink");
    if (!link) {
      link = buildChatLink();
      slot.appendChild(link);
    }

    var anchor = findFooterAnchor(sideMenu, slot);
    cleanupDuplicateSlots(slot);

    if (anchor) {
      if (slot.parentNode !== sideMenu || slot.nextElementSibling !== anchor) {
        sideMenu.insertBefore(slot, anchor);
      }
    } else if (slot.parentNode !== sideMenu) {
      sideMenu.appendChild(slot);
    }

    updateCompactState(link, sideMenu);
  }

  function refresh() {
    scheduled = false;
    ensureSidebarLink();
  }

  function scheduleRefresh() {
    if (scheduled) return;
    scheduled = true;
    window.requestAnimationFrame(refresh);
  }

  document.addEventListener("DOMContentLoaded", scheduleRefresh);
  window.addEventListener("load", scheduleRefresh);
  window.addEventListener("resize", scheduleRefresh);

  var observer = new MutationObserver(scheduleRefresh);
  observer.observe(document.documentElement, { childList: true, subtree: true });
})();
