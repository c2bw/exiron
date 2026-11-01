// LiveView owns the streamed rows. Capture the reading position on scroll:
// a stream reset can remove rows before the beforeUpdate hook is called.
export default {
  mounted() {
    this.filterKey = this.el.dataset.filterKey
    this.capturePosition = () => {
      const top = this.el.getBoundingClientRect().top
      const row = Array.from(this.el.querySelectorAll("[data-outcome]"))
        .find(row => row.getBoundingClientRect().bottom > top)
      this.position = {
        top: this.el.scrollTop,
        anchor: row && {id: row.id, offset: row.getBoundingClientRect().top - top},
      }
    }
    this.el.addEventListener("scroll", this.capturePosition, {passive: true})
    this.capturePosition()
  },

  updated() {
    const filterKey = this.el.dataset.filterKey
    const {top, anchor} = this.position
    if (filterKey !== this.filterKey || top <= 1) {
      this.el.scrollTop = 0
    } else {
      const row = anchor && this.el.querySelector(`#${CSS.escape(anchor.id)}`)
      if (row) {
        const offset = row.getBoundingClientRect().top - this.el.getBoundingClientRect().top
        this.el.scrollTop += offset - anchor.offset
      } else {
        // The anchor may have aged out of the bounded history.
        this.el.scrollTop = top
      }
    }
    this.filterKey = filterKey
    this.capturePosition()
  },

  destroyed() {
    this.el.removeEventListener("scroll", this.capturePosition)
  },
}
