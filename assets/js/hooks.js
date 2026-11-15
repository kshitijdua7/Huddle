// Client-side hooks for the board page. Each hook is attached to an element
// with `phx-hook="Name"` in lib/huddle_web/live/board_live.ex.

const COLOR = /^#[0-9a-fA-F]{6}$/

// Clears a form after LiveView has read its values, so the input is ready
// for the next card or chat message without losing focus.
const ResetOnSubmit = {
  mounted() {
    this.el.addEventListener("submit", () => {
      setTimeout(() => this.el.reset(), 0)
    })
  },
}

// Keeps the chat scrolled to the newest message, unless the reader has
// scrolled up to look at older ones.
const ChatScroll = {
  mounted() {
    this.pinned = true
    this.el.addEventListener("scroll", () => {
      const distance = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight
      this.pinned = distance < 80
    })
    this.observer = new MutationObserver(() => {
      if (this.pinned) this.scrollToBottom()
    })
    this.observer.observe(this.el, {childList: true})
    this.scrollToBottom()
  },
  destroyed() {
    this.observer.disconnect()
  },
  scrollToBottom() {
    this.el.scrollTop = this.el.scrollHeight
  },
}

// Shows the shared countdown. The server only sends the moment the timer
// ends (data-ends-at); the ticking happens here, so there is no message per
// second.
const Countdown = {
  mounted() {
    this.display = this.el.querySelector("#timer-display")
    this.interval = setInterval(() => this.tick(), 250)
    this.tick()
  },
  updated() {
    this.tick()
  },
  destroyed() {
    clearInterval(this.interval)
  },
  tick() {
    const endsAt = this.el.dataset.endsAt
    if (!endsAt) {
      this.display.textContent = ""
      this.display.classList.remove("timer-ending")
      return
    }
    const seconds = Math.max(0, Math.ceil((new Date(endsAt).getTime() - Date.now()) / 1000))
    const minutes = Math.floor(seconds / 60)
    this.display.textContent = `${minutes}:${String(seconds % 60).padStart(2, "0")}`
    this.display.classList.toggle("timer-ending", seconds <= 10)
  },
}

// Sends this browser's pointer position (as a fraction of the board area, so
// it maps onto screens of any size) and draws everyone else's.
const Cursors = {
  mounted() {
    this.cursors = new Map()
    this.canvas = this.el.parentElement

    let lastSent = 0
    this.onMove = event => {
      const now = performance.now()
      if (now - lastSent < 50) return
      lastSent = now

      const rect = this.canvas.getBoundingClientRect()
      if (rect.width === 0 || rect.height === 0) return
      this.pushEvent("cursor", {
        x: (event.clientX - rect.left) / rect.width,
        y: (event.clientY - rect.top) / rect.height,
      })
    }
    this.canvas.addEventListener("mousemove", this.onMove)

    this.handleEvent("cursor", payload => this.draw(payload))
    this.sweeper = setInterval(() => this.sweep(), 1000)
  },
  destroyed() {
    this.canvas.removeEventListener("mousemove", this.onMove)
    clearInterval(this.sweeper)
  },
  draw({id, name, color, x, y}) {
    let cursor = this.cursors.get(id)
    if (!cursor) {
      cursor = {el: this.build(), seen: 0}
      this.cursors.set(id, cursor)
      this.el.appendChild(cursor.el)
    }

    const safeColor = COLOR.test(color) ? color : "#f59e0b"
    cursor.el.querySelector("path").setAttribute("fill", safeColor)
    const label = cursor.el.querySelector("span")
    label.textContent = name
    label.style.backgroundColor = safeColor

    const rect = this.el.getBoundingClientRect()
    cursor.el.style.transform = `translate(${x * rect.width}px, ${y * rect.height}px)`
    cursor.el.classList.remove("is-idle")
    cursor.seen = Date.now()
  },
  build() {
    const el = document.createElement("div")
    el.className = "remote-cursor"

    const namespace = "http://www.w3.org/2000/svg"
    const svg = document.createElementNS(namespace, "svg")
    svg.setAttribute("viewBox", "0 0 24 24")
    const path = document.createElementNS(namespace, "path")
    path.setAttribute("d", "M4 2l16 9-7 2-3 7z")
    path.setAttribute("stroke", "#fff")
    path.setAttribute("stroke-width", "1.5")
    path.setAttribute("stroke-linejoin", "round")
    svg.appendChild(path)

    el.appendChild(svg)
    el.appendChild(document.createElement("span"))
    return el
  },
  // Fade cursors that stopped moving, then remove them.
  sweep() {
    const now = Date.now()
    for (const [id, cursor] of this.cursors) {
      const idle = now - cursor.seen
      if (idle > 15000) {
        cursor.el.remove()
        this.cursors.delete(id)
      } else if (idle > 5000) {
        cursor.el.classList.add("is-idle")
      }
    }
  },
}

