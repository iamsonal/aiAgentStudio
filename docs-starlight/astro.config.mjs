import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

const basePath = process.env.DOCS_BASE_PATH || '/';
const normalizedBasePath = basePath === '/' ? '/' : basePath.replace(/\/$/, '');
const baseAssetPrefix = normalizedBasePath === '/' ? '' : normalizedBasePath;

export default defineConfig({
  site: 'https://iamsonal.github.io',
  base: normalizedBasePath,
  integrations: [
    starlight({
      title: 'AI Agent Studio',
      description:
        'Enterprise-grade AI platform for Salesforce with secure orchestration, observability, and multi-provider LLM support.',
      logo: {
        src: './public/logo.png',
        alt: 'AI Agent Studio'
      },
      social: {
        github: 'https://github.com/iamsonal/aiAgentStudio'
      },
      head: [
        {
          tag: 'script',
          attrs: { type: 'module', src: `${baseAssetPrefix}/mermaid-init.js` }
        }
      ],
      customCss: ['./src/styles/custom.css'],
      sidebar: [
        {
          label: 'Start Here',
          items: [{ label: 'Overview', link: '/' }]
        },
        {
          label: 'Guides',
          autogenerate: { directory: 'guides' }
        },
        {
          label: 'Reference',
          autogenerate: { directory: 'reference' }
        }
      ]
    })
  ]
});
