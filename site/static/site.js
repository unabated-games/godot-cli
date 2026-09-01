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
