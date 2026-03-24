(function () {
  var CHAT_NAME = "Chutes Chat";
  var CHUTES_LOGO_URL = "/static/chutes-logo.svg";
  var CHUTES_APP_ICON_URL = "/static/chutes-chat-icon-180.png";
  var N8N_LOGO_URL = "/static/n8n-logo.svg";
  var ACCOUNT_SUMMARY_URL = "/api/v1/dropzone/account-summary";
  var ACCOUNT_SUMMARY_POLL_MS = 60000;
  var ACCOUNT_SUMMARY_RETRY_MS = 5000;
  var MENU_MARKERS = ["New Chat", "Search", "Notes", "Folders", "Chats"];
  var scheduled = false;
  var accountSummary = null;
  var accountSummaryLoaded = false;
  var accountSummaryPromise = null;
  var accountSummaryFailureCount = 0;
  var accountSummaryTimerId = null;
  var tooltipLayer = null;
  var activeTooltipTarget = null;


  function isVisible(node) {
    if (!node || !node.getBoundingClientRect) return false;
    var rect = node.getBoundingClientRect();
    if (rect.width < 24 || rect.height < 24) return false;
    if (!window.getComputedStyle) return true;
    var style = window.getComputedStyle(node);
    return style.display !== "none" && style.visibility !== "hidden" && style.opacity !== "0";
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

  function ensureFavicon() {
    var selectors = ['link[rel="icon"]', 'link[rel="shortcut icon"]'];
    var links = [];

    selectors.forEach(function (selector) {
      Array.prototype.forEach.call(document.querySelectorAll(selector), function (node) {
        if (links.indexOf(node) === -1) {
          links.push(node);
        }
      });
    });

    if (!links.length) {
      var icon = document.createElement("link");
      icon.setAttribute("rel", "icon");
      document.head.appendChild(icon);
      links.push(icon);
    }

    links.forEach(function (link) {
      if (!link.getAttribute("rel")) {
        link.setAttribute("rel", "icon");
      }
      link.setAttribute("href", CHUTES_LOGO_URL);
      link.setAttribute("type", "image/svg+xml");
    });
  }

  function upsertHeadNode(selector, tagName, attributes) {
    var node = document.head.querySelector(selector);
    if (!node) {
      node = document.createElement(tagName);
      document.head.appendChild(node);
    }

    Object.keys(attributes).forEach(function (name) {
      node.setAttribute(name, attributes[name]);
    });

    return node;
  }

  function ensureInstallMetadata() {
    upsertHeadNode('link[rel="apple-touch-icon"]', "link", {
      rel: "apple-touch-icon",
      href: CHUTES_APP_ICON_URL,
      sizes: "180x180",
      type: "image/png",
    });

    upsertHeadNode('meta[name="application-name"]', "meta", {
      name: "application-name",
      content: CHAT_NAME,
    });

    upsertHeadNode('meta[name="apple-mobile-web-app-title"]', "meta", {
      name: "apple-mobile-web-app-title",
      content: CHAT_NAME,
    });

    upsertHeadNode('meta[name="apple-mobile-web-app-capable"]', "meta", {
      name: "apple-mobile-web-app-capable",
      content: "yes",
    });

    upsertHeadNode('meta[name="theme-color"]', "meta", {
      name: "theme-color",
      content: "#171717",
    });
  }

  function patchBranding() {
    setDocumentTitle();
    ensureFavicon();
    ensureInstallMetadata();

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

  function scheduleAccountSummaryPoll(delay) {
    if (accountSummaryTimerId) {
      window.clearTimeout(accountSummaryTimerId);
    }

    accountSummaryTimerId = window.setTimeout(function () {
      accountSummaryTimerId = null;
      if (document.hidden) {
        scheduleAccountSummaryPoll(ACCOUNT_SUMMARY_POLL_MS);
        return;
      }
      queueAccountSummaryFetch(true);
    }, delay);
  }

  function shouldRenderAccountFallback() {
    return !accountSummary && accountSummaryLoaded && accountSummaryFailureCount >= 2;
  }

  function queueAccountSummaryFetch(force) {
    if (accountSummaryPromise) return;
    if (!force && (accountSummaryLoaded || accountSummaryFailureCount > 0)) return;

    accountSummaryPromise = window
      .fetch(ACCOUNT_SUMMARY_URL, {
        cache: "no-store",
        credentials: "include",
        headers: { Accept: "application/json" },
      })
      .then(function (response) {
        if (!response.ok) {
          throw new Error("account summary unavailable");
        }
        return response.json();
      })
      .then(function (payload) {
        var summary = (payload && payload.data) || payload || null;
        if (summary && summary.username) {
          accountSummary = summary;
          accountSummaryFailureCount = 0;
        } else {
          accountSummary = null;
          accountSummaryFailureCount += 1;
        }
        accountSummaryLoaded = true;
      })
      .catch(function () {
        if (!accountSummary) {
          accountSummaryFailureCount += 1;
        }
        accountSummaryLoaded = true;
      })
      .finally(function () {
        accountSummaryPromise = null;
        scheduleAccountSummaryPoll(accountSummary ? ACCOUNT_SUMMARY_POLL_MS : ACCOUNT_SUMMARY_RETRY_MS);
        scheduleRefresh();
      });
  }

  function formatQuota(value) {
    var number = Number(value || 0);
    if (!isFinite(number)) return "0";
    return Number.isInteger(number) ? String(number) : number.toFixed(2);
  }

  function formatUsd(value) {
    var number = Number(value || 0);
    if (!isFinite(number)) number = 0;
    return (number < 0 ? "-$" : "$") + Math.abs(number).toFixed(2);
  }

  function buildQuotaTooltip(summary) {
    var quota = (summary && summary.quota) || {};
    return (
      "Daily Quota Usage\nUsed: " +
      formatQuota(quota.used) +
      " / " +
      formatQuota(quota.limit) +
      "\nRemaining: " +
      formatQuota(quota.remaining) +
      "\nBalance: " +
      formatUsd(summary && summary.balanceUsd)
    );
  }

  function applyTooltip(node, text) {
    if (!node || !text) return node;
    node.classList.add("chutes-tooltip-anchor");
    node.setAttribute("data-chutes-tooltip", text);
    node.removeAttribute("title");
    if (!node.getAttribute("aria-label")) {
      node.setAttribute("aria-label", text);
    }
    if (!node.getAttribute("data-chutes-tooltip-bound")) {
      node.setAttribute("data-chutes-tooltip-bound", "true");
      node.addEventListener("mouseenter", function () {
        showTooltip(node);
      });
      node.addEventListener("mouseleave", function () {
        hideTooltip(node);
      });
      node.addEventListener("focus", function () {
        showTooltip(node);
      });
      node.addEventListener("blur", function () {
        hideTooltip(node);
      });
    }
    return node;
  }

  function ensureTooltipLayer() {
    if (tooltipLayer && document.body && document.body.contains(tooltipLayer)) {
      return tooltipLayer;
    }

    tooltipLayer = document.createElement("div");
    tooltipLayer.className = "chutes-ui-tooltip";
    tooltipLayer.setAttribute("aria-hidden", "true");
    document.body.appendChild(tooltipLayer);
    return tooltipLayer;
  }

  function positionTooltip(target) {
    var layer = ensureTooltipLayer();
    if (!target || !layer) return;

    var rect = target.getBoundingClientRect();
    var viewportWidth = window.innerWidth || document.documentElement.clientWidth || 0;
    var viewportHeight = window.innerHeight || document.documentElement.clientHeight || 0;
    var padding = 12;
    var gap = 12;

    layer.style.maxWidth = Math.max(180, Math.min(260, viewportWidth - padding * 2)) + "px";
    layer.style.left = "0px";
    layer.style.top = "0px";
    layer.classList.add("is-visible");
    layer.style.visibility = "hidden";

    var width = layer.offsetWidth;
    var height = layer.offsetHeight;
    var left = rect.left + rect.width / 2 - width / 2;
    var top = rect.top - height - gap;

    if (left < padding) {
      left = padding;
    } else if (left + width > viewportWidth - padding) {
      left = viewportWidth - padding - width;
    }

    if (top < padding) {
      top = rect.bottom + gap;
    }

    if (top + height > viewportHeight - padding) {
      top = Math.max(padding, viewportHeight - padding - height);
    }

    layer.style.left = Math.round(left) + "px";
    layer.style.top = Math.round(top) + "px";
    layer.style.visibility = "visible";
  }

  function showTooltip(target) {
    if (!target) return;

    var text = target.getAttribute("data-chutes-tooltip");
    if (!text) return;

    var layer = ensureTooltipLayer();
    activeTooltipTarget = target;
    layer.textContent = text;
    positionTooltip(target);
  }

  function hideTooltip(target) {
    if (target && activeTooltipTarget && target !== activeTooltipTarget) {
      return;
    }

    activeTooltipTarget = null;
    if (!tooltipLayer) return;
    tooltipLayer.classList.remove("is-visible");
    tooltipLayer.style.visibility = "hidden";
  }

  function createElement(tagName, className, text) {
    var node = document.createElement(tagName);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }

  function buildQuotaRing(summary) {
    var quota = (summary && summary.quota) || {};
    var percentage = Math.max(0, Math.min(100, Number(quota.percentage || 0)));
    var ring = createElement("div", "chutes-account-ring");
    applyTooltip(ring, buildQuotaTooltip(summary));

    var svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svg.setAttribute("viewBox", "0 0 36 36");
    svg.setAttribute("class", "chutes-account-ring-svg");

    var base = document.createElementNS("http://www.w3.org/2000/svg", "path");
    base.setAttribute("class", "chutes-account-ring-base");
    base.setAttribute("stroke-width", "3");
    base.setAttribute("fill", "none");
    base.setAttribute("d", "M18 2.0845 a 15.9155 15.9155 0 0 1 0 31.831 a 15.9155 15.9155 0 0 1 0 -31.831");

    var fill = document.createElementNS("http://www.w3.org/2000/svg", "path");
    fill.setAttribute("class", "chutes-account-ring-fill");
    fill.setAttribute("stroke-width", "3");
    fill.setAttribute("fill", "none");
    fill.setAttribute("stroke-dasharray", percentage + ", 100");
    fill.setAttribute("d", "M18 2.0845 a 15.9155 15.9155 0 0 1 0 31.831 a 15.9155 15.9155 0 0 1 0 -31.831");

    svg.appendChild(base);
    svg.appendChild(fill);
    ring.appendChild(svg);
    ring.appendChild(createElement("div", "chutes-account-ring-value", Math.round(percentage) + "%"));
    return ring;
  }

  function buildActionLink(href, label, extraClass, iconUrl, iconAlt) {
    var link = createElement("a", "chutes-account-link" + (extraClass ? " " + extraClass : ""));
    link.href = href;
    if (iconUrl) {
      var icon = document.createElement("img");
      icon.className = "chutes-account-link-icon";
      icon.src = iconUrl;
      icon.alt = iconAlt || "";
      link.appendChild(icon);
    }
    link.appendChild(createElement("span", "chutes-account-link-label", label));
    return link;
  }

  function buildSummaryCard(summary) {
    var wrapper = createElement("div", "chutes-account-card");
    wrapper.setAttribute("data-chutes-account-card", "true");

    var head = createElement("div", "chutes-account-head");
    head.appendChild(buildQuotaRing(summary));

    var copy = createElement("div", "chutes-account-copy");
    copy.appendChild(createElement("div", "chutes-account-name", summary.username || "Chutes User"));
    copy.appendChild(createElement("div", "chutes-account-tier", summary.tierLabel || "Flex"));
    head.appendChild(copy);
    wrapper.appendChild(head);

    wrapper.appendChild(
      applyTooltip(
        createElement(
          "div",
          "chutes-account-quota-copy",
          "Used " +
            formatQuota(summary.quota && summary.quota.used) +
            " / " +
            formatQuota(summary.quota && summary.quota.limit),
        ),
        buildQuotaTooltip(summary),
      ),
    );

    var actions = createElement("div", "chutes-account-actions");
    actions.appendChild(
      buildActionLink(
        (summary.links && summary.links.n8nUrl) || "/n8n/",
        "Open n8n",
        "is-accent",
        N8N_LOGO_URL,
        "n8n",
      ),
    );
    actions.appendChild(
      buildActionLink(
        (summary.links && summary.links.accountUrl) || "https://chutes.ai/app/api/billing-balance#daily-quota-usage",
        "Go to Account",
      ),
    );
    actions.appendChild(
      buildActionLink(
        (summary.links && summary.links.homeUrl) || "https://chutes.ai/",
        "Chutes.ai",
      ),
    );
    wrapper.appendChild(actions);

    return wrapper;
  }

  function buildFallbackLink() {
    var link = document.createElement("a");
    link.className = "chutes-crosslink";
    link.href = "/n8n/";
    link.innerHTML =
      '<span class="chutes-crosslink-mark">' +
      '<img class="chutes-crosslink-logo chutes-crosslink-logo-n8n" src="/static/n8n-logo.svg" alt="n8n" />' +
      "</span>" +
      '<span class="chutes-crosslink-copy">' +
      '<span class="chutes-crosslink-meta">Automation</span>' +
      '<span class="chutes-crosslink-label">Open n8n</span>' +
      "</span>";
    return link;
  }

  function isCompactSidebar(sidebar) {
    if (!sidebar) return false;

    var width = 0;
    if (sidebar.getBoundingClientRect) {
      width = sidebar.getBoundingClientRect().width;
    }

    var visibleLabelCount = 0;
    MENU_MARKERS.forEach(function (marker) {
      var nodes = Array.prototype.slice.call(sidebar.querySelectorAll("*")).filter(function (node) {
        return normalizeText(node.textContent) === marker && isVisible(node);
      });
      if (nodes.length) {
        visibleLabelCount += 1;
      }
    });

    return (width > 0 && width < 150) || visibleLabelCount < 2;
  }

  function updateCompactState(slot, sidebar, container) {
    var compact = isCompactSidebar(container || sidebar);
    slot.classList.toggle("is-compact", compact);
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
      var sidebarRect = sidebar.getBoundingClientRect ? sidebar.getBoundingClientRect() : { height: 0 };
      var directChildren = Array.prototype.slice.call(sidebar.children).filter(isVisible);

      if (directChildren.length === 1 && directChildren[0].childElementCount > 0) {
        return directChildren[0];
      }

      for (var index = 0; index < directChildren.length; index += 1) {
        var child = directChildren[index];
        var className = String(child.className || "");
        var rect = child.getBoundingClientRect ? child.getBoundingClientRect() : { height: 0 };
        if (
          className.indexOf("justify-between") !== -1 ||
          className.indexOf("sidebar") !== -1 ||
          (child.childElementCount >= 2 && rect.height >= sidebarRect.height * 0.5)
        ) {
          return child;
        }
      }

      if (directChildren.length) {
        return directChildren[0];
      }
    }

    return sidebar;
  }

  function findFooterAnchor(parent, slot) {
    if (!parent) return null;

    var directChildren = Array.prototype.slice.call(parent.children).filter(function (child) {
      return child !== slot && isVisible(child);
    });

    var footerChild = directChildren
      .slice()
      .reverse()
      .find(function (child) {
        var text = normalizeText(child.textContent);
        return /settings|profile|sign out|logout|sirouk2|free|plus|pro|enterprise|admin/i.test(text);
      });

    if (footerChild) {
      return footerChild;
    }

    var stickyChildren = directChildren.filter(function (child) {
      return String(child.className || "").indexOf("sticky") !== -1;
    });

    if (stickyChildren.length) {
      return stickyChildren[stickyChildren.length - 1];
    }

    return directChildren.length ? directChildren[directChildren.length - 1] : null;
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

  function ensureSidebarCard() {
    var sidebar = findSidebar();
    if (!sidebar) return;

    queueAccountSummaryFetch();

    var hasSummary = !!(accountSummary && accountSummary.username);
    if (!hasSummary && !shouldRenderAccountFallback()) {
      Array.prototype.forEach.call(
        document.querySelectorAll('[data-chutes-nav-slot="n8n"]'),
        function (slot) {
          slot.remove();
        },
      );
      scheduleRefresh();
      return;
    }

    var container = findInsertionParent(sidebar);
    if (!container) return;

    var slot = container.querySelector('[data-chutes-nav-slot="n8n"]');
    if (!slot) {
      slot = document.createElement("div");
      slot.setAttribute("data-chutes-nav-slot", "n8n");
    }

    if (!slot.hasAttribute("data-chutes-rendered")) {
      slot.innerHTML = "";
      if (hasSummary) {
        slot.appendChild(buildSummaryCard(accountSummary));
      } else if (shouldRenderAccountFallback()) {
        slot.appendChild(buildFallbackLink());
      }
      slot.setAttribute("data-chutes-rendered", "true");
    }

    var needsSummary = hasSummary && !slot.querySelector(".chutes-account-card");
    if (needsSummary) {
      slot.innerHTML = "";
      slot.appendChild(buildSummaryCard(accountSummary));
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

    updateCompactState(slot, sidebar, container);
  }

  function normalizeText(value) {
    return String(value || "").replace(/\s+/g, " ").trim();
  }

  function refresh() {
    scheduled = false;
    patchBranding();
    ensureSidebarCard();
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
  document.addEventListener("visibilitychange", function () {
    if (!document.hidden) {
      queueAccountSummaryFetch(true);
    }
  });
  window.addEventListener(
    "scroll",
    function () {
      if (activeTooltipTarget) {
        positionTooltip(activeTooltipTarget);
      }
    },
    true,
  );

  var observer = new MutationObserver(scheduleRefresh);
  observer.observe(document.documentElement, { childList: true, subtree: true });
})();
