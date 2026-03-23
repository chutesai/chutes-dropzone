(function () {
  var CHAT_NAME = "Chutes Chat";
  var CHUTES_LOGO_URL = "/static/chutes-logo.svg";
  var N8N_URL = "/n8n/";
  var MENU_MARKERS = ["New Chat", "Search", "Notes", "Folders", "Chats"];
  var scheduled = false;

  function isVisible(node) {
    if (!node || !node.getBoundingClientRect) return false;
    var rect = node.getBoundingClientRect();
    return rect.width >= 120 && rect.height >= 40;
  }

  function getMenuScore(text) {
    var haystack = String(text || "");
    var score = 0;

    MENU_MARKERS.forEach(function (marker) {
      if (haystack.indexOf(marker) !== -1) {
        score += 1;
      }
    });

    return score;
  }

  function setDocumentTitle() {
    var title = document.title || "";
    if (!title || title === "Open WebUI" || title === "Chutes Dropzone") {
      document.title = CHAT_NAME;
    }
  }

  function patchBranding() {
    setDocumentTitle();

    var scopes = document.querySelectorAll("aside, nav, header");
    if (!scopes.length) {
      scopes = [document.body];
    }

    scopes.forEach(function (scope) {
      var nodes = scope.querySelectorAll("a, button, span, div, h1, h2, h3, p");
      nodes.forEach(function (node) {
        if (node.childElementCount > 2) return;
        var text = (node.textContent || "").trim();
        if (!text || text.length > 72) return;

        if (text === "Open WebUI" || text === "Chutes Dropzone") {
          node.textContent = CHAT_NAME;
          return;
        }

        if (/\s+\(Open WebUI\)$/.test(text)) {
          node.textContent = text.replace(/\s+\(Open WebUI\)$/, "");
        }
      });
    });

    Array.prototype.forEach.call(document.querySelectorAll("img.sidebar-new-chat-icon"), function (img) {
      if (img.getAttribute("src") !== CHUTES_LOGO_URL) {
        img.setAttribute("src", CHUTES_LOGO_URL);
      }
      img.setAttribute("alt", "Chutes");
      img.classList.add("chutes-brand-icon");
    });
  }

  function buildN8nLink() {
    var link = document.createElement("a");
    link.className = "chutes-crosslink";
    link.href = N8N_URL;
    link.innerHTML =
      '<span class="chutes-crosslink-mark">n8n</span>' +
      '<span class="chutes-crosslink-copy">' +
      '<span class="chutes-crosslink-meta">Automation</span>' +
      '<span class="chutes-crosslink-label">Open n8n</span>' +
      "</span>";
    return link;
  }

  function updateCompactState(link, sidebar) {
    var compact = !!sidebar && sidebar.getBoundingClientRect().width < 110;
    link.classList.toggle("is-compact", compact);
    link.setAttribute("aria-label", compact ? "Open n8n" : "Open n8n");
  }

  function findSidebar() {
    var sidebar = document.getElementById("sidebar");
    if (isVisible(sidebar)) {
      return sidebar;
    }

    var best = null;
    var bestScore = -1;

    Array.prototype.forEach.call(document.querySelectorAll("aside"), function (aside) {
      if (!isVisible(aside)) return;

      var score = getMenuScore(aside.textContent);
      if (score > bestScore) {
        best = aside;
        bestScore = score;
      }
    });

    return best || document.querySelector("aside");
  }

  function findInsertionParent(sidebar) {
    if (sidebar && sidebar.id === "sidebar") {
      var directChildren = Array.prototype.slice.call(sidebar.children).filter(isVisible);

      for (var index = 0; index < directChildren.length; index += 1) {
        var child = directChildren[index];
        var className = String(child.className || "");
        if (
          className.indexOf("justify-between") !== -1 ||
          className.indexOf("sidebar") !== -1 ||
          child.childElementCount >= 2
        ) {
          return child;
        }
      }

      if (directChildren.length) {
        return directChildren[0];
      }
    }

    var candidates = [sidebar].concat(
      Array.prototype.slice.call(sidebar.querySelectorAll("div, nav, section")),
    );
    var best = sidebar;
    var bestWeight = -1;

    candidates.forEach(function (candidate) {
      if (!isVisible(candidate)) return;
      if (candidate.childElementCount < 2) return;

      var rect = candidate.getBoundingClientRect();
      if (rect.width < 160 || rect.height < 180) return;

      var score = getMenuScore(candidate.textContent);
      if (score < 2) return;

      var weight = score * 100000 + candidate.childElementCount * 100 + Math.round(rect.height);
      if (weight > bestWeight) {
        best = candidate;
        bestWeight = weight;
      }
    });

    return best;
  }

  function findFooterAnchor(parent, slot) {
    if (parent) {
      var stickyChildren = Array.prototype.slice
        .call(parent.children)
        .filter(function (child) {
          return child !== slot && isVisible(child) && String(child.className || "").indexOf("sticky") !== -1;
        });

      if (stickyChildren.length) {
        return stickyChildren[stickyChildren.length - 1];
      }
    }

    var parentRect = parent.getBoundingClientRect();
    var children = Array.prototype.slice
      .call(parent.children)
      .filter(function (child) {
        return child !== slot && isVisible(child);
      });

    if (!children.length) return null;

    for (var index = children.length - 1; index >= 0; index -= 1) {
      var child = children[index];
      var rect = child.getBoundingClientRect();
      if (rect.top >= parentRect.top + parentRect.height * 0.55) {
        return child;
      }
    }

    return children[children.length - 1];
  }

  function cleanupDuplicateSlots(kind, keepSlot) {
    Array.prototype.forEach.call(
      document.querySelectorAll('[data-chutes-nav-slot="' + kind + '"]'),
      function (slot) {
        if (slot !== keepSlot) {
          slot.remove();
        }
      },
    );
  }

  function ensureSidebarLink() {
    var sidebar = findSidebar();
    if (!sidebar) return;

    var container = findInsertionParent(sidebar);
    var slot = container.querySelector('[data-chutes-nav-slot="n8n"]');

    if (!slot) {
      slot = document.createElement("div");
      slot.setAttribute("data-chutes-nav-slot", "n8n");
    }

    var link = slot.querySelector(".chutes-crosslink");
    if (!link) {
      link = buildN8nLink();
      slot.appendChild(link);
    }

    var anchor = findFooterAnchor(container, slot);
    cleanupDuplicateSlots("n8n", slot);

    if (anchor) {
      if (slot.parentNode !== container || slot.nextElementSibling !== anchor) {
        container.insertBefore(slot, anchor);
      }
    } else if (slot.parentNode !== container) {
      container.appendChild(slot);
    }

    updateCompactState(link, sidebar);
  }

  function refresh() {
    scheduled = false;
    patchBranding();
    ensureSidebarLink();
  }

  function scheduleRefresh() {
    if (scheduled) return;
    scheduled = true;
    window.requestAnimationFrame(refresh);
  }

  document.addEventListener("DOMContentLoaded", scheduleRefresh);
  window.addEventListener("load", scheduleRefresh);
  window.addEventListener("popstate", scheduleRefresh);
  window.addEventListener("resize", scheduleRefresh);

  var observer = new MutationObserver(scheduleRefresh);
  observer.observe(document.documentElement, { childList: true, subtree: true });
})();
