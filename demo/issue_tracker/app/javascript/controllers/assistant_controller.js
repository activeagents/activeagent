import { Controller } from "@hotwired/stimulus"

// The chat panel: keeps the log scrolled to the newest turn, and shows the
// message and a waiting row while the agent's run is in flight. The server
// answers with a redirect, so the page (and the issues on it) re-renders with
// whatever the agent changed.
export default class extends Controller {
  static targets = ["log", "form", "input", "send"]

  connect() {
    this.logTarget.scrollTop = this.logTarget.scrollHeight
  }

  keydown(event) {
    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault()
      this.formTarget.requestSubmit()
    }
  }

  sending() {
    const text = this.inputTarget.value.trim()
    if (!text) return

    this.logTarget.querySelector(".assistant-empty")?.remove()
    this.append("turn turn-user", text)
    this.append("turn turn-assistant turn-waiting", "Working…")
    this.logTarget.scrollTop = this.logTarget.scrollHeight
    this.inputTarget.readOnly = true
    this.sendTarget.disabled = true
  }

  append(className, text) {
    const row = document.createElement("div")
    row.className = className
    const paragraph = document.createElement("p")
    paragraph.textContent = text
    row.append(paragraph)
    this.logTarget.append(row)
  }
}
