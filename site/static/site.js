// Theme toggle. The stored choice wins over the system preference; with
// nothing stored the page follows prefers-color-scheme.
(function () {
  var button = document.querySelector(".theme-toggle");
  if (!button) return;

  function current() {
    var explicit = document.documentElement.getAttribute("data-theme");
    if (explicit) return explicit;
    return window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
  }

  button.addEventListener("click", function () {
    var next = current() === "dark" ? "light" : "dark";
    document.documentElement.setAttribute("data-theme", next);
    try {
      localStorage.setItem("theme", next);
    } catch (e) {}
  });
})();

// Mobile navigation. The sidebar is hidden at phone widths and this button
// shows it; on wider screens the button itself is hidden by CSS.
(function () {
  var button = document.querySelector(".menu-toggle");
  var sidebar = document.getElementById("sidebar");
  if (!button || !sidebar) return;
  button.addEventListener("click", function () {
    var open = sidebar.classList.toggle("open");
    button.setAttribute("aria-expanded", open ? "true" : "false");
  });
})();