// Everything that happens on the columns area:
//
//   * drag and drop for cards, using the browser's native drag events
//   * double-click a card to edit it
//   * while presenting: clicking a card spotlights it for everyone, and
//     sideways scrolling is sent to the people following
//   * while following: scroll to where the presenter is
//
// Listeners are on the column container (event delegation), so they keep
// working when LiveView re-renders the cards.
const Board = {
  mounted() {
    this.dragId = null

    this.el.addEventListener("dragstart", event => {
      const card = this.closest(event, "[data-card-id]")
      if (!card || this.readOnly()) return
      this.dragId = card.dataset.cardId
      event.dataTransfer.effectAllowed = "move"
      event.dataTransfer.setData("text/plain", this.dragId)
      requestAnimationFrame(() => card.classList.add("is-dragging"))
    })

    this.el.addEventListener("dragend", () => this.finish())

    this.el.addEventListener("dragover", event => {
      const zone = this.closest(event, "[data-column-id]")
      if (!zone || !this.dragId) return
      event.preventDefault()
      event.dataTransfer.dropEffect = "move"
      this.highlight(zone)
    })

    this.el.addEventListener("drop", event => {
      const zone = this.closest(event, "[data-column-id]")
      if (!zone || !this.dragId) return
      event.preventDefault()

      // Drop in front of the first visible card whose middle is below the
      // pointer. Cards hidden by a filter keep their place.
      const others = [...zone.querySelectorAll("[data-card-id]")].filter(
        card => card.dataset.cardId !== this.dragId
      )
      const next = others.find(card => {
        if (card.offsetParent === null) return false
        const rect = card.getBoundingClientRect()
        return event.clientY <= rect.top + rect.height / 2
      })

      this.pushEvent("move_card", {
        id: this.dragId,
        column_id: zone.dataset.columnId,
        index: next ? others.indexOf(next) : others.length,
      })
      this.finish()
    })

    this.el.addEventListener("dblclick", event => {
      const card = this.cardBody(event)
      if (card && !this.readOnly()) this.pushEvent("edit_card", {id: card.dataset.cardId})
    })

    this.el.addEventListener("click", event => {
      const card = this.cardBody(event)
      if (card && this.presenting()) this.pushEvent("spotlight", {id: card.dataset.cardId})
    })

    let lastSent = 0
    this.el.addEventListener("scroll", () => {
      const now = performance.now()
      if (!this.presenting() || now - lastSent < 80) return
      lastSent = now
      const range = this.el.scrollWidth - this.el.clientWidth
      this.pushEvent("present_scroll", {x: range > 0 ? this.el.scrollLeft / range : 0})
    })

    this.handleEvent("follow_scroll", ({x}) => {
      const range = this.el.scrollWidth - this.el.clientWidth
      this.el.scrollTo({left: x * range, behavior: "smooth"})
    })

    this.handleEvent("spotlight", ({id}) => {
      const card = document.getElementById(`card-${id}`)
      if (card) card.scrollIntoView({behavior: "smooth", block: "center", inline: "center"})
    })
  },
  readOnly() {
    return this.el.dataset.readOnly === "true"
  },
  presenting() {
    return this.el.dataset.presenting === "true"
  },
  closest(event, selector) {
    return event.target instanceof Element ? event.target.closest(selector) : null
  },
  // The card under the pointer, unless the pointer is on one of its controls.
  cardBody(event) {
    if (this.closest(event, "button, a, input, form, label")) return null
    return this.closest(event, "[data-card-id]")
  },
  highlight(zone) {
    this.el.querySelectorAll(".is-drop-target").forEach(el => {
      if (el !== zone) el.classList.remove("is-drop-target")
    })
    zone.classList.add("is-drop-target")
  },
  finish() {
    this.dragId = null
    this.el
      .querySelectorAll(".is-dragging, .is-drop-target")
      .forEach(el => el.classList.remove("is-dragging", "is-drop-target"))
  },
}

