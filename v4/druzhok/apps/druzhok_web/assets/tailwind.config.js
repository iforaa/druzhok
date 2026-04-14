const plugin = require("tailwindcss/plugin")
const fs = require("fs")
const path = require("path")

module.exports = {
  content: [
    "./js/**/*.js",
    "../lib/druzhok_web_web.ex",
    "../lib/druzhok_web_web/**/*.*ex"
  ],
  theme: {
    extend: {
      colors: {
        bg:      "#0B0B0D",
        panel:   "#111113",
        raised:  "#17171A",
        line:    "rgb(232 228 216 / 0.08)",
        line2:   "rgb(232 228 216 / 0.16)",
        fg:      "#E8E4D8",
        muted:   "rgb(232 228 216 / 0.55)",
        subtle:  "rgb(232 228 216 / 0.32)",
        faint:   "rgb(232 228 216 / 0.18)",
        accent:  "#FD4F00",
        ok:      "#57C36A",
        err:     "#C44A45",
        warn:    "#D4A23A",
        idle:    "#8A8176",
        brand:   "#FD4F00",
      },
      fontFamily: {
        display: ['"JetBrains Mono"', "ui-monospace", "SFMono-Regular", "Menlo", "monospace"],
        sans:    ['"IBM Plex Sans"', "ui-sans-serif", "system-ui", "sans-serif"],
        mono:    ['"JetBrains Mono"', "ui-monospace", "monospace"],
      },
      letterSpacing: {
        wider2: "0.14em",
        caps:   "0.22em",
      },
      boxShadow: {
        cut: "inset 0 -1px 0 0 rgb(232 228 216 / 0.16)",
      },
      keyframes: {
        reveal: {
          from: { opacity: "0", transform: "translateY(-3px)" },
          to:   { opacity: "1", transform: "translateY(0)" },
        },
        "dot-pulse": {
          "0%, 100%": { transform: "scale(1)", opacity: "1" },
          "50%":      { transform: "scale(1.6)", opacity: "0.5" },
        },
        scanshift: {
          from: { backgroundPosition: "0 0" },
          to:   { backgroundPosition: "0 3px" },
        },
      },
      animation: {
        reveal: "reveal 280ms cubic-bezier(0.22, 1, 0.36, 1) both",
        "dot-pulse": "dot-pulse 1.4s ease-in-out infinite",
      },
    },
  },
  plugins: [
    require("@tailwindcss/forms"),
    plugin(({addVariant}) => addVariant("phx-click-loading", [".phx-click-loading&", ".phx-click-loading &"])),
    plugin(({addVariant}) => addVariant("phx-submit-loading", [".phx-submit-loading&", ".phx-submit-loading &"])),
    plugin(({addVariant}) => addVariant("phx-change-loading", [".phx-change-loading&", ".phx-change-loading &"])),

    // Heroicons
    plugin(function({matchComponents, theme}) {
      let iconsDir = path.join(__dirname, "../../../deps/heroicons/optimized")
      let values = {}
      let icons = [
        ["", "/24/outline"],
        ["-solid", "/24/solid"],
        ["-mini", "/20/solid"],
        ["-micro", "/16/solid"]
      ]
      icons.forEach(([suffix, dir]) => {
        fs.readdirSync(path.join(iconsDir, dir)).forEach(file => {
          let name = path.basename(file, ".svg") + suffix
          values[name] = {name, fullPath: path.join(iconsDir, dir, file)}
        })
      })
      matchComponents({
        "hero": ({name, fullPath}) => {
          let content = fs.readFileSync(fullPath).toString().replace(/\r?\n|\r/g, "")
          let size = theme("spacing.6")
          if (name.endsWith("-mini")) {
            size = theme("spacing.5")
          } else if (name.endsWith("-micro")) {
            size = theme("spacing.4")
          }
          return {
            [`--hero-${name}`]: `url('data:image/svg+xml;utf8,${content}')`,
            "-webkit-mask": `var(--hero-${name})`,
            "mask": `var(--hero-${name})`,
            "mask-repeat": "no-repeat",
            "background-color": "currentColor",
            "vertical-align": "middle",
            "display": "inline-block",
            "width": size,
            "height": size
          }
        }
      }, {values})
    })
  ]
}
