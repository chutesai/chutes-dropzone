(function () {
  var ACCOUNT_SUMMARY_URL = "/n8n/rest/sso/chutes/account-summary";
  var CHUTES_LOGO_URL = "/n8n/static/chutes-logo.svg";
  var ACCOUNT_SUMMARY_POLL_MS = 60000;
  var ACCOUNT_SUMMARY_RETRY_MS = 5000;
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
    var style = window.getComputedStyle ? window.getComputedStyle(node) : null;
    if (!style) return true;
    return style.display !== "none" && style.visibility !== "hidden" && style.opacity !== "0";
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

    layer.style.maxWidth = Math.max(180, Math.min(240, viewportWidth - padding * 2)) + "px";
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

    if (summary.avatarUrl) {
      var avatar = createElement("div", "chutes-account-avatar");
      var avatarImage = document.createElement("img");
      avatarImage.src = summary.avatarUrl;
      avatarImage.alt = summary.username;
      avatarImage.className = "chutes-account-avatar-image";
      avatar.appendChild(avatarImage);
      head.appendChild(avatar);
    }

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
        (summary.links && summary.links.chatUrl) || "/chat/",
        "Open Chat",
        "is-accent",
        CHUTES_LOGO_URL,
        "Chutes",
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
    link.href = "/chat/";
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

  function updateCompactState(slot, sideMenu) {
    var compact = !!sideMenu && sideMenu.getBoundingClientRect().width < 112;
    slot.classList.toggle("is-compact", compact);
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

    return children.length ? children[children.length - 1] : null;
  }

  function ensureSidebarLink() {
    var sideMenu = document.getElementById("side-menu");
    if (!sideMenu) return;

    queueAccountSummaryFetch();

    var hasSummary = !!(accountSummary && accountSummary.username);
    if (!hasSummary && !shouldRenderAccountFallback()) {
      Array.prototype.forEach.call(
        document.querySelectorAll('[data-chutes-nav-slot="chat"]'),
        function (slot) {
          slot.remove();
        },
      );
      scheduleRefresh();
      return;
    }

    var slot = sideMenu.querySelector('[data-chutes-nav-slot="chat"]');
    if (!slot) {
      slot = document.createElement("div");
      slot.setAttribute("data-chutes-nav-slot", "chat");
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

    var anchor = findFooterAnchor(sideMenu, slot);
    cleanupDuplicateSlots(slot);

    if (!anchor) {
      if (slot.parentNode === sideMenu) {
        sideMenu.removeChild(slot);
      }
      scheduleRefresh();
      return;
    }

    if (slot.parentNode !== sideMenu || slot.nextElementSibling !== anchor) {
      sideMenu.insertBefore(slot, anchor);
    }

    updateCompactState(slot, sideMenu);
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
