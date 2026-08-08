// Copies the install command from any [data-copy] button, falling back to
// selecting the text when the async clipboard API is unavailable.
for (const button of document.querySelectorAll("[data-copy]")) {
  button.addEventListener("click", async () => {
    const target = document.getElementById(button.dataset.copy);
    if (!target) return;

    let copied = true;
    try {
      await navigator.clipboard.writeText(target.textContent.trim());
    } catch {
      copied = false;
      const range = document.createRange();
      range.selectNodeContents(target);
      const selection = window.getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
    }

    button.textContent = copied ? "Copied" : "Press ⌘C";
    button.classList.add("is-done");
    window.setTimeout(() => {
      button.textContent = "Copy";
      button.classList.remove("is-done");
    }, 1600);
  });
}
