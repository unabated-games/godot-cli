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

// Copy buttons. Each one names the element whose text it copies, and says so
// for a moment afterwards.
(function () {
  document.querySelectorAll("[data-copy]").forEach(function (button) {
    button.addEventListener("click", function () {
      var source = document.getElementById(button.getAttribute("data-copy"));
      if (!source || !navigator.clipboard) return;
      var text = source.textContent.replace(/^\$ /gm, "");
      navigator.clipboard.writeText(text).then(function () {
        var label = button.innerHTML;
        button.textContent = "Copied";
        setTimeout(function () {
          button.innerHTML = label;
        }, 1400);
      });
    });
  });
})();

// The demo game. Nothing is downloaded until Play is pressed; then the still
// frame is swapped for the game itself.
(function () {
  var button = document.querySelector("[data-demo]");
  if (!button) return;
  button.addEventListener("click", function () {
    var screen = button.parentNode;
    var frame = document.createElement("iframe");
    frame.src = button.getAttribute("data-demo");
    frame.title = "Gem Grove";
    frame.allow = "autoplay; fullscreen";
    screen.classList.remove("poster");
    screen.innerHTML = "";
    screen.appendChild(frame);
    frame.focus();
  });
})();
