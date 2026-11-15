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

    const safeColor = COLOR.test(color) ? color : "#6366f1"
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

// Drag and drop for cards, using the browser's native drag events. Listeners
// are on the column container (event delegation), so they keep working when
// LiveView re-renders the cards.
const BoardDnD = {
  mounted() {
    this.dragId = null

    this.el.addEventListener("dragstart", event => {
      const card = this.closest(event, "[data-card-id]")
      if (!card) return
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

      // The new index is the number of other cards above the pointer.
      const others = [...zone.querySelectorAll("[data-card-id]")].filter(
        card => card.dataset.cardId !== this.dragId
      )
      const index = others.filter(card => {
        const rect = card.getBoundingClientRect()
        return event.clientY > rect.top + rect.height / 2
      }).length

      this.pushEvent("move_card", {
        id: this.dragId,
        column_id: zone.dataset.columnId,
        index: index,
      })
      this.finish()
    })
  },
  closest(event, selector) {
    return event.target instanceof Element ? event.target.closest(selector) : null
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

export const hooks = {ResetOnSubmit, ChatScroll, Countdown, Cursors, BoardDnD}
