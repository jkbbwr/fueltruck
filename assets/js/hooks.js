// LogStream: high-throughput log panel.
//
// Live batches arrive via `log_batch` push events (filtered by source). The hook
// appends rows to a bounded list, autoscrolls while pinned to the bottom, and — on
// scrolling near the top — pulls older history from the server via `log_history`
// (a pushEvent with reply), prepending it while preserving scroll position.
const LogStream = {
  mounted() {
    this.source = this.el.dataset.source
    this.max = parseInt(this.el.dataset.max || "4000", 10)
    this.list = this.el.querySelector("[data-log-list]")
    this.oldest = null
    this.newest = null
    this.pinned = true
    this.loading = false

    this.el.addEventListener("scroll", () => this.onScroll())

    this.handleEvent("log_batch", ({source, lines}) => {
      if (source !== this.source || !lines || !lines.length) return
      this.append(lines)
    })

    this.handleEvent("log_reset", ({source}) => {
      if (source !== this.source) return
      this.list.innerHTML = ""
      this.oldest = this.newest = null
      this.pinned = true
    })

    // Ask the server for a fresh snapshot now that we're connected.
    this.pushEvent("log_snapshot", {source: this.source}, (reply) => {
      if (reply && reply.lines) this.append(reply.lines)
      this.scrollToBottom()
    })
  },

  onScroll() {
    const el = this.el
    this.pinned = (el.scrollHeight - el.scrollTop - el.clientHeight) < 48
    if (el.scrollTop < 80 && !this.loading && this.oldest && this.oldest > 1) {
      this.loadOlder()
    }
  },

  loadOlder() {
    this.loading = true
    const before = this.oldest
    const prevHeight = this.el.scrollHeight
    this.pushEvent("log_history", {source: this.source, before_seq: before}, (reply) => {
      if (reply && reply.lines && reply.lines.length) {
        this.prepend(reply.lines)
        this.el.scrollTop = this.el.scrollHeight - prevHeight
      }
      this.loading = false
    })
  },

  row(seq, text) {
    const div = document.createElement("div")
    div.className = "log-line"
    div.dataset.seq = seq
    div.textContent = text
    return div
  },

  append(lines) {
    const frag = document.createDocumentFragment()
    for (const [seq, text] of lines) {
      frag.appendChild(this.row(seq, text))
      if (this.oldest === null || seq < this.oldest) this.oldest = seq
      if (this.newest === null || seq > this.newest) this.newest = seq
    }
    this.list.appendChild(frag)
    this.trimTop()
    if (this.pinned) this.scrollToBottom()
  },

  prepend(lines) {
    const frag = document.createDocumentFragment()
    for (const [seq, text] of lines) {
      frag.appendChild(this.row(seq, text))
      if (this.oldest === null || seq < this.oldest) this.oldest = seq
    }
    this.list.insertBefore(frag, this.list.firstChild)
  },

  trimTop() {
    while (this.list.childElementCount > this.max) {
      const first = this.list.firstChild
      const next = first.nextSibling
      if (next && next.dataset && next.dataset.seq) {
        this.oldest = parseInt(next.dataset.seq, 10)
      }
      this.list.removeChild(first)
    }
  },

  scrollToBottom() {
    this.el.scrollTop = this.el.scrollHeight
  },
}

// Copy: copies data-clipboard to the clipboard on click, with brief feedback.
const Copy = {
  mounted() {
    this.el.addEventListener("click", () => {
      const text = this.el.dataset.clipboard || ""
      const done = () => {
        const original = this.el.innerHTML
        this.el.textContent = "Copied!"
        setTimeout(() => { this.el.innerHTML = original }, 1200)
      }
      if (navigator.clipboard) {
        navigator.clipboard.writeText(text).then(done).catch(() => {})
      }
    })
  },
}

// ScrollBottom: keep an element pinned to the bottom as its content grows, unless the
// user has scrolled up. Captures pin state before the patch so a mid-update content
// change doesn't lose it.
const ScrollBottom = {
  mounted() {
    this.el.scrollTop = this.el.scrollHeight
  },
  beforeUpdate() {
    this.pinned = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < 60
  },
  updated() {
    if (this.pinned) this.el.scrollTop = this.el.scrollHeight
  },
}

// Preserve a <details> element's open/closed state across LiveView patches.
// `open` is a runtime DOM property, not in the server-rendered HTML, so morphdom
// resets it on every re-render (the deploy page re-renders on each proc-status tick).
const DetailsKeep = {
  beforeUpdate() {
    this.wasOpen = this.el.open
  },
  updated() {
    this.el.open = this.wasOpen
  },
}

export default {LogStream, Copy, ScrollBottom, DetailsKeep}
