import re, sys
DEFAULTS = {
  'font': 'system-ui, -apple-system, "Segoe UI", sans-serif',
  'font-mono': 'ui-monospace, SFMono-Regular, Menlo, monospace',
  'text': '#1b1f27', 'muted': '#5a6272', 'faint': '#8a92a1',
  'surface': '#ffffff', 'surface-soft': '#f6f7f9', 'surface-raised': '#eef0f4', 'surface-input': '#f9fafb',
  'line': '#e2e5eb', 'line-strong': '#cdd2da',
  'accent': '#2f5bd3', 'accent-strong': '#2448ad', 'on-accent': '#ffffff',
  'success': '#1f7a4d', 'warning': '#b26b00', 'warning-soft': '#fbf1de', 'danger': '#c2352b',
  'secondary-fill': '#f6f7f9', 'secondary-border': '#cdd2da', 'secondary-hover': '#eef0f4',
  'surface-overlay': '#ffffff', 'surface-backdrop': 'rgb(0 0 0 / .35)',
  'pill-fill': 'var(--byos-surface, #ffffff)',
  'pill-border': 'var(--byos-accent, #2f5bd3)', 'pill-text': 'var(--byos-accent-strong, #2448ad)',
  'radius': '8px', 'radius-lg': '14px', 'shadow': '0 24px 60px -24px rgb(0 0 0 / .35)',
}
src = open(sys.argv[1]).read()
def sub(m):
  name = m.group(1)
  return f'var(--byos-{name}, {DEFAULTS[name]})'
out = re.sub(r'\$([a-z-]+[a-z])', sub, src)
open(sys.argv[2], 'w').write(out)
