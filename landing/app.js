document.documentElement.classList.add("is-ready");

// Hide the n8n launch card when n8n is disabled.
// The template sets data-n8n-enabled on <body> at render time.
(function () {
  if (document.body.getAttribute("data-n8n-enabled") === "false") {
    var card = document.querySelector(".n8n-card");
    if (card) card.remove();
  }
})();