// Copies data-copy to the clipboard and briefly swaps the button's label for
// its "copied" one. The element needs phx-update="ignore".
const Copy = {
  mounted() {
    this.el.addEventListener("click", async () => {
      await this.copy(this.el.dataset.copy)
      this.el.classList.add("is-copied")
      clearTimeout(this.timeout)
      this.timeout = setTimeout(() => this.el.classList.remove("is-copied"), 1600)
    })
  },
  destroyed() {
    clearTimeout(this.timeout)
  },
  async copy(text) {
    try {
      await navigator.clipboard.writeText(text)
    } catch (_error) {
      // navigator.clipboard only exists on https and localhost. Fall back to
      // a temporary text field for plain http on a local network.
      const field = document.createElement("textarea")
      field.value = text
      field.style.position = "fixed"
      field.style.opacity = "0"
      document.body.appendChild(field)
      field.select()
      document.execCommand("copy")
      field.remove()
    }
  },
}

// A burst of confetti on a full-screen canvas when the server says so
// (the shared timer finishing). The canvas needs phx-update="ignore".
const Confetti = {
  mounted() {
    this.handleEvent("confetti", () => this.burst())
  },
  destroyed() {
    cancelAnimationFrame(this.frame)
  },
  burst() {
    if (matchMedia("(prefers-reduced-motion: reduce)").matches) return

    const canvas = this.el
    const context = canvas.getContext("2d")
    const ratio = window.devicePixelRatio || 1
    canvas.width = window.innerWidth * ratio
    canvas.height = window.innerHeight * ratio
    context.scale(ratio, ratio)

    const colors = ["#f59e0b", "#ec4899", "#8b5cf6", "#10b981", "#0ea5e9", "#f43f5e"]
    const pieces = Array.from({length: 140}, () => ({
      x: window.innerWidth / 2,
      y: window.innerHeight / 3,
      vx: (Math.random() - 0.5) * 18,
      vy: Math.random() * -14 - 4,
      size: Math.random() * 7 + 4,
      spin: Math.random() * Math.PI,
      spinSpeed: (Math.random() - 0.5) * 0.4,
      color: colors[Math.floor(Math.random() * colors.length)],
    }))

    const started = performance.now()
    cancelAnimationFrame(this.frame)

    const step = now => {
      const age = now - started
      context.clearRect(0, 0, window.innerWidth, window.innerHeight)
      if (age > 3200) return

      context.globalAlpha = Math.min(1, (3200 - age) / 800)
      for (const piece of pieces) {
        piece.vy += 0.35
        piece.vx *= 0.99
        piece.x += piece.vx
        piece.y += piece.vy
        piece.spin += piece.spinSpeed

        context.save()
        context.translate(piece.x, piece.y)
        context.rotate(piece.spin)
        context.fillStyle = piece.color
        context.fillRect(-piece.size / 2, -piece.size / 4, piece.size, piece.size / 2)
        context.restore()
      }
      this.frame = requestAnimationFrame(step)
    }
    this.frame = requestAnimationFrame(step)
  },
}

export const hooks = {ResetOnSubmit, ChatScroll, Countdown, Cursors, Board, Copy, Confetti}
