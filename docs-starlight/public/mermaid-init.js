import mermaid from 'https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs';

const MERMAID_SELECTOR = 'pre[data-language="mermaid"]';

function getMermaidSource(pre) {
  const copyButton = pre.closest('.expressive-code')?.querySelector('button[data-code]');
  const encodedSource = copyButton?.getAttribute('data-code');
  if (encodedSource) {
    return encodedSource.split('\u007f').join('\n').trim();
  }

  const lineNodes = pre.querySelectorAll('.ec-line .code');
  if (lineNodes.length > 0) {
    return Array.from(lineNodes)
      .map((line) => line.textContent || '')
      .join('\n')
      .trim();
  }

  return (pre.textContent || '').trim();
}

async function renderMermaidDiagrams() {
  const mermaidBlocks = document.querySelectorAll(MERMAID_SELECTOR);
  if (mermaidBlocks.length === 0) return;

  const theme = document.documentElement.classList.contains('dark') ? 'dark' : 'neutral';
  mermaid.initialize({
    startOnLoad: false,
    securityLevel: 'loose',
    theme
  });

  let index = 0;
  for (const pre of mermaidBlocks) {
    const source = getMermaidSource(pre);
    if (!source) continue;

    const host = document.createElement('div');
    host.className = 'mermaid';

    const frame = pre.closest('figure') || pre;
    frame.replaceWith(host);

    try {
      const id = `mermaid-${Date.now()}-${index++}`;
      const { svg, bindFunctions } = await mermaid.render(id, source);
      host.innerHTML = svg;
      if (typeof bindFunctions === 'function') bindFunctions(host);
    } catch (error) {
      host.textContent = source;
      host.classList.add('mermaid-fallback');
      console.error('Mermaid render failed:', error);
    }
  }
}

async function boot() {
  await renderMermaidDiagrams();
}

document.addEventListener('DOMContentLoaded', boot);
document.addEventListener('astro:page-load', boot);
